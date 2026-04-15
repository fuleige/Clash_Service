#!/usr/bin/env bash
set -Eeuo pipefail

MIHOMO_REPO="MetaCubeX/mihomo"
GEOIP_URL="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb"

CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}"
CACHE_HOME="${XDG_CACHE_HOME:-${HOME}/.cache}"
BIN_DIR="${HOME}/.local/bin"
MIHOMO_BIN="${BIN_DIR}/mihomo"
MIHOMO_CONFIG_DIR="${CONFIG_HOME}/mihomo"
MIHOMO_CONFIG_FILE="${MIHOMO_CONFIG_DIR}/config.yaml"
GEOIP_FILE="${MIHOMO_CONFIG_DIR}/geoip.metadb"
SYSTEMD_USER_DIR="${CONFIG_HOME}/systemd/user"
SYSTEMD_SERVICE_FILE="${SYSTEMD_USER_DIR}/mihomo.service"
STATE_DIR="${CONFIG_HOME}/clash-service"
PROXY_ENV_FILE="${STATE_DIR}/proxy.env"
CLIENT_INFO_FILE="${STATE_DIR}/client-info.txt"
PID_FILE="${STATE_DIR}/mihomo.pid"
LOG_FILE="${STATE_DIR}/mihomo.log"
CACHE_DIR="${CLASH_SERVICE_CACHE_DIR:-${CACHE_HOME}/clash-service}"
FORCE_DOWNLOAD="${CLASH_SERVICE_FORCE_DOWNLOAD:-0}"
SKIP_CONNECTIVITY_CHECK="${CLASH_SERVICE_SKIP_CHECK:-0}"
CONNECTIVITY_TEST_URL="${CLASH_SERVICE_CHECK_URL:-}"
CONNECTIVITY_TIMEOUT_MS="${CLASH_SERVICE_CHECK_TIMEOUT_MS:-8000}"
CONNECTIVITY_CURL_TIMEOUT="${CLASH_SERVICE_CHECK_CURL_TIMEOUT:-12}"
MIHOMO_CONTROLLER_URL="${CLASH_SERVICE_CONTROLLER_URL:-http://127.0.0.1:9090}"
MIHOMO_PROXY_NAME="${CLASH_SERVICE_PROXY_NAME:-trojan-service}"
DEFAULT_LOCAL_PROXY_PORT="7890"
RC_MARKER_BEGIN="# >>> clash-service proxy env >>>"
RC_MARKER_END="# <<< clash-service proxy env <<<"
ROOT_USAGE_WARNING_SHOWN=0

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
  bash client.sh update
  bash client.sh start
  bash client.sh stop
  bash client.sh restart
  bash client.sh status
  bash client.sh enable
  bash client.sh disable
  bash client.sh uninstall
  bash client.sh help

Env:
  CLASH_SERVICE_CACHE_DIR=/path/to/cache
  CLASH_SERVICE_FORCE_DOWNLOAD=1
  CLASH_SERVICE_SKIP_CHECK=1
  CLASH_SERVICE_CHECK_URL=https://example.com
  CLASH_SERVICE_CONTROLLER_URL=http://127.0.0.1:9090
EOF
}

