#!/bin/bash
set -e

# 检查root权限
if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 root 权限运行此脚本"
  exit 1
fi

echo "🚀 正在安装 Hysteria2..."

# 安装 Hysteria2
bash <(curl -fsSL https://get.hy2.sh/)

# 启用开机自启
systemctl enable hysteria-server.service

# 创建证书目录
mkdir -p /etc/hysteria

echo "🔐 生成自签名 TLS 证书..."
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
  -keyout /etc/hysteria/server.key \
  -out /etc/hysteria/server.crt \
  -subj "/CN=bing.com" -days 36500

chown hysteria /etc/hysteria/server.key
chown hysteria /etc/hysteria/server.crt

echo "🎲 正在生成可用端口..."
for i in {1..20}; do
  PORT=$(shuf -i 30000-65535 -n 1)
  if ! ss -tuln | grep -q ":$PORT "; then
    echo "✅ 找到未占用端口: $PORT"
    break
  fi
done

if ss -tuln | grep -q ":$PORT "; then
  echo "❌ 未能找到未占用端口，请重试或手动指定"
  exit 1
fi

# 生成强密码（长度20位，包含字母数字）
PASS=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 20)

echo "📝 写入配置文件 /etc/hysteria/config.yaml ..."

cat <<EOF > /etc/hysteria/config.yaml
listen: :$PORT

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: $PASS

masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true
EOF

# 启动服务
echo "📡 启动 Hysteria2 服务..."
systemctl restart hysteria-server.service

# 获取公网 IP
IP=$(curl -s https://api64.ipify.org || curl -s https://ipinfo.io/ip)

echo ""
echo "🎉 Hysteria2 节点部署完成！以下是连接信息："
echo "------------------------------------------------"
echo "🌐 节点 IP地址   : $IP"
echo "📡 监听端口     : $PORT"
echo "🔑 密码         : $PASS"
echo "🎭 伪装域名     : https://bing.com"
echo "📁 配置文件路径 : /etc/hysteria/config.yaml"
echo "------------------------------------------------"
echo ""
read -p "🔚 按下 Enter 键结束脚本..." _
