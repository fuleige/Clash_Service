# Clash Service

这个项目提供两个简单脚本：

- `server.sh`：在 Ubuntu/Debian 服务端一键安装 `trojan-go`，生成自签名证书，并交给系统级 `systemd` 管理。
- `client.sh`：在 Ubuntu/Debian 客户端安装 `mihomo`，生成 Clash 配置，并让后续新开的终端自动带或取消 HTTP/HTTPS 代理环境变量。

默认不启用 TUN 模式。TUN 属于更接近全局代理的方案，涉及虚拟网卡、DNS、路由和权限，放在 `advanced/` 目录中作为可选实验能力。

## 目录结构

```text
.
├── server.sh
├── client.sh
├── README.md
└── advanced
    ├── README.md
    └── client-tun.sh
```

## 服务端使用

目标环境：

- Ubuntu/Debian
- systemd
- root 权限

安装：

```bash
sudo bash server.sh install
```

安装时会询问：

- 绑定端口，默认 `443`
- trojan 密码，默认随机生成
- SNI/证书名称，默认使用当前主机名

脚本会完成：

- 检测并自动安装缺少的 `curl`、`unzip`、`openssl`、`ca-certificates`
- 检测 `trojan-go` 是否已存在，不存在才自动下载
- 生成自签名证书
- 写入 `/etc/trojan-go/config.json`
- 写入 `/etc/systemd/system/trojan-go.service`
- 如果检测到 `ufw` 或 `firewalld` 正在运行，自动放行服务端口
- 执行 `systemctl enable trojan-go.service` 并重启服务

常用命令：

```bash
sudo bash server.sh start
sudo bash server.sh stop
sudo bash server.sh restart
sudo bash server.sh status
sudo bash server.sh uninstall
```

如果直接执行 `sudo bash server.sh start`，但脚本发现配置、证书或服务还没准备好，会自动进入安装流程。

服务端关键路径：

```text
/usr/local/bin/trojan-go
/etc/trojan-go/config.json
/etc/trojan-go/certs/server.crt
/etc/trojan-go/certs/server.key
/etc/systemd/system/trojan-go.service
```

如果服务器启用了防火墙，需要放行安装时选择的端口。例如：

```bash
sudo ufw allow 443/tcp
```

## 客户端使用

目标环境：

- Ubuntu/Debian
- systemd user service
- 普通用户运行，不要用 `sudo`

安装：

```bash
bash client.sh install
```

安装时会询问：

- 服务端地址/IP
- 服务端端口，默认 `443`
- trojan 密码
- SNI，默认使用服务端地址

脚本会完成：

- 检测并自动安装缺少的 `curl`、`gzip`、`ca-certificates`
- 检测 `mihomo` 是否已存在，不存在才自动下载到 `~/.local/bin/mihomo`
- 写入 `${XDG_CONFIG_HOME:-$HOME/.config}/mihomo/config.yaml`
- 写入 `${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/mihomo.service`
- 在当前 shell 的启动文件中加入一个受控 loader
- 尝试启用 systemd linger，便于用户服务开机后自动运行
- 启用并启动 `mihomo.service`
- 写入 `${XDG_CONFIG_HOME:-$HOME/.config}/clash-service/proxy.env`，让后续新终端自动带代理变量

如果直接执行 `bash client.sh start`，但脚本发现 `mihomo` 配置还没生成，会自动进入安装流程。

启动客户端并让后续新终端使用代理：

```bash
bash client.sh start
```

停止客户端并让后续新终端取消代理：

```bash
bash client.sh stop
```

`stop` 会停止并禁用用户级 `mihomo.service`，同时关闭后续新终端的代理变量。

只修改后续新终端的代理变量，不启动或停止 mihomo：

```bash
bash client.sh enable
bash client.sh disable
```

查看状态：

```bash
bash client.sh status
```

重启 mihomo：

```bash
bash client.sh restart
```

卸载：

```bash
bash client.sh uninstall
```

## 代理环境变量实现

`client.sh` 不会反复把 `export http_proxy=...` 写进 `~/.bashrc` 或 `~/.zshrc`。它只加入一次受控 loader，内容类似：

```bash
# >>> clash-service proxy env >>>
__clash_service_proxy_env="${XDG_CONFIG_HOME:-$HOME/.config}/clash-service/proxy.env"
if [ -f "$__clash_service_proxy_env" ]; then
  . "$__clash_service_proxy_env"
fi
unset __clash_service_proxy_env
# <<< clash-service proxy env <<<
```

后续开关代理只修改：

```text
${XDG_CONFIG_HOME:-$HOME/.config}/clash-service/proxy.env
```

开启时内容类似：

```bash
export http_proxy="http://127.0.0.1:7890"
export https_proxy="http://127.0.0.1:7890"
export all_proxy="socks5://127.0.0.1:7890"
export HTTP_PROXY="$http_proxy"
export HTTPS_PROXY="$https_proxy"
export ALL_PROXY="$all_proxy"
```

关闭时内容类似：

```bash
unset http_proxy
unset https_proxy
unset all_proxy
unset HTTP_PROXY
unset HTTPS_PROXY
unset ALL_PROXY
```

注意：一个脚本不能反向修改已经打开的父级终端环境变量。所以 `start` 或 `stop` 后：

- 新开的终端会自动使用最新状态。
- 当前终端如果要立即同步，需要手动执行：

```bash
source "${XDG_CONFIG_HOME:-$HOME/.config}/clash-service/proxy.env"
```

## mihomo 配置

默认本地代理端口：

```text
HTTP/HTTPS/SOCKS mixed-port: 127.0.0.1:7890
External controller: 127.0.0.1:9090
```

默认规则：

- 局域网和本机地址直连
- 其他流量走 `PROXY`

默认使用服务端自签名证书：

```yaml
skip-cert-verify: true
```

这是为了配合 `server.sh` 的简单自签名证书方案。正式公网环境建议使用可信 CA 签发的证书，并把客户端配置改为校验证书。

## systemd user 常见问题

如果 `bash client.sh start` 报错类似：

```text
Failed to connect to bus: No medium found
```

说明当前会话没有可用的 systemd user bus。可以尝试重新登录用户会话，或在服务器上启用 linger：

```bash
sudo loginctl enable-linger "$USER"
```

然后重新运行：

```bash
systemctl --user daemon-reload
bash client.sh start
```

如果 `~/.local/bin` 不在 `PATH`，不影响 systemd 服务，因为服务文件使用的是绝对路径。

如果已经存在二进制文件，脚本默认复用现有文件。需要强制重新下载时可以执行：

```bash
CLASH_SERVICE_FORCE_DOWNLOAD=1 sudo bash server.sh install
CLASH_SERVICE_FORCE_DOWNLOAD=1 bash client.sh install
```

## 安全说明

默认配置优先简单可用，不是生产级强安全模板：

- 服务端证书是自签名。
- 客户端默认 `skip-cert-verify: true`。
- 客户端 external controller 没有设置 secret，但只监听 `127.0.0.1`。
- 默认代理环境变量只影响支持 `http_proxy`、`https_proxy`、`all_proxy` 的命令行程序，不等于全局代理。

如果需要更接近全局代理，请看 `advanced/README.md` 的 TUN 说明。
