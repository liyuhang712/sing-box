# 本地 Shadowsocks 双端调试

这套配置用于在同一台机器上调试 sing-box 客户端、Shadowsocks 服务端和路由规则。
不需要证书、TUN 或管理员权限，不会自动修改系统代理。

```text
curl / 浏览器 → SOCKS 客户端 127.0.0.1:10808
                   ├─ 国内域名 / 国内 IP / 私有 IP → direct → 目标
                   └─ 其他 → Shadowsocks 127.0.0.1:8388 → direct → 目标
```

| 文件 | 用途 |
| --- | --- |
| `debug/client.json` | SOCKS 入站（SOCKS4/4a/5）、本地规则集、direct 和 Shadowsocks 出站 |
| `debug/server.json` | Shadowsocks 入站、direct 出站 |
| `.vscode/launch.json` | 分别启动两端，或使用“本地双端”同时调试 |

两端采用 `2022-blake3-aes-128-gcm`，配置中的共享密钥是 **仅供本机调试的示例密钥**。
若修改密钥，必须同时修改两端；生成命令为 `go run ./cmd/sing-box generate rand --base64 16`。
两端只监听 `127.0.0.1`，默认不接受其他机器连接。

## 1. 准备规则文件

**以下所有终端命令都在仓库根目录执行。** 本地规则路径相对于进程工作目录，而不是 JSON 所在目录。

旧的 `geoip`、`geosite` 配置字段已在 sing-box 1.12 移除。这里使用可读的 JSON 规则集，
不需要 `geoip.db`、`geosite.db`。

客户端直接加载 `debug/rules/geoip-cn.json` 和 `debug/rules/geosite-cn.json`，
可以在编辑器中查看完整 IP 网段、域名、域名后缀及正则表达式。已有 JSON 时无需再次下载或转换。
JSON 文件不添加 Git 忽略规则，方便阅读和版本管理。

首次准备或手动更新数据时，下载二进制来源并反编译成 JSON（下载需要能访问 GitHub）：

```sh
mkdir -p debug/rules
curl -fL --retry 3 -o debug/rules/geoip-cn.srs https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs
curl -fL --retry 3 -o debug/rules/geosite-cn.srs https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs
go run ./cmd/sing-box rule-set decompile debug/rules/geoip-cn.srs -o debug/rules/geoip-cn.json
go run ./cmd/sing-box rule-set decompile debug/rules/geosite-cn.srs -o debug/rules/geosite-cn.json
```

本地 `.srs` 保留作为转换来源，客户端实际以 `type: local`、`format: source` 加载 JSON，服务端不加载规则。
JSON 比二进制大，但便于学习源码和修改规则；文件缺失或损坏会报错，不会静默绕过。
启动不联网获取规则，也不会自动更新；更新时停止客户端，重新下载、转换并执行配置检查后再启动。
如果需要自动下载和定期更新，sing-box 也支持 `type: remote`；本示例按手动方式配置。

## 2. 检查和启动

需要安装满足 `go.mod` 要求的 Go 工具链。VS Code 调试还需要 Go 扩展（`golang.go`）和兼容的 Delve。

先检查配置和规则文件能否加载：

```sh
go run ./cmd/sing-box check -c debug/server.json
go run ./cmd/sing-box check -c debug/client.json
```

检查通过时通常没有输出；这不代表监听端口和转发链路已验证。

**VS Code：** 以仓库根目录打开工作区，进入“运行和调试”，选择 **本地双端**，按 F5。
该 compound 会同时启动“本地服务端”和“本地客户端”；不保证启动先后顺序。
等待两个会话分别出现 `sing-box started` 以及以下监听日志后再发送请求：

```text
inbound/shadowsocks[ss-in]: tcp server started at 127.0.0.1:8388
inbound/socks[socks-in]: tcp server started at 127.0.0.1:10808
```

两端设置了固定工作目录和不同的调试二进制输出文件，避免相对路径错误和同时编译覆盖。
在调试工具栏选择当前会话，可以查看对应日志。停止其中一个会话将通过 `stopAll` 停止另一端。
原来的“Debug sing-box”入口继续使用根目录 `config.json`。

