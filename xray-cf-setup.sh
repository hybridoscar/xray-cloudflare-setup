#!/usr/bin/env bash
set -euo pipefail

# Xray + Nginx + Cloudflare VLESS XHTTP installer for Debian/Ubuntu.
# Run only on a VPS and domain you control.

readonly APP_NAME="xray-cf-setup"
readonly STATE_DIR="/etc/${APP_NAME}"
readonly STATE_FILE="${STATE_DIR}/state.env"
readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly NGINX_CONFIG="/etc/nginx/conf.d/xray-cloudflare.conf"
readonly BACKUP_ROOT="/root/${APP_NAME}-backups"
readonly XRAY_INSTALL_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

color() { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
info() { color "36" "[信息] $*"; }
ok() { color "32" "[完成] $*"; }
warn() { color "33" "[注意] $*"; }
die() { color "31" "[错误] $*" >&2; exit 1; }

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "请使用 root 用户运行：sudo bash $0"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

valid_domain() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] && [[ "$1" == *.* ]]
}

valid_path() {
  [[ "$1" =~ ^/[A-Za-z0-9_-]+$ ]]
}

load_state() {
  [[ -f "${STATE_FILE}" ]] || die "尚未安装。请先选择安装。"
  # shellcheck disable=SC1090
  source "${STATE_FILE}"
}

save_state() {
  install -d -m 700 "${STATE_DIR}"
  cat > "${STATE_FILE}" <<EOF
ORIGIN_DOMAIN='${ORIGIN_DOMAIN}'
CONNECT_DOMAIN='${CONNECT_DOMAIN}'
XHTTP_PATH='${XHTTP_PATH}'
WS_PATH='${WS_PATH}'
XHTTP_PORT='${XHTTP_PORT}'
WS_PORT='${WS_PORT}'
UUID='${UUID}'
EOF
  chmod 600 "${STATE_FILE}"
}

backup_existing() {
  local backup_dir="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
  install -d -m 700 "${backup_dir}"
  [[ -d /etc/nginx ]] && cp -a /etc/nginx "${backup_dir}/nginx"
  [[ -d /usr/local/etc/xray ]] && cp -a /usr/local/etc/xray "${backup_dir}/xray"
  [[ -f "${STATE_FILE}" ]] && cp -a "${STATE_FILE}" "${backup_dir}/state.env"
  ok "旧配置已备份到 ${backup_dir}"
}

wait_for_apt() {
  local waited=0
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    if (( waited == 0 )); then
      warn "系统自动更新正在占用 apt，等待其完成。请勿删除 lock 文件。"
    fi
    sleep 5
    waited=$((waited + 5))
    (( waited < 900 )) || die "等待 apt 超过 15 分钟，请稍后重新运行脚本。"
  done
}

install_packages() {
  wait_for_apt
  info "安装 Nginx、Certbot、curl、jq..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y nginx certbot curl jq openssl
}

install_xray() {
  info "使用 XTLS 官方脚本安装 Xray 稳定版..."
  bash -c "$(curl -fsSL "${XRAY_INSTALL_URL}")" @ install
}

write_xray_config() {
  install -d -m 755 "$(dirname "${XRAY_CONFIG}")"
  cat > "${XRAY_CONFIG}" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": ${XHTTP_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "${XHTTP_PATH}"
        }
      }
    },
    {
      "listen": "127.0.0.1",
      "port": ${WS_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "${WS_PATH}"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF
}

write_http_nginx_config() {
  cat > "${NGINX_CONFIG}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${ORIGIN_DOMAIN};

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 200 "ready\n";
        add_header Content-Type text/plain;
    }
}
EOF
}

