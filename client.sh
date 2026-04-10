#!/usr/bin/env bash
set -Eeuo pipefail

MIHOMO_REPO="MetaCubeX/mihomo"
SERVICE_NAME="mihomo.service"

CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}"
CACHE_HOME="${XDG_CACHE_HOME:-${HOME}/.cache}"
BIN_DIR="${HOME}/.local/bin"
MIHOMO_BIN="${BIN_DIR}/mihomo"
MIHOMO_CONFIG_DIR="${CONFIG_HOME}/mihomo"
MIHOMO_CONFIG_FILE="${MIHOMO_CONFIG_DIR}/config.yaml"
SYSTEMD_USER_DIR="${CONFIG_HOME}/systemd/user"
SERVICE_FILE="${SYSTEMD_USER_DIR}/${SERVICE_NAME}"
STATE_DIR="${CONFIG_HOME}/clash-service"
PROXY_ENV_FILE="${STATE_DIR}/proxy.env"
CLIENT_INFO_FILE="${STATE_DIR}/client-info.txt"
DOWNLOAD_CACHE_DIR="${CLASH_SERVICE_CACHE_DIR:-${CACHE_HOME}/clash-service}"
FORCE_DOWNLOAD="${CLASH_SERVICE_FORCE_DOWNLOAD:-0}"
SKIP_CONNECTIVITY_CHECK="${CLASH_SERVICE_SKIP_CHECK:-0}"
CONNECTIVITY_TEST_URL="${CLASH_SERVICE_CHECK_URL:-https://www.gstatic.com/generate_204}"
CONNECTIVITY_TIMEOUT_MS="${CLASH_SERVICE_CHECK_TIMEOUT_MS:-8000}"
CONNECTIVITY_CURL_TIMEOUT="${CLASH_SERVICE_CHECK_CURL_TIMEOUT:-12}"
MIHOMO_CONTROLLER_URL="${CLASH_SERVICE_CONTROLLER_URL:-http://127.0.0.1:9090}"
MIHOMO_PROXY_NAME="${CLASH_SERVICE_PROXY_NAME:-trojan-service}"

HTTP_PROXY_URL="http://127.0.0.1:7890"
ALL_PROXY_URL="socks5://127.0.0.1:7890"
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

Commands:
  install   Install mihomo, generate config.yaml, and write a user systemd unit.
  start     Start mihomo and enable proxy variables for future terminals.
  stop      Stop mihomo and disable proxy variables for future terminals.
  restart   Restart mihomo service.
  status    Show mihomo service status and proxy environment state.
  enable    Only enable proxy variables for future terminals.
  disable   Only disable proxy variables for future terminals.

Set CLASH_SERVICE_FORCE_DOWNLOAD=1 to reinstall mihomo even when the
binary already exists; a cached archive may be reused.
Set CLASH_SERVICE_CACHE_DIR=/path/to/dir to use a custom download cache.
Set CLASH_SERVICE_SKIP_CHECK=1 to skip the post-start connectivity check.
EOF
}

require_non_root() {
  if [ "$(id -u)" -eq 0 ]; then
    die "client.sh 默认安装到当前用户目录，请不要使用 sudo 运行。"
  fi
}

require_systemd_user() {
  command -v systemctl >/dev/null 2>&1 || die "未找到 systemctl。"
}

install_packages_if_needed() {
  local packages=("curl" "gzip" "ca-certificates")
  local missing=()
  local pkg

  if command -v dpkg >/dev/null 2>&1; then
    for pkg in "${packages[@]}"; do
      if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        missing+=("$pkg")
      fi
    done
  else
    command -v curl >/dev/null 2>&1 || missing+=("curl")
    command -v gzip >/dev/null 2>&1 || missing+=("gzip")
  fi

  if [ "${#missing[@]}" -eq 0 ]; then
    log "系统依赖已满足。"
    return
  fi

  command -v apt-get >/dev/null 2>&1 || die "缺少依赖: ${missing[*]}。请先安装后重试。"
  command -v sudo >/dev/null 2>&1 || die "缺少依赖: ${missing[*]}，且未找到 sudo。"

  log "缺少依赖，自动安装: ${missing[*]}"
  sudo apt-get update
  sudo apt-get install -y "${missing[@]}"
}

