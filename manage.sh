#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$BASE_DIR/.env"

[ -f "$ENV_FILE" ] && set -a && . "$ENV_FILE" && set +a


SERVER_CONF_TPL="${SERVER_CONF_TPL:-$BASE_DIR/server.conf.json.tpl}"
CLIENT_CONF_TPL="${CLIENT_CONF_TPL:-$BASE_DIR/client.conf.json.tpl}"

CLIENT_TUN_CONF="${CLIENT_TUN_CONF:-$SING_BOX_DIR/client-tun.json}"
CLIENT_PROXY_CONF="${CLIENT_PROXY_CONF:-$SING_BOX_DIR/client-proxy.json}"

SING_BOX_BIN="${SING_BOX_BIN:-/usr/local/bin/sing-box}"
SING_BOX_DIR="${SING_BOX_DIR:-/etc/sing-box}"
SING_BOX_SERVICE="${SING_BOX_SERVICE:-sing-box}"
SERVER_CONF_SRC="${SERVER_CONF_SRC:-$BASE_DIR/server.conf.json}"
CLIENT_CONF_SRC="${CLIENT_CONF_SRC:-$BASE_DIR/client.conf.json}"
CF_RECORD_TYPE="${CF_RECORD_TYPE:-A}"
CF_RECORD_PROXIED="${CF_RECORD_PROXIED:-false}"
SERVER_UDP_PORT="${SERVER_UDP_PORT:-8443}"

need_root() {
  [ "$(id -u)" -eq 0 ] || {
    echo "请使用 root 运行：sudo $0 $*"
    exit 1
  }
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "缺少命令：$1"
    exit 1
  }
}

require_env() {
  local name="$1"
  [ -n "${!name:-}" ] || {
    echo ".env 缺少变量：$name"
    exit 1
  }
}

