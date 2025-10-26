# 这是一个手搓hysteria2,trojan节点的脚本，下面是一键脚本
```sh
bash <(curl -fsSL https://raw.githubusercontent.com/leolabtec/AutoTroHyste/main/install.sh)
```

检查状态和日志

```
systemctl status trojan-go.service
```

```
journalctl -u trojan-go.service -b
```
