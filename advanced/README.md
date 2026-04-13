# Advanced: Mihomo TUN Mode

默认 `client.sh` 不启用 TUN。这个目录提供一个可选脚本，用尽量一键的方式启用或关闭 Mihomo TUN。

## 最短步骤

先完成普通客户端安装：

```bash
bash client.sh install
```

然后直接执行：

```bash
bash advanced/client-tun.sh enable
```

确认状态：

```bash
bash advanced/client-tun.sh status
```

如需关闭：

```bash
bash advanced/client-tun.sh disable
```

## 推荐用法

- 优先用执行过 `bash client.sh install` 的那个普通用户直接运行脚本
- 脚本在需要 root 权限时会自动调用 `sudo`
- 如果你是用 `sudo bash advanced/client-tun.sh enable` 执行，脚本会优先操作 `SUDO_USER` 对应用户的 `mihomo` 配置

## 脚本会自动处理什么

执行 `bash advanced/client-tun.sh enable` 时，脚本会自动完成这些步骤：

- 备份 `config.yaml`
- 把 `tun.enable` 改成 `true`
- 如果缺少 `setcap`，尝试按当前发行版自动安装对应的 `libcap` 包
- 如果缺少 `/dev/net/tun`，尝试自动执行 `modprobe tun`
- 如果 `/dev/net/tun` 仍不存在，尝试自动创建 `/dev/net/tun`
- 给 `mihomo` 授予 `cap_net_admin,cap_net_bind_service`
- 优先尝试重启 `mihomo.service`
- 如果当前环境走的是 `service` 模式，尝试重启 `mihomo-<当前用户名>`
- 如果当前环境是前台模式，会提示你手动重新运行 `bash client.sh start`

目标是让使用者只需要执行一条 `enable` 命令；环境准备工作尽量放在脚本里完成。

## 启用后的检查

建议至少检查一次：

```bash
bash advanced/client-tun.sh status
tail -f ~/.config/clash-service/mihomo.log
```

如果当前机器平时需要走代理访问外网，可以在新终端里再做一次无环境变量测试：

```bash
env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  curl -I https://www.google.com
```

## 常见问题

缺少 `setcap`：

脚本会先自动尝试安装对应发行版的 `libcap` 包；自动安装失败时，再手动安装包含 `setcap` 的 `libcap` 工具包。

TUN 设备不存在：

```bash
ls -l /dev/net/tun
```

如果还是没有：

```bash
sudo modprobe tun
sudo mkdir -p /dev/net
sudo mknod /dev/net/tun c 10 200
sudo chmod 666 /dev/net/tun
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
