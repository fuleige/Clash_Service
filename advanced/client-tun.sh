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
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
  CONFIG_HOME="${TARGET_HOME}/.config"
else
  CONFIG_HOME="${XDG_CONFIG_HOME:-${TARGET_HOME}/.config}"
fi
MIHOMO_CONFIG_FILE="${CONFIG_HOME}/mihomo/config.yaml"
MIHOMO_BIN="${TARGET_HOME}/.local/bin/mihomo"
SYSV_SERVICE_NAME="mihomo-$(printf '%s' "$TARGET_USER" | tr -c 'A-Za-z0-9._-' '_')"

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
  tmp_file="$(mktemp "${MIHOMO_CONFIG_FILE}.tmp.XXXXXX")"
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

  mv "$tmp_file" "$MIHOMO_CONFIG_FILE"
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

ensure_tun_device() {
  if [ -c /dev/net/tun ]; then
    return
  fi

  log "未发现 /dev/net/tun，尝试自动准备 TUN 设备。"

  if command -v modprobe >/dev/null 2>&1; then
    run_root modprobe tun || true
  else
    log "未找到 modprobe，继续尝试直接创建设备节点。"
  fi

  if [ ! -e /dev/net ]; then
    run_root mkdir -p /dev/net || true
  fi

  if [ ! -e /dev/net/tun ] && command -v mknod >/dev/null 2>&1; then
    run_root mknod /dev/net/tun c 10 200 || true
  fi

  if [ -e /dev/net/tun ] && [ ! -c /dev/net/tun ]; then
    die "/dev/net/tun 已存在但不是字符设备，请手动检查。"
  fi

  if [ -c /dev/net/tun ]; then
    run_root chmod 0666 /dev/net/tun || true
    return
  fi

  die "未能准备 /dev/net/tun。请确认内核支持 TUN，或手动执行 modprobe tun 后重试。"
}

grant_capability() {
  ensure_setcap
  run_root setcap cap_net_admin,cap_net_bind_service+ep "$MIHOMO_BIN" ||
    die "为 mihomo 授权失败。请确认当前用户可使用 sudo，或直接以 root 执行。"
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
    return 1
  fi
}

service_available() {
  command -v service >/dev/null 2>&1 && [ -f "/etc/init.d/${SYSV_SERVICE_NAME}" ]
}

restart_mihomo() {
  if command -v systemctl >/dev/null 2>&1; then
    user_systemctl daemon-reload || true
    if user_systemctl restart "$SERVICE_NAME"; then
      return
    fi
  fi

  if service_available; then
    run_root service "$SYSV_SERVICE_NAME" restart || true
    return
  fi

  log "未检测到可自动重启的 mihomo 服务。请按你的运行方式手动重启："
  log "  bash client.sh start"
}

enable_tun() {
  ensure_tun_device
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
  awk '
    /^tun:[[:space:]]*$/ { in_tun = 1 }
    in_tun {
      if (printed && /^[^[:space:]#][^:]*:[[:space:]]*/) exit
      print
      printed = 1
    }
  ' "$MIHOMO_CONFIG_FILE"
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