systemd_user_available() {
  systemctl --user show-environment >/dev/null 2>&1
}

enable_linger_if_possible() {
  local current_user

  if ! command -v loginctl >/dev/null 2>&1 || ! command -v sudo >/dev/null 2>&1; then
    return
  fi

  current_user="$(id -un)"

  if loginctl show-user "$current_user" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
    return
  fi

  log "尝试启用 systemd linger，便于用户服务开机后自动运行。"
  sudo loginctl enable-linger "$current_user" || true
}

ensure_systemd_user_ready() {
  local current_user

  require_systemd_user

  if systemd_user_available; then
    return
  fi

  enable_linger_if_possible

  if systemd_user_available; then
    return
  fi

  current_user="$(id -un)"
  die "当前会话没有可用的 systemd user bus。请重新登录后再运行，或先执行: sudo loginctl enable-linger ${current_user}"
}

detect_mihomo_asset_patterns() {
  case "$(uname -m)" in
    x86_64 | amd64)
      printf '%s\n' \
        'mihomo-linux-amd64-v1-v[^"]+\.gz' \
        'mihomo-linux-amd64-v1-go[0-9]+-v[^"]+\.gz' \
        'mihomo-linux-amd64-v[^"]+\.gz'
      ;;
    i386 | i686)
      printf '%s\n' 'mihomo-linux-386-v[^"]+\.gz'
      ;;
    aarch64 | arm64)
      printf '%s\n' \
        'mihomo-linux-arm64-v8-v[^"]+\.gz' \
        'mihomo-linux-arm64-v[^"]+\.gz'
      ;;
    armv7l | armv7*)
      printf '%s\n' 'mihomo-linux-armv7-v[^"]+\.gz'
      ;;
    armv6l | armv6*)
      printf '%s\n' 'mihomo-linux-armv6-v[^"]+\.gz'
      ;;
    arm*)
      printf '%s\n' 'mihomo-linux-arm-v[^"]+\.gz'
      ;;
    *) die "不支持的 CPU 架构: $(uname -m)" ;;
  esac
}

detect_mihomo_asset_globs() {
  case "$(uname -m)" in
    x86_64 | amd64)
      printf '%s\n' \
        'mihomo-linux-amd64-v1-v*.gz' \
        'mihomo-linux-amd64-v1-go*-v*.gz' \
        'mihomo-linux-amd64-v*.gz'
      ;;
    i386 | i686)
      printf '%s\n' 'mihomo-linux-386-v*.gz'
      ;;
    aarch64 | arm64)
      printf '%s\n' \
        'mihomo-linux-arm64-v8-v*.gz' \
        'mihomo-linux-arm64-v*.gz'
      ;;
    armv7l | armv7*)
      printf '%s\n' 'mihomo-linux-armv7-v*.gz'
      ;;
    armv6l | armv6*)
      printf '%s\n' 'mihomo-linux-armv6-v*.gz'
      ;;
    arm*)
      printf '%s\n' 'mihomo-linux-arm-v*.gz'
      ;;
    *) die "不支持的 CPU 架构: $(uname -m)" ;;
  esac
}

find_cached_mihomo_archive() {
  local pattern
  local archive

  [ -d "$DOWNLOAD_CACHE_DIR" ] || return 1

  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    archive="$(find "$DOWNLOAD_CACHE_DIR" -maxdepth 1 -type f -name "$pattern" | sort -V | tail -n 1 || true)"
    if [ -n "$archive" ]; then
      printf '%s' "$archive"
      return 0
    fi
  done <<< "$(detect_mihomo_asset_globs)"

  return 1
}

