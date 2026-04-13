# Advanced: Mihomo TUN Mode

默认 `client.sh` 不启用 TUN。这个目录提供一个可选脚本，只负责切换 `tun.enable`。

## 使用前提

先完成普通客户端安装：

```bash
bash client.sh install
```

确认这两个文件存在：

```bash
ls -l ~/.local/bin/mihomo
ls -l ~/.config/mihomo/config.yaml
```

## 启用 TUN

```bash
bash advanced/client-tun.sh enable
```

脚本会：

- 备份 `config.yaml`
- 把 `tun.enable` 改成 `true`
- 如果缺少 `setcap`，自动安装 `libcap2-bin`
- 给 `mihomo` 授予 `cap_net_admin,cap_net_bind_service`
- 尝试重启 `mihomo.service`

如果 `/dev/net/tun` 不存在，脚本会尝试执行 `modprobe tun`。

## 关闭 TUN

```bash
bash advanced/client-tun.sh disable
```

## 查看状态

```bash
bash advanced/client-tun.sh status
```

## 常见问题

缺少 `setcap`：

```bash
sudo apt-get install -y libcap2-bin
```

TUN 设备不存在：

```bash
ls -l /dev/net/tun
```

用户服务无法重启：

```bash
systemctl --user status mihomo.service
systemctl --user restart mihomo.service
```

开启后网络异常，先关闭：

```bash
bash advanced/client-tun.sh disable
```