need_user() {
  if [ "$(id -u)" -eq 0 ] && [ "$ROOT_USAGE_WARNING_SHOWN" -eq 0 ]; then
    ROOT_USAGE_WARNING_SHOWN=1
    log "警告: 检测到以 root 身份运行 client.sh。"
    log "继续执行会写入当前用户目录: ${BIN_DIR}、${MIHOMO_CONFIG_DIR}、${STATE_DIR}"
    log "更推荐使用普通用户运行；否则客户端会安装到 root 自己的环境中。"
  fi
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

ensure_download_tool() {
  if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; then
    return
  fi

  log "未找到 curl/wget/python3，尝试自动安装 curl。"
  install_packages curl ca-certificates || die "未找到 curl/wget/python3，且自动安装失败。"
}

ensure_http_client() {
  if command -v curl >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; then
    return
  fi

  log "未找到 curl/python3，尝试自动安装 curl。"
  install_packages curl ca-certificates || true
  if command -v curl >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; then
    return
  fi

  die "未找到 curl 或 python3，无法执行本地连通性检测。"
}

download_file() {
  local url="$1"
  local output="$2"

  ensure_download_tool
  mkdir -p "$(dirname "$output")"

  if command -v curl >/dev/null 2>&1; then
    curl -fL "$url" -o "$output"
    return
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -O "$output" "$url"
    return
  fi

  DOWNLOAD_URL="$url" DOWNLOAD_OUTPUT="$output" python3 - <<'PY'
import os
import urllib.request

url = os.environ["DOWNLOAD_URL"]
output = os.environ["DOWNLOAD_OUTPUT"]
with urllib.request.urlopen(url, timeout=60) as response, open(output, "wb") as fh:
    fh.write(response.read())
PY
}

http_get() {
  local url="$1"
  local timeout="$2"
  local no_proxy="${3:-0}"

  ensure_http_client

  if command -v curl >/dev/null 2>&1; then
    if [ "$no_proxy" = "1" ]; then
      env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
        curl -fsS --noproxy '*' --max-time "$timeout" "$url"
    else
      curl -fsS --max-time "$timeout" "$url"
    fi
    return
  fi

  HTTP_GET_URL="$url" HTTP_GET_TIMEOUT="$timeout" HTTP_GET_NO_PROXY="$no_proxy" python3 - <<'PY'
import os
import urllib.request

url = os.environ["HTTP_GET_URL"]
timeout = float(os.environ["HTTP_GET_TIMEOUT"])
handlers = []
if os.environ.get("HTTP_GET_NO_PROXY") == "1":
    handlers.append(urllib.request.ProxyHandler({}))
opener = urllib.request.build_opener(*handlers)
request = urllib.request.Request(url, headers={"User-Agent": "clash-service"})
with opener.open(request, timeout=timeout) as response:
    print(response.read().decode("utf-8", "replace"))
PY
}

build_delay_url() {
  local test_url="$1"

  if command -v python3 >/dev/null 2>&1; then
    DELAY_BASE="${MIHOMO_CONTROLLER_URL}/proxies/${MIHOMO_PROXY_NAME}/delay" \
      DELAY_TIMEOUT="$CONNECTIVITY_TIMEOUT_MS" \
      DELAY_TEST_URL="$test_url" \
      python3 - <<'PY'
import os
import urllib.parse

base = os.environ["DELAY_BASE"]
query = urllib.parse.urlencode({
    "timeout": os.environ["DELAY_TIMEOUT"],
    "url": os.environ["DELAY_TEST_URL"],
})
print(f"{base}?{query}")
PY
    return
  fi

  printf '%s/proxies/%s/delay?timeout=%s&url=%s' \
    "$MIHOMO_CONTROLLER_URL" \
    "$MIHOMO_PROXY_NAME" \
    "$CONNECTIVITY_TIMEOUT_MS" \
    "$test_url"
}

connectivity_test_urls() {
  if [ -n "$CONNECTIVITY_TEST_URL" ]; then
    printf '%s\n' "$CONNECTIVITY_TEST_URL"
    return
  fi

  cat <<'EOF'
https://www.cloudflare.com/cdn-cgi/trace
https://www.google.com
http://cp.cloudflare.com/generate_204
https://www.gstatic.com/generate_204
http://www.msftconnecttest.com/connecttest.txt
EOF
}

systemd_running() {
  [ "$(ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]')" = "systemd" ] &&
    command -v systemctl >/dev/null 2>&1
}

service_available() {
  command -v service >/dev/null 2>&1 && [ -d /etc/init.d ]
}

user_bus_ready() {
  command -v systemctl >/dev/null 2>&1 &&
    systemctl --user show-environment >/dev/null 2>&1
}

enable_linger_if_possible() {
  local current_user

  systemd_running || return
  command -v loginctl >/dev/null 2>&1 || return
  if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
    return
  fi

  current_user="$(id -un)"
  if loginctl show-user "$current_user" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
    return
  fi

  log "尝试启用 systemd linger。"
  run_root loginctl enable-linger "$current_user" || true
}

client_service_name() {
  printf 'mihomo-%s' "$(id -un | tr -c 'A-Za-z0-9._-' '_')"
}

client_service_mode() {
  if systemd_running; then
    if user_bus_ready; then
      printf 'systemd-user'
      return
    fi

    enable_linger_if_possible
    if user_bus_ready; then
      printf 'systemd-user'
      return
    fi
  fi

  if service_available && { [ "$(id -u)" -eq 0 ] || command -v sudo >/dev/null 2>&1; }; then
    printf 'sysv'
    return
  fi

  printf 'foreground'
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

  ensure_download_tool
  if command -v curl >/dev/null 2>&1; then
    release_json="$(curl -fsSL "https://api.github.com/repos/${MIHOMO_REPO}/releases/latest")" || return 1
  elif command -v python3 >/dev/null 2>&1; then
    release_json="$(
      DOWNLOAD_URL="https://api.github.com/repos/${MIHOMO_REPO}/releases/latest" python3 - <<'PY'
import os
import urllib.request

with urllib.request.urlopen(os.environ["DOWNLOAD_URL"], timeout=30) as response:
    print(response.read().decode("utf-8", "replace"))
PY
    )" || return 1
  else
    release_json="$(wget -qO- "https://api.github.com/repos/${MIHOMO_REPO}/releases/latest")" || return 1
  fi

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

extract_gzip() {
  local archive="$1"
  local output="$2"

  if command -v gzip >/dev/null 2>&1; then
    gzip -dc "$archive" > "$output"
    return
  fi

  if command -v gunzip >/dev/null 2>&1; then
    gunzip -c "$archive" > "$output"
    return
  fi

  if command -v python3 >/dev/null 2>&1; then
    GZIP_ARCHIVE="$archive" GZIP_OUTPUT="$output" python3 - <<'PY'
import gzip
import os

with gzip.open(os.environ["GZIP_ARCHIVE"], "rb") as source, open(os.environ["GZIP_OUTPUT"], "wb") as target:
    target.write(source.read())
PY
    return
  fi

  die "未找到 gzip/gunzip/python3，无法解压: ${archive}"
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
    if ! download_file "$url" "$archive"; then
      die "下载 mihomo 失败。你也可以手动下载 ${url##*/} 后放到 ${archive}"
    fi
  else
    log "检测到本地缓存: ${archive}"
  fi

  tmp_dir="$(mktemp -d)"
  tmp_bin="${tmp_dir}/mihomo"
  extract_gzip "$archive" "$tmp_bin"
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
    if ! download_file "$GEOIP_URL" "$cache_file"; then
      die "下载 geoip.metadb 失败。你也可以手动下载后放到 ${cache_file}"
    fi
  fi

  install -m 0644 "$cache_file" "$GEOIP_FILE"
}

current_local_proxy_port() {
  local port=""

  if [ -f "$MIHOMO_CONFIG_FILE" ]; then
    port="$(sed -n 's/^[[:space:]]*port:[[:space:]]*\([0-9]\+\).*/\1/p' "$MIHOMO_CONFIG_FILE" | head -n 1)"
    if [ -z "$port" ]; then
      port="$(sed -n 's/^[[:space:]]*mixed-port:[[:space:]]*\([0-9]\+\).*/\1/p' "$MIHOMO_CONFIG_FILE" | head -n 1)"
    fi
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
port: ${local_proxy_port}
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

announce_client_info_source() {
  log "默认读取连接信息文件: ${CLIENT_INFO_FILE}"
  if [ -f "$CLIENT_INFO_FILE" ]; then
    log "检测到已有连接信息，将优先使用该文件中的值。"
  else
    log "未检测到已有连接信息，首次安装后会写入该文件。"
  fi
}

read_saved_client_field() {
  local field="$1"

  [ -f "$CLIENT_INFO_FILE" ] || return 0
  sed -n "s/^${field}:[[:space:]]*//p" "$CLIENT_INFO_FILE" | head -n 1
}

read_current_mihomo_proxy_field() {
  local field="$1"

  [ -f "$MIHOMO_CONFIG_FILE" ] || return 0
  awk -v proxy_name="$MIHOMO_PROXY_NAME" -v field="$field" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }

    function unquote(value) {
      value = trim(value)
      if (value ~ /^".*"$/ || value ~ /^'\''.*'\''$/) {
        value = substr(value, 2, length(value) - 2)
      }
      gsub(/\047\047/, "\047", value)
      return value
    }

    /^proxies:[[:space:]]*$/ { in_proxies = 1; next }
    in_proxies && /^[^[:space:]#][^:]*:[[:space:]]*/ { exit }
    in_proxies && /^  - / {
      current_target = 0
      if ($0 ~ /^  - name:[[:space:]]*/) {
        value = $0
        sub(/^  - name:[[:space:]]*/, "", value)
        if (unquote(value) == proxy_name) {
          current_target = 1
        }
      }
      next
    }
    in_proxies && current_target && $0 ~ ("^    " field ":[[:space:]]*") {
      value = $0
      sub("^    " field ":[[:space:]]*", "", value)
      print unquote(value)
      exit
    }
  ' "$MIHOMO_CONFIG_FILE" | head -n 1
}

client_connection_default() {
  local field="$1"
  local fallback="$2"
  local value=""

  value="$(read_saved_client_field "$field")"
  if [ -z "$value" ]; then
    value="$(read_current_mihomo_proxy_field "$field")"
  fi

  printf '%s' "${value:-$fallback}"
}

update_mihomo_proxy_connection() {
  local server_addr="$1"
  local server_port="$2"
  local password="$3"
  local sni="$4"
  local tmp_file
  local server_line port_line password_line sni_line

  [ -f "$MIHOMO_CONFIG_FILE" ] || return 1

  tmp_file="$(mktemp "${MIHOMO_CONFIG_FILE}.tmp.XXXXXX")"
  server_line="    server: $(yaml_quote "$server_addr")"
  port_line="    port: ${server_port}"
  password_line="    password: $(yaml_quote "$password")"
  sni_line="    sni: $(yaml_quote "$sni")"

  if awk \
    -v proxy_name="$MIHOMO_PROXY_NAME" \
    -v server_line="$server_line" \
    -v port_line="$port_line" \
    -v password_line="$password_line" \
    -v sni_line="$sni_line" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }

    function unquote(value) {
      value = trim(value)
      if (value ~ /^".*"$/ || value ~ /^'\''.*'\''$/) {
        value = substr(value, 2, length(value) - 2)
      }
      gsub(/\047\047/, "\047", value)
      return value
    }

    function flush_missing() {
      if (!updated_server) print server_line
      if (!updated_port) print port_line
      if (!updated_password) print password_line
      if (!updated_sni) print sni_line
    }

    BEGIN {
      in_proxies = 0
      in_target = 0
      found_target = 0
      updated_server = 0
      updated_port = 0
      updated_password = 0
      updated_sni = 0
    }

    /^proxies:[[:space:]]*$/ {
      if (in_target) {
        flush_missing()
        in_target = 0
      }
      in_proxies = 1
      print
      next
    }

    in_proxies && /^[^[:space:]#][^:]*:[[:space:]]*/ {
      if (in_target) {
        flush_missing()
        in_target = 0
      }
      in_proxies = 0
      print
      next
    }

    in_proxies && /^  - / {
      if (in_target) {
        flush_missing()
        in_target = 0
      }

      updated_server = 0
      updated_port = 0
      updated_password = 0
      updated_sni = 0

      if ($0 ~ /^  - name:[[:space:]]*/) {
        value = $0
        sub(/^  - name:[[:space:]]*/, "", value)
        if (unquote(value) == proxy_name) {
          in_target = 1
          found_target = 1
        }
      }

      print
      next
    }

    in_target && /^    server:[[:space:]]*/ {
      print server_line
      updated_server = 1
      next
    }

    in_target && /^    port:[[:space:]]*/ {
      print port_line
      updated_port = 1
      next
    }

    in_target && /^    password:[[:space:]]*/ {
      print password_line
      updated_password = 1
      next
    }

    in_target && /^    sni:[[:space:]]*/ {
      print sni_line
      updated_sni = 1
      next
    }

    {
      print
    }

    END {
      if (in_target) {
        flush_missing()
      }
      if (!found_target) {
        exit 3
      }
    }
  ' "$MIHOMO_CONFIG_FILE" > "$tmp_file"; then
    mv "$tmp_file" "$MIHOMO_CONFIG_FILE"
    chmod 600 "$MIHOMO_CONFIG_FILE"
    return 0
  fi

  rm -f "$tmp_file"
  return 1
}

client_service_running() {
  local name

  case "$(client_service_mode)" in
    systemd-user)
      systemctl --user is-active --quiet mihomo.service
      ;;
    sysv)
      name="$(client_service_name)"
      run_root service "$name" status >/dev/null 2>&1
      ;;
    foreground)
      return 1
      ;;
  esac
}

