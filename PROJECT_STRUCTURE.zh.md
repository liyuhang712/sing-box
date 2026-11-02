# sing-box 项目结构说明

本文基于当前 `v1.14.4` 系列代码，说明这个 fork 的目录职责、核心架构和数据流，供阅读源码和定位功能时参考。仓库的 Git 远程地址是 `liyuhang712/sing-box`，但 Go 模块路径仍然是上游的 `github.com/sagernet/sing-box`，因此源码中的 import 路径与 fork 的仓库地址不同。

## 顶层目录

```text
sing-box/
├── cmd/                 CLI 入口和内部构建工具
├── option/              JSON 配置的数据结构与校验
├── adapter/             核心接口、管理器和注册表
├── include/             按配置类型注册具体实现
├── protocol/            各类代理协议和连接方式
├── transport/           底层传输实现
├── route/               流量路由、规则匹配和连接管理
├── dns/                 DNS 客户端、路由器与传输
├── service/             长期运行的服务模块
├── experimental/        实验性 API、缓存、嵌入库等
├── daemon/              gRPC 守护进程接口
├── common/              跨模块公共工具
├── constant/            常量、类型名、默认值
├── log/                 日志实现
├── schema/              JSON Schema 生成器
├── clients/             Android、Apple、桌面客户端子模块
├── test/                集成测试与测试配置
├── docs/                MkDocs 文档源文件
├── release/             打包、安装和服务配置
├── .github/             CI、跨平台构建及辅助脚本
├── box.go               核心运行实例的组装与生命周期
├── debug*.go            调试入口及平台相关实现
├── Makefile             主要构建入口
├── Dockerfile           容器镜像构建文件
├── go.mod / go.sum      Go 模块及依赖锁定
└── mkdocs.yml           文档站点配置
```

## 核心架构

一条普通连接从配置到代理转发，大致经过以下路径：

```text
config.json
  -> option：解析配置并校验字段
  -> include：根据 type 找到具体实现并创建注册表
  -> adapter：管理器创建 Inbound、Outbound、Endpoint 和 Service
  -> box.go：组装 DNS、路由、连接和服务
  -> route/rule：根据连接信息选择路由动作或出站
  -> protocol + transport：建立连接并处理实际流量
```

其中，`option` 描述“用户配置了什么”，`adapter` 描述“系统内部需要哪些能力”，`include` 负责把配置中的类型字符串绑定到具体实现，`protocol` 和 `transport` 完成真正的连接处理。

## 主要目录

### cmd

[cmd/sing-box](./cmd/sing-box/main.go) 是命令行程序的入口，包含以下子命令：

- `run`：启动代理服务。
- `check`：检查配置。
- `format`：格式化配置。
- `api`：通过 API 查询和操作运行中的实例。
- `rule-set`：管理规则集。
- `generate`、`geoip`、`geosite`、`tools` 等辅助功能。

`cmd/internal` 存放构建和发布工具，包括跨平台打包、Apple/Android SDK 处理、文档格式化和版本更新。这些工具通常不参与普通 CLI 功能。

### 根目录 Go 文件

[box.go](./box.go) 是整个运行时最重要的装配点。`Box` 持有入站管理器、出站管理器、端点管理器、DNS 路由器、连接管理器、路由器和各类服务，并负责创建、启动和关闭实例。

根目录下的 `debug*.go` 是调试入口及平台适配代码。公共嵌入接口也在根包中，供 `experimental/libbox` 等模块调用。

### option

[option/options.go](./option/options.go) 定义配置文件的 Go 类型，负责以下工作：

- 将 JSON 解码为强类型配置。
- 拒绝未知字段。
- 检查重复标签、缺失字段和互斥配置。
- 描述 JSON Schema。

配置中的 `log`、`dns`、`inbounds`、`outbounds`、`endpoints`、`route`、`services` 和 `experimental` 都可以在 `option` 中找到对应结构。新增配置字段通常从修改此目录开始。

### adapter

[adapter](./adapter) 定义核心内部的接口、管理器和注册表，不实现具体代理协议。

主要抽象包括：

- `Inbound`：接收客户端连接，例如 SOCKS、HTTP、TUN 和 Shadowsocks。
- `Outbound`：向目标或代理服务器建立连接，例如 Direct、VLESS 和 Hysteria2。
- `Endpoint`：具有持续网络状态的连接实体，例如 WireGuard、OpenVPN 和 Tailscale。
- `Service`：具有独立生命周期的服务，例如 API、ACME 和 USB/IP。
- `Router`：根据连接上下文选择出站并执行路由动作。

