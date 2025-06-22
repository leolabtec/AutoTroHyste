#!/bin/bash
set -e

# 检查 root 权限
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

# 若未找到端口则报错退出
if ss -tuln | grep -q ":$PORT "; then
  echo "❌ 未能找到未占用端口，请重试或手动指定"
  exit 1
fi

# 生成随机密码（20位）
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

# 启动服务，失败时打印日志
echo "📡 启动 Hysteria2 服务..."
if ! systemctl restart hysteria-server.service; then
  echo "❌ 启动失败，打印日志："
  journalctl -u hysteria-server --no-pager -n 20
  exit 1
fi

# 关闭 set -e，避免 curl 错误中止脚本
set +e

# 获取公网 IP
IPv4=$(curl -4 -s https://api64.ipify.org)
IPv6=$(curl -6 -s https://api64.ipify.org)
IP=${IPv4:-$IPv6}
IP=${IP:-"未知，无法获取"}

echo ""
echo "🎉 Hysteria2 节点部署完成！以下是连接信息："
echo "------------------------------------------------"
echo "🌐 节点 IP地址   : $IP"
echo "📡 监听端口     : $PORT"
echo "🔑 密码         : $PASS"
echo "🎭 伪装域名     : https://bing.com"
echo "📁
