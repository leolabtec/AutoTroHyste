# 这是一个手搓hysteria2,trojan节点的脚本，下面是一键脚本
```sh
curl -fsSL https://raw.githubusercontent.com/leolabtec/AutoTroHyste/refs/heads/main/AllOne.sh | bash
```
SingBox版本
```
bash <(curl -sSL https://raw.githubusercontent.com/leolabtec/AutoTroHyste/main/sing-boxAll)
```
检查状态
```
systemctl status sing-box.service
```

检查状态和日志

```
systemctl status trojan-go.service
```

```
journalctl -u trojan-go.service -b
```
# 开启BBR
```
bash <(curl -fsSL https://raw.githubusercontent.com/leolabtec/AutoTroHyste/refs/heads/main/bbr.sh)
```
# TUIC V5
```
bash -c "$(curl -fsSL https://raw.githubusercontent.com/leolabtec/AutoTroHyste/refs/heads/main/tuic_v5)"
```