write_https_nginx_config() {
  cat > "${NGINX_CONFIG}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${ORIGIN_DOMAIN};

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${ORIGIN_DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${ORIGIN_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${ORIGIN_DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location ${XHTTP_PATH} {
        proxy_pass http://127.0.0.1:${XHTTP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_buffering off;
        proxy_request_buffering off;
        client_max_body_size 0;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    location ${WS_PATH} {
        proxy_pass http://127.0.0.1:${WS_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    location / {
        return 200 "ok\n";
        add_header Content-Type text/plain;
    }
}
EOF
}

disable_default_site() {
  if [[ -L /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
  fi
}

issue_certificate() {
  if [[ -f "/etc/letsencrypt/live/${ORIGIN_DOMAIN}/fullchain.pem" ]]; then
    info "检测到已有证书，跳过申请。"
    return
  fi

  info "为 ${ORIGIN_DOMAIN} 申请 Let's Encrypt 证书..."
  certbot certonly \
    --webroot \
    --webroot-path /var/www/html \
    --domain "${ORIGIN_DOMAIN}" \
    --non-interactive \
    --agree-tos \
    --register-unsafely-without-email

  install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
  cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/usr/bin/env bash
systemctl reload nginx
EOF
  chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
}

test_and_restart() {
  /usr/local/bin/xray run -test -config "${XRAY_CONFIG}"
  nginx -t
  systemctl enable xray nginx
  systemctl restart xray
  systemctl reload nginx
}

urlencode_path() {
  printf '%s' "$1" | sed 's#/#%2F#g'
}

export_link() {
  load_state
  local encoded_xhttp_path encoded_ws_path
  encoded_xhttp_path="$(urlencode_path "${XHTTP_PATH}")"
  encoded_ws_path="$(urlencode_path "${WS_PATH}")"
  printf '\n'
  color "35" "=== 1. XHTTP 主节点，请勿发送给他人 ==="
  printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&type=xhttp&host=%s&path=%s&mode=packet-up#Cloudflare-VLESS-XHTTP\n' \
    "${UUID}" "${CONNECT_DOMAIN}" "${ORIGIN_DOMAIN}" "${ORIGIN_DOMAIN}" "${encoded_xhttp_path}"
  printf '\n'
  color "35" "=== 2. WS 兼容备用节点，请勿发送给他人 ==="
  printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&type=ws&host=%s&path=%s#Cloudflare-VLESS-WS-Backup\n' \
    "${UUID}" "${CONNECT_DOMAIN}" "${ORIGIN_DOMAIN}" "${ORIGIN_DOMAIN}" "${encoded_ws_path}"
  printf '\n'
  warn "最新版 v2rayN 请关闭 mux.cool；如需兼容 Codex，请将本地 mixed 端口设置为 10809。"
}

show_status() {
  load_state
  printf '\n'
  info "服务状态"
  systemctl --no-pager --full status xray nginx | sed -n '1,28p'
  printf '\n'
  info "监听端口"
  ss -lntp | grep -E ":80|:443|:${XHTTP_PORT}|:${WS_PORT}" || true
  printf '\n'
  info "配置检查"
  /usr/local/bin/xray run -test -config "${XRAY_CONFIG}"
  nginx -t
  printf '\n'
  info "当前参数"
  printf '回源域名: %s\n连接域名: %s\nXHTTP 路径: %s\nWS 备用路径: %s\nXHTTP 本地端口: %s\nWS 本地端口: %s\n' \
    "${ORIGIN_DOMAIN}" "${CONNECT_DOMAIN}" "${XHTTP_PATH}" "${WS_PATH}" "${XHTTP_PORT}" "${WS_PORT}"
}

rotate_uuid() {
  load_state
  backup_existing
  UUID="$(cat /proc/sys/kernel/random/uuid)"
  jq --arg uuid "${UUID}" '(.inbounds[].settings.clients[].id) = $uuid' \
    "${XRAY_CONFIG}" > "${XRAY_CONFIG}.tmp"
  mv "${XRAY_CONFIG}.tmp" "${XRAY_CONFIG}"
  save_state
  /usr/local/bin/xray run -test -config "${XRAY_CONFIG}"
  systemctl restart xray
  ok "UUID 已更新，旧链接立即失效。"
  export_link
}

install_all() {
  backup_existing

  read -r -p "请输入回源域名，例如 cdn.example.com: " ORIGIN_DOMAIN
  valid_domain "${ORIGIN_DOMAIN}" || die "回源域名格式不正确。"

  read -r -p "请输入客户端连接域名，直接回源可留空 [${ORIGIN_DOMAIN}]: " CONNECT_DOMAIN
  CONNECT_DOMAIN="${CONNECT_DOMAIN:-${ORIGIN_DOMAIN}}"
  valid_domain "${CONNECT_DOMAIN}" || die "连接域名格式不正确。"

  local default_xhttp_path default_ws_path
  default_xhttp_path="/$(tr -d '-' < /proc/sys/kernel/random/uuid | cut -c1-12)"
  default_ws_path="/$(tr -d '-' < /proc/sys/kernel/random/uuid | cut -c1-12)"
  read -r -p "请输入 XHTTP 路径，直接回车自动生成 [${default_xhttp_path}]: " XHTTP_PATH
  XHTTP_PATH="${XHTTP_PATH:-${default_xhttp_path}}"
  valid_path "${XHTTP_PATH}" || die "路径必须以 / 开头，只能包含字母、数字、下划线和短横线。"

  read -r -p "请输入 WS 备用路径，直接回车自动生成 [${default_ws_path}]: " WS_PATH
  WS_PATH="${WS_PATH:-${default_ws_path}}"
  valid_path "${WS_PATH}" || die "路径必须以 / 开头，只能包含字母、数字、下划线和短横线。"

  read -r -p "请输入 XHTTP 本地端口 [12761]: " XHTTP_PORT
  XHTTP_PORT="${XHTTP_PORT:-12761}"
  [[ "${XHTTP_PORT}" =~ ^[0-9]+$ ]] || die "端口必须是数字。"
  (( XHTTP_PORT >= 1024 && XHTTP_PORT <= 65535 )) || die "端口范围应为 1024-65535。"

  read -r -p "请输入 WS 备用本地端口 [12762]: " WS_PORT
  WS_PORT="${WS_PORT:-12762}"
  [[ "${WS_PORT}" =~ ^[0-9]+$ ]] || die "端口必须是数字。"
  (( WS_PORT >= 1024 && WS_PORT <= 65535 )) || die "端口范围应为 1024-65535。"
  [[ "${XHTTP_PORT}" != "${WS_PORT}" ]] || die "XHTTP 和 WS 端口不能相同。"

  UUID="$(cat /proc/sys/kernel/random/uuid)"

  install_packages
  install_xray
  disable_default_site
  install -d -m 755 /var/www/html/.well-known/acme-challenge
  write_xray_config
  write_http_nginx_config
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
  issue_certificate
  write_https_nginx_config
  test_and_restart
  save_state

  ok "安装完成。"
  warn "Cloudflare 中请开启橙色云，并将 SSL/TLS 模式设置为 Full (Strict)。"
  export_link
}

uninstall_all() {
  warn "此操作会停用 Xray，并删除本工具生成的 Nginx 配置。证书和备份不会删除。"
  read -r -p "确认卸载请输入 YES: " answer
  [[ "${answer}" == "YES" ]] || die "已取消。"
  backup_existing
  systemctl disable --now xray 2>/dev/null || true
  rm -f "${NGINX_CONFIG}"
  nginx -t
  systemctl reload nginx
  rm -rf "${STATE_DIR}"
  ok "已停用 Xray 并移除本工具生成的 Nginx 配置。"
}

menu() {
  printf '\n'
  color "36" "========== Xray + Cloudflare 中文管理脚本 =========="
  printf '1. 安装或重新配置 VLESS + XHTTP + TLS（附带 WS 备用）\n'
  printf '2. 查看服务状态并检查配置\n'
  printf '3. 导出 v2rayN 导入链接\n'
  printf '4. 轮换 UUID 并导出新链接\n'
  printf '5. 卸载本脚本生成的配置\n'
  printf '0. 退出\n'
  printf '\n'
  read -r -p "请选择: " choice
  case "${choice}" in
    1) install_all ;;
    2) show_status ;;
    3) export_link ;;
    4) rotate_uuid ;;
    5) uninstall_all ;;
    0) exit 0 ;;
    *) die "无效选择。" ;;
  esac
}

require_root
menu
