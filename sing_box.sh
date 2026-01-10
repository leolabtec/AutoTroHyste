#!/bin/bash
# =========================================
# Sing-box 全协议节点管理脚本 - 终极修复版
# 修复点：
# 1) HOOK 脚本直接使用 --install-cert 写入的证书路径（不依赖 _ecc）
# 2) 修复回滚逻辑（备份文件名匹配）
# 3) 修复 --reloadcmd 引号问题
# 4) 增强错误处理和日志
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

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
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
    
    if systemctl is-active --quiet sing-box && (ss -tuln | grep -q ":$port " || ss -uapn | grep -q ":$port "); then
        systemctl stop sing-box
        temp_stop=1
    fi
    
    if ss -tuln | grep -q ":$port " || ss -uapn | grep -q ":$port "; then
        [ $temp_stop -eq 1 ] && systemctl start sing-box
        echo "端口 $port 已被占用（TCP 或 UDP），请重新输入。"
        return 1
    else
        [ $temp_stop -eq 1 ] && systemctl start sing-box
        return 0
    fi
}

install_dependencies() {
    echo "安装必要依赖..."
    local DEPS=(socat unzip cron dnsutils docker.io openssl curl jq iproute2 tar gzip)
    apt update -y >/dev/null 2>&1 || true
    
    for pkg in "${DEPS[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            apt install -y "$pkg"
        fi
    done
    
    # 安装 docker-compose
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
    "$ACME_HOME/acme.sh" --set-default-ca --server letsencrypt
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
            | sed -n 's/.*CN = \([^,]*\).*/\1/p' | head -n1)
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

# ========================== 
# ✅ 终极修复版 HOOK 脚本
# ==========================
create_acme_hook() {
    local hook="$ACME_HOME/singbox-reload.sh"
    
    # 关键修复：
    # 1. 不依赖 _ecc 路径，直接验证 CERT_DIR 中的证书（由 --install-cert 写入）
    # 2. 修复回滚逻辑（使用固定备份文件名）
    # 3. 增强错误处理
    cat > "$hook" <<'EOFHOOK'
#!/bin/bash
set -euo pipefail

CERT_DIR="/root/cert"
FAKEWEB_DIR="/home/wzweb"
LOG_FILE="/var/log/singbox-cert.log"
BACKUP_SUFFIX=".backup"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "=== 证书续签 HOOK 开始执行 ==="

# 1) 验证 acme.sh 已将新证书写入 CERT_DIR
#    （此时 --install-cert 已经覆盖了 fullchain.pem 和 private.pem）
if [ ! -f "$CERT_DIR/fullchain.pem" ] || [ ! -f "$CERT_DIR/private.pem" ]; then
    log "错误：证书文件不存在于 $CERT_DIR"
    exit 1
fi

# 2) 验证新证书有效性
if ! openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -checkend 0 >/dev/null 2>&1; then
    log "错误：新证书无效或已过期"
    
    # 回滚到备份（如果存在）
    if [ -f "$CERT_DIR/fullchain.pem$BACKUP_SUFFIX" ] && [ -f "$CERT_DIR/private.pem$BACKUP_SUFFIX" ]; then
        log "正在回滚到备份证书..."
        cp "$CERT_DIR/fullchain.pem$BACKUP_SUFFIX" "$CERT_DIR/fullchain.pem"
        cp "$CERT_DIR/private.pem$BACKUP_SUFFIX" "$CERT_DIR/private.pem"
        log "已回滚到备份证书"
    fi
    exit 1
fi

log "新证书验证成功"

# 3) 创建本次备份（覆盖旧备份）
cp "$CERT_DIR/fullchain.pem" "$CERT_DIR/fullchain.pem$BACKUP_SUFFIX" 2>/dev/null || true
cp "$CERT_DIR/private.pem" "$CERT_DIR/private.pem$BACKUP_SUFFIX" 2>/dev/null || true
log "已创建证书备份"

# 4) 重启 sing-box
if systemctl is-active --quiet sing-box; then
    log "正在重启 sing-box..."
    if systemctl restart sing-box; then
        log "✅ sing-box 重启成功"
    else
        log "❌ sing-box 重启失败"
        journalctl -u sing-box -n 20 --no-pager | tee -a "$LOG_FILE"
        exit 1
    fi
else
    log "警告：sing-box 服务未运行，尝试启动..."
    if systemctl start sing-box; then
        log "✅ sing-box 启动成功"
    else
        log "❌ 无法启动 sing-box"
        exit 1
    fi
fi

# 5) 确保伪装站正常运行
if [ -f "$FAKEWEB_DIR/docker-compose.yml" ]; then
    cd "$FAKEWEB_DIR" || exit 1
    if command -v docker-compose >/dev/null 2>&1; then
        docker-compose up -d >/dev/null 2>&1 || log "警告：伪装站重启失败"
    else
        docker compose up -d >/dev/null 2>&1 || log "警告：伪装站重启失败"
    fi
    log "伪装站已确保运行"
fi

log "=== 证书续签 HOOK 执行完成 ==="
EOFHOOK

    chmod +x "$hook"
    log "HOOK 脚本已创建: $hook"
    echo "$hook"
}

