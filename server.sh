#!/usr/bin/env bash
set -Eeuo pipefail

TROJAN_REPO="p4gefau1t/trojan-go"
TROJAN_BIN="/usr/local/bin/trojan-go"
CONFIG_DIR="/etc/trojan-go"
CONFIG_FILE="${CONFIG_DIR}/config.json"
CERT_DIR="${CONFIG_DIR}/certs"
CERT_FILE="${CERT_DIR}/server.crt"
KEY_FILE="${CERT_DIR}/server.key"
SERVICE_FILE="/etc/systemd/system/trojan-go.service"
SERVICE_NAME="trojan-go.service"
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

This script installs trojan-go on Ubuntu/Debian, writes a systemd service,
and generates a self-signed TLS certificate by default.

Set CLASH_SERVICE_FORCE_DOWNLOAD=1 to re-download trojan-go even when the
binary already exists.
EOF
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "请使用 root 权限运行，例如: sudo bash server.sh $1"
  fi
}

require_apt_system() {
  command -v apt-get >/dev/null 2>&1 || die "当前脚本默认支持 Ubuntu/Debian，需要 apt-get。"
  command -v systemctl >/dev/null 2>&1 || die "未找到 systemctl，无法写入 systemd 服务。"
}

install_packages() {
  local packages=("curl" "unzip" "openssl" "ca-certificates")
  local missing=()
  local pkg

  require_apt_system

  for pkg in "${packages[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      missing+=("$pkg")
    fi
  done

  if [ "${#missing[@]}" -eq 0 ]; then
    log "系统依赖已满足。"
    return
  fi

  log "缺少依赖，自动安装: ${missing[*]}"
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

validate_port() {
  local port="$1"
  if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    die "端口号必须是 1-65535 之间的整数: ${port}"
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

json_escape() {
  local value="${1:-}"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\b'/\\b}
  value=${value//$'\f'/\\f}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

validate_no_control_chars() {
  local label="$1"
  local value="$2"

  if [[ "$value" =~ [[:cntrl:]] ]]; then
    die "${label} 不能包含控制字符。"
  fi
}

validate_sni() {
  local value="$1"

  validate_no_control_chars "SNI/证书名称" "$value"

  if [[ "$value" == *"/"* ]]; then
    die "SNI/证书名称不能包含 /。"
  fi
  if [[ "$value" == *:* ]] && ! [[ "$value" =~ ^[0-9A-Fa-f:.]+$ ]]; then
    die "SNI/证书名称不要包含端口；如需填写 IPv6，只填写 IPv6 地址本身。"
  fi
  if ! [[ "$value" =~ ^[A-Za-z0-9._:-]+$ ]]; then
    die "SNI/证书名称只能包含字母、数字、点、短横线、下划线和冒号。"
  fi
}

default_sni() {
  local host=""
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

backup_file_if_exists() {
  local file="$1"
  local backup_file

  [ -f "$file" ] || return 0
  backup_file="${file}.bak.$(date +%Y%m%d%H%M%S)"
  cp -a "$file" "$backup_file"
  log "已备份已有文件: ${backup_file}"
}

download_trojan_go() {
  local arch
  local url
  local tmp_dir
  local binary_path

  arch="$(detect_arch)"
  url="https://github.com/${TROJAN_REPO}/releases/latest/download/trojan-go-linux-${arch}.zip"
  tmp_dir="$(mktemp -d)"

  log "下载 trojan-go (${arch})"
  if ! curl -fL "$url" -o "${tmp_dir}/trojan-go.zip"; then
    rm -rf "$tmp_dir"
    die "下载 trojan-go 失败。"
  fi
  if ! unzip -q "${tmp_dir}/trojan-go.zip" -d "$tmp_dir"; then
    rm -rf "$tmp_dir"
    die "解压 trojan-go 失败。"
  fi

  binary_path="$(find "$tmp_dir" -type f -name trojan-go | head -n 1 || true)"
  if [ -z "$binary_path" ]; then
    rm -rf "$tmp_dir"
    die "下载包中未找到 trojan-go 二进制文件。"
  fi

  if ! install -m 0755 "$binary_path" "$TROJAN_BIN"; then
    rm -rf "$tmp_dir"
    die "安装 trojan-go 失败。"
  fi
  rm -rf "$tmp_dir"
  log "已安装: ${TROJAN_BIN}"
}

install_trojan_go_if_needed() {
  if [ -x "$TROJAN_BIN" ] && [ "$FORCE_DOWNLOAD" != "1" ]; then
    log "检测到 trojan-go 已存在: ${TROJAN_BIN}"
    "$TROJAN_BIN" -version 2>/dev/null | head -n 1 || true
    log "如需强制重新下载，请设置 CLASH_SERVICE_FORCE_DOWNLOAD=1。"
    return
  fi

  download_trojan_go
}

generate_certificate() {
  local sni="$1"
  local san

  mkdir -p "$CERT_DIR"
  backup_file_if_exists "$CERT_FILE"
  backup_file_if_exists "$KEY_FILE"

  if [[ "$sni" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$sni" == *:* ]]; then
    san="IP:${sni}"
  else
    san="DNS:${sni}"
  fi

  log "生成自签名证书: ${CERT_FILE}"
  if ! openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$KEY_FILE" \
    -out "$CERT_FILE" \
    -days 3650 \
    -subj "/CN=${sni}" \
    -addext "subjectAltName=${san}" >/dev/null 2>&1; then
    log "当前 OpenSSL 不支持 -addext，回退为仅 CN 的自签名证书。"
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "$KEY_FILE" \
      -out "$CERT_FILE" \
      -days 3650 \
      -subj "/CN=${sni}" >/dev/null 2>&1
  fi

  chmod 600 "$KEY_FILE"
  chmod 644 "$CERT_FILE"
}

write_config() {
  local listen_port="$1"
  local password="$2"
  local sni="$3"
  local password_json
  local sni_json

  password_json="$(json_escape "$password")"
  sni_json="$(json_escape "$sni")"

  mkdir -p "$CONFIG_DIR"
  backup_file_if_exists "$CONFIG_FILE"
  cat > "$CONFIG_FILE" <<EOF
{
  "run_type": "server",
  "local_addr": "0.0.0.0",
  "local_port": ${listen_port},
  "remote_addr": "www.cloudflare.com",
  "remote_port": 80,
  "password": [
    "${password_json}"
  ],
  "ssl": {
    "cert": "${CERT_FILE}",
    "key": "${KEY_FILE}",
    "sni": "${sni_json}"
  }
}
EOF
  chmod 600 "$CONFIG_FILE"
  log "已写入配置: ${CONFIG_FILE}"
}

write_systemd_service() {
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
  log "已写入 systemd 服务: ${SERVICE_FILE}"
}

server_config_complete() {
  [ -f "$CONFIG_FILE" ] && [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]
}

ensure_server_runtime() {
  install_packages
  install_trojan_go_if_needed
  write_systemd_service
}

open_firewall_if_present() {
  local listen_port="$1"

  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -qi '^Status: active'; then
      log "检测到 ufw 已启用，自动放行 ${listen_port}/tcp。"
      ufw allow "${listen_port}/tcp"
    else
      log "ufw 未启用，跳过防火墙配置。"
    fi
    return
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    log "检测到 firewalld 已启用，自动放行 ${listen_port}/tcp。"
    firewall-cmd --add-port="${listen_port}/tcp" --permanent
    firewall-cmd --reload
    return
  fi

  log "未检测到已启用的 ufw/firewalld，跳过防火墙配置。"
}

install_server() {
  local listen_port
  local password
  local sni

  require_root install
  install_packages

  listen_port="$(ask_with_default "绑定端口" "443")"
  validate_port "$listen_port"
  password="$(ask_with_default "trojan 密码" "$(random_password)")"
  [ -n "$password" ] || die "密码不能为空。"
  validate_no_control_chars "trojan 密码" "$password"
  sni="$(ask_with_default "SNI/证书名称" "$(default_sni)")"
  [ -n "$sni" ] || die "SNI 不能为空。"
  validate_sni "$sni"

  install_trojan_go_if_needed
  generate_certificate "$sni"
  write_config "$listen_port" "$password" "$sni"
  write_systemd_service
  open_firewall_if_present "$listen_port"

  systemctl enable "$SERVICE_NAME"
  systemctl restart "$SERVICE_NAME"

  cat <<EOF

安装完成。
服务端连接信息:
  server: <你的服务器 IP 或域名>
  port: ${listen_port}
  password: ${password}
  sni: ${sni}
  skip-cert-verify: true

查看状态:
  sudo systemctl status ${SERVICE_NAME}
EOF
}

start_server() {
  require_root start

  if ! server_config_complete; then
    log "未检测到完整服务端安装，进入一键安装流程。"
    install_server
    return
  fi

  ensure_server_runtime
  systemctl enable "$SERVICE_NAME"
  systemctl start "$SERVICE_NAME"
}

restart_server() {
  require_root restart

  if ! server_config_complete; then
    log "未检测到完整服务端安装，进入一键安装流程。"
    install_server
    return
  fi

  ensure_server_runtime
  systemctl enable "$SERVICE_NAME"
  systemctl restart "$SERVICE_NAME"
}

uninstall_server() {
  require_root uninstall

  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload
  systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true

  rm -f "$TROJAN_BIN"

  if [ -t 0 ]; then
    read -r -p "是否删除 ${CONFIG_DIR} 下的配置和证书? [y/N]: " answer
    case "$answer" in
      y | Y | yes | YES) rm -rf "$CONFIG_DIR" ;;
      *) log "保留配置目录: ${CONFIG_DIR}" ;;
    esac
  else
    log "保留配置目录: ${CONFIG_DIR}"
  fi

  log "卸载完成。"
}

systemctl_action() {
  local action="$1"
  require_root "$action"
  require_apt_system
  systemctl "$action" "$SERVICE_NAME"
}

main() {
  local command="${1:-help}"

  case "$command" in
    install) install_server ;;
    start) start_server ;;
    stop) systemctl_action stop ;;
    restart) restart_server ;;
    status) systemctl_action status ;;
    uninstall) uninstall_server ;;
    help | -h | --help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
