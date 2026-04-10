# Advanced: mihomo TUN Mode

默认 `client.sh` 不启用 TUN。这个目录提供可选实验脚本，用来把 `~/.config/mihomo/config.yaml` 里的 `tun.enable` 在 `true` 和 `false` 之间切换。

## TUN 是什么

普通终端代理依赖环境变量：

```bash
http_proxy
https_proxy
all_proxy
```

这种方式只影响支持这些变量的命令行程序。

TUN 模式会创建虚拟网卡，把系统流量导入 mihomo，再由 mihomo 按规则决定直连或代理。它更接近全局代理，但也更容易遇到环境差异：

- 需要 `/dev/net/tun`
- 需要 `CAP_NET_ADMIN`
- 可能影响系统路由
- DNS 配置不当可能导致解析失败或 DNS 泄漏
- WSL、容器、精简服务器环境可能不支持或表现不同

## 使用前提

先完成默认客户端安装：

```bash
bash client.sh install
```

确认 mihomo 二进制存在：

```bash
ls -l ~/.local/bin/mihomo
```

确认配置存在：

```bash
ls -l ~/.config/mihomo/config.yaml
```

如果安装客户端时设置了 `XDG_CONFIG_HOME`，这里也会跟随该路径。

## 启用 TUN

推荐以普通用户运行，脚本会在需要 `setcap` 时调用 `sudo`：

```bash
bash advanced/client-tun.sh enable
```

脚本会做这些事：

- 备份 `~/.config/mihomo/config.yaml`
- 确保存在 `tun:` 配置块
- 设置 `tun.enable: true`
- 如果缺少 `setcap`，自动安装 `libcap2-bin`
- 对 `~/.local/bin/mihomo` 执行 `setcap cap_net_admin,cap_net_bind_service+ep`
- 如果 `/dev/net/tun` 不存在，尝试加载 `tun` 内核模块
- 尝试重启 `mihomo.service`

也可以使用 sudo 运行，脚本会尽量识别 `SUDO_USER` 并修改该用户的配置：

```bash
sudo bash advanced/client-tun.sh enable
```

## 关闭 TUN

```bash
bash advanced/client-tun.sh disable
```

脚本会：

- 备份配置
- 设置 `tun.enable: false`
- 尝试重启 `mihomo.service`

## 查看状态

```bash
bash advanced/client-tun.sh status
```

## 排错

如果缺少 `setcap`：

```bash
sudo apt-get install -y libcap2-bin
```

如果缺少 TUN 设备：

```bash
ls -l /dev/net/tun
```

如果 user systemd 服务无法重启：

```bash
systemctl --user status mihomo.service
systemctl --user restart mihomo.service
```

如果 TUN 开启后网络异常，先关闭：

```bash
bash advanced/client-tun.sh disable
```

再查看 mihomo 日志：

```bash
journalctl --user -u mihomo.service -e --no-pager
```

## 默认配置片段

`client.sh install` 生成的配置默认包含但关闭 TUN：

```yaml
tun:
  enable: false
  stack: system
  auto-route: true
  auto-detect-interface: true
  strict-route: false
  dns-hijack:
    - any:53
```

高级脚本只切换 `enable` 值，不会默认把 TUN 合入普通安装流程。