# ========================== 
# ✅ 终极修复版证书签发流程
# ==========================
issue_cert() {
    [ "${MENU_STATUS[0]}" = "active" ] && { echo "证书已存在（域名: $DOMAIN）"; return; }
    
    read -p "请输入域名: " DOMAIN
    [[ -z "$DOMAIN" ]] && return
    
    mkdir -p "$CERT_DIR"
    log "开始为域名 $DOMAIN 签发证书..."
    
    # 1) 临时停止伪装站（避免端口占用）
    if [ -f "$FAKEWEB_DIR/docker-compose.yml" ]; then
        log "临时停止伪装站..."
        if command -v docker-compose >/dev/null 2>&1; then
            (cd "$FAKEWEB_DIR" && docker-compose down >/dev/null 2>&1) || true
        else
            (cd "$FAKEWEB_DIR" && docker compose down >/dev/null 2>&1) || true
        fi
    fi
    
    # 2) 创建 HOOK 脚本
    local HOOK
    HOOK=$(create_acme_hook)
    
    # 3) 申请证书（ECC）
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
    
    # 4) 安装证书并注册 HOOK
    #    关键修复：不用转义引号，直接传递脚本路径
    log "正在安装证书并注册续签钩子..."
    if ! "$ACME_HOME/acme.sh" --install-cert -d "$DOMAIN" --ecc \
        --fullchain-file "$CERT_DIR/fullchain.pem" \
        --key-file "$CERT_DIR/private.pem" \
        --reloadcmd "$HOOK"; then
        log "❌ 证书安装失败"
        echo "❌ 证书安装失败"
        return 1
    fi
    
    # 5) 立即执行一次 HOOK（确保首次签发后立即生效）
    log "首次执行证书部署..."
    if [ -x "$HOOK" ]; then
        if "$HOOK"; then
            log "✅ 证书部署成功"
        else
            log "⚠️  首次 HOOK 执行失败，但证书已安装"
        fi
    fi
    
    # 6) 启用自动升级
    "$ACME_HOME/acme.sh" --upgrade --auto-upgrade >/dev/null 2>&1 || true
    
    # 7) 恢复伪装站
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
    echo "✅ 证书路径：$CERT_DIR/fullchain.pem"
    echo "✅ 后续每次续签都会自动重启 sing-box"
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
    
    # Trojan (带 fallback)
    if [ "${MENU_STATUS[1]}" = "active" ]; then
        jq -n \
            --argjson port "$TROJAN_PORT" \
            --arg pass "$TROJAN_PASS" \
            --argjson fakeport "$FAKEWEB_PORT" \
            --arg fullchain "$CERT_DIR/fullchain.pem" \
            --arg key "$CERT_DIR/private.pem" \
            '{ type: "trojan", tag: "trojan-in", listen: "0.0.0.0", listen_port: $port, users: [{password: $pass}], tls: { enabled: true, certificate_path: $fullchain, key_path: $key }, fallback: { server: "127.0.0.1", server_port: $fakeport } }' >> "$temp_inbounds"
    fi
    
    # Hysteria2
    if [ "${MENU_STATUS[2]}" = "active" ]; then
        jq -n \
            --argjson port "$HYSTERIA2_PORT" \
            --arg pass "$HYSTERIA2_PASS" \
            --argjson bw "$HYSTERIA_BANDWIDTH" \
            --arg fullchain "$CERT_DIR/fullchain.pem" \
            --arg key "$CERT_DIR/private.pem" \
            '{ type: "hysteria2", tag: "hysteria2-in", listen: "0.0.0.0", listen_port: $port, up_mbps: $bw, down_mbps: $bw, users: [{password: $pass}], tls: { enabled: true, certificate_path: $fullchain, key_path: $key } }' >> "$temp_inbounds"
    fi
    
    # Tuic
    if [ "${MENU_STATUS[3]}" = "active" ]; then
        jq -n \
            --argjson port "$TUIC_PORT" \
            --arg uuid "$TUIC_UUID" \
            --arg pass "$TUIC_PASS" \
            --arg fullchain "$CERT_DIR/fullchain.pem" \
            --arg key "$CERT_DIR/private.pem" \
            '{ type: "tuic", tag: "tuic-in", listen: "0.0.0.0", listen_port: $port, users: [{uuid: $uuid, password: $pass}], congestion_control: "cubic", tls: { enabled: true, certificate_path: $fullchain, key_path: $key } }' >> "$temp_inbounds"
    fi
    
    # 组装最终配置
    if [ -s "$temp_inbounds" ]; then
        jq -s '{ log: {level: "info"}, inbounds: ., outbounds: [{type: "direct", tag: "direct"}] }' "$temp_inbounds" > "$SINGBOX_CONFIG"
    else
        jq -n '{ log: {level: "info"}, inbounds: [], outbounds: [{type: "direct", tag: "direct"}] }' > "$SINGBOX_CONFIG"
    fi
    rm -f "$temp_inbounds"
    
    # 校验
    echo "正在校验配置..."
    if sing-box check -c "$SINGBOX_CONFIG" >/dev/null 2>&1; then
        log "配置校验成功"
        echo "✅ 配置校验成功！"
        if $need_backup; then
            rm -f "$SINGBOX_CONFIG_BAK"
        fi
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
        if systemctl is-active --quiet sing-box; then
            echo "✅ sing-box 运行正常"
        else
            echo "⚠️  sing-box 可能未正常运行，请检查日志"
        fi
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
    
    # 生成订阅
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
        echo "     Sing-box 节点管理脚本 v2.0"
        echo "=========================================="
        echo "1. 创建/查看域名证书 [${MENU_STATUS[0]}] ${DOMAIN:+域名:$DOMAIN}"
        echo "2. Trojan 节点 [${MENU_STATUS[1]}] ${TROJAN_PORT:+端口:$TROJAN_PORT}"
        echo "3. Hysteria2 节点 [${MENU_STATUS[2]}] ${HYSTERIA2_PORT:+端口:$HYSTERIA2_PORT}"
        echo "4. Tuic 节点 [${MENU_STATUS[3]}] ${TUIC_PORT:+端口:$TUIC_PORT}"
        echo "5. 查看所有节点信息和订阅"
        echo "6. 查看日志"
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
                
                # 检查是否已启用
                if [[ $c == 2 && "${MENU_STATUS[1]}" == "active" ]] || \
                   [[ $c == 3 && "${MENU_STATUS[2]}" == "active" ]] || \
                   [[ $c == 4 && "${MENU_STATUS[3]}" == "active" ]]; then
                    echo "该节点已启用"
                    read -p "是否重新配置？(y/N): " reconf
                    [[ ! "$reconf" =~ ^[Yy]$ ]] && continue
                fi
                
                # 配置节点
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
                
                # 生成配置并重启
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
                echo "========== 最近 50 行日志 =========="
                tail -n 50 "$LOG_FILE" 2>/dev/null || echo "日志文件不存在"
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

# ========================== 
# 主流程
# ==========================
main() {
    # 确保以 root 运行
    if [ "$(id -u)" -ne 0 ]; then
        echo "❌ 请使用 root 用户运行此脚本"
        exit 1
    fi
    
    # 创建日志文件
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
    
    log "=========================================="
    log "脚本启动"
    log "=========================================="
    
    # 安装依赖
    install_dependencies
    check_singbox
    check_acme
    deploy_fakeweb
    create_systemd_service
    load_existing_config
    
    # 显示菜单
    show_menu
}

# 执行主函数
main