`adapter/inbound.go` 中的 `InboundContext` 会携带目标地址、域名、用户、嗅探结果、DNS 信息、命中的规则和进程信息等连接上下文。

### include

[include/registry.go](./include/registry.go) 是“配置类型到具体实现”的注册中心。例如：

- 配置 `"type": "mixed"` 时创建 mixed 入站。
- 配置 `"type": "vless"` 时创建 VLESS 入站或出站。
- 配置 `"type": "wireguard"` 时创建 WireGuard 端点。

目录中各功能的普通文件和 `_stub.go` 文件通常受 Go 构建标签控制。构建时未启用某项功能时，对应 stub 会让配置解析或创建阶段给出明确错误。默认标签和链接参数维护在 [release](./release) 目录。

### protocol

[protocol](./protocol) 存放代理协议和连接模型，主要包括：

- 本地代理入口：SOCKS、HTTP、mixed。
- 透明代理与虚拟网卡：TUN、Redirect、TProxy、Direct Inbound。
- 代理协议：Shadowsocks、VMess、VLESS、Trojan、Hysteria、Hysteria2、TUIC、AnyTLS、Snell、ShadowTLS 等。
- 特殊连接：SSH、Tor、Naive、Cloudflared、OpenVPN、OpenConnect。
- 端点协议：WireGuard、Tailscale。
- 出站组合：Selector、URLTest、Block、Bridge。

如果改动涉及协议握手、数据帧格式或连接语义，通常应在此目录中寻找对应实现。

### transport

[transport](./transport) 存放代理协议使用的底层传输，例如：

- WebSocket。
- HTTP 和 HTTPUpgrade。
- gRPC 与 gRPC Lite。
- QUIC。
- Trojan、OpenVPN、OpenConnect 和 WireGuard 的底层连接处理。
- simple-obfs、SIP003 等兼容传输。

可以简单理解为：`protocol` 决定代理协议，`transport` 决定数据通过什么通道传输。

### route

[route](./route) 负责决定一条连接应该走哪个出站，或者执行拒绝、DNS 劫持等其他动作。

其中：

- `route/rule` 按条件拆分匹配器，包括域名、CIDR、端口、进程、用户、网络类型、Wi-Fi、规则集等。
- `route/router.go` 负责路由决策。
- 连接管理、FakeIP、邻居发现、网络接口管理和引用关系也在该目录或其子包中实现。

规则处理大致遵循：

```text
入站连接
  -> 收集地址、域名、协议和进程等上下文
  -> 匹配 route/rule
  -> 选择 outbound 或执行 route action
  -> 建立最终连接
```

### dns

[dns](./dns) 包含 DNS 路由、客户端和传输管理。

- 普通 DNS 传输支持 UDP、TCP、TLS、HTTPS、QUIC 等方式。
- `protocol/dns` 负责把 DNS 请求作为一种连接或入站流量处理。
- `option/dns.go` 定义 DNS 配置。
- FakeIP、Hosts、本地系统 DNS 和 DNS 规则动作分别有独立实现。

DNS 请求同样可能进入路由规则，因此不能只把 `dns` 看作简单的域名解析工具。

### service

[service](./service) 存放由配置中 `services` 启动的长期服务，例如：

- sing-box API。
- ACME 证书服务。
- Resolved DNS。
- DERP。
- CCM 和 OCM。
- USB/IP。
- OOM killer。
- 电量和流量统计。

这些服务通常拥有独立生命周期，与普通入站和出站不同。

### experimental

[experimental](./experimental) 存放兼容性、实验性或嵌入能力：

- Clash API 和 V2Ray API。
- 缓存文件。
- 废弃接口兼容层。
- `libbox` 移动端和嵌入式 Go 库。
- `boxdd` 守护进程。

这些模块可能包含更复杂的平台接口和 FFI，也更容易受到版本变化影响。修改前应同时检查构建标签和目标平台。

### daemon

[daemon](./daemon) 实现守护进程的客户端、服务端、实例管理和 gRPC 接口。`*.pb.go` 和 `*_grpc.pb.go` 是生成的协议代码，不应直接手工修改；对应生成工具位于 `cmd/internal/protogen`。

