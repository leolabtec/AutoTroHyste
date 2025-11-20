#!/bin/bash
set -euo pipefail

# ============ 配色 ============
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# 检查 root
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}请使用 root 权限运行此脚本${NC}"
  exit 1
fi

# ============ 安装必要依赖 ============
echo -e "${GREEN}安装必要依赖...${NC}"
apt update -y
apt install -y curl wget socat unzip cron dnsutils openssl

systemctl enable --now cron

# ===============================
# 1️⃣ 输入域名并检查解析是否匹配本机公网
# ===============================
read -p "请输入你的域名（确保已解析）: " DOMAIN

# 域名解析
resolve_ipv4=$(dig +short A "${DOMAIN}" | head -n1 || true)
resolve_ipv6=$(dig +short AAAA "${DOMAIN}" | head -n1 || true)

if [[ -z "$resolve_ipv4" && -z "$resolve_ipv6" ]]; then
    echo -e "${RED}错误：域名未解析到任何公网 IP！${NC}"
    exit 1
fi

# 获取本机公网 IP（强制 IPv4/IPv6）
my_ipv4=$(curl -4 -s https://ifconfig.me || curl -4 -s https://ifconfig.co || true)
my_ipv6=$(curl -6 -s https://ifconfig.me || curl -6 -s https://ifconfig.co || true)

# 优先校验 IPv4，如果没有 IPv4 再校验 IPv6
if [[ -n "$resolve_ipv4" ]]; then
    if [[ "$resolve_ipv4" != "$my_ipv4" ]]; then
        echo -e "${RED}错误：域名解析的 IPv4 ($resolve_ipv4) 与本机公网 IPv4 ($my_ipv4) 不匹配！${NC}"
        exit 1
    fi
    echo -e "${GREEN}域名解析成功且匹配本机公网 IPv4${NC}"
elif [[ -n "$resolve_ipv6" ]]; then
    if [[ -z "$my_ipv6" ]]; then
        echo -e "${RED}错误：本机没有可用的 IPv6 公网地址，无法校验！${NC}"
        exit 1
    fi
    if [[ "$resolve_ipv6" != "$my_ipv6" ]]; then
        echo -e "${RED}错误：域名解析的 IPv6 ($resolve_ipv6) 与本机公网 IPv6 ($my_ipv6) 不匹配！${NC}"
        exit 1
    fi
    echo -e "${GREEN}域名解析成功且匹配本机公网 IPv6${NC}"
else
    echo -e "${RED}错误：未检测到有效的解析记录（不应出现）${NC}"
    exit 1
fi

echo -e "${GREEN}域名解析成功且匹配本机公网 IP${NC}"


# ============ 检查并安装 Docker ============
if ! command -v docker >/dev/null 2>&1; then
  echo -e "${GREEN}安装 Docker...${NC}"
  curl -fsSL https://get.docker.com | sh
else
  echo -e "${GREEN}Docker 已安装${NC}"
fi

# ============ 检查 / 安装 Docker Compose（同时兼容 v1/v2 调用） ============

COMPOSE_BIN=()

# 优先使用新版本：docker compose
if docker compose version >/dev/null 2>&1; then
  echo -e "${GREEN}检测到 docker compose（V2 插件）${NC}"
  COMPOSE_BIN=(docker compose)

# 其次使用老版本：docker-compose
elif docker-compose version >/dev/null 2>&1; then
  echo -e "${GREEN}检测到 docker-compose（V1 独立二进制）${NC}"
  COMPOSE_BIN=(docker-compose)

# 两个都没有 → 安装 Compose V2 插件，并兼容两种用法
else
  echo -e "${GREEN}未检测到 Docker Compose，开始安装 Compose V2 插件...${NC}"

  # 官方推荐的插件目录（Docker CLI 会自动识别）
  PLUGIN_DIR="/root/.docker/cli-plugins"
  mkdir -p "$PLUGIN_DIR"

  # 获取最新版本下载地址（Linux x86_64）
  LATEST_URL=$(curl -fsSL https://api.github.com/repos/docker/compose/releases/latest \
    | grep browser_download_url \
    | grep linux-x86_64 \
    | cut -d '"' -f 4)

  if [[ -z "$LATEST_URL" ]]; then
    echo -e "${RED}获取 Docker Compose 最新版本下载链接失败${NC}"
    exit 1
  fi

  curl -L "$LATEST_URL" -o "${PLUGIN_DIR}/docker-compose"
  chmod +x "${PLUGIN_DIR}/docker-compose"

  # 额外做一个兼容：让 `docker-compose` 这个命令也可用
  ln -sf "${PLUGIN_DIR}/docker-compose" /usr/local/bin/docker-compose

  echo -e "${GREEN}Docker Compose V2 安装完成！${NC}"
  echo -e "${GREEN}支持：'docker compose' 和 'docker-compose' 两种写法${NC}"

  COMPOSE_BIN=(docker compose)
fi

# ============ 安装 acme.sh ============
if [[ ! -d ~/.acme.sh ]]; then
  curl https://get.acme.sh | sh
fi
export PATH=~/.acme.sh:$PATH

# ============ 创建伪装网站（Docker） ============
echo -e "${GREEN}部署伪装网站容器...${NC}"
mkdir -p /home/wzweb
cd /home/wzweb

cat > docker-compose.yml <<EOF
version: '3'
services:
  fakeweb:
    image: hongcheng618/wzweb
    container_name: fakeweb
    ports:
      - "8080:80"
    restart: always
EOF

# 兼容 docker compose / docker-compose
if command -v docker &>/dev/null && docker compose version &>/dev/null; then
    echo "使用 docker compose up -d"
    docker compose up -d
elif command -v docker-compose &>/dev/null; then
    echo "使用 docker-compose up -d"
    docker-compose up -d
else
    echo -e "${RED}错误：系统未安装 docker compose 或 docker-compose${NC}"
    exit 1
fi

# ============ 下载 Trojan-Go ============
echo -e "${GREEN}安装 Trojan-Go...${NC}"
mkdir -p /root/trojan
cd /root/trojan
if [[ ! -f trojan-go ]]; then
  wget -O trojan-go.zip https://github.com/p4gefau1t/trojan-go/releases/download/v0.10.6/trojan-go-linux-amd64.zip
  unzip -o trojan-go.zip
  chmod +x trojan-go
fi

TROJAN_PASS=$(openssl rand -base64 32 | tr -dc A-Za-z0-9 | head -c 20)

cat > /root/trojan/config.json <<EOF
{
  "run_type": "server",
  "local_addr": "0.0.0.0",
  "local_port": 443,
  "remote_addr": "127.0.0.1",
  "remote_port": 8080,
  "password": [
    "$TROJAN_PASS"
  ],
  "log_level": 1,
  "ssl": {
    "cert": "/root/trojan/server.crt",
    "key": "/root/trojan/server.key",
    "sni": "$DOMAIN",
    "fallback_addr": "127.0.0.1",
    "fallback_port": 8080
  },
  "router": {
    "enabled": true,
    "block": [
      "geoip:private"
    ]
  }
}
EOF

# ============ 创建 Trojan-Go systemd 服务 ============
cat > /etc/systemd/system/trojan-go.service <<EOF
[Unit]
Description=Trojan-Go Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root/trojan
ExecStart=/root/trojan/trojan-go -config /root/trojan/config.json
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable trojan-go

# ============ 安装 Hysteria2，并使用同一套证书 ============
echo -e "${GREEN}安装 Hysteria2...${NC}"
bash <(curl -fsSL https://get.hy2.sh/)
systemctl enable hysteria-server.service

# ============ Hysteria 用户与目录检查 ============

echo -e "${GREEN}检查 Hysteria2 用户与配置目录...${NC}"

HYSTERIA_USER="hysteria"
HYSTERIA_DIR="/etc/hysteria"

# 检查 Hysteria 用户
if id "$HYSTERIA_USER" >/dev/null 2>&1; then
    echo -e "${GREEN}用户 $HYSTERIA_USER 已存在，跳过创建${NC}"
else
    echo -e "${GREEN}用户 $HYSTERIA_USER 不存在，创建中...${NC}"
    useradd -r -s /usr/sbin/nologin "$HYSTERIA_USER"
    echo -e "${GREEN}用户 $HYSTERIA_USER 已创建${NC}"
fi

# 检查目录 /etc/hysteria
if [[ -d "$HYSTERIA_DIR" ]]; then
    echo -e "${GREEN}目录 $HYSTERIA_DIR 已存在，跳过创建${NC}"
else
    echo -e "${GREEN}目录 $HYSTERIA_DIR 不存在，创建中...${NC}"
    mkdir -p "$HYSTERIA_DIR"
    echo -e "${GREEN}目录 $HYSTERIA_DIR 已创建${NC}"
fi

# 目录归属 hysteria 用户（防止已有目录但属主错的情况）
chown -R "$HYSTERIA_USER:$HYSTERIA_USER" "$HYSTERIA_DIR"

echo -e "${GREEN}Hysteria 用户与目录检查已完成${NC}"

# ==============================
# 2️⃣ 创建 Hook 脚本（证书续签使用）
# ==============================

# pre-hook：续签前停止服务
cat > /root/hook_pre.sh <<'EOF'
#!/bin/bash
set -euo pipefail
echo "[HOOK-PRE] 停止 Trojan-Go 与 Hysteria 服务..."
systemctl stop trojan-go.service || true
systemctl stop hysteria-server.service || true
sleep 1
echo "[HOOK-PRE] 已停止服务."
EOF
chmod 700 /root/hook_pre.sh
chown root:root /root/hook_pre.sh

# post-hook：续签后更新证书并重启
cat > /root/hook_post.sh <<'EOF'
#!/bin/bash
set -euo pipefail
DOMAIN="${Le_Domain:-}"
if [[ -z "$DOMAIN" ]]; then
    echo "[HOOK-POST] ERROR: 未获取到域名变量 Le_Domain"
    exit 1
fi

ACME_PATH="/root/.acme.sh/${DOMAIN}_ecc"
SRC_CERT="${ACME_PATH}/fullchain.cer"
SRC_KEY="${ACME_PATH}/${DOMAIN}.key"
TROJAN_DIR="/root/trojan"
HYSTERIA_DIR="/etc/hysteria"
HYSTERIA_USER="hysteria"

echo "[HOOK-POST] 覆盖新证书..."
install -m 600 "$SRC_KEY" "$TROJAN_DIR/server.key"
install -m 644 "$SRC_CERT" "$TROJAN_DIR/server.crt"
chown root:root "$TROJAN_DIR/server.key" "$TROJAN_DIR/server.crt"

if [[ -d "$HYSTERIA_DIR" ]]; then
    install -m 600 "$SRC_KEY" "$HYSTERIA_DIR/server.key"
    install -m 644 "$SRC_CERT" "$HYSTERIA_DIR/server.crt"
    if id "$HYSTERIA_USER" >/dev/null 2>&1; then
        chown "$HYSTERIA_USER:$HYSTERIA_USER" "$HYSTERIA_DIR/server.key" "$HYSTERIA_DIR/server.crt"
    fi
fi

echo "[HOOK-POST] 重启服务..."
systemctl restart trojan-go.service || echo "[HOOK-POST] Trojan-Go 重启失败"
systemctl restart hysteria-server.service || echo "[HOOK-POST] Hysteria 重启失败"
echo "[HOOK-POST] ✅ 更新完成."
EOF
chmod 700 /root/hook_post.sh
chown root:root /root/hook_post.sh

# quarterly-hook：每季度维护任务
cat > /root/hook_quarterly.sh <<'EOF'
#!/bin/bash
set -euo pipefail
LOGFILE="/root/hook_quarterly.log"
echo "[HOOK-QUARTERLY] 开始季度维护任务: $(date)" | tee -a "$LOGFILE"

if [[ -f "/root/trojan/server.crt" ]]; then
    echo "[HOOK-QUARTERLY] 证书过期时间：" | tee -a "$LOGFILE"
    openssl x509 -in /root/trojan/server.crt -noout -dates | tee -a "$LOGFILE"
fi

systemctl restart trojan-go.service || echo "[HOOK-QUARTERLY] Trojan-Go 重启失败" | tee -a "$LOGFILE"
systemctl restart hysteria-server.service || echo "[HOOK-QUARTERLY] Hysteria 重启失败" | tee -a "$LOGFILE"

find /root/.acme.sh -type f -name "*.bak" -delete
echo "[HOOK-QUARTERLY] ✅ 维护任务完成: $(date)" | tee -a "$LOGFILE"
EOF
chmod 700 /root/hook_quarterly.sh
chown root:root /root/hook_quarterly.sh

# 定时任务：每季度 1 日凌晨 3 点执行
(crontab -l 2>/dev/null; echo "0 3 1 1,4,7,10 * bash /root/hook_quarterly.sh") | crontab -

# ============ 申请证书（HTTP standalone + hook） ============
echo -e "${GREEN}申请 TLS 证书...${NC}"
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 \
  --pre-hook "bash /root/hook_pre.sh" \
  --post-hook "bash /root/hook_post.sh"

# 安装证书到 trojan 目录（并绑定 reload hook）
~/.acme.sh/acme.sh --installcert -d "$DOMAIN" --ecc \
  --key-file /root/trojan/server.key \
  --fullchain-file /root/trojan/server.crt \
  --reloadcmd "bash /root/hook_post.sh"

~/.acme.sh/acme.sh --upgrade --auto-upgrade

# 启动 Trojan-Go
systemctl restart trojan-go


# 确保证书在 /etc/hysteria 下也有一份（hook_post 也会维护）
cp -f /root/trojan/server.crt /etc/hysteria/server.crt
cp -f /root/trojan/server.key /etc/hysteria/server.key
chown "$HYSTERIA_USER:$HYSTERIA_USER" /etc/hysteria/server.crt /etc/hysteria/server.key

echo "🎲 正在为 Hysteria2 生成端口..."
for i in {1..20}; do
  HY_PORT=$(shuf -i 30000-65535 -n 1)
  if ! ss -tuln | grep -q ":$HY_PORT "; then
    echo "✅ Hysteria2 使用端口: $HY_PORT"
    break
  fi
done

if ss -tuln | grep -q ":$HY_PORT "; then
  echo -e "${RED}❌ 未能找到未占用端口，请重试或手动修改端口${NC}"
  exit 1
fi

HY_PASS=$(openssl rand -base64 32 | tr -dc A-Za-z0-9 | head -c 20)

cat > /etc/hysteria/config.yaml <<EOF
listen: :$HY_PORT

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: $HY_PASS

masquerade:
  type: proxy
  proxy:
    url: https://$DOMAIN
    rewriteHost: true
EOF

chown "$HYSTERIA_USER:$HYSTERIA_USER" /etc/hysteria/config.yaml

echo "📡 启动 Hysteria2 服务..."
if ! systemctl restart hysteria-server.service; then
  echo -e "${RED}❌ Hysteria2 启动失败，最近日志：${NC}"
  journalctl -u hysteria-server --no-pager -n 30
  exit 1
fi

# ============ 输出节点信息 ============
IPv4=$(curl -4 -s https://api64.ipify.org || true)
IPv6=$(curl -6 -s https://api64.ipify.org || true)
IP=${IPv4:-$IPv6}
IP=${IP:-"未知"}

TROJAN_URL="trojan://${TROJAN_PASS}@${DOMAIN}:443?security=tls&type=tcp&sni=${DOMAIN}#Trojan-${DOMAIN}"
HY_URL="hysteria2://${HY_PASS}@${DOMAIN}:${HY_PORT}/?sni=${DOMAIN}&insecure=0#Hy2-${DOMAIN}"

echo ""
echo -e "${GREEN}✅ Trojan-Go + Hysteria2 部署完成${NC}"
echo "------------------------------------------------"
echo "🌐 公网 IP        : $IP"
echo "🌍 域名           : $DOMAIN"
echo ""
echo "🔹 Trojan-Go 节点信息："
echo "    协议    : trojan"
echo "    地址    : $DOMAIN"
echo "    端口    : 443"
echo "    密码    : $TROJAN_PASS"
echo "    SNI     : $DOMAIN"
echo "    URL     :"
echo "      $TROJAN_URL"
echo ""
echo "🔹 Hysteria2 节点信息："
echo "    协议    : hysteria2"
echo "    地址    : $DOMAIN"
echo "    端口    : $HY_PORT"
echo "    密码    : $HY_PASS"
echo "    伪装域名: https://$DOMAIN"
echo "    URL     :"
echo "      $HY_URL"
echo ""
echo "📁 Trojan 配置路径 : /root/trojan/config.json"
echo "📁 Hy2 配置路径    : /etc/hysteria/config.yaml"
echo "📁 证书路径        : /root/trojan/server.crt / .key（主） + /etc/hysteria/ （副本）"
echo ""
echo -e "${GREEN}自动续签说明：${NC}"
echo "  acme.sh 会在到期前自动续签："
echo "    续签前 → /root/hook_pre.sh 停止服务"
echo "    续签后 → /root/hook_post.sh 覆盖证书并重启 Trojan & Hysteria"
echo "    每季度 → /root/hook_quarterly.sh 做一次维护和日志记录"
