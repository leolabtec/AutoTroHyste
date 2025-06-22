#!/bin/bash
set -e

# ✅ 系统架构和平台检查
arch=$(uname -m)
os=""
if [ -f /etc/os-release ]; then
    . /etc/os-release
    os=$ID
else
    echo "❌ 无法检测系统类型"
    exit 1
fi

echo "[🔍] 检测系统: $os"
echo "[🔍] 检测架构: $arch"

case "$os" in
    debian|ubuntu|alpine)
        echo "[✅] 系统受支持"
        ;;
    *)
        echo "❌ 当前系统不受支持，仅支持 Debian/Ubuntu/Alpine"
        exit 1
        ;;
esac

# ✅ 安装依赖
echo "[📦] 安装必要依赖..."

if [[ "$os" == "alpine" ]]; then
    apk update
    apk add dante-server
else
    apt update
    apt install -y dante-server
fi

# ✅ 添加用户
echo "[👤] 创建 Socks5 用户..."

SOCKS_USER=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12)
SOCKS_PASS=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12)

while :; do
  PORT=$(shuf -i 20000-65535 -n 1)
  if ! ss -lnt | grep -q ":$PORT\b"; then
    break
  fi
done

echo "[✅] 用户名：$SOCKS_USER"
echo "[✅] 密码：$SOCKS_PASS"
echo "[✅] 端口：$PORT"

# ✅ 创建系统用户用于认证
id "$SOCKS_USER" &>/dev/null || useradd -M -s /sbin/nologin "$SOCKS_USER"
echo "$SOCKS_USER:$SOCKS_PASS" | chpasswd

# ✅ 获取出口 IP
OUT_IP=$(ip route get 1.1.1.1 | awk '/src/ {print $7; exit}')

# ✅ 创建配置文件
echo "[🛠] 写入配置文件..."
cat > /etc/danted.conf <<EOF
logoutput: /var/log/danted.log
internal: 0.0.0.0 port = $PORT
external: $OUT_IP
method: username
user.notprivileged: nobody

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect error
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    protocol: tcp udp
    log: connect disconnect error
}
EOF

# ✅ 创建日志文件
touch /var/log/danted.log
chmod 644 /var/log/danted.log

# ✅ 启动服务
echo "[🚀] 启动 SOCKS5 服务..."

if command -v systemctl &>/dev/null; then
    cat > /etc/systemd/system/danted.service <<EOF
[Unit]
Description=Dante SOCKS5 Proxy
After=network.target

[Service]
ExecStart=/usr/sbin/danted -f /etc/danted.conf
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable danted
    systemctl restart danted
else
    nohup danted -f /etc/danted.conf &
fi

# ✅ 获取公网 IP
public_ip=$(curl -s https://api.ipify.org || echo "YOUR_IP")

# ✅ 显示连接信息
echo -e "\n[✅ SOCKS5 节点部署成功]"
echo "地址：$public_ip"
echo "端口：$PORT"
echo "用户名：$SOCKS_USER"
echo "密码：$SOCKS_PASS"
