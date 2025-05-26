#!/bin/bash
set -e

# 必须以 root 身份运行
if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 root 权限运行此脚本"
  exit 1
fi

# 定义本地目录和脚本路径
INSTALL_DIR="/opt/AutoTroHyste"
TROJAN_SCRIPT="$INSTALL_DIR/autoTrojan.sh"
HYSTERIA_SCRIPT="$INSTALL_DIR/autohysteria2.sh"
BIN_LINK="/usr/local/bin/d"

# 初始化脚本存储目录
mkdir -p "$INSTALL_DIR"

# 如果是首次运行，下载脚本并创建快捷方式
if [ ! -f "$TROJAN_SCRIPT" ] || [ ! -f "$HYSTERIA_SCRIPT" ]; then
  echo "⬇️  正在首次下载代理部署脚本..."
  curl -fsSL "https://raw.githubusercontent.com/leolabtec/AutoTroHyste/refs/heads/main/autoTrojan" -o "$TROJAN_SCRIPT"
  curl -fsSL "https://raw.githubusercontent.com/leolabtec/AutoTroHyste/refs/heads/main/autohysteria2.sh" -o "$HYSTERIA_SCRIPT"
  chmod +x "$TROJAN_SCRIPT" "$HYSTERIA_SCRIPT"

  echo "🔧 正在设置快捷命令 'd'..."
  cat <<EOF > "$INSTALL_DIR/deploy.sh"
#!/bin/bash
bash "$0"
EOF
  chmod +x "$INSTALL_DIR/deploy.sh"
  ln -sf "$INSTALL_DIR/deploy.sh" "$BIN_LINK"
  echo "✅ 安装完成，您以后可通过命令 'd' 直接运行。"
fi

# 运行主选择界面
echo "📦 请选择要部署的节点类型："
echo "1) Trojan-Go"
echo "2) Hysteria2"
read -rp "请输入选项 [1-2]: " OPTION

case "$OPTION" in
  1)
    echo "🔻 正在部署 Trojan-Go..."
    bash "$TROJAN_SCRIPT"
    ;;
  2)
    echo "🔺 正在部署 Hysteria2..."
    bash "$HYSTERIA_SCRIPT"
    ;;
  *)
    echo "❌ 无效选项，退出。"
    exit 1
    ;;
esac
