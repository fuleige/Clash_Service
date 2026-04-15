# Clash Service

用两个脚本快速搭一个基于 `trojan-go` + `mihomo` 的简单代理服务。

<details>
<summary>点击查看：trojan-go 和 mihomo 是什么</summary>

- `trojan-go`
  服务端实际运行的 Trojan 协议程序。这个仓库里主要用它在服务器上接收客户端连接。
- `mihomo`
  本地客户端核心，兼容 Clash 配置格式。这个仓库里主要用它在本机启动代理端口、连接 `trojan-go`，并给终端程序提供本地代理入口。

</details>

- `server.sh`
  服务端安装脚本。负责下载 `trojan-go`、生成自签名证书、写入配置，并根据环境选择 `systemd`、`service` 或前台运行。
- `client.sh`
  纯 Linux 终端客户端脚本。负责下载 `mihomo`、生成本地 Clash 配置，并根据环境选择 `systemd --user`、`service` 或前台运行。
- `examples/clash-client.yaml`
  给 Clash for Windows、Clash Verge、Mihomo Party、OpenClash 这类图形客户端直接导入的示例配置。
- `advanced/client-tun.sh`
  可选的 TUN 开关脚本。说明见 [advanced/README.md](advanced/README.md)。

## 先看这里

最常见的使用方式只有两种：

1. 服务端部署 Trojan：在服务器上运行 `server.sh`
2. 客户端选择一种方式连接：
   - 纯 Linux 终端环境：运行 `client.sh`
   - 图形客户端或路由器客户端：直接导入 `examples/clash-client.yaml`

如果你只是想让 Clash for Windows 一类工具连接服务端，不需要再运行 `client.sh`。

## 1. 服务端部署

使用 root 运行：

```bash
sudo bash server.sh install
```

安装完成后，连接信息会保存到：

```text
/etc/trojan-go/client-info.txt
```

如果当前环境既没有 `systemd`，也没有 `service`，`install` 只会完成安装，不会在后台常驻。此时需要再执行：

```bash
sudo bash server.sh start
```

并保持这个终端不要关闭。

服务端常用命令：

```bash
sudo bash server.sh start
sudo bash server.sh stop
sudo bash server.sh restart
sudo bash server.sh status
sudo bash server.sh uninstall
```

## 2. 客户端使用

### 方式 A：纯 Linux 终端客户端

`client.sh` 只面向纯 Linux 终端环境。

使用普通用户运行：

```bash
bash client.sh install
```

如果直接用 `root` 或 `sudo` 运行，脚本现在只会告警并继续执行，但会把 `mihomo`、配置和代理环境安装到 root 对应的用户目录里，通常不是你日常登录的那个用户环境。

这个安装流程主要会做 4 件事：

- 下载或复用 `mihomo`
- 根据你输入的服务端地址、端口、密码、SNI，生成 `~/.config/mihomo/config.yaml`
- 在可用的后台服务管理器环境中自动启动本地 `mihomo`，并连接到服务端的 `trojan-service`
- 为后续新终端写入代理环境变量加载逻辑

最重要的本地代理入口是：

- `127.0.0.1:7890`

这是 `mihomo` 的本地 HTTP 代理端口。终端代理环境变量会默认指向它。大多数命令行程序只要读取了代理环境变量，就会通过这个端口走 HTTP/HTTPS 代理。

如果你要手动给程序填代理地址，通常也优先填：

```text
http://127.0.0.1:7890
```

安装完成后，连接信息会保存到：

```text
~/.config/clash-service/client-info.txt
```

后续再次执行 `bash client.sh install` 时，会默认从这个文件读取 `server`、`port`、`password`、`sni` 作为输入默认值。

如果本地 `mihomo` 配置文件丢失，但这个连接信息文件还在，`bash client.sh start` 和 `bash client.sh restart` 会优先尝试根据它自动恢复配置，而不是重新让你输入一遍。

代理环境变量会写到：

```text
~/.config/clash-service/proxy.env
```

新开的终端会自动加载这个文件，因此会自动写入这些环境变量：

- `http_proxy=http://127.0.0.1:7890`
- `https_proxy=http://127.0.0.1:7890`
- `HTTP_PROXY=$http_proxy`
- `HTTPS_PROXY=$https_proxy`

也就是说，后续新终端里大多数支持标准 HTTP/HTTPS 代理环境变量的程序都会直接走本地 `mihomo` 代理。

