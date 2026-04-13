#!/usr/bin/env bash
set -Eeuo pipefail

MIHOMO_REPO="MetaCubeX/mihomo"
SERVICE_NAME="mihomo.service"
GEOIP_URL="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb"

CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}"
CACHE_HOME="${XDG_CACHE_HOME:-${HOME}/.cache}"
BIN_DIR="${HOME}/.local/bin"
MIHOMO_BIN="${BIN_DIR}/mihomo"
MIHOMO_CONFIG_DIR="${CONFIG_HOME}/mihomo"
MIHOMO_CONFIG_FILE="${MIHOMO_CONFIG_DIR}/config.yaml"
GEOIP_FILE="${MIHOMO_CONFIG_DIR}/geoip.metadb"
SYSTEMD_USER_DIR="${CONFIG_HOME}/systemd/user"
SERVICE_FILE="${SYSTEMD_USER_DIR}/${SERVICE_NAME}"
STATE_DIR="${CONFIG_HOME}/clash-service"
PROXY_ENV_FILE="${STATE_DIR}/proxy.env"
CLIENT_INFO_FILE="${STATE_DIR}/client-info.txt"
CACHE_DIR="${CLASH_SERVICE_CACHE_DIR:-${CACHE_HOME}/clash-service}"
FORCE_DOWNLOAD="${CLASH_SERVICE_FORCE_DOWNLOAD:-0}"
SKIP_CONNECTIVITY_CHECK="${CLASH_SERVICE_SKIP_CHECK:-0}"
CONNECTIVITY_TEST_URL="${CLASH_SERVICE_CHECK_URL:-https://www.gstatic.com/generate_204}"
CONNECTIVITY_TIMEOUT_MS="${CLASH_SERVICE_CHECK_TIMEOUT_MS:-8000}"
CONNECTIVITY_CURL_TIMEOUT="${CLASH_SERVICE_CHECK_CURL_TIMEOUT:-12}"
MIHOMO_CONTROLLER_URL="${CLASH_SERVICE_CONTROLLER_URL:-http://127.0.0.1:9090}"
MIHOMO_PROXY_NAME="${CLASH_SERVICE_PROXY_NAME:-trojan-service}"

DEFAULT_LOCAL_PROXY_PORT="7890"
RC_MARKER_BEGIN="# >>> clash-service proxy env >>>"
RC_MARKER_END="# <<< clash-service proxy env <<<"

log() {
  printf '[client] %s\n' "$*"
}

die() {
  printf '[client] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  bash client.sh install
  bash client.sh start
  bash client.sh stop
  bash client.sh restart
  bash client.sh status
  bash client.sh enable
  bash client.sh disable
  bash client.sh uninstall
  bash client.sh help

After install, open a new terminal and use:
  clash_service start
  clash_service stop

Env:
  CLASH_SERVICE_CACHE_DIR=/path/to/cache
  CLASH_SERVICE_FORCE_DOWNLOAD=1
  CLASH_SERVICE_SKIP_CHECK=1
  CLASH_SERVICE_CHECK_URL=https://example.com
  CLASH_SERVICE_CONTROLLER_URL=http://127.0.0.1:9090
EOF
}

need_user() {
  if [ "$(id -u)" -eq 0 ]; then
    die "client.sh 默认安装到当前用户目录，请不要使用 sudo 运行。"
  fi
}

ask() {
  local prompt="$1"
  local default_value="$2"
  local answer=""

  if [ -t 0 ]; then
    read -r -p "${prompt} [${default_value}]: " answer
  fi

  printf '%s' "${answer:-$default_value}"
}

validate_port() {
  local port="$1"

  if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    die "端口号必须是 1-65535 之间的整数: ${port}"
  fi
}

validate_positive_int() {
  local label="$1"
  local value="$2"

  if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 1 ]; then
    die "${label} 必须是正整数: ${value}"
  fi
}

install_packages() {
  local packages=(curl gzip ca-certificates)
  local missing=()
  local pkg

  for pkg in "${packages[@]}"; do
    if command -v dpkg >/dev/null 2>&1; then
      dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
    else
      command -v "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
    fi
  done

  if [ "${#missing[@]}" -eq 0 ]; then
    return
  fi

  command -v apt-get >/dev/null 2>&1 || die "缺少依赖: ${missing[*]}。请先安装后重试。"
  command -v sudo >/dev/null 2>&1 || die "缺少依赖: ${missing[*]}，且未找到 sudo。"

  log "准备安装系统依赖: ${missing[*]}"
  sudo apt-get update
  sudo apt-get install -y "${missing[@]}"
}

