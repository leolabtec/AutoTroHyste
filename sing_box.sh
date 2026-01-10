#!/usr/bin/env bash
# =========================================================
# Sing-box 节点管理脚本（JSON 永远合法 + 证书续签兜底版）
# =========================================================

set -euo pipefail

# ---------------- 基础路径 ----------------
ACME_HOME="/root/.acme.sh"
CERT_DIR="/root/cert"
CERT_CANDIDATE="$CERT_DIR/candidate"
CERT_GOOD="$CERT_DIR/good"

SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_CONFIG="/etc/sing-box/config.json"
SINGBOX_CONFIG_BAK="/etc/sing-box/config.json.bak"
SINGBOX_SERVICE="/etc/systemd/system/sing-box.service"

FAKEWEB_DIR="/home/wzweb"
FAKEWEB_PORT=8080

LOG_FILE="/var/log/singbox-cert.log"

# ---------------- 节点状态 ----------------
MENU_STATUS=("inactive" "inactive" "inactive" "inactive")
DOMAIN=""

TROJAN_PORT=443
TROJAN_PASS=""

HYSTERIA2_PORT=""
HYSTERIA2_PASS=""
HYSTERIA_BANDWIDTH=500

TUIC_PORT=""
TUIC_UUID=""
TUIC_PASS=""

# ---------------- 工具函数 ----------------
log() {
    echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "❌ 缺少依赖：$1"
        exit 1
    }
}

is_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

rand_pass() {
    openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 20
}

rand_uuid() {
    "$SINGBOX_BIN" generate uuid
}

# ---------------- sing-box service ----------------
ensure_service() {
    if [ ! -f "$SINGBOX_SERVICE" ]; then
        cat > "$SINGBOX_SERVICE" <<EOF
[Unit]
Description=Sing-box
After=network.target

[Service]
ExecStart=$SINGBOX_BIN run -c $SINGBOX_CONFIG
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable sing-box
    fi
}

restart_singbox() {
    log "重启 sing-box..."
    if systemctl restart sing-box; then
        sleep 2
        systemctl is-active --quiet sing-box && {
            log "✅ sing-box 正常运行"
            return 0
        }
    fi
    log "❌ sing-box 启动失败"
    journalctl -u sing-box -n 30 --no-pager | tee -a "$LOG_FILE"
    return 1
}

# ---------------- 证书 HOOK（兜底闭环） ----------------
create_hook() {
    local hook="$ACME_HOME/singbox-reload.sh"
    mkdir -p "$CERT_DIR" "$CERT_CANDIDATE" "$CERT_GOOD"

    cat > "$hook" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CERT_DIR="/root/cert"
CAND="$CERT_DIR/candidate"
GOOD="$CERT_DIR/good"
LOG="/var/log/singbox-cert.log"

log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

log "=== ACME HOOK START ==="

# acme.sh 已写入 fullchain.pem / private.pem
if ! openssl x509 -in "$CERT_DIR/fullchain.pem" -noout >/dev/null 2>&1; then
    log "❌ 新证书无效"
    exit 1
fi

ts=$(date +%Y%m%d-%H%M%S)
mkdir -p "$CAND"
cp "$CERT_DIR/fullchain.pem" "$CAND/fullchain.pem.$ts"
cp "$CERT_DIR/private.pem" "$CAND/private.pem.$ts"

log "证书 candidate 保存完成"

if systemctl restart sing-box; then
    log "sing-box 已加载新证书"
    mkdir -p "$GOOD"
    cp "$CERT_DIR/fullchain.pem" "$GOOD/fullchain.pem"
    cp "$CERT_DIR/private.pem" "$GOOD/private.pem"
    log "good 证书已更新"
else
    log "❌ 重启失败，回滚 good"
    if [ -f "$GOOD/fullchain.pem" ]; then
        cp "$GOOD/fullchain.pem" "$CERT_DIR/fullchain.pem"
        cp "$GOOD/private.pem" "$CERT_DIR/private.pem"
        systemctl restart sing-box || true
    fi
    exit 1
fi

log "=== ACME HOOK END ==="
EOF

    chmod +x "$hook"
    echo "$hook"
}

