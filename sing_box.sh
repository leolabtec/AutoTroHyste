#!/bin/bash
# =========================================
# Sing-box 全协议节点管理脚本 - 续签闭环兜底版
# 解决：续签后证书不更新 / 不重启 / 重启失败导致只剩旧证书快过期
#
# 关键点：
# 1) acme.sh --install-cert 写到 /root/cert/fullchain.pem private.pem
# 2) HOOK：新证书有效 -> 先保存 candidate -> 尝试重启
#    - 重启成功：更新 .good（最后一次可用基线）
#    - 重启失败：回滚到 .good 并重启（保服务），同时新证书 candidate 不丢
# =========================================

set -u

FAKEWEB_DIR="/home/wzweb"
FAKEWEB_PORT=8080

SINGBOX_CONFIG="/etc/sing-box/config.json"
SINGBOX_CONFIG_BAK="/etc/sing-box/config.json.bak"

ACME_HOME="/root/.acme.sh"
CERT_DIR="/root/cert"

SINGBOX_SERVICE="/etc/systemd/system/sing-box.service"
LOG_FILE="/var/log/singbox-cert.log"

MENU_STATUS=("inactive" "inactive" "inactive" "inactive")
DOMAIN=""

TROJAN_PORT=443
TROJAN_PASS=""

HYSTERIA2_PORT=""
HYSTERIA2_PASS=""

TUIC_PORT=""
TUIC_UUID=""
TUIC_PASS=""

HYSTERIA_BANDWIDTH=500

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

die() {
  log "❌ $*"
  echo "❌ $*"
  exit 1
}

generate_password() {
  openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 20
}

generate_uuid() {
  sing-box generate uuid
}

check_port() {
  local port=$1
  local temp_stop=0

  # 如果 sing-box 正在占用该端口，先临时停一下再判断
  if systemctl is-active --quiet sing-box && (ss -tuln | grep -Eq ":${port}\b" || ss -uapn 2>/dev/null | grep -Eq ":${port}\b"); then
    systemctl stop sing-box || true
    temp_stop=1
  fi

  if ss -tuln | grep -Eq ":${port}\b" || ss -uapn 2>/dev/null | grep -Eq ":${port}\b"; then
    [ $temp_stop -eq 1 ] && systemctl start sing-box || true
    echo "端口 $port 已被占用（TCP/UDP），请重新输入。"
    return 1
  fi

  [ $temp_stop -eq 1 ] && systemctl start sing-box || true
  return 0
}

install_dependencies() {
  echo "安装必要依赖..."
  local DEPS=(socat unzip cron dnsutils openssl curl jq iproute2 tar gzip)

  apt update -y >/dev/null 2>&1 || true

  for pkg in "${DEPS[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      apt install -y "$pkg"
    fi
  done

  # docker / compose 仅伪装站需要
  if ! command -v docker >/dev/null 2>&1; then
    apt install -y docker.io || true
  fi

  if ! command -v docker-compose >/dev/null 2>&1; then
    if apt-cache show docker-compose-plugin >/dev/null 2>&1; then
      apt install -y docker-compose-plugin || true
    fi
    if ! command -v docker-compose >/dev/null 2>&1; then
      if apt-cache show docker-compose >/dev/null 2>&1; then
        apt install -y docker-compose || true
      fi
    fi
  fi

  systemctl enable docker >/dev/null 2>&1 || true
  systemctl start docker >/dev/null 2>&1 || true
}