apt_install() {
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

install_sing_box() {
  if command -v "$SING_BOX_BIN" >/dev/null 2>&1 || command -v sing-box >/dev/null 2>&1; then
    echo "sing-box 已安装"
    return 0
  fi

  curl -fsSL https://sing-box.app/install.sh | sh
}

write_service() {
  cat >/etc/systemd/system/${SING_BOX_SERVICE}.service <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org/
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
ExecStart=${SING_BOX_BIN} run -c ${SING_BOX_DIR}/config.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
}
load_env() {
  [ -f "$ENV_FILE" ] || {
    echo "找不到 .env：$ENV_FILE"
    exit 1
  }

  set -a
  . "$ENV_FILE"
  set +a
}

render_server_conf() {
  need_root
  need_cmd envsubst
  load_env

  [ -f "$SERVER_CONF_TPL" ] || {
    echo "找不到模板：$SERVER_CONF_TPL"
    exit 1
  }

  envsubst < "$SERVER_CONF_TPL" > "$SERVER_CONF_SRC"
  "$SING_BOX_BIN" check -c "$SERVER_CONF_SRC"

  echo "已生成服务端配置：$SERVER_CONF_SRC"
}

render_client_conf() {
  need_root
  need_cmd envsubst
  load_env

  [ -f "$CLIENT_CONF_TPL" ] || {
    echo "找不到模板：$CLIENT_CONF_TPL"
    exit 1
  }

  envsubst < "$CLIENT_CONF_TPL" > "$CLIENT_CONF_SRC"
  "$SING_BOX_BIN" check -c "$CLIENT_CONF_SRC"

  echo "已生成客户端配置：$CLIENT_CONF_SRC"
}

build_client_profiles() {
  need_root
  need_cmd jq

  render_client_conf

  mkdir -p "$SING_BOX_DIR"

  install -m 600 "$CLIENT_CONF_SRC" "$CLIENT_TUN_CONF"

  jq 'del(.inbounds[] | select(.type == "tun"))' \
    "$CLIENT_CONF_SRC" > "$CLIENT_PROXY_CONF.tmp"

  install -m 600 "$CLIENT_PROXY_CONF.tmp" "$CLIENT_PROXY_CONF"
  rm -f "$CLIENT_PROXY_CONF.tmp"

  "$SING_BOX_BIN" check -c "$CLIENT_TUN_CONF"
  "$SING_BOX_BIN" check -c "$CLIENT_PROXY_CONF"

  echo "已生成客户端模式配置："
  echo "TUN:   $CLIENT_TUN_CONF"
  echo "Proxy: $CLIENT_PROXY_CONF"
}

enable_tun() {
  need_root
  build_client_profiles

  ln -sf "$CLIENT_TUN_CONF" "$SING_BOX_DIR/config.json"

  write_service
  systemctl enable --now "$SING_BOX_SERVICE"
  systemctl restart "$SING_BOX_SERVICE"

  sleep 1
  systemctl is-active --quiet "$SING_BOX_SERVICE"

  echo "TUN 模式已开启"
  ip addr show "${TUN_NAME:-sing0}" 2>/dev/null || true
}

disable_tun() {
  need_root
  build_client_profiles

  ln -sf "$CLIENT_PROXY_CONF" "$SING_BOX_DIR/config.json"

  write_service
  systemctl enable --now "$SING_BOX_SERVICE"
  systemctl restart "$SING_BOX_SERVICE"

  sleep 1
  systemctl is-active --quiet "$SING_BOX_SERVICE"

  echo "TUN 模式已关闭，仅保留 mixed 代理"
}
install_server() {
  need_root
  apt_install curl ca-certificates jq openssl certbot python3-certbot-dns-cloudflare iproute2 gettext-base
  install_sing_box
  echo "服务端工具安装完成"
}

install_client() {
  need_root
  apt_install curl ca-certificates iproute2 jq gettext-base
  install_sing_box
  echo "客户端工具安装完成"
}

set_dns() {
  need_root
  require_env CF_API_TOKEN
  require_env CF_ZONE_ID
  require_env CF_RECORD_NAME

  local ip="${CF_RECORD_IP:-}"

  if [ -z "$ip" ]; then
    ip="$(curl -fsS https://ipv4.icanhazip.com | tr -d '\n')"
  fi

  [ -n "$ip" ] || {
    echo "无法获取 IP"
    exit 1
  }

  echo "目标 DNS：$CF_RECORD_NAME -> $ip"

  local list record_id result method url
  list="$(curl -fsS -G \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    --data-urlencode "type=${CF_RECORD_TYPE}" \
    --data-urlencode "name=${CF_RECORD_NAME}")"

  record_id="$(echo "$list" | jq -r '.result[0].id // empty')"

  if [ -n "$record_id" ]; then
    echo "记录已存在，更新：$record_id"
    method="PATCH"
    url="https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${record_id}"
  else
    echo "记录不存在，创建新记录"
    method="POST"
    url="https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records"
  fi

  result="$(curl -fsS -X "$method" "$url" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "{
      \"type\":\"${CF_RECORD_TYPE}\",
      \"name\":\"${CF_RECORD_NAME}\",
      \"content\":\"${ip}\",
      \"ttl\":120,
      \"proxied\":${CF_RECORD_PROXIED}
    }")"

  echo "$result" | jq -e '.success == true' >/dev/null
  echo "DNS 配置完成"
}

set_cert() {
  need_root
  require_env CF_API_TOKEN
  require_env CERT_DOMAIN
  require_env CERT_EMAIL

  mkdir -p /etc/letsencrypt

  cat >/etc/letsencrypt/cloudflare.ini <<EOF
dns_cloudflare_api_token = ${CF_API_TOKEN}
EOF
  chmod 600 /etc/letsencrypt/cloudflare.ini

  certbot certonly \
    --non-interactive \
    --agree-tos \
    --email "$CERT_EMAIL" \
    --dns-cloudflare \
    --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
    -d "$CERT_DOMAIN"

  mkdir -p /etc/letsencrypt/renewal-hooks/deploy

  cat >/etc/letsencrypt/renewal-hooks/deploy/restart-sing-box.sh <<EOF
#!/usr/bin/env bash
systemctl reload ${SING_BOX_SERVICE} 2>/dev/null || systemctl restart ${SING_BOX_SERVICE}
EOF
  chmod +x /etc/letsencrypt/renewal-hooks/deploy/restart-sing-box.sh

  systemctl enable --now certbot.timer 2>/dev/null || true
  echo "证书申请完成"
}

update_cert() {
  need_root
  certbot renew
  echo "证书续期检查完成"
}

set_server() {
  need_root
  render_server_conf

  mkdir -p "$SING_BOX_DIR"
  install -m 600 "$SERVER_CONF_SRC" "$SING_BOX_DIR/config.json"

  "$SING_BOX_BIN" check -c "$SING_BOX_DIR/config.json"

  write_service
  systemctl enable --now "$SING_BOX_SERVICE"
  systemctl restart "$SING_BOX_SERVICE"

  sleep 1
  systemctl is-active --quiet "$SING_BOX_SERVICE"

  if ss -lun | grep -q ":${SERVER_UDP_PORT} "; then
    echo "服务端启动成功，UDP ${SERVER_UDP_PORT} 正在监听"
  else
    echo "sing-box 已启动，但未检测到 UDP ${SERVER_UDP_PORT} 监听，请检查配置"
    ss -lun
  fi
}

set_client() {
  need_root
  enable_tun
}



case "${1:-}" in
  install_server) install_server ;;
  set_dns) set_dns ;;
  set_cert) set_cert ;;
  update_cert) update_cert ;;
  set_server) set_server ;;
  install_client) install_client ;;
  set_client) set_client ;;
  render_server_conf) render_server_conf ;;
  render_client_conf) render_client_conf ;;
  build_client_profiles) build_client_profiles ;;
  enable_tun) enable_tun ;;
  disable_tun) disable_tun ;;
  *)
    echo "用法：$0 {install_server|set_dns|set_cert|update_cert|set_server|install_client|set_client|render_server_conf|render_client_conf|build_client_profiles|enable_tun|disable_tun}"
    exit 1
    ;;
esac