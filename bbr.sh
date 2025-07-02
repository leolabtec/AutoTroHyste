#!/bin/bash

set -e

echo "==============================="
echo " 开启 BBR 拥塞控制算法"
echo "==============================="

# 检查当前用户是否为 root
if [[ $EUID -ne 0 ]]; then
  echo "请使用 root 用户运行此脚本！"
  exit 1
fi

# 检查当前内核版本
kernel_version=$(uname -r | cut -d '-' -f1)
main_ver=$(echo "$kernel_version" | cut -d '.' -f1)
minor_ver=$(echo "$kernel_version" | cut -d '.' -f2)

if (( main_ver < 4 )) || (( main_ver == 4 && minor_ver < 9 )); then
  echo "当前内核版本 $kernel_version 不支持原生 BBR（需要 ≥ 4.9）"
  echo "请升级内核后重试。"
  exit 1
fi

# 检查是否已启用 BBR
if sysctl net.ipv4.tcp_congestion_control | grep -q bbr && lsmod | grep -q bbr; then
  echo "BBR 已经启用，无需重复设置。"
  exit 0
fi

# 写入 sysctl 参数（避免重复写入）
if ! grep -q "net.core.default_qdisc = fq" /etc/sysctl.conf; then
  echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
fi
if ! grep -q "net.ipv4.tcp_congestion_control = bbr" /etc/sysctl.conf; then
  echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
fi

# 应用配置
sysctl -p

# 验证
echo ""
echo "当前拥塞控制算法：$(sysctl net.ipv4.tcp_congestion_control)"
echo "BBR 模块状态："
lsmod | grep bbr || echo "未加载 bbr 模块（请重启后再试）"

# 判断最终结果
if sysctl net.ipv4.tcp_congestion_control | grep -q bbr && lsmod | grep -q bbr; then
  echo "✅ BBR 启用成功！"
else
  echo "⚠️  BBR 配置完成，但模块未加载。建议重启后检查："
  echo "sysctl net.ipv4.tcp_congestion_control"
  echo "lsmod | grep bbr"
fi