**终端替代方式：** 打开两个终端，在仓库根目录分别执行：

```sh
# 终端一：服务端
go run ./cmd/sing-box run -c debug/server.json
```

```sh
# 终端二：客户端
go run ./cmd/sing-box run -c debug/client.json
```

终端运行和 VS Code 调试二选一，避免端口占用。终端方式需要分别按 Ctrl+C 停止两端。

## 3. 发起请求并观察分流

```sh
# 国内域名，预期客户端 direct
curl --max-time 20 --noproxy "" --proxy socks5h://127.0.0.1:10808 https://www.baidu.com

# 中国公网 IP，预期客户端 direct
curl --max-time 20 --noproxy "" --proxy socks5h://127.0.0.1:10808 http://223.5.5.5/

# 默认 Shadowsocks 转发，预期两端都有对应连接日志
curl --max-time 20 --noproxy "" --proxy socks5h://127.0.0.1:10808 https://example.com

```

应用的代理类型选择 SOCKS5，地址为 `127.0.0.1`，端口为 `10808`，无需用户名或密码。
入站仅支持 SOCKS；通过 SOCKS 代理仍然可以访问 HTTP 和 HTTPS 网站。

`--noproxy ""` 排除环境变量 `NO_PROXY` 导致的绕过；`socks5h` 将目标域名交给 sing-box，
以便参与域名分流。普通 `socks5` 通常由 curl 先解析，客户端可能只收到 IP，无法按原域名匹配 geosite。
这些公网测试仍需要本机网络和系统 DNS 可用。IP 测试收到 HTTP 重定向或错误状态也可能表明转发成功，
它不是完整网页可用性的保证；不要添加 `-L` 后再用最终响应判断最初目标的路由。

客户端按顺序执行：

1. 已知私有目标 IP 直连。
2. 命中 `geosite-cn` 的域名直连。
3. 对其余域名执行 `resolve`，取得 IP；解析失败则当前请求失败。
4. 解析后命中私有 IP 的目标直连。
5. 命中 `geoip-cn` 的目标直连。
6. 其余目标走默认出站 `ss-out`。

两端使用系统 DNS，优先 IPv4 并保留 IPv6 回退。默认代理目标也会先在客户端解析，以便检查 GeoIP；
这套最小配置没有提供代理 DNS。Shadowsocks 服务端地址直接使用 IP，不会产生解析它自身的循环。

路由以实际规则数据和 DNS 结果为准，可以先确认样例是否命中：

```sh
go run ./cmd/sing-box rule-set match -f source debug/rules/geosite-cn.json www.baidu.com
go run ./cmd/sing-box rule-set match -f source debug/rules/geoip-cn.json 223.5.5.5
go run ./cmd/sing-box rule-set match -f source debug/rules/geosite-cn.json example.com
```

命中会输出 `match rules...`，不命中不输出；不能仅用退出码区分。example.com 还会继续接受解析后的 IP 检查。

预期日志（省略时间戳和连接 ID）：

```text
# 客户端：国内域名直连；国内 IP 则显示 rule_set=geoip-cn
router: match[1] rule_set=geosite-cn => route(direct)
outbound/direct[direct]: outbound connection to www.baidu.com:443

# 客户端：默认代理
outbound/shadowsocks[ss-out]: outbound connection to <目标地址>:443

# 服务端：解密并连接目标
inbound/shadowsocks[ss-in]: inbound connection to <目标地址>:443
outbound/direct[direct]: outbound connection to <目标地址>:443
```

只有走 Shadowsocks 的请求才会到达服务端。两端的连接 ID 独立生成，通过目标地址和时间关联日志。
因为客户端和服务端在同一台机器，最终公网出口通常相同；不能通过公网 IP 是否改变判断代理是否生效。

## 4. 断点与本地链路验证

建议依次在这些位置设置断点：

