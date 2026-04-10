# Clash Service

用两个脚本快速搭一个基于 `trojan-go` + `mihomo` 的简单代理服务。

- `server.sh`：服务端安装 `trojan-go`，生成自签名证书，并交给系统级 `systemd` 管理。
- `client.sh`：客户端安装 `mihomo`，生成 Clash 配置，并控制后续新终端的代理环境变量。
- TUN 模式默认不启用，需要时再看 [advanced/README.md](advanced/README.md)。

## 快速开始

服务端，使用 root 权限运行：

```bash
sudo bash server.sh install
```

安装结束后会打印连接信息，并保存到：

```text
/etc/trojan-go/client-info.txt
```

客户端，使用普通用户运行：

```bash
bash client.sh install
```

按提示填入服务端地址、端口、密码和 SNI。安装结束后客户端也会保存一份连接信息：

```text
~/.config/clash-service/client-info.txt
```

启动或停止客户端代理：

```bash
bash client.sh start
bash client.sh stop
```

客户端启动后会先检测代理节点连通性，检测通过后才启用后续新终端的代理环境变量。

## 常用命令

服务端：

```bash
sudo bash server.sh start
sudo bash server.sh stop
sudo bash server.sh restart
sudo bash server.sh status
sudo bash server.sh uninstall
```

客户端：

```bash
bash client.sh start
bash client.sh stop
bash client.sh restart
bash client.sh status
bash client.sh enable
bash client.sh disable
bash client.sh uninstall
```

`enable` / `disable` 只切换后续新终端的代理环境变量，不启动或停止 `mihomo`。

<details>
<summary>安装时会做什么</summary>

服务端：

- 安装缺少的 `curl`、`unzip`、`openssl`、`ca-certificates`
- 下载或复用 `trojan-go`
- 生成自签名证书
- 写入 `/etc/trojan-go/config.json`
- 写入 `/etc/trojan-go/client-info.txt`
- 写入 `/etc/systemd/system/trojan-go.service`
- 如果检测到启用中的 `ufw` 或 `firewalld`，自动放行服务端口
- 执行 `systemctl enable trojan-go.service` 并重启服务

客户端：

- 安装缺少的 `curl`、`gzip`、`ca-certificates`
- 下载或复用 `mihomo`
- 写入 `~/.config/mihomo/config.yaml`
- 写入 `~/.config/clash-service/client-info.txt`
- 写入 `~/.config/systemd/user/mihomo.service`
- 在当前 shell 启动文件中加入受控 loader
- 尝试启用 systemd linger
- 启用并启动 `mihomo.service`
- 检测 `trojan-service` 代理节点是否可用
- 写入 `~/.config/clash-service/proxy.env`

</details>

<details>
<summary>关键路径</summary>

服务端：

```text
/usr/local/bin/trojan-go
/etc/trojan-go/config.json
/etc/trojan-go/client-info.txt
/etc/trojan-go/certs/server.crt
/etc/trojan-go/certs/server.key
/etc/systemd/system/trojan-go.service
/var/cache/clash-service/trojan-go-linux-<arch>.zip
```

客户端：

```text
~/.local/bin/mihomo
~/.config/mihomo/config.yaml
~/.config/clash-service/client-info.txt
~/.config/clash-service/proxy.env
~/.config/systemd/user/mihomo.service
~/.cache/clash-service/mihomo-linux-*.gz
```

如果设置了 `XDG_CONFIG_HOME` 或 `XDG_CACHE_HOME`，客户端会跟随这些路径。

</details>

<details>
<summary>客户端连通性检测</summary>

`client.sh install`、`client.sh start` 和 `client.sh restart` 会在启动 `mihomo` 后访问本地 controller：

```text
http://127.0.0.1:9090
```

然后让 `mihomo` 检测 `trojan-service` 节点访问默认测试地址：

```text
https://www.gstatic.com/generate_204
```

检测失败时，脚本不会提示启动成功，也不会启用后续新终端的代理环境变量。可以查看日志：

```bash
journalctl --user -u mihomo.service -e --no-pager
```

如果只是测试地址不可用，可以换一个测试 URL：

```bash
CLASH_SERVICE_CHECK_URL=https://www.cloudflare.com/cdn-cgi/trace bash client.sh start
```

确认不需要检测时可以跳过：

```bash
CLASH_SERVICE_SKIP_CHECK=1 bash client.sh start
```

</details>

<details>
<summary>下载缓存和网络不好时的处理</summary>

脚本会优先检测缓存目录里匹配当前 CPU 架构的压缩包。GitHub 网络不稳定时，可以先把文件下载到缓存目录，再重新运行安装脚本。

服务端默认缓存目录：

```text
/var/cache/clash-service
```

服务端文件名保持为：

```text
trojan-go-linux-<arch>.zip
```

客户端默认缓存目录：

```text
~/.cache/clash-service
```

客户端文件名保持为 mihomo release 原始文件名，例如：

```text
mihomo-linux-amd64-v1-v<version>.gz
```

也可以自定义缓存目录：

```bash
CLASH_SERVICE_CACHE_DIR=/path/to/cache sudo bash server.sh install
CLASH_SERVICE_CACHE_DIR=/path/to/cache bash client.sh install
```

如果已经存在二进制文件，脚本默认复用现有文件。需要强制重新安装二进制时：

```bash
CLASH_SERVICE_FORCE_DOWNLOAD=1 sudo bash server.sh install
CLASH_SERVICE_FORCE_DOWNLOAD=1 bash client.sh install
```

</details>

<details>
<summary>代理环境变量怎么生效</summary>

`client.sh` 不会反复把 `export http_proxy=...` 写进 `~/.bashrc` 或 `~/.zshrc`。它只加入一次受控 loader，后续开关代理只修改：

```text
~/.config/clash-service/proxy.env
```

脚本不能反向修改已经打开的父级终端环境变量。所以 `start` 或 `stop` 后：

- 新开的终端会自动使用最新状态。
- 当前终端如果要立即同步，需要手动执行：

```bash
source ~/.config/clash-service/proxy.env
```

默认本地代理端口：

```text
HTTP/HTTPS/SOCKS mixed-port: 127.0.0.1:7890
External controller: 127.0.0.1:9090
```

</details>

<details>
<summary>systemd user 常见问题</summary>

如果 `bash client.sh start` 报错类似：

```text
Failed to connect to bus: No medium found
```

说明当前会话没有可用的 systemd user bus。可以尝试重新登录用户会话，或启用 linger：

```bash
sudo loginctl enable-linger "$USER"
```

然后重新运行：

```bash
systemctl --user daemon-reload
bash client.sh start
```

如果 `~/.local/bin` 不在 `PATH`，不影响 systemd 服务，因为服务文件使用的是绝对路径。

</details>

<details>
<summary>安全说明</summary>

默认配置优先简单可用，不是生产级强安全模板：

- 服务端证书是自签名。
- 客户端默认 `skip-cert-verify: true`。
- 客户端 external controller 没有设置 secret，但只监听 `127.0.0.1`。
- 默认代理环境变量只影响支持 `http_proxy`、`https_proxy`、`all_proxy` 的命令行程序，不等于全局代理。
- `/etc/trojan-go/client-info.txt` 和 `~/.config/clash-service/client-info.txt` 会保存明文密码，脚本会设置为 `0600` 权限。

</details>