download_mihomo() {
  local pattern
  local release_json
  local download_url
  local archive_path
  local download_file
  local tmp_dir
  local tmp_bin

  tmp_dir="$(mktemp -d)"
  tmp_bin="${tmp_dir}/mihomo"

  mkdir -p "$BIN_DIR" "$DOWNLOAD_CACHE_DIR"
  archive_path="$(find_cached_mihomo_archive || true)"

  if [ -n "$archive_path" ]; then
    log "检测到本地 mihomo 压缩包，跳过下载: ${archive_path}"
  else
    log "查询 mihomo 最新稳定版 release"
    log "未发现本地 mihomo 压缩包。网络不好时，可先从 https://github.com/${MIHOMO_REPO}/releases/latest 下载匹配当前架构的 .gz 文件到: ${DOWNLOAD_CACHE_DIR}"
    if ! release_json="$(curl -fsSL "https://api.github.com/repos/${MIHOMO_REPO}/releases/latest")"; then
      rm -rf "$tmp_dir"
      die "查询 mihomo release 失败。可手动下载压缩包到 ${DOWNLOAD_CACHE_DIR} 后重试。"
    fi
    download_url=""

    while IFS= read -r pattern; do
      [ -n "$pattern" ] || continue
      download_url="$(printf '%s\n' "$release_json" | grep -Eo "https://[^\"]+/${pattern}" | head -n 1 || true)"
      if [ -n "$download_url" ]; then
        break
      fi
    done <<< "$(detect_mihomo_asset_patterns)"

    [ -n "$download_url" ] || die "没有找到匹配当前架构的 mihomo release 资产。"

    download_file="${download_url##*/}"
    archive_path="${DOWNLOAD_CACHE_DIR}/${download_file}"

    log "准备下载 mihomo: ${download_url}"
    log "网络不好时，可先手动下载该文件到: ${archive_path}"
    log "文件名保持不变，重新运行脚本会自动检测并使用本地压缩包。"
    if ! curl -fL "$download_url" -o "${tmp_dir}/${download_file}"; then
      rm -rf "$tmp_dir"
      die "下载 mihomo 失败。可先手动下载到 ${archive_path} 后重试。"
    fi
    if ! install -m 0644 "${tmp_dir}/${download_file}" "$archive_path"; then
      rm -rf "$tmp_dir"
      die "保存 mihomo 压缩包失败: ${archive_path}"
    fi
  fi

  if ! gzip -dc "$archive_path" > "$tmp_bin"; then
    rm -rf "$tmp_dir"
    die "解压 mihomo 失败: ${archive_path}"
  fi
  if ! install -m 0755 "$tmp_bin" "$MIHOMO_BIN"; then
    rm -rf "$tmp_dir"
    die "安装 mihomo 失败。"
  fi
  rm -rf "$tmp_dir"
  log "已安装: ${MIHOMO_BIN}"
}

