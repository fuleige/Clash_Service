# Clash Service

用两个脚本快速搭一个基于 `trojan-go` + `mihomo` 的简单代理服务。

- `server.sh`
  安装 `trojan-go`、生成自签名证书、写入 `systemd` 服务。
- `client.sh`
  安装 `mihomo`、生成 Clash 配置、写入 `systemd --user` 服务，并管理终端代理环境变量。
- `advanced/client-tun.sh`
  可选的 TUN 开关脚本。

## 快速开始

服务端，使用 root 运行：

```bash
sudo bash server.sh install
```

安装完成后，连接信息会保存到：

```text
/etc/trojan-go/client-info.txt
```

客户端，使用普通用户运行：

```bash
bash client.sh install
```

安装完成后，连接信息会保存到：

```text
~/.config/clash-service/client-info.txt
```

之后在新开的终端中使用：

```bash
clash_service start
clash_service stop
clash_service restart
clash_service status
```

## 脚本会自动做什么

服务端：

- 自动安装缺少的 `curl`、`unzip`、`openssl`、`ca-certificates`
- 自动下载或复用 `trojan-go`
- 自动生成证书、配置和 `systemd` 服务
- 如果检测到 `ufw` 或 `firewalld` 已启用，会自动放行端口

客户端：

- 自动安装缺少的 `curl`、`gzip`、`ca-certificates`
- 自动下载或复用 `mihomo`
- 自动生成 `config.yaml`、用户级 `systemd` 服务和 shell loader
- 启动后自动检测 `trojan-service` 节点是否可用
- 检测本地 controller 时会主动绕过当前 shell 已存在的旧代理环境变量，避免误判
- 如果旧配置需要 `geoip.metadb`，也会自动下载或复用它

## 离线下载

脚本在真正下载前，会先打印需要的文件名、下载地址和缓存目录。

服务端：

- 默认缓存目录：`/var/cache/clash-service`
- 文件名：`trojan-go-linux-<arch>.zip`

客户端：

- 默认缓存目录：`~/.cache/clash-service`
- 文件名：匹配当前架构的 `mihomo-linux-*.gz`
- 如果脚本检测到旧配置依赖 GeoIP 数据，还会使用 `geoip.metadb`

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

安装完成后，更推荐直接在新终端使用：

```bash
clash_service start
clash_service stop
clash_service restart
clash_service status
```

## 关键路径

服务端：

```text
/usr/local/bin/trojan-go
/etc/trojan-go/config.json
/etc/trojan-go/client-info.txt
/etc/trojan-go/certs/server.crt
/etc/trojan-go/certs/server.key
/etc/systemd/system/trojan-go.service
```

客户端：

```text
~/.local/bin/mihomo
~/.config/mihomo/config.yaml
~/.config/clash-service/client-info.txt
~/.config/clash-service/proxy.env
~/.config/systemd/user/mihomo.service
```

如果设置了 `XDG_CONFIG_HOME` 或 `XDG_CACHE_HOME`，客户端会跟随这些路径。

## 日志与排错

服务端日志：

```bash
sudo systemctl status trojan-go.service
sudo journalctl -u trojan-go.service -e --no-pager
```

客户端日志：

```bash
systemctl --user status mihomo.service
journalctl --user -u mihomo.service -e --no-pager
```

如果客户端启动后检测失败，可以临时换检测地址：

```bash
CLASH_SERVICE_CHECK_URL=https://www.cloudflare.com/cdn-cgi/trace bash client.sh restart
```

确认只是临时不想检测时：

```bash
CLASH_SERVICE_SKIP_CHECK=1 bash client.sh restart
```

如果 `systemctl --user` 报 `Failed to connect to bus`，说明当前会话没有可用的 user bus。常见处理：

```bash
sudo loginctl enable-linger "$USER"
```

然后重新登录，再执行：

```bash
systemctl --user daemon-reload
bash client.sh start
```

## 代理环境变量

`client.sh` 只会维护一个受控文件：

```text
~/.config/clash-service/proxy.env
```

安装时会在当前 shell 的启动文件里加入一次 loader 和 `clash_service` 函数。以后开关代理，只改 `proxy.env`，不会反复往 `~/.bashrc` 或 `~/.zshrc` 里追加多段配置。

如果你直接运行 `bash client.sh start` 或 `bash client.sh stop`，当前父终端不会被脚本反向修改；需要手动执行：

```bash
source ~/.config/clash-service/proxy.env
```

## 安全说明

- 服务端证书默认是自签名
- 客户端默认 `skip-cert-verify: true`
- 客户端 controller 只监听 `127.0.0.1`
- 连接信息文件里会保存明文密码，脚本会设置为 `0600`

TUN 模式见 [advanced/README.md](advanced/README.md)。
