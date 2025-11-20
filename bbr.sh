#!/bin/bash
set -e

GREEN="\033[0;32m"
RED="\033[0;31m"
NC="\033[0m"

echo -e "${GREEN}🚀 BBR 加速检测 & 自动开启（V2）${NC}"

# 检查当前拥塞算法
current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "")

echo "📌 当前拥塞控制算法：$current_cc"
echo "📌 当前队列算法：$current_qdisc"
echo ""

# 判断是否已启用 BBR
if [[ "$current_cc" == "bbr" ]]; then
    echo -e "${GREEN}🎉 已启用 BBR，无需操作${NC}"
    exit 0
fi

echo -e "${RED}❌ 未启用 BBR，继续检查内核是否支持...${NC}"

# 检查内核是否包含 tcp_bbr 模块
if [[ -f "/lib/modules/$(uname -r)/kernel/net/ipv4/tcp_bbr.ko" ]]; then
    echo -e "${GREEN}✔ 当前内核已包含 BBR 模块${NC}"
else
    echo -e "${RED}❌ 当前内核不支持 BBR！${NC}"
    echo "➡ 解决方法：升级系统到 Debian 12/13 或 Ubuntu 20/22"
    exit 1
fi

# 尝试加载模块（如果未加载）
if ! lsmod | grep -q '^tcp_bbr'; then
    echo "📌 加载 BBR 模块..."
    modprobe tcp_bbr || true
fi

# 写入 sysctl 配置启用 BBR
echo "📌 正在启用 BBR..."
sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf

echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf

sysctl -p >/dev/null 2>&1

# 再次校验
new_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
new_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)

echo ""
echo -e "${GREEN}🔍 重新检查结果：${NC}"
echo "📌 拥塞控制算法：$new_cc"
echo "📌 队列算法：$new_qdisc"

if [[ "$new_cc" == "bbr" ]]; then
    echo -e "${GREEN}🎉 BBR 启用成功！${NC}"
else
    echo -e "${RED}❌ 启用失败，请手动检查 /etc/sysctl.conf${NC}"
fi