<details>
<summary>点击查看：controller 和本地 DNS 是什么</summary>

`client.sh` 生成的 `mihomo` 配置里，除了本地代理端口，还会启用两个本地监听地址：

- `127.0.0.1:9090`
  这是 `mihomo` 自己的本地管理接口，也就是 controller。它不是拿来给业务流量走代理的，而是给脚本或管理工具查询状态、读取节点信息、做 delay 检测用的。
- `127.0.0.1:1053`
  这是 `mihomo` 自己启动的本地 DNS 监听地址。

这两个端口都是 `mihomo` 进程自己提供的，不是系统额外安装的独立服务。

需要注意：

- controller 默认只监听本机，不对外开放
- 本地 DNS 虽然会跟着 `mihomo` 一起启动，但当前脚本默认不会自动修改系统 `resolv.conf`
- 所以默认真正“自动生效”的是代理环境变量，不是系统级 DNS 接管
- 如果以后启用 TUN 或手动改系统 DNS，`127.0.0.1:1053` 的作用才会更直接

</details>

之后在新开的终端里使用：

```bash
clash_service start
clash_service stop
clash_service restart
clash_service status
```

也可以直接调用脚本：

```bash
bash client.sh start
bash client.sh stop
bash client.sh restart
bash client.sh status
bash client.sh enable
bash client.sh disable
bash client.sh uninstall
```

补充说明：

- 如果你直接执行 `bash client.sh install` 或 `bash client.sh start`，当前这个终端不会被脚本反向改写；新开的终端会自动读取 `proxy.env`
- 如果想让当前终端立刻生效，可以手动执行 `source ~/.config/clash-service/proxy.env`
- 如果使用的是 `clash_service start` / `clash_service stop` 这个 shell 函数，当前终端也会同步更新代理环境变量
- `stop` 或 `disable` 会把后续新终端中的代理环境变量一起清掉
- 如果当前环境没有可用的后台服务管理器，`install` 会先写好配置，等你执行 `bash client.sh start` 后再以前台方式运行

如果当前环境既没有可用的 `systemd --user`，也没有可用的 `service`，`start` 和 `restart` 会直接前台运行 `mihomo`。这时要把它放在一个专门终端里运行，并保持该终端不要关闭。

### 方式 B：图形客户端或路由器客户端

如果客户端使用的是 Clash for Windows、Clash Verge、Mihomo Party、OpenClash 这类工具，不需要运行 `client.sh`，直接导入示例配置即可：

```text
examples/clash-client.yaml
```

导入前通常只需要改这 4 个值：

- `server`
  你的服务器 IP 或域名
- `port`
  `server.sh` 配置的监听端口
- `password`
  `server.sh` 配置的 Trojan 密码
- `sni`
  证书名或域名

默认示例里保留了 `skip-cert-verify: true`，因为 `server.sh` 默认生成的是自签名证书。如果你自己换成了可信 CA 证书，可以再改成 `false`。

## 3. 可选功能

如果客户端需要 TUN 模式，先完成普通客户端安装，再看 [advanced/README.md](advanced/README.md)：

```bash
bash advanced/client-tun.sh enable
```

## 4. 重点行为

脚本会自动处理这些事情：

- 自动下载或复用 `trojan-go`、`mihomo`
- 下载前先打印文件名、下载地址和缓存目录，方便手动上传
- 自动生成服务端和客户端配置
- 按环境自动选择 `systemd`、`service` 或前台运行
- 客户端启动后自动检测 `trojan-service` 是否可用
- 检测本地 controller 时主动绕过旧代理环境变量，避免误判
- 如果旧配置依赖 `geoip.metadb`，客户端会自动下载或复用

<details>
<summary>点击查看：服务管理器回退逻辑</summary>

### 服务端

- 有正在运行的 `systemd`：写入 `trojan-go.service`，使用 `systemctl`
- 没有 `systemd` 但有 `service`/`init.d`：写入 `/etc/init.d/trojan-go`，使用 `service`
- 两者都没有：`start` 直接前台运行 `trojan-go`

### 客户端

- 有可用的 `systemd --user`：写入 `mihomo.service`，使用 `systemctl --user`
- 没有 `systemd --user` 但有 `service`：写入 `/etc/init.d/mihomo-<当前用户名>`，使用 `service`
- 两者都没有：`start` 直接前台运行 `mihomo`

</details>

<details>
<summary>点击查看：离线下载和缓存目录</summary>