restore_client_config_from_saved_info() {
  local server_addr server_port password sni

  [ -f "$CLIENT_INFO_FILE" ] || return 1

  announce_client_info_source
  server_addr="$(read_saved_client_field server)"
  server_port="$(read_saved_client_field port)"
  password="$(read_saved_client_field password)"
  sni="$(read_saved_client_field sni)"

  [ -n "$server_addr" ] || die "已保存连接信息文件缺少 server: ${CLIENT_INFO_FILE}"
  [ -n "$server_port" ] || die "已保存连接信息文件缺少 port: ${CLIENT_INFO_FILE}"
  [ -n "$password" ] || die "已保存连接信息文件缺少 password: ${CLIENT_INFO_FILE}"
  [ -n "$sni" ] || die "已保存连接信息文件缺少 sni: ${CLIENT_INFO_FILE}"
  validate_port "$server_port"

  log "正在根据保存的连接信息重新生成客户端配置。"
  write_mihomo_config "$server_addr" "$server_port" "$password" "$sni"
  write_client_info "$server_addr" "$server_port" "$password" "$sni"
  return 0
}

write_systemd_service() {
  mkdir -p "$SYSTEMD_USER_DIR"
  cat > "$SYSTEMD_SERVICE_FILE" <<EOF
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

write_init_service() {
  local name tmp_file service_file

  name="$(client_service_name)"
  service_file="/etc/init.d/${name}"
  tmp_file="$(mktemp)"
  cat > "$tmp_file" <<EOF
#!/bin/sh
USER_NAME=$(shell_quote "$(id -un)")
BIN=$(shell_quote "$MIHOMO_BIN")
CFG_DIR=$(shell_quote "$MIHOMO_CONFIG_DIR")
CFG_FILE=$(shell_quote "$MIHOMO_CONFIG_FILE")
STATE_DIR=$(shell_quote "$STATE_DIR")
PID_FILE=$(shell_quote "$PID_FILE")
LOG_FILE=$(shell_quote "$LOG_FILE")

run_as_user() {
  su -s /bin/sh "\$USER_NAME" -c "\$1"
}

is_running() {
  [ -f "\$PID_FILE" ] && kill -0 "\$(cat "\$PID_FILE" 2>/dev/null)" 2>/dev/null
}

start() {
  if is_running; then
    echo "${name} is already running"
    exit 0
  fi
  mkdir -p "\$STATE_DIR"
  chown "\$USER_NAME":"\$USER_NAME" "\$STATE_DIR" 2>/dev/null || true
  run_as_user "mkdir -p '$STATE_DIR' && nohup '$MIHOMO_BIN' -d '$MIHOMO_CONFIG_DIR' -f '$MIHOMO_CONFIG_FILE' >> '$LOG_FILE' 2>&1 & echo \\\$! > '$PID_FILE'"
  sleep 1
  is_running || exit 1
}

stop() {
  if ! is_running; then
    echo "${name} is not running"
    rm -f "\$PID_FILE"
    exit 0
  fi
  kill "\$(cat "\$PID_FILE")"
  sleep 1
  rm -f "\$PID_FILE"
}

status() {
  if is_running; then
    echo "${name} is running with pid \$(cat "\$PID_FILE")"
    exit 0
  fi
  echo "${name} is not running"
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

  run_root install -m 0755 "$tmp_file" "$service_file"
  rm -f "$tmp_file"
}

enable_service() {
  local name

  case "$(client_service_mode)" in
    systemd-user)
      systemctl --user enable mihomo.service >/dev/null 2>&1 || true
      ;;
    sysv)
      name="$(client_service_name)"
      if command -v chkconfig >/dev/null 2>&1; then
        run_root chkconfig --add "$name" >/dev/null 2>&1 || true
        run_root chkconfig "$name" on >/dev/null 2>&1 || true
      elif command -v update-rc.d >/dev/null 2>&1; then
        run_root update-rc.d "$name" defaults >/dev/null 2>&1 || true
      elif command -v rc-update >/dev/null 2>&1; then
        run_root rc-update add "$name" default >/dev/null 2>&1 || true
      fi
      ;;
  esac
}