user_bus_ready() {
  systemctl --user show-environment >/dev/null 2>&1
}

enable_linger_if_possible() {
  local current_user

  command -v loginctl >/dev/null 2>&1 || return
  command -v sudo >/dev/null 2>&1 || return

  current_user="$(id -un)"
  if loginctl show-user "$current_user" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
    return
  fi

  log "尝试启用 systemd linger。"
  sudo loginctl enable-linger "$current_user" || true
}

ensure_user_systemd() {
  local current_user

  command -v systemctl >/dev/null 2>&1 || die "未找到 systemctl。"
  if user_bus_ready; then
    return
  fi

  enable_linger_if_possible
  if user_bus_ready; then
    return
  fi

  current_user="$(id -un)"
  die "当前会话没有可用的 systemd user bus。请重新登录后再运行，或先执行: sudo loginctl enable-linger ${current_user}"
}

mihomo_asset_regexes() {
  case "$(uname -m)" in
    x86_64 | amd64)
      printf '%s\n' \
        'mihomo-linux-amd64-v1-v[^"]+\.gz' \
        'mihomo-linux-amd64-v1-go[0-9]+-v[^"]+\.gz' \
        'mihomo-linux-amd64-v[^"]+\.gz'
      ;;
    i386 | i686) printf '%s\n' 'mihomo-linux-386-v[^"]+\.gz' ;;
    aarch64 | arm64)
      printf '%s\n' \
        'mihomo-linux-arm64-v8-v[^"]+\.gz' \
        'mihomo-linux-arm64-v[^"]+\.gz'
      ;;
    armv7l | armv7*) printf '%s\n' 'mihomo-linux-armv7-v[^"]+\.gz' ;;
    armv6l | armv6*) printf '%s\n' 'mihomo-linux-armv6-v[^"]+\.gz' ;;
    arm*) printf '%s\n' 'mihomo-linux-arm-v[^"]+\.gz' ;;
    *) die "不支持的 CPU 架构: $(uname -m)" ;;
  esac
}

mihomo_asset_globs() {
  case "$(uname -m)" in
    x86_64 | amd64)
      printf '%s\n' \
        'mihomo-linux-amd64-v1-v*.gz' \
        'mihomo-linux-amd64-v1-go*-v*.gz' \
        'mihomo-linux-amd64-v*.gz'
      ;;
    i386 | i686) printf '%s\n' 'mihomo-linux-386-v*.gz' ;;
    aarch64 | arm64)
      printf '%s\n' \
        'mihomo-linux-arm64-v8-v*.gz' \
        'mihomo-linux-arm64-v*.gz'
      ;;
    armv7l | armv7*) printf '%s\n' 'mihomo-linux-armv7-v*.gz' ;;
    armv6l | armv6*) printf '%s\n' 'mihomo-linux-armv6-v*.gz' ;;
    arm*) printf '%s\n' 'mihomo-linux-arm-v*.gz' ;;
    *) die "不支持的 CPU 架构: $(uname -m)" ;;
  esac
}

cached_mihomo_archive() {
  local glob archive

  [ -d "$CACHE_DIR" ] || return 1
  while IFS= read -r glob; do
    [ -n "$glob" ] || continue
    archive="$(find "$CACHE_DIR" -maxdepth 1 -type f -name "$glob" | sort -V | tail -n 1 || true)"
    if [ -n "$archive" ]; then
      printf '%s' "$archive"
      return 0
    fi
  done <<< "$(mihomo_asset_globs)"

  return 1
}

announce_mihomo_download() {
  local glob

  log "准备下载 mihomo。"
  log "如网络不好，可手动下载匹配当前架构的 mihomo 压缩包后放到: ${CACHE_DIR}"
  log "发布页: https://github.com/${MIHOMO_REPO}/releases/latest"
  while IFS= read -r glob; do
    [ -n "$glob" ] || continue
    log "文件名可匹配: ${glob}"
  done <<< "$(mihomo_asset_globs)"
}