install_mihomo_if_needed() {
  if [ -x "$MIHOMO_BIN" ] && [ "$FORCE_DOWNLOAD" != "1" ]; then
    log "检测到 mihomo 已存在: ${MIHOMO_BIN}"
    "$MIHOMO_BIN" -v 2>/dev/null | head -n 1 || true
    log "如需强制重新下载，请设置 CLASH_SERVICE_FORCE_DOWNLOAD=1。"
    return
  fi

  download_mihomo
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

ask_with_default() {
  local prompt="$1"
  local default_value="$2"
  local answer=""

  if [ -t 0 ]; then
    read -r -p "${prompt} [${default_value}]: " answer
  fi

  if [ -z "$answer" ]; then
    printf '%s' "$default_value"
  else
    printf '%s' "$answer"
  fi
}

yaml_single_quote() {
  local value="${1:-}"
  value=${value//\'/\'\'}
  printf "'%s'" "$value"
}

shell_single_quote() {
  local value="${1:-}"
  value=${value//\'/\'\\\'\'}
  printf "'%s'" "$value"
}

write_mihomo_config() {
  local server_addr="$1"
  local server_port="$2"
  local password="$3"
  local sni="$4"
  local server_addr_yaml
  local password_yaml
  local sni_yaml

  server_addr_yaml="$(yaml_single_quote "$server_addr")"
  password_yaml="$(yaml_single_quote "$password")"
  sni_yaml="$(yaml_single_quote "$sni")"

  mkdir -p "$MIHOMO_CONFIG_DIR"
  cat > "$MIHOMO_CONFIG_FILE" <<EOF
mixed-port: 7890
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
    - https://dns.alidns.com/dns-query
    - https://doh.pub/dns-query
  fallback:
    - https://1.1.1.1/dns-query
    - https://8.8.8.8/dns-query

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
    server: ${server_addr_yaml}
    port: ${server_port}
    password: ${password_yaml}
    sni: ${sni_yaml}
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

  chmod 0600 "$MIHOMO_CONFIG_FILE"
  log "已写入配置: ${MIHOMO_CONFIG_FILE}"
}

write_client_info() {
  local server_addr="$1"
  local server_port="$2"
  local password="$3"
  local sni="$4"

  mkdir -p "$STATE_DIR"
  cat > "$CLIENT_INFO_FILE" <<EOF
# Generated by client.sh. Keep this file private.
server: ${server_addr}
port: ${server_port}
password: ${password}
sni: ${sni}
skip-cert-verify: true
config: ${MIHOMO_CONFIG_FILE}
proxy-env: ${PROXY_ENV_FILE}
EOF
  chmod 0600 "$CLIENT_INFO_FILE"
  log "客户端连接信息已保存: ${CLIENT_INFO_FILE}"
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

  ensure_systemd_user_ready
  systemctl --user daemon-reload
  log "已写入用户 systemd 服务: ${SERVICE_FILE}"
}

detect_shell_rc_file() {
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
  local rc_file
  local proxy_env_file_shell

  rc_file="$(detect_shell_rc_file)"
  proxy_env_file_shell="$(shell_single_quote "$PROXY_ENV_FILE")"
  mkdir -p "$(dirname "$rc_file")"
  touch "$rc_file"
  remove_loader_from_file "$rc_file"

  cat >> "$rc_file" <<EOF

${RC_MARKER_BEGIN}
__clash_service_proxy_env="\${XDG_CONFIG_HOME:-\$HOME/.config}/clash-service/proxy.env"
if [ ! -f "\$__clash_service_proxy_env" ]; then
  __clash_service_proxy_env=${proxy_env_file_shell}
fi
if [ -f "\$__clash_service_proxy_env" ]; then
  . "\$__clash_service_proxy_env"
fi
unset __clash_service_proxy_env
${RC_MARKER_END}
EOF

  log "已在 ${rc_file} 加入受控代理 loader。"
}

remove_shell_loader() {
  local rc_file

  rc_file="$(detect_shell_rc_file)"
  remove_loader_from_file "$rc_file"
  log "已清理 ${rc_file} 中的受控代理 loader。"
}

write_proxy_enabled_env() {
  mkdir -p "$STATE_DIR"
  cat > "$PROXY_ENV_FILE" <<EOF
# Generated by client.sh. Source this file to apply in the current shell.
export http_proxy="${HTTP_PROXY_URL}"
export https_proxy="${HTTP_PROXY_URL}"
export all_proxy="${ALL_PROXY_URL}"
export HTTP_PROXY="\$http_proxy"
export HTTPS_PROXY="\$https_proxy"
export ALL_PROXY="\$all_proxy"
EOF
  log "后续新终端将启用代理: ${HTTP_PROXY_URL}"
  log "当前终端如需立即生效，请执行: source ${PROXY_ENV_FILE}"
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
  log "后续新终端将不再注入代理变量。"
  log "当前终端如需立即生效，请执行: source ${PROXY_ENV_FILE}"
}

start_service() {
  ensure_systemd_user_ready
  systemctl --user daemon-reload
  systemctl --user enable --now "$SERVICE_NAME"
}

stop_service() {
  if ! command -v systemctl >/dev/null 2>&1; then
    log "未找到 systemctl，跳过停止 mihomo 服务。"
    return 1
  fi

  if ! systemd_user_available; then
    log "当前会话没有可用的 systemd user bus，跳过停止 mihomo 服务。"
    return 1
  fi

  systemctl --user disable --now "$SERVICE_NAME"
}

restart_service() {
  ensure_systemd_user_ready
  systemctl --user daemon-reload
  systemctl --user restart "$SERVICE_NAME"
}

wait_mihomo_controller() {
  local attempt=1
  local max_attempts=10

  while [ "$attempt" -le "$max_attempts" ]; do
    if curl -fsS --max-time 1 "${MIHOMO_CONTROLLER_URL}/version" >/dev/null 2>&1; then
      return 0
    fi

    sleep 1
    attempt=$((attempt + 1))
  done

  return 1
}

check_proxy_connectivity() {
  local response=""

  if [ "$SKIP_CONNECTIVITY_CHECK" = "1" ]; then
    log "已跳过代理连通性检测。"
    return
  fi

  command -v curl >/dev/null 2>&1 || die "未找到 curl，无法执行代理连通性检测。"
  validate_positive_int "CLASH_SERVICE_CHECK_TIMEOUT_MS" "$CONNECTIVITY_TIMEOUT_MS"
  validate_positive_int "CLASH_SERVICE_CHECK_CURL_TIMEOUT" "$CONNECTIVITY_CURL_TIMEOUT"

  log "等待 mihomo 本地控制端口: ${MIHOMO_CONTROLLER_URL}"
  if ! wait_mihomo_controller; then
    write_proxy_disabled_env
    die "mihomo 已启动，但无法访问本地控制端口 ${MIHOMO_CONTROLLER_URL}。请查看日志: journalctl --user -u ${SERVICE_NAME} -e --no-pager"
  fi

  log "检测代理节点连通性: ${MIHOMO_PROXY_NAME} -> ${CONNECTIVITY_TEST_URL}"
  if response="$(curl -fsS --max-time "$CONNECTIVITY_CURL_TIMEOUT" \
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

client_config_complete() {
  [ -f "$MIHOMO_CONFIG_FILE" ]
}

ensure_client_runtime() {
  install_packages_if_needed
  ensure_systemd_user_ready
  install_mihomo_if_needed
  write_user_service
  install_shell_loader
}

install_client() {
  local server_addr
  local server_port
  local password
  local sni

  require_non_root
  install_packages_if_needed
  ensure_systemd_user_ready

  server_addr="$(ask_with_default "服务端地址/IP" "127.0.0.1")"
  [ -n "$server_addr" ] || die "服务端地址不能为空。"
  server_port="$(ask_with_default "服务端端口" "443")"
  validate_port "$server_port"
  password="$(ask_with_default "trojan 密码" "change-me")"
  [ -n "$password" ] || die "密码不能为空。"
  sni="$(ask_with_default "SNI" "$server_addr")"
  [ -n "$sni" ] || die "SNI 不能为空。"

  install_mihomo_if_needed
  write_mihomo_config "$server_addr" "$server_port" "$password" "$sni"
  write_client_info "$server_addr" "$server_port" "$password" "$sni"
  write_user_service
  install_shell_loader
  start_service
  check_proxy_connectivity
  write_proxy_enabled_env

  cat <<EOF

安装完成。
已自动启动 mihomo，并启用后续新终端代理。

客户端连接信息:
  server: ${server_addr}
  port: ${server_port}
  password: ${password}
  sni: ${sni}
  saved: ${CLIENT_INFO_FILE}

查看状态:
  bash client.sh status
EOF
}

start_client() {
  require_non_root

  if ! client_config_complete; then
    log "未检测到 mihomo 配置，进入一键安装流程。"
    install_client
    return
  fi

  ensure_client_runtime
  start_service
  check_proxy_connectivity
  write_proxy_enabled_env
}

stop_client() {
  require_non_root
  stop_service || true
  write_proxy_disabled_env
}

status_client() {
  require_non_root
  ensure_systemd_user_ready

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

  require_non_root

  systemctl --user stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl --user disable "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true

  remove_shell_loader
  write_proxy_disabled_env
  rm -f "$MIHOMO_BIN"

  if [ -t 0 ]; then
    read -r -p "是否删除 ${MIHOMO_CONFIG_DIR} 和 ${STATE_DIR}? [y/N]: " answer
    case "$answer" in
      y | Y | yes | YES)
        rm -rf "$MIHOMO_CONFIG_DIR" "$STATE_DIR"
        ;;
      *)
        log "保留配置目录: ${MIHOMO_CONFIG_DIR}"
        log "保留状态目录: ${STATE_DIR}"
        ;;
    esac
  else
    log "保留配置目录: ${MIHOMO_CONFIG_DIR}"
    log "保留状态目录: ${STATE_DIR}"
  fi

  log "卸载完成。"
}

main() {
  local command="${1:-help}"

  case "$command" in
    install) install_client ;;
    start) start_client ;;
    stop) stop_client ;;
    restart) require_non_root; restart_service; check_proxy_connectivity ;;
    status) status_client ;;
    enable) require_non_root; install_shell_loader; write_proxy_enabled_env ;;
    disable) require_non_root; write_proxy_disabled_env ;;
    uninstall) uninstall_client ;;
    help | -h | --help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