install_singbox() {
  echo "安装最新版 sing-box..."
  local ARCH
  ARCH=$(uname -m)
  [ "$ARCH" = "x86_64" ] && ARCH="amd64" || ARCH="arm64"

  local LATEST
  LATEST=$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest \
    | grep tag_name | cut -d '"' -f4 | sed 's/v//')

  curl -fsSL "https://github.com/SagerNet/sing-box/releases/download/v${LATEST}/sing-box-${LATEST}-linux-${ARCH}.tar.gz" -o /tmp/sb.tar.gz
  tar -xzf /tmp/sb.tar.gz -C /tmp
  mv "/tmp/sing-box-${LATEST}-linux-${ARCH}/sing-box" /usr/local/bin/
  chmod +x /usr/local/bin/sing-box
  rm -rf /tmp/sb* "/tmp/sing-box-${LATEST}-linux-${ARCH}"

  echo "sing-box 安装完成: v$LATEST"
}

check_singbox() {
  command -v sing-box >/dev/null 2>&1 || install_singbox
}

check_acme() {
  if [ ! -d "$ACME_HOME" ]; then
    curl -fsSL https://get.acme.sh | sh
  fi
  "$ACME_HOME/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
}

deploy_fakeweb() {
  mkdir -p "$FAKEWEB_DIR"
  cd "$FAKEWEB_DIR" || return

  cat > docker-compose.yml <<EOF
version: '3'
services:
  nginx:
    image: nginx:alpine
    container_name: fakeweb
    ports:
      - "$FAKEWEB_PORT:80"
    volumes:
      - ./html:/usr/share/nginx/html:ro
    restart: unless-stopped
EOF

  mkdir -p html
  cat > html/index.html <<'EOF'
<!DOCTYPE html>
<html>
<head><title>Welcome</title></head>
<body><h1>Site Under Construction</h1></body>
</html>
EOF

  if command -v docker-compose >/dev/null 2>&1; then
    docker-compose up -d || true
  else
    docker compose up -d || true
  fi
}

create_systemd_service() {
  [ -f "$SINGBOX_SERVICE" ] && return

  cat > "$SINGBOX_SERVICE" <<EOF
[Unit]
Description=Sing-box Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c $SINGBOX_CONFIG
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable sing-box >/dev/null 2>&1 || true
}

load_existing_config() {
  if [ -f "$CERT_DIR/fullchain.pem" ]; then
    MENU_STATUS[0]="active"
    DOMAIN=$(openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -subject \
      | sed -n 's/.*CN = \([^,]*\).*/\1/p' | head -n1 || true)
  fi

  if [ -f "$SINGBOX_CONFIG" ] && command -v jq >/dev/null 2>&1 && sing-box check -c "$SINGBOX_CONFIG" >/dev/null 2>&1; then
    mapfile -t types < <(jq -r '.inbounds[].type' "$SINGBOX_CONFIG")
    mapfile -t ports < <(jq -r '.inbounds[].listen_port' "$SINGBOX_CONFIG")
    mapfile -t passwords < <(jq -r '.inbounds[].users[0].password // empty' "$SINGBOX_CONFIG")
    mapfile -t uuids < <(jq -r '.inbounds[].users[0].uuid // empty' "$SINGBOX_CONFIG")

    for i in "${!types[@]}"; do
      case "${types[$i]}" in
        trojan)
          MENU_STATUS[1]="active"
          TROJAN_PORT="${ports[$i]}"
          TROJAN_PASS="${passwords[$i]}"
          ;;
        hysteria2)
          MENU_STATUS[2]="active"
          HYSTERIA2_PORT="${ports[$i]}"
          HYSTERIA2_PASS="${passwords[$i]}"
          ;;
        tuic)
          MENU_STATUS[3]="active"
          TUIC_PORT="${ports[$i]}"
          TUIC_UUID="${uuids[$i]}"
          TUIC_PASS="${passwords[$i]}"
          ;;
      esac
    done
  fi
}

