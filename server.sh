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
SYSTEMD_SERVICE_FILE="/etc/systemd/system/trojan-go.service"
INIT_SERVICE_FILE="/etc/init.d/trojan-go"
SERVICE_NAME="trojan-go"
PID_FILE="/var/run/trojan-go.pid"
LOG_FILE="/var/log/trojan-go.log"
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
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y "$@"
      ;;
    dnf)
      dnf install -y "$@"
      ;;
    yum)
      yum install -y "$@"
      ;;
    zypper)
      zypper --non-interactive install "$@"
      ;;
    apk)
      apk add --no-cache "$@"
      ;;
  esac
}

need_openssl() {
  if command -v openssl >/dev/null 2>&1; then
    return
  fi

  log "未找到 openssl，尝试自动安装。"
  install_packages openssl ca-certificates || die "未找到 openssl，且自动安装失败。"
  command -v openssl >/dev/null 2>&1 || die "安装后仍未找到 openssl。"
}

download_file() {
  local url="$1"
  local output="$2"

  mkdir -p "$(dirname "$output")"

  if command -v curl >/dev/null 2>&1; then
    curl -fL "$url" -o "$output"
    return
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -O "$output" "$url"
    return
  fi

  if command -v python3 >/dev/null 2>&1; then
    DOWNLOAD_URL="$url" DOWNLOAD_OUTPUT="$output" python3 - <<'PY'
import os
import urllib.request

url = os.environ["DOWNLOAD_URL"]
output = os.environ["DOWNLOAD_OUTPUT"]
with urllib.request.urlopen(url, timeout=60) as response, open(output, "wb") as fh:
    fh.write(response.read())
PY
    return
  fi

  die "未找到 curl/wget/python3，无法下载文件: ${url}"
}

extract_zip() {
  local archive="$1"
  local dest="$2"

  mkdir -p "$dest"

  if command -v unzip >/dev/null 2>&1; then
    unzip -q "$archive" -d "$dest"
    return
  fi

  if command -v python3 >/dev/null 2>&1; then
    ZIP_ARCHIVE="$archive" ZIP_DEST="$dest" python3 - <<'PY'
import os
import zipfile

with zipfile.ZipFile(os.environ["ZIP_ARCHIVE"]) as zf:
    zf.extractall(os.environ["ZIP_DEST"])
PY
    return
  fi

  if command -v jar >/dev/null 2>&1; then
    (
      cd "$dest"
      jar xf "$archive"
    )
    return
  fi

  die "未找到 unzip/python3/jar，无法解压: ${archive}"
}

systemd_running() {
  [ "$(ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]')" = "systemd" ] &&
    command -v systemctl >/dev/null 2>&1
}

service_available() {
  command -v service >/dev/null 2>&1 && [ -d /etc/init.d ]
}

service_mode() {
  if systemd_running; then
    printf 'systemd'
    return
  fi

  if service_available; then
    printf 'sysv'
    return
  fi

  printf 'foreground'
}

enable_service() {
  case "$(service_mode)" in
    systemd)
      systemctl enable "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
      ;;
    sysv)
      if command -v chkconfig >/dev/null 2>&1; then
        chkconfig --add "$SERVICE_NAME" >/dev/null 2>&1 || true
        chkconfig "$SERVICE_NAME" on >/dev/null 2>&1 || true
      elif command -v update-rc.d >/dev/null 2>&1; then
        update-rc.d "$SERVICE_NAME" defaults >/dev/null 2>&1 || true
      elif command -v rc-update >/dev/null 2>&1; then
        rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 || true
      fi
      ;;
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
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
    return
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY'
import secrets
print(secrets.token_hex(16))
PY
    return
  fi

  od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
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
    if ! download_file "$url" "$archive"; then
      rm -rf "$tmp_dir"
      die "下载 trojan-go 失败。你也可以手动下载 ${file} 后放到 ${archive}"
    fi
  else
    log "检测到本地缓存: ${archive}"
  fi

  extract_zip "$archive" "$tmp_dir"
  bin_file="$(find "$tmp_dir" -type f -name trojan-go | head -n 1 || true)"
  [ -n "$bin_file" ] || die "压缩包中未找到 trojan-go: ${archive}"

  install -m 0755 "$bin_file" "$TROJAN_BIN"
  rm -rf "$tmp_dir"
  log "已安装 trojan-go: ${TROJAN_BIN}"
}

generate_certificate() {
  local sni="$1"
  local san

  need_openssl
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

write_systemd_service() {
  cat > "$SYSTEMD_SERVICE_FILE" <<EOF
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

write_init_service() {
  cat > "$INIT_SERVICE_FILE" <<EOF
#!/bin/sh
BIN="${TROJAN_BIN}"
CFG="${CONFIG_FILE}"
PID_FILE="${PID_FILE}"
LOG_FILE="${LOG_FILE}"

is_running() {
  [ -f "\$PID_FILE" ] && kill -0 "\$(cat "\$PID_FILE" 2>/dev/null)" 2>/dev/null
}

start() {
  if is_running; then
    echo "${SERVICE_NAME} is already running"
    exit 0
  fi
  mkdir -p "\$(dirname "\$PID_FILE")" "\$(dirname "\$LOG_FILE")"
  nohup "\$BIN" -config "\$CFG" >> "\$LOG_FILE" 2>&1 &
  echo \$! > "\$PID_FILE"
  sleep 1
  is_running || exit 1
}

stop() {
  if ! is_running; then
    echo "${SERVICE_NAME} is not running"
    rm -f "\$PID_FILE"
    exit 0
  fi
  kill "\$(cat "\$PID_FILE")"
  sleep 1
  rm -f "\$PID_FILE"
}

status() {
  if is_running; then
    echo "${SERVICE_NAME} is running with pid \$(cat "\$PID_FILE")"
    exit 0
  fi
  echo "${SERVICE_NAME} is not running"
  exit 1
}

case "\${1:-}" in
  start) start ;;
  stop) stop ;;
  restart) stop || true; start ;;
  status) status ;;
  *) echo "Usage: \$0 {start|stop|restart|status}"; exit 1 ;;
