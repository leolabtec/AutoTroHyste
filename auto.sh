#!/bin/bash
set -e

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 root 权限运行此脚本"
  exit 1
fi

# 输入域名
read -p "🔑 请输入你的域名 (确保已经解析到当前主机IP): " DOMAIN

# 检查域名解析
resolve_ip=$(getent hosts "$DOMAIN" | awk '{ print $1 }' | head -n1)
if [[ -z "$resolve_ip" ]]; then
    resolve_ip=$(ping -c1 "$DOMAIN" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
fi

if [[ -z "$resolve_ip" ]]; then
    echo "❌ 错误: 域名未解析成功"
    exit 1
else
    echo "✅ 域名解析成功: $resolve_ip"
fi

# 安装依赖
apt update -y
apt install -y curl wget socat unzip cron docker.io docker-compose openssl

# 安装 acme.sh
curl https://get.acme.sh | sh
export PATH=~/.acme.sh:$PATH
source ~/.bashrc

# 创建相关目录
mkdir -p /root/trojan /home/wzweb /etc/hysteria

# 启动伪装站点
cd /home/wzweb
cat > docker-compose.yml <<EOF
version: '3'
services:
  fakeweb:
    image: hongcheng618/wzweb
    container_name: fakeweb
    ports:
      - "9181:80"
    restart: always
EOF

docker-compose up -d

# 请求证书
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
~/.acme.sh/acme.sh --issue -d $DOMAIN --standalone --keylength ec-256

# 安装证书到 trojan 和 hysteria（不使用 --reloadcmd）
~/.acme.sh/acme.sh --installcert -d $DOMAIN --ecc \
  --key-file /root/trojan/server.key \
  --fullchain-file /root/trojan/server.crt

~/.acme.sh/acme.sh --installcert -d $DOMAIN --ecc \
  --key-file /etc/hysteria/server.key \
  --fullchain-file /etc/hysteria/server.crt

chown hysteria /etc/hysteria/server.key
chown hysteria /etc/hysteria/server.crt

# 下载 trojan-go
cd /root/trojan
wget -O trojan-go.zip https://github.com/p4gefau1t/trojan-go/releases/download/v0.10.6/trojan-go-linux-amd64.zip
unzip -o trojan-go.zip
chmod +x trojan-go

# 随机生成 Trojan-Go 密码
TROJAN_PASS=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 20)

cat > /root/trojan/config.json <<EOF
{
  "run_type": "server",
  "local_addr": "0.0.0.0",
  "local_port": 443,
  "remote_addr": "127.0.0.1",
  "remote_port": 9181,
  "password": ["$TROJAN_PASS"],
  "ssl": {
    "cert": "/root/trojan/server.crt",
    "key": "/root/trojan/server.key",
    "sni": "$DOMAIN"
  },
  "router": {
    "enabled": true,
    "block": ["geoip:private"]
  }
}
EOF

# 生成 systemd 服务文件
echo "⚙️ 创建 systemd 服务文件..."
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
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable trojan-go.service
systemctl start trojan-go.service

# 安装 Hysteria2
bash <(curl -fsSL https://get.hy2.sh/)
systemctl enable hysteria-server.service

# 随机生成未被占用的端口
for i in {1..20}; do
  PORT=$(shuf -i 30000-65535 -n 1)
  if ! ss -tuln | grep -q ":$PORT "; then
    echo "✅ Hysteria2 使用端口: $PORT"
    break
  fi
done

if ss -tuln | grep -q ":$PORT "; then
  echo "❌ 未找到可用端口"
  exit 1
fi

HY_PASS=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 20)

cat > /etc/hysteria/config.yaml <<EOF
listen: :$PORT

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

systemctl restart hysteria-server.service

# 写重启服务脚本
cat > /root/restart_services.sh <<EOF
#!/bin/bash
systemctl daemon-reload
systemctl restart trojan-go.service
systemctl restart hysteria-server.service
EOF
chmod +x /root/restart_services.sh

# 添加定时重启服务的cron任务（每50天凌晨5点）
cronjob="0 5 */50 * * /root/restart_services.sh"
(crontab -l 2>/dev/null | grep -v -F "/root/restart_services.sh" ; echo "$cronjob") | crontab -
echo "✅ 已添加定时任务：每50天凌晨5点自动重启服务"

# 获取公网 IP
IPv4=$(curl -4 -s https://api64.ipify.org)
IPv6=$(curl -6 -s https://api64.ipify.org)
IP=${IPv4:-$IPv6}

# 输出配置信息
echo -e "\n==================== TROJAN-GO ====================="
echo "🌐 域名    : $DOMAIN"
echo "🔒 密码    : $TROJAN_PASS"
echo "🔹 端口    : 443"
echo "☎️ SNI     : $DOMAIN"
echo "📍 假装网站 : http://$DOMAIN"

echo -e "\n=================== HYSTERIA2 ====================="
echo "🌐 节点IP  : $IP"
echo "🔹 端口    : $PORT"
echo "🔒 密码    : $HY_PASS"
echo "🛀 假装域名: https://$DOMAIN"
echo "📂 配置文件: /etc/hysteria/config.yaml"
echo "=================================================="

read -p "\n📄 按回车结束脚本..." _