resolve_mihomo_download_url() {
  local release_json url pattern

  release_json="$(curl -fsSL "https://api.github.com/repos/${MIHOMO_REPO}/releases/latest")" || return 1
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    url="$(printf '%s\n' "$release_json" | grep -Eo "https://[^\"]+/${pattern}" | head -n 1 || true)"
    if [ -n "$url" ]; then
      printf '%s' "$url"
      return 0
    fi
  done <<< "$(mihomo_asset_regexes)"

  return 1
}

install_mihomo() {
  local archive tmp_dir tmp_bin url

  if [ -x "$MIHOMO_BIN" ] && [ "$FORCE_DOWNLOAD" != "1" ]; then
    log "复用已有 mihomo: ${MIHOMO_BIN}"
    "$MIHOMO_BIN" -v 2>/dev/null | head -n 1 || true
    return
  fi

  mkdir -p "$BIN_DIR" "$CACHE_DIR"
  archive="$(cached_mihomo_archive || true)"

  if [ -z "$archive" ]; then
    announce_mihomo_download
    url="$(resolve_mihomo_download_url || true)"
    [ -n "$url" ] || die "查询 mihomo release 失败。你也可以手动下载压缩包后放到 ${CACHE_DIR}"
    archive="${CACHE_DIR}/${url##*/}"
    log "自动下载: ${url}"
    if ! curl -fL "$url" -o "$archive"; then
      die "下载 mihomo 失败。你也可以手动下载 ${url##*/} 后放到 ${archive}"
    fi
  else
    log "检测到本地缓存: ${archive}"
  fi

  tmp_dir="$(mktemp -d)"
  tmp_bin="${tmp_dir}/mihomo"
  if ! gzip -dc "$archive" > "$tmp_bin"; then
    rm -rf "$tmp_dir"
    die "解压 mihomo 失败: ${archive}"
  fi

  install -m 0755 "$tmp_bin" "$MIHOMO_BIN"
  rm -rf "$tmp_dir"
  log "已安装 mihomo: ${MIHOMO_BIN}"
}

config_needs_geoip() {
  [ -f "$MIHOMO_CONFIG_FILE" ] || return 1
  grep -Eq '(^[[:space:]]*fallback:|geoip|geoip\.metadb|Country\.mmdb)' "$MIHOMO_CONFIG_FILE"
}

install_geoip_metadb() {
  local cache_file

  cache_file="${CACHE_DIR}/geoip.metadb"
  mkdir -p "$CACHE_DIR" "$MIHOMO_CONFIG_DIR"

  if [ ! -f "$cache_file" ]; then
    log "当前配置依赖 geoip.metadb。"
    log "如网络不好，可手动下载后放到: ${cache_file}"
    log "下载地址: ${GEOIP_URL}"
    if ! curl -fL "$GEOIP_URL" -o "$cache_file"; then
      die "下载 geoip.metadb 失败。你也可以手动下载后放到 ${cache_file}"
    fi
  fi

  install -m 0644 "$cache_file" "$GEOIP_FILE"
}

current_local_proxy_port() {
  local port=""

  if [ -f "$MIHOMO_CONFIG_FILE" ]; then
    port="$(sed -n 's/^[[:space:]]*mixed-port:[[:space:]]*\([0-9]\+\).*/\1/p' "$MIHOMO_CONFIG_FILE" | head -n 1)"
  fi

  printf '%s' "${port:-$DEFAULT_LOCAL_PROXY_PORT}"
}