# ============================================================
# ✅ HOOK：续签闭环兜底（保留 good + candidate，重启失败可回滚）
# ============================================================
create_acme_hook() {
  local hook="$ACME_HOME/singbox-reload.sh"

  cat > "$hook" <<'EOFHOOK'
#!/bin/bash
set -euo pipefail

CERT_DIR="/root/cert"
FAKEWEB_DIR="/home/wzweb"
LOG_FILE="/var/log/singbox-cert.log"

GOOD_FULL="$CERT_DIR/fullchain.pem.good"
GOOD_KEY="$CERT_DIR/private.pem.good"

CAND_DIR="$CERT_DIR/candidate"
mkdir -p "$CAND_DIR"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

cert_enddate() {
  # 输出证书到期时间，失败则空
  openssl x509 -in "$1" -noout -enddate 2>/dev/null | sed 's/notAfter=//'
}

log "=== 证书续签 HOOK 开始执行 ==="

# 0) 必须存在 acme.sh 安装后的当前证书
if [ ! -f "$CERT_DIR/fullchain.pem" ] || [ ! -f "$CERT_DIR/private.pem" ]; then
  log "❌ 错误：$CERT_DIR/fullchain.pem 或 private.pem 不存在"
  exit 1
fi

# 1) 验证当前（新）证书是否有效
if ! openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -checkend 0 >/dev/null 2>&1; then
  log "❌ 错误：当前证书无效（可能写坏/截断）"
  # 如果有 good，则回滚并尝试拉起服务
  if [ -f "$GOOD_FULL" ] && [ -f "$GOOD_KEY" ]; then
    log "尝试回滚到最后可用证书 good..."
    cp -f "$GOOD_FULL" "$CERT_DIR/fullchain.pem"
    cp -f "$GOOD_KEY"  "$CERT_DIR/private.pem"
    chmod 600 "$CERT_DIR/private.pem" || true
    systemctl restart sing-box && log "✅ 回滚后 sing-box 已重启" || log "⚠️ 回滚后 sing-box 仍重启失败"
  fi
  exit 1
fi

NEW_END="$(cert_enddate "$CERT_DIR/fullchain.pem")"
log "✅ 当前证书验证通过，到期时间：${NEW_END:-unknown}"

# 2) 保存 candidate（即使后面重启失败也不丢新证书）
TS="$(date +%Y%m%d-%H%M%S)"
CAND_FULL="$CAND_DIR/fullchain.pem.$TS"
CAND_KEY="$CAND_DIR/private.pem.$TS"
cp -f "$CERT_DIR/fullchain.pem" "$CAND_FULL"
cp -f "$CERT_DIR/private.pem" "$CAND_KEY"
chmod 600 "$CAND_KEY" || true
log "已保存新证书 candidate：$CAND_FULL"

# 3) 尝试重启 sing-box（让它吃到新证书）
log "正在重启 sing-box 以加载新证书..."
if systemctl restart sing-box; then
  log "✅ sing-box 重启成功（已加载当前证书）"
  # 3.1) 只有“确认服务已正常重启”后，才更新 good 基线
  cp -f "$CERT_DIR/fullchain.pem" "$GOOD_FULL"
  cp -f "$CERT_DIR/private.pem"  "$GOOD_KEY"
  chmod 600 "$GOOD_KEY" || true
  log "已更新最后可用证书 good（基线已刷新）"

else
  log "❌ sing-box 重启失败：尝试回滚到 good 保证服务可用"
  # 4) 重启失败：回滚到 good 并再次重启（保服务）
  if [ -f "$GOOD_FULL" ] && [ -f "$GOOD_KEY" ]; then
    OLD_END="$(cert_enddate "$GOOD_FULL")"
    log "good 证书到期时间：${OLD_END:-unknown}"
    cp -f "$GOOD_FULL" "$CERT_DIR/fullchain.pem"
    cp -f "$GOOD_KEY"  "$CERT_DIR/private.pem"
    chmod 600 "$CERT_DIR/private.pem" || true

    if systemctl restart sing-box; then
      log "✅ 回滚到 good 后 sing-box 重启成功（服务已恢复）"
      log "⚠️ 注意：新证书已保存为 candidate（$CAND_FULL），待排查重启失败原因后可切回新证书"
      # 这里不更新 good（保持 good 仍是已知可用）
    else
      log "❌ 回滚后 sing-box 仍重启失败（可能是配置/依赖问题）"
      journalctl -u sing-box -n 40 --no-pager | tee -a "$LOG_FILE" || true
      exit 1
    fi
  else
    log "⚠️ 没有 good 基线证书可回滚（首次部署场景）"
    journalctl -u sing-box -n 40 --no-pager | tee -a "$LOG_FILE" || true
    exit 1
  fi
fi

# 5) 确保伪装站运行
if [ -f "$FAKEWEB_DIR/docker-compose.yml" ]; then
  cd "$FAKEWEB_DIR" || exit 1
  if command -v docker-compose >/dev/null 2>&1; then
    docker-compose up -d >/dev/null 2>&1 || log "⚠️ 伪装站重启失败"
  else
    docker compose up -d >/dev/null 2>&1 || log "⚠️ 伪装站重启失败"
  fi
  log "伪装站已确保运行"
fi

# 6) 清理 candidate（保留最近 10 份）
ls -1t "$CAND_DIR"/fullchain.pem.* 2>/dev/null | tail -n +11 | xargs -r rm -f
ls -1t "$CAND_DIR"/private.pem.*  2>/dev/null | tail -n +11 | xargs -r rm -f

log "=== 证书续签 HOOK 执行完成 ==="
EOFHOOK

  chmod +x "$hook"
  log "HOOK 脚本已创建: $hook"
  echo "$hook"
}

