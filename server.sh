#!/usr/bin/env bash
set -Eeuo pipefail

TROJAN_REPO="p4gefau1t/trojan-go"
TROJAN_BIN="/usr/local/bin/trojan-go"
CONFIG_DIR="/etc/trojan-go"
CONFIG_FILE="${CONFIG_DIR}/config.json"
INFO_FILE="${CONFIG_DIR}/client-info.txt"
CERT_DIR="${CONFIG_DIR}/certs"
CERT_FILE="${CERT_DIR}/server.crt"
KEY_FILE="${CERT_DIR}/server.key"
SERVICE_FILE="/etc/systemd/system/trojan-go.service"
SERVICE_NAME="trojan-go.service"
CACHE_DIR="${CLASH_SERVICE_CACHE_DIR:-/var/cache/clash-service}"
FORCE_DOWNLOAD="${CLASH_SERVICE_FORCE_DOWNLOAD:-0}"

log() {
  printf '[server] %s\n' "$*"
}

die() {
  printf '[server] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  sudo bash server.sh install
  sudo bash server.sh start
  sudo bash server.sh stop
  sudo bash server.sh restart
  sudo bash server.sh status
  sudo bash server.sh uninstall
  bash server.sh help

Env:
  CLASH_SERVICE_CACHE_DIR=/path/to/cache
  CLASH_SERVICE_FORCE_DOWNLOAD=1
EOF
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "请使用 root 权限运行，例如: sudo bash server.sh $1"
  fi
}

need_apt_system() {
  command -v apt-get >/dev/null 2>&1 || die "当前脚本只支持 Ubuntu/Debian。"
  command -v systemctl >/dev/null 2>&1 || die "未找到 systemctl。"
}

install_packages() {
  local packages=(curl unzip openssl ca-certificates)
  local missing=()
  local pkg

  need_apt_system

  for pkg in "${packages[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      missing+=("$pkg")
    fi
  done

  if [ "${#missing[@]}" -eq 0 ]; then
    return
  fi

  log "准备安装系统依赖: ${missing[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y "${missing[@]}"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) printf 'amd64' ;;
    i386 | i686) printf '386' ;;
    aarch64 | arm64) printf 'arm64' ;;
    armv7l | armv7*) printf 'armv7' ;;
    armv6l | armv6*) printf 'armv6' ;;
    armv5l | armv5*) printf 'armv5' ;;
    arm*) printf 'arm' ;;
    *) die "不支持的 CPU 架构: $(uname -m)" ;;
  esac
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

validate_text() {
  local label="$1"
  local value="$2"

  [ -n "$value" ] || die "${label} 不能为空。"
  [[ "$value" =~ [[:cntrl:]] ]] && die "${label} 不能包含控制字符。"
}