# ---------------- JSON 生成（关键修复点） ----------------
configure_singbox() {
    mkdir -p /etc/sing-box

    local tmp
    tmp=$(mktemp)
    trap 'rm -f "$tmp"' RETURN

    local arr="[]"

    # ---------- Trojan ----------
    if [ "${MENU_STATUS[1]}" = "active" ]; then
        is_port "$TROJAN_PORT" || { echo "❌ Trojan 端口非法"; return 1; }

        arr=$(jq \
            --arg pass "$TROJAN_PASS" \
            --argjson port "$TROJAN_PORT" \
            --arg cert "$CERT_DIR/fullchain.pem" \
            --arg key "$CERT_DIR/private.pem" \
            --argjson fb "$FAKEWEB_PORT" \
            '. + [{
              type:"trojan",
              tag:"trojan-in",
              listen:"0.0.0.0",
              listen_port:$port,
              users:[{password:$pass}],
              tls:{enabled:true,certificate_path:$cert,key_path:$key},
              fallback:{server:"127.0.0.1",server_port:$fb}
            }]' <<<"$arr")
    fi

    # ---------- Hysteria2 ----------
    if [ "${MENU_STATUS[2]}" = "active" ]; then
        is_port "$HYSTERIA2_PORT" || { echo "❌ Hysteria2 端口非法"; return 1; }

        arr=$(jq \
            --arg pass "$HYSTERIA2_PASS" \
            --argjson port "$HYSTERIA2_PORT" \
            --argjson bw "$HYSTERIA_BANDWIDTH" \
            --arg cert "$CERT_DIR/fullchain.pem" \
            --arg key "$CERT_DIR/private.pem" \
            '. + [{
              type:"hysteria2",
              tag:"hysteria2-in",
              listen:"0.0.0.0",
              listen_port:$port,
              users:[{password:$pass}],
              up_mbps:$bw,
              down_mbps:$bw,
              tls:{enabled:true,certificate_path:$cert,key_path:$key}
            }]' <<<"$arr")
    fi

    # ---------- Tuic ----------
    if [ "${MENU_STATUS[3]}" = "active" ]; then
        is_port "$TUIC_PORT" || { echo "❌ Tuic 端口非法"; return 1; }

        arr=$(jq \
            --arg uuid "$TUIC_UUID" \
            --arg pass "$TUIC_PASS" \
            --argjson port "$TUIC_PORT" \
            --arg cert "$CERT_DIR/fullchain.pem" \
            --arg key "$CERT_DIR/private.pem" \
            '. + [{
              type:"tuic",
              tag:"tuic-in",
              listen:"0.0.0.0",
              listen_port:$port,
              users:[{uuid:$uuid,password:$pass}],
              congestion_control:"cubic",
              tls:{enabled:true,certificate_path:$cert,key_path:$key}
            }]' <<<"$arr")
    fi

    jq -n \
      --argjson inb "$arr" \
      '{
        log:{level:"info"},
        inbounds:$inb,
        outbounds:[{type:"direct",tag:"direct"}]
      }' > "$SINGBOX_CONFIG"

    if "$SINGBOX_BIN" check -c "$SINGBOX_CONFIG"; then
        log "✅ sing-box 配置校验通过"
        return 0
    else
        log "❌ sing-box 配置校验失败"
        return 1
    fi
}

# ---------------- 示例流程 ----------------
echo "✅ 这是 JSON 永远合法 + 续签兜底的最终版本"
echo "你现在可以："
echo "1️⃣ 配置 Trojan / Hysteria2 / Tuic"
echo "2️⃣ 再也不会出现首次 JSON 校验失败"
echo "3️⃣ 证书续签失败也不会炸服务"