write_service_files() {
  case "$(client_service_mode)" in
    systemd-user)
      write_systemd_service
      ;;
    sysv)
      write_init_service
      ;;
    foreground)
      log "未检测到可用的 systemd --user 或 service，后续将以前台方式运行。"
      ;;
  esac
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
  local rc_file proxy_env_path

  rc_file="$(detect_rc_file)"
  proxy_env_path="$(shell_quote "$PROXY_ENV_FILE")"

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
${RC_MARKER_END}
EOF
}

remove_shell_loader() {
  remove_loader_from_file "$(detect_rc_file)"
}

write_proxy_enabled_env() {
  local port http_proxy_url

  port="$(current_local_proxy_port)"
  http_proxy_url="http://127.0.0.1:${port}"
  mkdir -p "$STATE_DIR"
  cat > "$PROXY_ENV_FILE" <<EOF
# Generated by client.sh. Source this file to apply in the current shell.
export http_proxy="${http_proxy_url}"
export https_proxy="${http_proxy_url}"
export HTTP_PROXY="\$http_proxy"
export HTTPS_PROXY="\$https_proxy"
unset all_proxy
unset ALL_PROXY
EOF

  log "已启用后续新终端代理。当前终端如需立即生效，请执行: source ${PROXY_ENV_FILE}"
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

  log "已关闭后续新终端代理。当前终端如需立即生效，请执行: source ${PROXY_ENV_FILE}"
}