### common

[common](./common) 是没有独立生命周期的跨模块工具，包括：

- 拨号器和连接中断控制。
- TLS、uTLS、REALITY 和证书处理。
- 流量嗅探和协议识别。
- 系统代理、网络命名空间和进程信息。
- 缓存、队列、流量控制和规则集相关工具。
- 平台专用网络能力。

文件名中的 `_linux.go`、`_darwin.go`、`_windows.go`、`_android.go` 等后缀表示平台专用实现，阅读功能时应注意文件是否适用于目标平台。

### constant、log 和 schema

- `constant` 定义配置类型名、网络类型、默认值和共享常量。
- `log` 定义结构化日志、格式化器和平台日志输出。
- `schema` 根据 Go 配置结构生成 JSON Schema。执行 `make schema` 可以重新生成与当前构建标签匹配的 schema。

### clients

[clients](./clients) 下的 Android、Apple 和桌面客户端是 Git 子模块。普通 CLI 编译不需要初始化它们；需要构建图形客户端时执行：

```bash
git submodule update --init --recursive
```

### test

[test](./test) 是单独的 Go 模块，主要包含：

- 端到端和 Docker 集成测试。
- 各类协议的客户端/服务端组合测试。
- 测试证书生成。
- 各协议使用的 JSON、YAML 和 Docker 配置。

普通包内部的单元测试仍分散在各自目录中。由于 `test` 有独立的 `go.mod`，从根目录执行普通 `go test ./...` 不会自动运行整个集成测试模块。

### docs、release 和 .github

- [docs](./docs) 是 MkDocs 文档源码，中文文件通常使用 `.zh.md` 后缀。
- [release](./release) 保存默认构建标签、链接参数、shell 补全、systemd/OpenWrt 配置和安装脚本。
- [.github/workflows](./.github/workflows) 定义 Linux、Windows、macOS、Android、Apple 和 Docker 等 CI 构建流程。
- [Dockerfile](./Dockerfile) 和 [Dockerfile.binary](./Dockerfile.binary) 分别用于源码构建镜像和二进制运行镜像。

## 常见修改入口

### 新增或修改入站、出站协议

通常需要检查以下位置：

1. 在 `option` 中增加或修改配置结构和校验。
2. 在 `protocol` 中实现入站或出站的创建与连接逻辑。
3. 在 `include` 中注册类型和构造函数。
4. 如果使用独立传输，在 `transport` 中实现或复用传输层。
5. 在对应包和 `test` 模块中补充测试。
6. 更新 `docs/configuration` 下中英文配置文档。

### 修改路由规则

先查看 `option/rule.go` 中的配置字段，再查看 `route/rule` 匹配器，最后检查 `route/router.go` 等路由执行代码。涉及新动作时还应检查 `option/rule_action.go` 和 `route/rule/rule_action.go`。

### 修改 DNS 行为

配置通常在 `option/dns.go`，DNS 路由位于 `dns/router.go`，传输实现位于 `dns/transport`。如果 DNS 请求作为入站流量处理，还需要检查 `protocol/dns`。

### 修改命令行

普通 CLI 子命令位于 `cmd/sing-box`。每个子命令通常有独立的 `cmd_*.go` 文件，主命令和全局参数位于 `cmd/sing-box/cmd.go`。

## 阅读建议

第一次阅读代码时，建议按以下顺序：

1. [cmd/sing-box/main.go](./cmd/sing-box/main.go)：找到程序入口。
2. [cmd/sing-box/cmd_run.go](./cmd/sing-box/cmd_run.go)：理解配置读取和启动流程。
3. [option/options.go](./option/options.go)：理解配置结构。
4. [include/registry.go](./include/registry.go)：理解配置类型如何绑定实现。
5. [box.go](./box.go)：理解各管理器如何组装。
6. `route`、`dns` 和具体 `protocol`：理解单条连接如何被路由和转发。

## 外部依赖边界


这个仓库大量使用 `github.com/sagernet/sing` 提供的网络、元数据、生命周期和服务框架，也使用 `github.com/sagernet/sing-tun` 实现 TUN 相关能力。部分底层概念和辅助类型不在当前仓库中，遇到以 `sing/` 或 `sing-tun` 开头的 import 时，需要到相应依赖中继续追踪。

liyuhang