# ==========================
# ✅ 证书签发流程
# ==========================
issue_cert() {
  [ "${MENU_STATUS[0]}" = "active" ] && { echo "证书已存在（域名: $DOMAIN）"; return; }

  read -p "请输入域名: " DOMAIN
  [[ -z "$DOMAIN" ]] && return

  mkdir -p "$CERT_DIR"
  log "开始为域名 $DOMAIN 签发证书..."

  # 停伪装站避免占用 80
  if [ -f "$FAKEWEB_DIR/docker-compose.yml" ]; then
    log "临时停止伪装站..."
    if command -v docker-compose >/dev/null 2>&1; then
      (cd "$FAKEWEB_DIR" && docker-compose down >/dev/null 2>&1) || true
    else
      (cd "$FAKEWEB_DIR" && docker compose down >/dev/null 2>&1) || true
    fi
  fi

  local HOOK
  HOOK=$(create_acme_hook)

  log "正在申请证书..."
  if ! "$ACME_HOME/acme.sh" --issue --standalone -d "$DOMAIN" --keylength ec-256 --force; then
    log "❌ 证书申请失败"
    echo "❌ 证书申请失败"

    # 恢复伪装站
    if [ -f "$FAKEWEB_DIR/docker-compose.yml" ]; then
      if command -v docker-compose >/dev/null 2>&1; then
        (cd "$FAKEWEB_DIR" && docker-compose up -d >/dev/null 2>&1) || true
      else
        (cd "$FAKEWEB_DIR" && docker compose up -d >/dev/null 2>&1) || true
      fi
    fi
    return 1
  fi

  log "正在安装证书并注册续签钩子..."
  if ! "$ACME_HOME/acme.sh" --install-cert -d "$DOMAIN" --ecc \
      --fullchain-file "$CERT_DIR/fullchain.pem" \
      --key-file "$CERT_DIR/private.pem" \
      --reloadcmd "$HOOK"; then
    log "❌ 证书安装失败"
    echo "❌ 证书安装失败"
    return 1
  fi

  # 首次执行 hook：会建立 good/candidate 并尝试重启
  log "首次执行证书部署 HOOK..."
  "$HOOK" || log "⚠️ 首次 HOOK 执行失败（看日志排查）：$LOG_FILE"

  "$ACME_HOME/acme.sh" --upgrade --auto-upgrade >/dev/null 2>&1 || true

  # 恢复伪装站
  if [ -f "$FAKEWEB_DIR/docker-compose.yml" ]; then
    log "恢复伪装站..."
    if command -v docker-compose >/dev/null 2>&1; then
      (cd "$FAKEWEB_DIR" && docker-compose up -d >/dev/null 2>&1) || true
    else
      (cd "$FAKEWEB_DIR" && docker compose up -d >/dev/null 2>&1) || true
    fi
  fi

  MENU_STATUS[0]="active"
  log "✅ 证书签发完成：$DOMAIN"
  echo ""
  echo "✅ 证书已签发并安装：$DOMAIN"
  echo "✅ 证书路径：$CERT_DIR/fullchain.pem / $CERT_DIR/private.pem"
  echo "✅ good 基线：$CERT_DIR/fullchain.pem.good / $CERT_DIR/private.pem.good"
  echo "✅ candidate 目录：$CERT_DIR/candidate/"
  echo ""
}