- `route/route.go` 的 `actionResolve`：观察客户端域名解析及目标地址列表。
- `protocol/shadowsocks/outbound.go` 的 `Outbound.DialContext`：客户端选择 Shadowsocks 出站。
- `protocol/shadowsocks/inbound.go` 的 `Inbound.newConnection`（小写 `newConnection`）：服务端完成解密，取得目标。
- `protocol/direct/outbound.go` 的 `Outbound.DialContext`：客户端直连，或服务端访问最终目标。

若请求命中国内/私有地址直连，Shadowsocks 断点不会命中，这是预期行为。
暂停任一进程会让另一端或 curl 等待，必要时增加 `--max-time`；双端调试时注意选择对应会话。

想在不依赖公网的情况下验证完整协议链路，可使用临时的“全部代理”客户端：

1. 停止双端会话。在终端一执行 `python3 -m http.server 18080 --bind 127.0.0.1 --directory debug`。
2. 在仓库根目录生成临时配置，不改正式配置：

   ```sh
   python3 - <<'PY'
   import json
   import os
   import tempfile
   from pathlib import Path

   config = json.loads(Path("debug/client.json").read_text())
   config["route"]["rules"] = []
   config["route"].pop("rule_set")
   descriptor, name = tempfile.mkstemp(prefix="sing-box-all-ss-", suffix=".json")
   with os.fdopen(descriptor, "w") as output:
       json.dump(config, output, indent=2)
   print(name)
   PY
   ```

3. 在终端二启动正式服务端；终端三执行 `go run ./cmd/sing-box run -c <上一步输出的路径>`。
4. 执行 `curl --max-time 20 --noproxy "" --proxy socks5h://127.0.0.1:10808 http://127.0.0.1:18080/README.zh.md`。
   应返回这份文档，并在两端看到 Shadowsocks 日志。正式配置访问该私有地址会直接连接，不能用它证明协议链路。
5. 停止服务端，再执行相同请求，应失败；停止临时客户端后改用正式客户端，相同请求应直连成功。
6. 分别停止 HTTP 服务和客户端，删除上一步生成的临时 JSON。

## 排查与验证记录

| 现象 | 检查 |
| --- | --- |
| `no such file` 或规则解析失败 | 是否从仓库根目录启动、两个 JSON 是否正确生成或编辑；重新执行 `check` |
| `address already in use` | 是否同时启动了终端和 VS Code 实例；修改端口时同步修改客户端服务器端口 |
| 连接 `127.0.0.1:8388` 被拒绝 | 服务端是否启动完成、是否被断点暂停或已经退出 |
| Shadowsocks 认证失败 | 两端 method、password 是否完全一致，2022 密钥是否为正确长度的 Base64 |
| 服务端没有请求日志 | 请求可能走 direct，或应用未使用代理；检查客户端路由日志 |
| DNS 错误或公网请求超时 | 检查系统 DNS 和本机网络；先用上面的本地 HTTP 测试隔离问题 |
| VS Code 无法启动调试 | 检查 Go 扩展、Go/Delve 版本；先用终端方式验证配置 |

2026-11-13 切换 SOCKS 入站前，使用当前源码、Go 1.27.3 在本机完成：两份配置检查、双端启动、HTTP/SOCKS5 混合入站、
geosite/geoip 直连、example.com 和 1.1.1.1 默认代理、本地 HTTP 完整 Shadowsocks 往返、
服务端解析 localhost、停止服务端后代理失败而直连可用，以及停止后两个 TCP 端口释放。
测试临时配置、日志和 HTTP 服务均已清理。VS Code 图形界面的 F5 操作尚未实际执行。
本轮验收针对 TCP；未测试 UDP。配置文件没有关闭协议默认的 UDP 支持。
随后客户端改为 SOCKS 入站（`socks-in`），保留 `127.0.0.1:10808`，并重新通过配置检查。
规则集随后从现有 `.srs` 完整转换为 JSON，客户端已通过文本规则加载检查。
对 GeoIP 的 `223.5.5.5`、`114.114.114.114`、`1.1.1.1`、`127.0.0.1`，
以及 Geosite 的 `www.baidu.com`、`www.bilibili.com`、`example.com`、`localhost`，
逐项对比了转换前后的命中结果，均一致；此次格式切换未重新执行网络链路测试。
