#!/usr/bin/env bash
set -Eeuo pipefail

SERVICE_NAME="mihomo.service"

log() {
  printf '[tun] %s\n' "$*"
}

die() {
  printf '[tun] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  bash advanced/client-tun.sh enable
  bash advanced/client-tun.sh disable
  bash advanced/client-tun.sh status
  bash advanced/client-tun.sh help
EOF
}

run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
    return
  fi

  command -v sudo >/dev/null 2>&1 || return 1
  sudo "$@"
}

pkg_manager() {
  local manager

  for manager in apt-get dnf yum zypper apk; do
    if command -v "$manager" >/dev/null 2>&1; then
      printf '%s' "$manager"
      return 0
    fi
  done

  return 1
}

install_packages() {
  local manager

  [ "$#" -gt 0 ] || return 0
  manager="$(pkg_manager || true)"
  [ -n "$manager" ] || return 1

  case "$manager" in
    apt-get)
      run_root env DEBIAN_FRONTEND=noninteractive apt-get update
      run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
      ;;
    dnf)
      run_root dnf install -y "$@"
      ;;
    yum)
      run_root yum install -y "$@"
      ;;
    zypper)
      run_root zypper --non-interactive install "$@"
      ;;
    apk)
      run_root apk add --no-cache "$@"
      ;;
  esac
}

target_user() {
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    printf '%s' "$SUDO_USER"
  else
    id -un
  fi
}

target_home() {
  getent passwd "$1" | cut -d: -f6
}

TARGET_USER="$(target_user)"
TARGET_HOME="$(target_home "$TARGET_USER")"
TARGET_UID="$(id -u "$TARGET_USER")"
CONFIG_HOME="${XDG_CONFIG_HOME:-${TARGET_HOME}/.config}"
MIHOMO_CONFIG_FILE="${CONFIG_HOME}/mihomo/config.yaml"
MIHOMO_BIN="${TARGET_HOME}/.local/bin/mihomo"

ensure_config() {
  [ -f "$MIHOMO_CONFIG_FILE" ] || die "未找到 mihomo 配置: ${MIHOMO_CONFIG_FILE}。请先运行 bash client.sh install。"
  [ -x "$MIHOMO_BIN" ] || die "未找到 mihomo 二进制: ${MIHOMO_BIN}。请先运行 bash client.sh install。"
}

backup_config() {
  local backup_file

  ensure_config
  backup_file="${MIHOMO_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$MIHOMO_CONFIG_FILE" "$backup_file"
  if [ "$(id -u)" -eq 0 ]; then
    chown "$TARGET_USER:$TARGET_USER" "$backup_file"
  fi
  log "已备份配置: ${backup_file}"
}

ensure_tun_block() {
  if grep -q '^tun:[[:space:]]*$' "$MIHOMO_CONFIG_FILE"; then
    return
  fi

  cat >> "$MIHOMO_CONFIG_FILE" <<'EOF'

tun:
  enable: false
  stack: system
  auto-route: true
  auto-detect-interface: true
  strict-route: false
  dns-hijack:
    - any:53
EOF
}

set_tun_enabled() {
  local value="$1"
  local tmp_file

  ensure_tun_block
  tmp_file="$(mktemp)"
  awk -v value="$value" '
    BEGIN { in_tun = 0; changed = 0 }
    /^tun:[[:space:]]*$/ { in_tun = 1; print; next }
    in_tun && /^[^[:space:]#][^:]*:[[:space:]]*/ {
      if (!changed) print "  enable: " value
      in_tun = 0
      changed = 1
    }
    in_tun && /^[[:space:]]+enable:[[:space:]]*/ { print "  enable: " value; changed = 1; next }
    { print }
    END { if (in_tun && !changed) print "  enable: " value }
  ' "$MIHOMO_CONFIG_FILE" > "$tmp_file"

  cat "$tmp_file" > "$MIHOMO_CONFIG_FILE"
  rm -f "$tmp_file"
  if [ "$(id -u)" -eq 0 ]; then
    chown "$TARGET_USER:$TARGET_USER" "$MIHOMO_CONFIG_FILE"
  fi
  log "已设置 tun.enable=${value}"
}

ensure_setcap() {
  if command -v setcap >/dev/null 2>&1; then
    return
  fi

  install_packages libcap2-bin || install_packages libcap || die "未找到 setcap，且自动安装失败。请手动安装包含 setcap 的 libcap 包。"
}

grant_capability() {
  ensure_setcap
  if [ "$(id -u)" -eq 0 ]; then
    setcap cap_net_admin,cap_net_bind_service+ep "$MIHOMO_BIN"
  else
    sudo setcap cap_net_admin,cap_net_bind_service+ep "$MIHOMO_BIN"
  fi
  log "已为 mihomo 授权 cap_net_admin,cap_net_bind_service。"
}

user_systemctl() {
  if [ "$(id -u)" -ne 0 ]; then
    systemctl --user "$@"
    return
  fi

  if [ -S "/run/user/${TARGET_UID}/bus" ]; then
    sudo -u "$TARGET_USER" env \
      XDG_RUNTIME_DIR="/run/user/${TARGET_UID}" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${TARGET_UID}/bus" \
      systemctl --user "$@"
  else
    log "未找到 ${TARGET_USER} 的 user systemd bus，请手动执行: systemctl --user restart ${SERVICE_NAME}"
  fi
}

restart_mihomo() {
  command -v systemctl >/dev/null 2>&1 || return
  user_systemctl daemon-reload || true
  user_systemctl restart "$SERVICE_NAME" || true
}

enable_tun() {
  if [ ! -e /dev/net/tun ]; then
    log "未发现 /dev/net/tun，尝试加载 tun 模块。"
    if command -v modprobe >/dev/null 2>&1; then
      if [ "$(id -u)" -eq 0 ]; then
        modprobe tun || true
      else
        sudo modprobe tun || true
      fi
    fi
  fi

  backup_config
  set_tun_enabled true
  grant_capability
  restart_mihomo
}

disable_tun() {
  backup_config
  set_tun_enabled false
  restart_mihomo
}

status_tun() {
  ensure_config
  printf 'Target user: %s\n' "$TARGET_USER"
  printf 'Config: %s\n' "$MIHOMO_CONFIG_FILE"
  printf 'Binary: %s\n\n' "$MIHOMO_BIN"
  sed -n '/^tun:[[:space:]]*$/,/^[^[:space:]#][^:]*:[[:space:]]*/p' "$MIHOMO_CONFIG_FILE"
}

main() {
  case "${1:-help}" in
    enable) enable_tun ;;
    disable) disable_tun ;;
    status) status_tun ;;
    help | -h | --help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
