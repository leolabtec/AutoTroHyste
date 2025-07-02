#!/bin/bash
set -e

# 必须以 root 身份运行
if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 root 权限运行此脚本"
  exit 1
fi

# 确保依赖 dnsutils 存在（提供 dig 命令）
if ! command -v dig >/dev/null 2>&1; then
  echo "🔧 安装 dig 所需依赖 dnsutils..."
  apt update && apt install -y dnsutils
fi

# 定义本地目录和脚本路径
INSTALL_DIR="/opt/AutoTroHyste"
TROJAN_SCRIPT="$INSTALL_DIR/autoTrojan.sh"
HYSTERIA_SCRIPT="$INSTALL_DIR/autohysteria2.sh"
BBR_SCRIPT="$INSTALL_DIR/bbr.sh"

# 初始化脚本存储目录
mkdir -p "$INSTALL_DIR"

# 首次运行：下载脚本并设置权限
if [ ! -f "$TROJAN_SCRIPT" ] || [ ! -f "$HYSTERIA_SCRIPT" ] || [ ! -f "$BBR_SCRIPT" ]; then
  echo "⬇️  正在首次下载代理部署脚本..."
  curl -fsSL "https://raw.githubusercontent.com/leolabtec/AutoTroHyste/refs/heads/main/autoTrojan" -o "$TROJAN_SCRIPT"
  curl -fsSL "https://raw.githubusercontent.com/leolabtec/AutoTroHyste/refs/heads/main/autohysteria2.sh" -o "$HYSTERIA_SCRIPT"
  curl -fsSL "https://raw.githubusercontent.com/leolabtec/AutoTroHyste/refs/heads/main/bbr.sh" -o "$BBR_SCRIPT"
  chmod +x "$TROJAN_SCRIPT" "$HYSTERIA_SCRIPT" "$BBR_SCRIPT"
fi

# 显示部署选项菜单
echo "📦 请选择要部署的功能："
echo "1) Trojan-Go"
echo "2) Hysteria2"
echo "3) 启用 BBR 加速"
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
    echo "🚀 正在启用 BBR..."
    bash "$BBR_SCRIPT"
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