start_service() {
  local name

  case "$(client_service_mode)" in
    systemd-user)
      systemctl --user daemon-reload
      enable_service
      systemctl --user start mihomo.service
      ;;
    sysv)
      name="$(client_service_name)"
      enable_service
      if run_root service "$name" start; then
        return
      fi
      write_proxy_enabled_env
      log "service 启动失败，回退到前台方式运行 mihomo。停止时请按 Ctrl-C。"
      exec "$MIHOMO_BIN" -d "$MIHOMO_CONFIG_DIR" -f "$MIHOMO_CONFIG_FILE"
      ;;
    foreground)
      write_proxy_enabled_env
      log "未检测到后台服务管理器，正在以前台方式运行 mihomo。停止时请按 Ctrl-C。"
      exec "$MIHOMO_BIN" -d "$MIHOMO_CONFIG_DIR" -f "$MIHOMO_CONFIG_FILE"
      ;;
  esac
}

stop_service() {
  local name

  case "$(client_service_mode)" in
    systemd-user)
      systemctl --user stop mihomo.service
      ;;
    sysv)
      name="$(client_service_name)"
      run_root service "$name" stop
      ;;
    foreground)
      log "当前是前台模式。请在运行 mihomo 的终端中按 Ctrl-C 停止。"
      ;;
  esac
}

