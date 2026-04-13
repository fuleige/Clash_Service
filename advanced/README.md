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
- 如果缺少 `setcap`，尝试按当前发行版自动安装对应的 `libcap` 包
- 给 `mihomo` 授予 `cap_net_admin,cap_net_bind_service`
- 优先尝试重启 `mihomo.service`
- 如果当前环境走的是 `service` 模式，尝试重启 `mihomo-<当前用户名>`
- 如果当前环境是前台模式，会提示你手动重新运行 `bash client.sh start`

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

脚本会先自动尝试安装对应发行版的 `libcap` 包；自动安装失败时，再手动安装包含 `setcap` 的 `libcap` 工具包。

TUN 设备不存在：

```bash
ls -l /dev/net/tun
```

用户服务无法重启：

```bash
systemctl --user status mihomo.service
systemctl --user restart mihomo.service
```

如果当前环境不是 `systemd --user`，也可以改用：

```bash
sudo service "mihomo-$(id -un)" restart
```

开启后网络异常，先关闭：

```bash
bash advanced/client-tun.sh disable
```