yaml_quote() {
  local value="${1:-}"

  value=${value//\'/\'\'}
  printf "'%s'" "$value"
}

shell_quote() {
  local value="${1:-}"

  value=${value//\'/\'\\\'\'}
  printf "'%s'" "$value"
}

write_mihomo_config() {
  local server_addr="$1"
  local server_port="$2"
  local password="$3"
  local sni="$4"
  local local_proxy_port

  local_proxy_port="$(current_local_proxy_port)"
  mkdir -p "$MIHOMO_CONFIG_DIR"
  cat > "$MIHOMO_CONFIG_FILE" <<EOF
mixed-port: ${local_proxy_port}
allow-lan: false
mode: rule
log-level: info
ipv6: false
external-controller: 127.0.0.1:9090

profile:
  store-selected: true
  store-fake-ip: true

dns:
  enable: true
  listen: 127.0.0.1:1053
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - 1.1.1.1
    - 8.8.8.8
    - 223.5.5.5

tun:
  enable: false
  stack: system
  auto-route: true
  auto-detect-interface: true
  strict-route: false
  dns-hijack:
    - any:53

proxies:
  - name: trojan-service
    type: trojan
    server: $(yaml_quote "$server_addr")
    port: ${server_port}
    password: $(yaml_quote "$password")
    sni: $(yaml_quote "$sni")
    skip-cert-verify: true
    udp: true
    client-fingerprint: chrome

proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - trojan-service
      - DIRECT

rules:
  - DOMAIN-SUFFIX,local,DIRECT
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR,169.254.0.0/16,DIRECT,no-resolve
  - MATCH,PROXY
EOF

  chmod 600 "$MIHOMO_CONFIG_FILE"
}

write_client_info() {
  local server_addr="$1"
  local server_port="$2"
  local password="$3"
  local sni="$4"
  local local_proxy_port

  local_proxy_port="$(current_local_proxy_port)"
  mkdir -p "$STATE_DIR"
  cat > "$CLIENT_INFO_FILE" <<EOF
# Generated by client.sh. Keep this file private.
server: ${server_addr}
port: ${server_port}
password: ${password}
sni: ${sni}
skip-cert-verify: true
local-proxy: http://127.0.0.1:${local_proxy_port}
config: ${MIHOMO_CONFIG_FILE}
proxy-env: ${PROXY_ENV_FILE}
EOF

  chmod 600 "$CLIENT_INFO_FILE"
}

write_user_service() {
  mkdir -p "$SYSTEMD_USER_DIR"
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=mihomo client
Documentation=https://github.com/${MIHOMO_REPO}
After=network.target

[Service]
Type=simple
ExecStart=${MIHOMO_BIN} -d ${MIHOMO_CONFIG_DIR} -f ${MIHOMO_CONFIG_FILE}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=default.target
EOF

  systemctl --user daemon-reload
}

detect_rc_file() {
  if [ -n "${CLASH_SERVICE_RC:-}" ]; then
    printf '%s' "$CLASH_SERVICE_RC"
    return
  fi

  case "${SHELL##*/}" in
    zsh) printf '%s/.zshrc' "$HOME" ;;
    bash) printf '%s/.bashrc' "$HOME" ;;
    *) printf '%s/.profile' "$HOME" ;;
  esac
}

remove_loader_from_file() {
  local rc_file="$1"
  local tmp_file

  [ -f "$rc_file" ] || return 0
  tmp_file="$(mktemp)"
  sed "/^${RC_MARKER_BEGIN}$/,/^${RC_MARKER_END}$/d" "$rc_file" > "$tmp_file"
  cat "$tmp_file" > "$rc_file"
  rm -f "$tmp_file"
}

install_shell_loader() {
  local rc_file proxy_env_path script_path

  rc_file="$(detect_rc_file)"
  proxy_env_path="$(shell_quote "$PROXY_ENV_FILE")"
  script_path="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"

  mkdir -p "$(dirname "$rc_file")"
  touch "$rc_file"
  remove_loader_from_file "$rc_file"

  cat >> "$rc_file" <<EOF

${RC_MARKER_BEGIN}
__clash_service_proxy_env="\${XDG_CONFIG_HOME:-\$HOME/.config}/clash-service/proxy.env"
if [ ! -f "\$__clash_service_proxy_env" ]; then
  __clash_service_proxy_env=${proxy_env_path}
fi
if [ -f "\$__clash_service_proxy_env" ]; then
  . "\$__clash_service_proxy_env"
fi
unset __clash_service_proxy_env

clash_service() {
  __clash_service_script=$(shell_quote "$script_path")
  if CLASH_SERVICE_SHELL_FUNCTION=1 bash "\$__clash_service_script" "\$@"; then
    __clash_service_status=0
  else
    __clash_service_status=\$?
  fi

  __clash_service_proxy_env="\${XDG_CONFIG_HOME:-\$HOME/.config}/clash-service/proxy.env"
  if [ ! -f "\$__clash_service_proxy_env" ]; then
    __clash_service_proxy_env=${proxy_env_path}
  fi

  case "\${1:-}" in
    install | start | enable | restart | stop | disable | uninstall)
      if [ -f "\$__clash_service_proxy_env" ]; then
        . "\$__clash_service_proxy_env"
      else
        unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
      fi
      ;;
  esac

  unset __clash_service_script __clash_service_proxy_env
  return "\$__clash_service_status"
}
${RC_MARKER_END}
EOF
}