configure_singbox() {
  mkdir -p /etc/sing-box
  local need_backup=false

  if [ -f "$SINGBOX_CONFIG" ] && sing-box check -c "$SINGBOX_CONFIG" >/dev/null 2>&1; then
    need_backup=true
    cp "$SINGBOX_CONFIG" "$SINGBOX_CONFIG_BAK"
    log "已备份当前配置"
  fi

  local temp_inbounds
  temp_inbounds=$(mktemp)

  if [ "${MENU_STATUS[1]}" = "active" ]; then
    jq -n \
      --argjson port "$TROJAN_PORT" \
      --arg pass "$TROJAN_PASS" \
      --argjson fakeport "$FAKEWEB_PORT" \
      --arg fullchain "$CERT_DIR/fullchain.pem" \
      --arg key "$CERT_DIR/private.pem" \
      '{ type: "trojan", tag: "trojan-in", listen: "0.0.0.0", listen_port: $port, users: [{password: $pass}],
         tls: { enabled: true, certificate_path: $fullchain, key_path: $key },
         fallback: { server: "127.0.0.1", server_port: $fakeport } }' >> "$temp_inbounds"
  fi

  if [ "${MENU_STATUS[2]}" = "active" ]; then
    jq -n \
      --argjson port "$HYSTERIA2_PORT" \
      --arg pass "$HYSTERIA2_PASS" \
      --argjson bw "$HYSTERIA_BANDWIDTH" \
      --arg fullchain "$CERT_DIR/fullchain.pem" \
      --arg key "$CERT_DIR/private.pem" \
      '{ type: "hysteria2", tag: "hysteria2-in", listen: "0.0.0.0", listen_port: $port,
         up_mbps: $bw, down_mbps: $bw, users: [{password: $pass}],
         tls: { enabled: true, certificate_path: $fullchain, key_path: $key } }' >> "$temp_inbounds"
  fi

  if [ "${MENU_STATUS[3]}" = "active" ]; then
    jq -n \
      --argjson port "$TUIC_PORT" \
      --arg uuid "$TUIC_UUID" \
      --arg pass "$TUIC_PASS" \
      --arg fullchain "$CERT_DIR/fullchain.pem" \
      --arg key "$CERT_DIR/private.pem" \
      '{ type: "tuic", tag: "tuic-in", listen: "0.0.0.0", listen_port: $port,
         users: [{uuid: $uuid, password: $pass}],
         congestion_control: "cubic",
         tls: { enabled: true, certificate_path: $fullchain, key_path: $key } }' >> "$temp_inbounds"
  fi

  if [ -s "$temp_inbounds" ]; then
    jq -s '{ log: {level: "info"}, inbounds: ., outbounds: [{type: "direct", tag: "direct"}] }' "$temp_inbounds" > "$SINGBOX_CONFIG"
  else
    jq -n '{ log: {level: "info"}, inbounds: [], outbounds: [{type: "direct", tag: "direct"}] }' > "$SINGBOX_CONFIG"
  fi
  rm -f "$temp_inbounds"

  echo "正在校验配置..."
  if sing-box check -c "$SINGBOX_CONFIG" >/dev/null 2>&1; then
    log "配置校验成功"
    echo "✅ 配置校验成功！"
    $need_backup && rm -f "$SINGBOX_CONFIG_BAK" || true
    return 0
  else
    log "配置校验失败"
    echo "❌ 配置异常！"
    if $need_backup; then
      echo "正在回滚到上一版本..."
      cp "$SINGBOX_CONFIG_BAK" "$SINGBOX_CONFIG"
      rm -f "$SINGBOX_CONFIG_BAK"
      log "已回滚到备份配置"
      echo "已恢复正常配置"
    else
      echo "首次配置失败，请检查日志：$LOG_FILE"
    fi
    return 1
  fi
}

