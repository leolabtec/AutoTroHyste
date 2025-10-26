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

# 检查证书目录是否存在，若不存在则创建
if [ ! -d /etc/hysteria ]; then
    echo "📁 创建证书目录 /etc/hysteria"
    mkdir -p /etc/hysteria
else
    echo "📁 证书目录 /etc/hysteria 已存在，跳过创建"
fi


[ -f /etc/hysteria/server.key ] && chown hysteria /etc/hysteria/server.key
[ -f /etc/hysteria/server.crt ] && chown hysteria /etc/hysteria/server.crt

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

# -----------------------------
# 从现有证书获取域名
# -----------------------------
if [ -f /etc/hysteria/server.crt ]; then
    DOMAIN=$(openssl x509 -in /etc/hysteria/server.crt -noout -text | grep -A1 "Subject Alternative Name" | tail -n1 | sed 's/ *DNS://g' | tr ',' '\n' | head -n1)
    if [ -z "$DOMAIN" ]; then
        echo "❌ 未能从 /etc/hysteria/server.crt 获取域名，请手动输入"
        read -rp "🌐 请输入伪装域名: " DOMAIN
    else
        echo "✅ 从证书读取到域名: $DOMAIN"
    fi
else
    echo "❌ 证书 /etc/hysteria/server.crt 不存在，请先生成或放置证书"
    exit 1
fi


# 写入配置文件
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
    url: https://$DOMAIN
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
echo "🎭 伪装域名     : https://$DOMAIN"
echo "📁 配置文件路径 : /etc/hysteria/config.yaml"