remove_shell_loader() {
  remove_loader_from_file "$(detect_rc_file)"
}

write_proxy_enabled_env() {
  local port http_proxy_url all_proxy_url

  port="$(current_local_proxy_port)"
  http_proxy_url="http://127.0.0.1:${port}"
  all_proxy_url="socks5://127.0.0.1:${port}"
  mkdir -p "$STATE_DIR"
  cat > "$PROXY_ENV_FILE" <<EOF
# Generated by client.sh. Source this file to apply in the current shell.
export http_proxy="${http_proxy_url}"
export https_proxy="${http_proxy_url}"
export all_proxy="${all_proxy_url}"
export HTTP_PROXY="\$http_proxy"
export HTTPS_PROXY="\$https_proxy"
export ALL_PROXY="\$all_proxy"
EOF

  if [ "${CLASH_SERVICE_SHELL_FUNCTION:-0}" = "1" ]; then
    log "已启用代理并同步当前终端。"
  else
    log "已启用后续新终端代理。当前终端如需立即生效，请执行: source ${PROXY_ENV_FILE}"
  fi
}

write_proxy_disabled_env() {
  mkdir -p "$STATE_DIR"
  cat > "$PROXY_ENV_FILE" <<'EOF'
# Generated by client.sh. Source this file to apply in the current shell.
unset http_proxy
unset https_proxy
unset all_proxy
unset HTTP_PROXY
unset HTTPS_PROXY
unset ALL_PROXY
EOF

  if [ "${CLASH_SERVICE_SHELL_FUNCTION:-0}" = "1" ]; then
    log "已关闭代理并同步当前终端。"
  else
    log "已关闭后续新终端代理。当前终端如需立即生效，请执行: source ${PROXY_ENV_FILE}"
  fi
}

start_service() {
  ensure_user_systemd
  systemctl --user daemon-reload
  systemctl --user enable --now "$SERVICE_NAME"
}

stop_service() {
  if ! command -v systemctl >/dev/null 2>&1 || ! user_bus_ready; then
    return
  fi

  systemctl --user disable --now "$SERVICE_NAME"
}

restart_service() {
  ensure_user_systemd
  systemctl --user daemon-reload
  systemctl --user restart "$SERVICE_NAME"
}

local_curl() {
  env \
    -u http_proxy \
    -u https_proxy \
    -u all_proxy \
    -u HTTP_PROXY \
    -u HTTPS_PROXY \
    -u ALL_PROXY \
    curl --noproxy '*' "$@"
}

wait_controller() {
  local attempt

  for attempt in $(seq 1 15); do
    if local_curl -fsS --max-time 1 "${MIHOMO_CONTROLLER_URL}/version" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  return 1
}

check_proxy_connectivity() {
  local response=""

  if [ "$SKIP_CONNECTIVITY_CHECK" = "1" ]; then
    log "已跳过代理连通性检测。"
    return
  fi

  validate_positive_int "CLASH_SERVICE_CHECK_TIMEOUT_MS" "$CONNECTIVITY_TIMEOUT_MS"
  validate_positive_int "CLASH_SERVICE_CHECK_CURL_TIMEOUT" "$CONNECTIVITY_CURL_TIMEOUT"

  log "等待 mihomo controller: ${MIHOMO_CONTROLLER_URL}"
  if ! wait_controller; then
    write_proxy_disabled_env
    die "mihomo 已启动，但本地 controller 不可访问。请查看日志: journalctl --user -u ${SERVICE_NAME} -e --no-pager"
  fi

  log "检测代理节点: ${MIHOMO_PROXY_NAME} -> ${CONNECTIVITY_TEST_URL}"
  if response="$(local_curl -fsS --max-time "$CONNECTIVITY_CURL_TIMEOUT" \
    -G "${MIHOMO_CONTROLLER_URL}/proxies/${MIHOMO_PROXY_NAME}/delay" \
    --data-urlencode "timeout=${CONNECTIVITY_TIMEOUT_MS}" \
    --data-urlencode "url=${CONNECTIVITY_TEST_URL}" 2>/dev/null)" &&
    printf '%s' "$response" | grep -Eq '"delay"[[:space:]]*:[[:space:]]*[0-9]+'; then
    log "代理连通性检测通过: ${response}"
    return
  fi

  write_proxy_disabled_env
  die "mihomo 已启动，但代理节点连通性检测失败。请核对服务端地址、端口、密码、SNI、防火墙；如确认只是测试 URL 不通，可设置 CLASH_SERVICE_CHECK_URL 或 CLASH_SERVICE_SKIP_CHECK=1。"
}