restart_service() {
  local name

  case "$(client_service_mode)" in
    systemd-user)
      systemctl --user daemon-reload
      enable_service
      systemctl --user restart mihomo.service
      ;;
    sysv)
      name="$(client_service_name)"
      enable_service
      if run_root service "$name" restart; then
        return
      fi
      write_proxy_enabled_env
      log "service 重启失败，回退到前台方式运行 mihomo。停止时请按 Ctrl-C。"
      exec "$MIHOMO_BIN" -d "$MIHOMO_CONFIG_DIR" -f "$MIHOMO_CONFIG_FILE"
      ;;
    foreground)
      write_proxy_enabled_env
      log "未检测到后台服务管理器，restart 会以前台方式重新运行 mihomo。"
      exec "$MIHOMO_BIN" -d "$MIHOMO_CONFIG_DIR" -f "$MIHOMO_CONFIG_FILE"
      ;;
  esac
}

wait_controller() {
  local attempt

  for attempt in $(seq 1 15); do
    if http_get "${MIHOMO_CONTROLLER_URL}/version" 1 1 >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  return 1
}

delay_request() {
  local test_url="$1"

  if command -v curl >/dev/null 2>&1; then
    env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
      curl -fsS --noproxy '*' --max-time "$CONNECTIVITY_CURL_TIMEOUT" \
      -G "${MIHOMO_CONTROLLER_URL}/proxies/${MIHOMO_PROXY_NAME}/delay" \
      --data-urlencode "timeout=${CONNECTIVITY_TIMEOUT_MS}" \
      --data-urlencode "url=${test_url}"
    return
  fi

  http_get "$(build_delay_url "$test_url")" "$CONNECTIVITY_CURL_TIMEOUT" 1
}

proxy_probe() {
  local test_url="$1"
  local local_proxy_port

  command -v curl >/dev/null 2>&1 || return 1
  local_proxy_port="$(current_local_proxy_port)"

  env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
    curl -fsS --proxy "http://127.0.0.1:${local_proxy_port}" --max-time "$CONNECTIVITY_CURL_TIMEOUT" \
    "$test_url" >/dev/null
}