restart_singbox() {
  echo "正在重启 sing-box..."
  if systemctl restart sing-box; then
    log "sing-box 服务启动成功"
    echo "✅ sing-box 服务启动成功"
    sleep 2
    systemctl is-active --quiet sing-box && echo "✅ sing-box 运行正常" || echo "⚠️ sing-box 可能未正常运行，请检查日志"
  else
    log "sing-box 服务启动失败"
    echo "❌ sing-box 服务启动失败，查看日志："
    journalctl -u sing-box.service -n 30 --no-pager
    return 1
  fi
}

print_all_nodes_and_nodelist() {
  echo -e "\n\033[1;32m========== 所有节点连接信息 ==========\033[0m"

  if [ "${MENU_STATUS[1]}" = "active" ]; then
    echo -e "\n【Trojan】"
    echo "trojan://$TROJAN_PASS@$DOMAIN:$TROJAN_PORT?#Trojan"
  fi

  if [ "${MENU_STATUS[2]}" = "active" ]; then
    echo -e "\n【Hysteria2】"
    echo "hysteria2://$HYSTERIA2_PASS@$DOMAIN:$HYSTERIA2_PORT/?sni=$DOMAIN#Hysteria2"
  fi

  if [ "${MENU_STATUS[3]}" = "active" ]; then
    echo -e "\n【Tuic】"
    echo "tuic://$TUIC_UUID:$TUIC_PASS@$DOMAIN:$TUIC_PORT/?sni=$DOMAIN&congestion_control=cubic#Tuic"
  fi

  echo -e "\n\033[1;32m======================================\033[0m\n"

  local nodelist=""
  [ "${MENU_STATUS[1]}" = "active" ] && nodelist+="trojan://$TROJAN_PASS@$DOMAIN:$TROJAN_PORT?#Trojan\n"
  [ "${MENU_STATUS[2]}" = "active" ] && nodelist+="hysteria2://$HYSTERIA2_PASS@$DOMAIN:$HYSTERIA2_PORT/?sni=$DOMAIN#Hysteria2\n"
  [ "${MENU_STATUS[3]}" = "active" ] && nodelist+="tuic://$TUIC_UUID:$TUIC_PASS@$DOMAIN:$TUIC_PORT/?sni=$DOMAIN&congestion_control=cubic#Tuic\n"

  if [[ -n "$nodelist" ]]; then
    local base64
    base64=$(echo -e "$nodelist" | base64 -w 0 2>/dev/null || echo -e "$nodelist" | base64 | tr -d '\n')
    echo -e "\033[1;33m========== NodeList 订阅（Base64）==========\033[0m"
    echo "$base64"
    echo -e "\033[1;33m\n💡 复制上方 Base64 用于订阅转换\033[0m\n"
  fi
}