client_ready() {
  [ -f "$MIHOMO_CONFIG_FILE" ]
}

ensure_runtime() {
  install_packages
  ensure_user_systemd
  install_mihomo
  if config_needs_geoip; then
    install_geoip_metadb
  fi
  write_user_service
  install_shell_loader
}

install_client() {
  local server_addr server_port password sni

  need_user
  install_packages
  ensure_user_systemd

  server_addr="$(ask "服务端地址/IP" "127.0.0.1")"
  [ -n "$server_addr" ] || die "服务端地址不能为空。"
  server_port="$(ask "服务端端口" "443")"
  validate_port "$server_port"
  password="$(ask "trojan 密码" "change-me")"
  [ -n "$password" ] || die "密码不能为空。"
  sni="$(ask "SNI" "$server_addr")"
  [ -n "$sni" ] || die "SNI 不能为空。"

  install_mihomo
  write_mihomo_config "$server_addr" "$server_port" "$password" "$sni"
  write_client_info "$server_addr" "$server_port" "$password" "$sni"
  write_user_service
  install_shell_loader
  start_service
  check_proxy_connectivity
  write_proxy_enabled_env

  cat <<EOF

安装完成。
客户端连接信息:
  server: ${server_addr}
  port: ${server_port}
  password: ${password}
  sni: ${sni}
  saved: ${CLIENT_INFO_FILE}

新开的终端可使用:
  clash_service start
  clash_service stop
EOF
}

start_client() {
  need_user
  if ! client_ready; then
    log "未检测到 mihomo 配置，进入安装流程。"
    install_client
    return
  fi

  ensure_runtime
  start_service
  check_proxy_connectivity
  write_proxy_enabled_env
}

stop_client() {
  need_user
  stop_service || true
  write_proxy_disabled_env
}

status_client() {
  need_user
  ensure_user_systemd
  systemctl --user --no-pager status "$SERVICE_NAME" || true

  printf '\nProxy env file: %s\n' "$PROXY_ENV_FILE"
  if [ -f "$PROXY_ENV_FILE" ]; then
    sed -n '1,120p' "$PROXY_ENV_FILE"
  else
    printf 'not found\n'
  fi
}

uninstall_client() {
  local answer=""

  need_user
  systemctl --user stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl --user disable "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE" "$MIHOMO_BIN"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
  remove_shell_loader
  write_proxy_disabled_env

  if [ -t 0 ]; then
    read -r -p "是否删除 ${MIHOMO_CONFIG_DIR} 和 ${STATE_DIR}? [y/N]: " answer
    case "$answer" in
      y | Y | yes | YES) rm -rf "$MIHOMO_CONFIG_DIR" "$STATE_DIR" ;;
      *)
        log "保留配置目录: ${MIHOMO_CONFIG_DIR}"
        log "保留状态目录: ${STATE_DIR}"
        ;;
    esac
  else
    log "保留配置目录: ${MIHOMO_CONFIG_DIR}"
    log "保留状态目录: ${STATE_DIR}"
  fi
}

main() {
  case "${1:-help}" in
    install) install_client ;;
    start) start_client ;;
    stop) stop_client ;;
    restart)
      need_user
      ensure_runtime
      restart_service
      check_proxy_connectivity
      write_proxy_enabled_env
      ;;
    status) status_client ;;
    enable)
      need_user
      install_shell_loader
      write_proxy_enabled_env
      ;;
    disable)
      need_user
      write_proxy_disabled_env
      ;;
    uninstall) uninstall_client ;;
    help | -h | --help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