check_proxy_connectivity() {
  local response="" test_url="" attempted="0"
  local delay_output="" proxy_output=""
  local local_proxy_port

  if [ "$SKIP_CONNECTIVITY_CHECK" = "1" ]; then
    log "已跳过代理连通性检测。"
    return
  fi

  validate_positive_int "CLASH_SERVICE_CHECK_TIMEOUT_MS" "$CONNECTIVITY_TIMEOUT_MS"
  validate_positive_int "CLASH_SERVICE_CHECK_CURL_TIMEOUT" "$CONNECTIVITY_CURL_TIMEOUT"
  local_proxy_port="$(current_local_proxy_port)"

  log "等待 mihomo controller: ${MIHOMO_CONTROLLER_URL}"
  if ! wait_controller; then
    write_proxy_disabled_env
    die "mihomo 已启动，但本地 controller 不可访问。请查看日志。"
  fi
  log "本地代理入口: http://127.0.0.1:${local_proxy_port}"

  while IFS= read -r test_url; do
    [ -n "$test_url" ] || continue
    attempted="1"

    log "检测代理节点: ${MIHOMO_PROXY_NAME} -> ${test_url}"

    if delay_output="$(delay_request "$test_url" 2>&1)"; then
      response="$delay_output"
    else
      response="$delay_output"
    fi
    if [ -n "$response" ] &&
      printf '%s' "$response" | grep -Eq '"delay"[[:space:]]*:[[:space:]]*[0-9]+'; then
      log "代理连通性检测通过(controller delay): ${response}"
      return
    fi
    if [ -n "$response" ]; then
      log "controller delay 失败: ${response}"
    else
      log "controller delay 失败: 无返回结果"
    fi

    if proxy_output="$(proxy_probe "$test_url" 2>&1)"; then
      log "代理连通性检测通过(local proxy fetch): ${test_url}"
      return
    fi
    if [ -n "$proxy_output" ]; then
      log "local proxy fetch 失败: ${proxy_output}"
    else
      log "local proxy fetch 失败: 无返回结果"
    fi
  done <<< "$(connectivity_test_urls)"

  [ "$attempted" = "1" ] || die "未配置任何可用的代理检测地址。"
  log "代理节点连通性检测未通过，但已保留当前运行中的 mihomo。"
  log "这通常表示默认检测 URL 不适合当前网络，并不一定代表节点不可用。"
  log "如需指定检测地址，可设置 CLASH_SERVICE_CHECK_URL；如确认代理可用，也可忽略此提示。"
}

client_ready() {
  [ -f "$MIHOMO_CONFIG_FILE" ]
}

ensure_runtime() {
  install_mihomo
  if config_needs_geoip; then
    install_geoip_metadb
  fi
  write_service_files
  install_shell_loader
}

print_install_summary() {
  local server_addr="$1"
  local server_port="$2"
  local password="$3"
  local sni="$4"

  cat <<EOF

安装完成。
客户端连接信息:
  server: ${server_addr}
  port: ${server_port}
  password: ${password}
  sni: ${sni}
  saved: ${CLIENT_INFO_FILE}
  service-mode: $(client_service_mode)
EOF
}

install_client() {
  local server_addr server_port password sni mode
  local server_addr_default server_port_default password_default sni_default

  need_user
  mode="$(client_service_mode)"
  announce_client_info_source

  server_addr_default="$(read_saved_client_field server)"
  server_port_default="$(read_saved_client_field port)"
  password_default="$(read_saved_client_field password)"
  sni_default="$(read_saved_client_field sni)"

  [ -n "$server_addr_default" ] || server_addr_default="127.0.0.1"
  [ -n "$server_port_default" ] || server_port_default="443"
  [ -n "$password_default" ] || password_default="change-me"
  [ -n "$sni_default" ] || sni_default="$server_addr_default"

  server_addr="$(ask "服务端地址/IP" "$server_addr_default")"
  [ -n "$server_addr" ] || die "服务端地址不能为空。"
  server_port="$(ask "服务端端口" "$server_port_default")"
  validate_port "$server_port"
  password="$(ask "trojan 密码" "$password_default")"
  [ -n "$password" ] || die "密码不能为空。"
  sni="$(ask "SNI" "$sni_default")"
  [ -n "$sni" ] || die "SNI 不能为空。"

  install_mihomo
  write_mihomo_config "$server_addr" "$server_port" "$password" "$sni"
  write_client_info "$server_addr" "$server_port" "$password" "$sni"
  write_service_files
  install_shell_loader

  if [ "$mode" = "foreground" ]; then
    write_proxy_disabled_env
    print_install_summary "$server_addr" "$server_port" "$password" "$sni"
    cat <<'EOF'

未检测到可用的后台服务管理器。
需要时请执行:
  bash client.sh start
EOF
    return
  fi

  start_service
  check_proxy_connectivity
  write_proxy_enabled_env
  print_install_summary "$server_addr" "$server_port" "$password" "$sni"
}

