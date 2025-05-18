#!/bin/bash
set -e

# 必须以 root 身份运行
if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 root 权限运行此脚本"
  exit 1
fi

echo "📦 请选择要部署的节点类型："
echo "1) Trojan-Go"
echo "2) Hysteria2"
read -rp "请输入选项 [1-2]: " OPTION

# 定义脚本链接
TROJAN_SCRIPT_URL="https://raw.githubusercontent.com/leolabtec/AutoTroHyste/refs/heads/main/autoTrojan"
HYSTERIA_SCRIPT_URL="https://raw.githubusercontent.com/leolabtec/AutoTroHyste/refs/heads/main/autohysteria2.sh"

case "$OPTION" in
  1)
    echo "🔻 正在部署 Trojan-Go..."
    curl -fsSL "$TROJAN_SCRIPT_URL" -o autoTrojan.sh
    chmod +x autoTrojan.sh
    ./autoTrojan.sh
    ;;
  2)
    echo "🔺 正在部署 Hysteria2..."
    curl -fsSL "$HYSTERIA_SCRIPT_URL" -o autohysteria2.sh
    chmod +x autohysteria2.sh
    ./autohysteria2.sh
    ;;
  *)
    echo "❌ 无效选项，退出。"
    exit 1
    ;;
esac