validate_sni() {
  local sni="$1"

  validate_text "SNI/证书名称" "$sni"
  [[ "$sni" == */* ]] && die "SNI/证书名称不能包含 /。"
  [[ "$sni" =~ ^[A-Za-z0-9._:-]+$ ]] || die "SNI/证书名称格式不合法: ${sni}"
}

default_sni() {
  local host

  host="$(hostname -f 2>/dev/null || hostname 2>/dev/null || true)"
  if [ -n "$host" ] && [ "$host" != "(none)" ]; then
    printf '%s' "$host"
  else
    printf 'trojan.local'
  fi
}

random_password() {
  openssl rand -hex 16
}

backup_if_exists() {
  local file="$1"

  [ -f "$file" ] || return 0
  cp -a "$file" "${file}.bak.$(date +%Y%m%d%H%M%S)"
}

note_manual_download() {
  local url="$1"
  local path="$2"

  log "准备下载: ${url##*/}"
  log "如网络不好，可手动下载后放到: ${path}"
  log "下载地址: ${url}"
}

install_trojan_go() {
  local arch file url archive tmp_dir bin_file

  if [ -x "$TROJAN_BIN" ] && [ "$FORCE_DOWNLOAD" != "1" ]; then
    log "复用已有 trojan-go: ${TROJAN_BIN}"
    "$TROJAN_BIN" -version 2>/dev/null | head -n 1 || true
    return
  fi

  arch="$(detect_arch)"
  file="trojan-go-linux-${arch}.zip"
  url="https://github.com/${TROJAN_REPO}/releases/latest/download/${file}"
  archive="${CACHE_DIR}/${file}"
  tmp_dir="$(mktemp -d)"

  mkdir -p "$CACHE_DIR"
  if [ ! -f "$archive" ]; then
    note_manual_download "$url" "$archive"
    if ! curl -fL "$url" -o "$archive"; then
      rm -rf "$tmp_dir"
      die "下载 trojan-go 失败。你也可以手动下载 ${file} 后放到 ${archive}"
    fi
  else
    log "检测到本地缓存: ${archive}"
  fi

  if ! unzip -q "$archive" -d "$tmp_dir"; then
    rm -rf "$tmp_dir"
    die "解压 trojan-go 失败: ${archive}"
  fi

  bin_file="$(find "$tmp_dir" -type f -name trojan-go | head -n 1 || true)"
  [ -n "$bin_file" ] || die "压缩包中未找到 trojan-go: ${archive}"

  install -m 0755 "$bin_file" "$TROJAN_BIN"
  rm -rf "$tmp_dir"
  log "已安装 trojan-go: ${TROJAN_BIN}"
}

generate_certificate() {
  local sni="$1"
  local san

  mkdir -p "$CERT_DIR"
  backup_if_exists "$CERT_FILE"
  backup_if_exists "$KEY_FILE"

  if [[ "$sni" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$sni" == *:* ]]; then
    san="IP:${sni}"
  else
    san="DNS:${sni}"
  fi

  if ! openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$KEY_FILE" \
    -out "$CERT_FILE" \
    -days 3650 \
    -subj "/CN=${sni}" \
    -addext "subjectAltName=${san}" >/dev/null 2>&1; then
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "$KEY_FILE" \
      -out "$CERT_FILE" \
      -days 3650 \
      -subj "/CN=${sni}" >/dev/null 2>&1
  fi

  chmod 600 "$KEY_FILE"
  chmod 644 "$CERT_FILE"
  log "已生成证书: ${CERT_FILE}"
}

json_escape() {
  local value="${1:-}"

  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

write_config() {
  local port="$1"
  local password="$2"
  local sni="$3"

  mkdir -p "$CONFIG_DIR"
  backup_if_exists "$CONFIG_FILE"

  cat > "$CONFIG_FILE" <<EOF
{
  "run_type": "server",
  "local_addr": "0.0.0.0",
  "local_port": ${port},
  "remote_addr": "www.cloudflare.com",
  "remote_port": 80,
  "password": [
    "$(json_escape "$password")"
  ],
  "ssl": {
    "cert": "${CERT_FILE}",
    "key": "${KEY_FILE}",
    "sni": "$(json_escape "$sni")"
  }
}
EOF

  chmod 600 "$CONFIG_FILE"
}

write_info() {
  local port="$1"
  local password="$2"
  local sni="$3"

  mkdir -p "$CONFIG_DIR"
  cat > "$INFO_FILE" <<EOF
# Generated by server.sh. Keep this file private.
server: <你的服务器 IP 或域名>
port: ${port}
password: ${password}
sni: ${sni}
skip-cert-verify: true
config: ${CONFIG_FILE}
cert: ${CERT_FILE}
key: ${KEY_FILE}
EOF

  chmod 600 "$INFO_FILE"
}

write_service() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=trojan-go server
Documentation=https://github.com/${TROJAN_REPO}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${TROJAN_BIN} -config ${CONFIG_FILE}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
}

open_firewall() {
  local port="$1"

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    log "检测到 ufw，自动放行 ${port}/tcp"
    ufw allow "${port}/tcp"
    return
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    log "检测到 firewalld，自动放行 ${port}/tcp"
    firewall-cmd --add-port="${port}/tcp" --permanent
    firewall-cmd --reload
  fi
}

server_ready() {
  [ -x "$TROJAN_BIN" ] && [ -f "$CONFIG_FILE" ] && [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]
}

ensure_runtime() {
  install_packages
  install_trojan_go
  write_service
}

install_server() {
  local port password sni

  need_root install
  install_packages

  port="$(ask "绑定端口" "443")"
  validate_port "$port"
  password="$(ask "trojan 密码" "$(random_password)")"
  validate_text "trojan 密码" "$password"
  sni="$(ask "SNI/证书名称" "$(default_sni)")"
  validate_sni "$sni"

  install_trojan_go
  generate_certificate "$sni"
  write_config "$port" "$password" "$sni"
  write_info "$port" "$password" "$sni"
  write_service
  open_firewall "$port"

  systemctl enable --now "$SERVICE_NAME"

  cat <<EOF

安装完成。
服务端连接信息:
  server: <你的服务器 IP 或域名>
  port: ${port}
  password: ${password}
  sni: ${sni}
  saved: ${INFO_FILE}

查看状态:
  sudo systemctl status ${SERVICE_NAME}
EOF
}

start_or_restart() {
  local action="$1"

  need_root "$action"
  if ! server_ready; then
    log "未检测到完整安装，进入安装流程。"
    install_server
    return
  fi

  ensure_runtime
  systemctl enable "$SERVICE_NAME"
  systemctl "$action" "$SERVICE_NAME"
}

uninstall_server() {
  local answer=""

  need_root uninstall
  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE" "$TROJAN_BIN"
  systemctl daemon-reload
  systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true

  if [ -t 0 ]; then
    read -r -p "是否删除 ${CONFIG_DIR} 下的配置和证书? [y/N]: " answer
    case "$answer" in
      y | Y | yes | YES) rm -rf "$CONFIG_DIR" ;;
      *) log "保留配置目录: ${CONFIG_DIR}" ;;
    esac
  else
    log "保留配置目录: ${CONFIG_DIR}"
  fi
}

service_cmd() {
  local action="$1"

  need_root "$action"
  need_apt_system
  systemctl "$action" "$SERVICE_NAME"
}

main() {
  case "${1:-help}" in
    install) install_server ;;
    start) start_or_restart start ;;
    stop) service_cmd stop ;;
    restart) start_or_restart restart ;;
    status) service_cmd status ;;
    uninstall) uninstall_server ;;
    help | -h | --help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