update_client_connection() {
  local server_addr server_port password sni
  local server_addr_default server_port_default password_default sni_default

  need_user
  [ -x "$MIHOMO_BIN" ] || die "未检测到 mihomo，请先执行 bash client.sh install。"
  announce_client_info_source

  server_addr_default="$(client_connection_default server 127.0.0.1)"
  server_port_default="$(client_connection_default port 443)"
  password_default="$(client_connection_default password change-me)"
  sni_default="$(client_connection_default sni "$server_addr_default")"

  server_addr="$(ask "新的服务端地址/IP" "$server_addr_default")"
  [ -n "$server_addr" ] || die "服务端地址不能为空。"
  server_port="$(ask "新的服务端端口" "$server_port_default")"
  validate_port "$server_port"
  password="$(ask "新的 trojan 密码" "$password_default")"
  [ -n "$password" ] || die "密码不能为空。"
  sni="$(ask "新的 SNI" "$sni_default")"
  [ -n "$sni" ] || die "SNI 不能为空。"

  if [ -f "$MIHOMO_CONFIG_FILE" ]; then
    if ! update_mihomo_proxy_connection "$server_addr" "$server_port" "$password" "$sni"; then
      die "未能在现有配置中定位代理节点 ${MIHOMO_PROXY_NAME}。如果你想重建标准配置，可执行 bash client.sh install。"
    fi
    log "已原地更新 mihomo 配置中的服务端连接参数。"
  else
    log "未检测到 mihomo 配置，改为重新生成标准配置。"
    write_mihomo_config "$server_addr" "$server_port" "$password" "$sni"
  fi

  write_client_info "$server_addr" "$server_port" "$password" "$sni"

  if [ "$(client_service_mode)" = "foreground" ]; then
    log "连接信息已更新并写入: ${CLIENT_INFO_FILE}"
    log "如果 mihomo 正在另一个终端以前台运行，请先在原终端按 Ctrl-C，再执行: bash client.sh start"
    return
  fi

  ensure_runtime
  if client_service_running; then
    restart_service
    check_proxy_connectivity
    write_proxy_enabled_env
    log "连接信息已更新，并已自动重启客户端。"
  else
    log "连接信息已更新，但当前客户端未运行。需要时执行: bash client.sh start"
  fi
}

start_client() {
  need_user
  if ! client_ready; then
    if restore_client_config_from_saved_info; then
      log "未检测到 mihomo 配置，已根据保存的连接信息重新生成。"
    else
      log "未检测到 mihomo 配置，进入安装流程。"
      install_client
      return
    fi
  fi

  ensure_runtime
  if [ "$(client_service_mode)" = "foreground" ]; then
    start_service
    return
  fi

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
  local name

  need_user
  case "$(client_service_mode)" in
    systemd-user)
      systemctl --user --no-pager status mihomo.service || true
      ;;
    sysv)
      name="$(client_service_name)"
      run_root service "$name" status || true
      ;;
    foreground)
      printf 'Service mode: foreground\n'
      printf 'Start command: %s -d %s -f %s\n' "$MIHOMO_BIN" "$MIHOMO_CONFIG_DIR" "$MIHOMO_CONFIG_FILE"
      ;;
  esac

  printf '\nProxy env file: %s\n' "$PROXY_ENV_FILE"
  if [ -f "$PROXY_ENV_FILE" ]; then
    sed -n '1,120p' "$PROXY_ENV_FILE"
  else
    printf 'not found\n'
  fi
}

uninstall_client() {
  local answer="" name

  need_user
  name="$(client_service_name)"

  systemctl --user stop mihomo.service >/dev/null 2>&1 || true
  systemctl --user disable mihomo.service >/dev/null 2>&1 || true
  run_root service "$name" stop >/dev/null 2>&1 || true
  run_root rm -f "/etc/init.d/${name}" >/dev/null 2>&1 || true
  rm -f "$SYSTEMD_SERVICE_FILE" "$MIHOMO_BIN" "$PID_FILE"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user reset-failed mihomo.service >/dev/null 2>&1 || true
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
    update) update_client_connection ;;
    start) start_client ;;
    stop) stop_client ;;
    restart)
      need_user
      if ! client_ready; then
        if restore_client_config_from_saved_info; then
          log "未检测到 mihomo 配置，已根据保存的连接信息重新生成。"
        else
          log "未检测到 mihomo 配置，进入安装流程。"
          install_client
          return
        fi
      fi
      ensure_runtime
      if [ "$(client_service_mode)" = "foreground" ]; then
        restart_service
        return
      fi
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