esac
EOF

  chmod 755 "$INIT_SERVICE_FILE"
}

write_service_files() {
  case "$(service_mode)" in
    systemd)
      write_systemd_service
      ;;
    sysv)
      write_init_service
      ;;
    foreground)
      log "未检测到 systemd 或 service，后续将以前台方式运行。"
      ;;
  esac
}

start_managed_server() {
  case "$(service_mode)" in
    systemd)
      enable_service
      systemctl start "${SERVICE_NAME}.service"
      ;;
    sysv)
      enable_service
      if service "$SERVICE_NAME" start; then
        return
      fi
      log "service 启动失败，回退到前台方式运行。"
      exec "$TROJAN_BIN" -config "$CONFIG_FILE"
      ;;
    foreground)
      log "未检测到后台服务管理器，正在以前台方式运行 trojan-go。"
      exec "$TROJAN_BIN" -config "$CONFIG_FILE"
      ;;
  esac
}

restart_managed_server() {
  case "$(service_mode)" in
    systemd)
      enable_service
      systemctl restart "${SERVICE_NAME}.service"
      ;;
    sysv)
      enable_service
      if service "$SERVICE_NAME" restart; then
        return
      fi
      log "service 重启失败，回退到前台方式运行。"
      exec "$TROJAN_BIN" -config "$CONFIG_FILE"
      ;;
    foreground)
      log "未检测到后台服务管理器，restart 会以前台方式重新运行 trojan-go。"
      exec "$TROJAN_BIN" -config "$CONFIG_FILE"
      ;;
  esac
}

stop_managed_server() {
  case "$(service_mode)" in
    systemd)
      systemctl stop "${SERVICE_NAME}.service"
      ;;
    sysv)
      service "$SERVICE_NAME" stop
      ;;
    foreground)
      log "当前是前台模式。请在运行 trojan-go 的终端中按 Ctrl-C 停止。"
      ;;
  esac
}

status_managed_server() {
  case "$(service_mode)" in
    systemd)
      systemctl status "${SERVICE_NAME}.service"
      ;;
    sysv)
      service "$SERVICE_NAME" status
      ;;
    foreground)
      printf 'Service mode: foreground\n'
      printf 'Start command: %s -config %s\n' "$TROJAN_BIN" "$CONFIG_FILE"
      ;;
  esac
}

server_ready() {
  [ -x "$TROJAN_BIN" ] && [ -f "$CONFIG_FILE" ] && [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]
}

open_firewall() {
  local port="$1"

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    log "检测到 ufw，自动放行 ${port}/tcp"
    ufw allow "${port}/tcp" || true
    return
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    log "检测到 firewalld，自动放行 ${port}/tcp"
    firewall-cmd --add-port="${port}/tcp" --permanent || true
    firewall-cmd --reload || true
  fi
}

install_server() {
  local auto_start="${1:-0}"
  local port password sni mode

  need_root install
  mode="$(service_mode)"

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
  write_service_files
  open_firewall "$port"

  cat <<EOF

安装完成。
服务端连接信息:
  server: <你的服务器 IP 或域名>
  port: ${port}
  password: ${password}
  sni: ${sni}
  saved: ${INFO_FILE}
  service-mode: ${mode}
EOF

  if [ "$mode" = "foreground" ] && [ "$auto_start" != "1" ]; then
    cat <<EOF

未检测到 systemd 或 service。
需要时请执行:
  sudo bash server.sh start
EOF
    return
  fi

  if [ "$mode" != "foreground" ]; then
    start_managed_server
    cat <<EOF

查看状态:
  sudo bash server.sh status
EOF
    return
  fi

  printf '\n'
  start_managed_server
}

start_server() {
  need_root start
  if ! server_ready; then
    log "未检测到完整安装，进入安装流程。"
    install_server 1
    return
  fi

  write_service_files
  start_managed_server
}

restart_server() {
  need_root restart
  if ! server_ready; then
    log "未检测到完整安装，进入安装流程。"
    install_server 1
    return
  fi

  write_service_files
  restart_managed_server
}

uninstall_server() {
  local answer=""

  need_root uninstall
  systemctl stop "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
  systemctl disable "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
  service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
  rm -f "$SYSTEMD_SERVICE_FILE" "$INIT_SERVICE_FILE" "$TROJAN_BIN" "$PID_FILE"
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed "${SERVICE_NAME}.service" >/dev/null 2>&1 || true

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

main() {
  case "${1:-help}" in
    install) install_server 0 ;;
    start) start_server ;;
    stop) stop_managed_server ;;
    restart) restart_server ;;
    status) status_managed_server ;;
    uninstall) uninstall_server ;;
    help | -h | --help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
