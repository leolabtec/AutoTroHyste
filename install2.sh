#!/bin/bash
set -e

# 必须以 root 身份运行
if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 root 权限运行此脚本"
  exit 1
fi

# 确保 dig 可用
if ! command -v dig >/dev/null 2>&1; then
  echo "🔧 安装 dig 所需依赖 dnsutils..."
  apt update && apt install -y dnsutils
fi

# 定义本地目录和脚本路径
INSTALL_DIR="/opt/AutoTroHyste"
TROJAN_SCRIPT="$INSTALL_DIR/autoTrojan.sh"
HYSTERIA_SCRIPT="$INSTALL_DIR/autohysteria2.sh"
SOCKS5_SCRIPT="$INSTALL_DIR/autosocks5.sh"

# 创建脚本存储目录
mkdir -p "$INSTALL_DIR"

# 下载缺失的脚本文件
echo "⬇️  正在检查并下载缺失的部署脚本..."
[[ ! -f "$TROJAN_SCRIPT" ]] && curl -fsSL "https://raw.githubusercontent.com/leolabtec/AutoTroHyste/main/autoTrojan.sh" -o "$TROJAN_SCRIPT"
[[ ! -f "$HYSTERIA_SCRIPT" ]] && curl -fsSL "https://raw.githubusercontent.com/leolabtec/AutoTroHyste/main/autohysteria2.sh" -o "$HYSTERIA_SCRIPT"
[[ ! -f "$SOCKS5_SCRIPT" ]] && curl -fsSL "https://raw.githubusercontent.com/leolabtec/AutoTroHyste/main/autosocks5.sh" -o "$SOCKS5_SCRIPT"
chmod +x "$TROJAN_SCRIPT" "$HYSTERIA_SCRIPT" "$SOCKS5_SCRIPT"

# 显示部署菜单
echo ""
echo "📦 请选择要部署的节点类型："
echo "1) Trojan-Go"
echo "2) Hysteria2"
echo "3) Socks5"
echo "0) 退出"
read -rp "请输入选项 [0-3]: " OPTION

case "$OPTION" in
  1)
    echo "🔻 正在部署 Trojan-Go..."
    bash "$TROJAN_SCRIPT"
    ;;
  2)
    echo "🔺 正在部署 Hysteria2..."
    bash "$HYSTERIA_SCRIPT"
    ;;
  3)
    echo "🧦 正在部署 Socks5..."
    bash "$SOCKS5_SCRIPT"
    ;;
  0)
    echo "👋 已退出。"
    exit 0
    ;;
  *)
    echo "❌ 无效选项，退出。"
    exit 1
    ;;
esac