脚本在真正下载前，会先打印需要的文件名、下载地址和缓存目录。

主下载流程优先使用 `curl`、`wget` 或 `python3`，尽量不依赖 `apt`、`yum` 这类包管理器。只有缺少必要系统工具时，才会尝试自动调用系统包管理器补齐。

服务端默认缓存目录：

```text
/var/cache/clash-service
```

客户端默认缓存目录：

```text
~/.cache/clash-service
```

也可以自定义缓存目录：

```bash
CLASH_SERVICE_CACHE_DIR=/path/to/cache sudo bash server.sh install
CLASH_SERVICE_CACHE_DIR=/path/to/cache bash client.sh install
```

如果你已经手动把文件上传到缓存目录，脚本会直接复用，不再重新下载。

如需强制重新下载：

```bash
CLASH_SERVICE_FORCE_DOWNLOAD=1 sudo bash server.sh install
CLASH_SERVICE_FORCE_DOWNLOAD=1 bash client.sh install
```

常见缓存文件：

- 服务端：`trojan-go-linux-<arch>.zip`
- 客户端：匹配当前架构的 `mihomo-linux-*.gz`
- 旧客户端配置额外可能需要：`geoip.metadb`

</details>

<details>
<summary>点击查看：关键路径和日志位置</summary>

### 服务端

```text
/usr/local/bin/trojan-go
/etc/trojan-go/config.json
/etc/trojan-go/client-info.txt
/etc/trojan-go/certs/server.crt
/etc/trojan-go/certs/server.key
/etc/systemd/system/trojan-go.service
/etc/init.d/trojan-go
/var/run/trojan-go.pid
/var/log/trojan-go.log
```

### 客户端

```text
~/.local/bin/mihomo
~/.config/mihomo/config.yaml
~/.config/clash-service/client-info.txt
~/.config/clash-service/proxy.env
~/.config/systemd/user/mihomo.service
~/.config/clash-service/mihomo.pid
~/.config/clash-service/mihomo.log
/etc/init.d/mihomo-<当前用户名>
```

如果设置了 `XDG_CONFIG_HOME` 或 `XDG_CACHE_HOME`，客户端会跟随这些路径。

服务端日志查看：

```bash
sudo systemctl status trojan-go.service
sudo journalctl -u trojan-go.service -e --no-pager
sudo service trojan-go status
sudo tail -f /var/log/trojan-go.log
```

客户端日志查看：

```bash
systemctl --user status mihomo.service
journalctl --user -u mihomo.service -e --no-pager
sudo service "mihomo-$(id -un)" status
tail -f ~/.config/clash-service/mihomo.log
```

</details>

<details>
<summary>点击查看：常见排错</summary>

客户端启动后检测失败，可以临时换检测地址：

```bash
CLASH_SERVICE_CHECK_URL=https://www.cloudflare.com/cdn-cgi/trace bash client.sh restart
```

确认只是临时不想检测时：

```bash
CLASH_SERVICE_SKIP_CHECK=1 bash client.sh restart
```

如果 `systemctl --user` 报 `Failed to connect to bus`，说明当前会话没有可用的 user bus。脚本会先尝试启用 linger；仍然不行时，会退回 `service`，再不行就退回前台运行。常见手动处理：

```bash
sudo loginctl enable-linger "$USER"
```

然后重新登录，再执行：

```bash
systemctl --user daemon-reload
bash client.sh start
```

如果当前环境是前台模式，`server.sh start` 或 `client.sh start` 本来就会占用当前终端，这是正常行为，不是卡死。

</details>

<details>
<summary>点击查看：代理环境变量和安全说明</summary>

`client.sh` 只会维护一个受控文件：

```text
~/.config/clash-service/proxy.env
```

安装时会在当前 shell 的启动文件里加入一次 loader 和 `clash_service` 函数。以后开关代理，只改 `proxy.env`，不会反复往 `~/.bashrc` 或 `~/.zshrc` 里追加多段配置。

如果你直接运行 `bash client.sh start` 或 `bash client.sh stop`，当前父终端不会被脚本反向修改；需要手动执行：

```bash
source ~/.config/clash-service/proxy.env
```

安全相关默认行为：

- 服务端证书默认是自签名
- 客户端默认 `skip-cert-verify: true`
- 客户端 controller 只监听 `127.0.0.1`
- 连接信息文件里会保存明文密码，脚本会设置为 `0600`

</details>