show_menu() {
  while true; do
    clear
    echo "=========================================="
    echo "     Sing-box 节点管理脚本（续签闭环兜底版）"
    echo "=========================================="
    echo "1. 创建/查看域名证书 [${MENU_STATUS[0]}] ${DOMAIN:+域名:$DOMAIN}"
    echo "2. Trojan 节点 [${MENU_STATUS[1]}] ${TROJAN_PORT:+端口:$TROJAN_PORT}"
    echo "3. Hysteria2 节点 [${MENU_STATUS[2]}] ${HYSTERIA2_PORT:+端口:$HYSTERIA2_PORT}"
    echo "4. Tuic 节点 [${MENU_STATUS[3]}] ${TUIC_PORT:+端口:$TUIC_PORT}"
    echo "5. 查看所有节点信息和订阅"
    echo "6. 查看日志（最近 80 行）"
    echo "0. 退出"
    echo "=========================================="
    read -p "请选择 [0-6]: " c

    case $c in
      1)
        issue_cert
        create_systemd_service
        ;;
      2|3|4)
        [ "${MENU_STATUS[0]}" != "active" ] && {
          echo "❌ 请先创建证书（选项 1）"
          read -n1 -s -p "按任意键继续..."
          continue
        }

        if [[ $c == 2 && "${MENU_STATUS[1]}" == "active" ]] || \
           [[ $c == 3 && "${MENU_STATUS[2]}" == "active" ]] || \
           [[ $c == 4 && "${MENU_STATUS[3]}" == "active" ]]; then
          echo "该节点已启用"
          read -p "是否重新配置？(y/N): " reconf
          [[ ! "$reconf" =~ ^[Yy]$ ]] && continue
        fi

        if [[ $c == 2 ]]; then
          read -p "Trojan 端口 (默认 443): " p
          TROJAN_PORT=${p:-443}
          while ! check_port "$TROJAN_PORT"; do
            read -p "请重新输入端口: " TROJAN_PORT
          done
          TROJAN_PASS=$(generate_password)
          echo "✅ 新密码: $TROJAN_PASS"
          MENU_STATUS[1]="active"

        elif [[ $c == 3 ]]; then
          read -p "Hysteria2 端口: " HYSTERIA2_PORT
          while ! check_port "$HYSTERIA2_PORT" || [ -z "$HYSTERIA2_PORT" ]; do
            read -p "请重新输入端口: " HYSTERIA2_PORT
          done
          HYSTERIA2_PASS=$(generate_password)
          echo "✅ 新密码: $HYSTERIA2_PASS"
          MENU_STATUS[2]="active"

        else
          read -p "Tuic 端口: " TUIC_PORT
          while ! check_port "$TUIC_PORT" || [ -z "$TUIC_PORT" ]; do
            read -p "请重新输入端口: " TUIC_PORT
          done
          TUIC_UUID=$(generate_uuid)
          TUIC_PASS=$(generate_password)
          echo "✅ UUID: $TUIC_UUID"
          echo "✅ 密码: $TUIC_PASS"
          MENU_STATUS[3]="active"
        fi

        if configure_singbox; then
          restart_singbox
          echo ""
          print_all_nodes_and_nodelist
        else
          echo "❌ 配置失败，请检查日志：$LOG_FILE"
        fi
        ;;
      5)
        print_all_nodes_and_nodelist
        ;;
      6)
        echo "========== 最近 80 行日志 =========="
        tail -n 80 "$LOG_FILE" 2>/dev/null || echo "日志文件不存在"
        echo "===================================="
        ;;
      0)
        echo "再见！"
        exit 0
        ;;
      *)
        echo "❌ 无效选项"
        ;;
    esac

    read -n1 -s -p "按任意键继续..."
  done
}

main() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 请使用 root 用户运行此脚本"
    exit 1
  fi

  touch "$LOG_FILE"
  chmod 644 "$LOG_FILE" || true

  log "=========================================="
  log "脚本启动"
  log "=========================================="

  install_dependencies
  check_singbox
  check_acme
  deploy_fakeweb
  create_systemd_service
  load_existing_config

  show_menu
}

main
