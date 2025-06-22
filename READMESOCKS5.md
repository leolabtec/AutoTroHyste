## 一键命令
```sh
bash <(curl -fsSL https://raw.githubusercontent.com/leolabtec/AutoTroHyste/refs/heads/main/Socks5.sh)
```




✅ 二、检查 SOCKS5 是否运行正常

1. 检查监听端口是否正常：
```sh
ss -lntp | grep danted
# 或者
netstat -lntp | grep danted
```

输出示例：

```txt
LISTEN 0 128 0.0.0.0:30001 ... /usr/sbin/danted
LISTEN 0 128 0.0.0.0:30002 ... /usr/sbin/danted
```

2. 检查服务状态：
```sh
systemctl status danted@30001
systemctl status danted@30002
```

3. 查看日志：
```
tail -f /var/log/danted-30001.log
```

✅ 三、列出当前正在运行的 Dante 实例（数量）
```
ps -ef | grep danted | grep -v grep
```
or
```
systemctl list-units --type=service | grep danted@
```

