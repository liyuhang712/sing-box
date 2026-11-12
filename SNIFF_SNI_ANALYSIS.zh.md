# Sing-box Postman SOCKS5 HTTPS SNI 嗅探分析

本文分析 Postman 通过 SOCKS5 代理发起以下 HTTPS 请求时，sing-box 如何通过
`sniff` 动作识别 TLS，并提取 SNI：

```text
https://jhjmanagement.jhj515.com/user/login
```

分析基于当前工作区代码和根目录的 `config.json`。Postman 的 SOCKS5 代理地址假定为：

```text
127.0.0.1:10809
```

该端口对应当前配置中的 `socks-in`。

本次调试中 Postman 使用 `socks5://`，会先在本地解析
`jhjmanagement.jhj515.com`，因此 SOCKS5 CONNECT 请求携带的是目标 IP。
SOCKS5 层的 `Destination.Fqdn` 是空字符串，不是域名。

## 1. 结论

Postman 通过 `socks-in` 发起 HTTPS 请求时，典型调用路径是：

```text
Postman
  │
  │ 1. SOCKS5 握手，目标为 <解析后的 IP>:443
  ▼
socks-in (127.0.0.1:10809)
  │
  │ 2. 解析 SOCKS5 CONNECT 请求和目标地址
  ▼
RouteConnectionEx
  │
  ▼
routeConnection
  │
  ▼
matchRule
  │
  │ 3. 命中 action=sniff
  ▼
actionSniff
  │
  │ 4. 读取连接开头的 TLS ClientHello
  ▼
PeekStream
  │
  ▼
TLSClientHello
  │
  │ 5. Go TLS 解析器取得 ClientHello.ServerName
  ▼
metadata.Protocol = "tls"
metadata.Domain = "jhjmanagement.jhj515.com"
metadata.Destination.Addr = <目标 IP>
metadata.Destination.Fqdn = ""
```

关键点：

1. Postman 使用 SOCKS5 代理，不会发送 HTTP CONNECT。
2. 路由代码看不到 `/user/login`，该路径位于 TLS 加密流量中。
3. TLS 嗅探不会解密 HTTPS 正文。
4. SNI 来自 TLS ClientHello 的 `server_name` 扩展。
5. 当前实现使用 Go 标准库 `crypto/tls` 解析 ClientHello，没有手写 TLS 二进制解析器。
6. 嗅探时读取的 ClientHello 会放回连接，真正的 TLS 握手仍能收到完整数据。
7. SNI 写入 `metadata.Domain`，不会修改 SOCKS5 提供的目标 IP。

## 2. 当前配置和处理结果

当前 `config.json` 中相关配置是：

```json
{
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": 10808
    },
    {
      "type": "socks",
      "tag": "socks-in",
      "listen": "127.0.0.1",
      "listen_port": 10809
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "action": "sniff"
      }
    ],
    "final": "direct"
  }
}
```

本次请求进入路由时，关键元数据大致为：

```go
metadata.Inbound = "socks-in"
metadata.InboundType = "socks"
metadata.Protocol = ""
metadata.Domain = "" // 没有反向映射时为空，随后由 SNI 填充
metadata.Destination.Addr = <目标 IP>
metadata.Destination.Fqdn = ""
metadata.Destination.Port = 443
```

TLS ClientHello 嗅探成功后，更新为：

```go
metadata.Protocol = "tls"
metadata.Domain = "jhjmanagement.jhj515.com"

// Destination 保持 SOCKS5 请求中的 IP，不被 SNI 改写。
metadata.Destination.Addr = <目标 IP>
metadata.Destination.Fqdn = ""
metadata.Destination.Port = 443
```

当前只有 `sniff` 规则，没有后续基于 `protocol` 或 `domain` 的路由规则。因此：

- 嗅探结果会写入元数据并记录日志。
- 嗅探结果不会改变当前出站选择。
- 最终仍然使用 `route.final` 指定的 `direct` 出站。

## 3. HTTPS 请求首先经过 SOCKS5 CONNECT

Postman 配置 SOCKS5 代理后，会直接连接：

```text
127.0.0.1:10809
```

不会发送 HTTP CONNECT 文本请求。SOCKS5 握手的主要流程是：

```text
Postman                         socks-in
  │                                │
  │ SOCKS5 版本和方法协商           │
  ├───────────────────────────────►│
  │                                │
  │ 认证方法选择                    │
  │◄───────────────────────────────┤
  │                                │
  │ CONNECT <目标 IP>:443
  ├───────────────────────────────►│
  │                                │ 解析 request.Destination
  │                                │ 进入 RouteConnectionEx
  │                                ▼
```

Postman 12.36.0 支持 `socks5://` 和 `socks5h://`。两者的 DNS 行为不同：

```text
socks5://  -> Postman 本地 DNS -> SOCKS5 携带 IP
socks5h:// -> Postman 不解析   -> SOCKS5 携带域名
```

其内置 SOCKS 客户端逻辑可以简化为：

```js
let shouldLookup = false;

switch (proxy.protocol) {
case "socks5":
    shouldLookup = true;
    break;
case "socks5h":
case "socks":
    shouldLookup = false;
    break;
}

if (shouldLookup) {
    host = await dns.lookup(host);
}

SocksClient.createConnection({
    destination: {
        host: host,
        port: port
    }
});
```

当前调试使用 `socks5://`，所以 `shouldLookup == true`，进入 SOCKS5 报文的是本地
DNS 解析后的 IP。只有使用 `socks5h://`，Postman 才会把原始主机名交给 SOCKS5 层。

SOCKS 入站的 TCP 入口位于 [protocol/socks/inbound.go](protocol/socks/inbound.go)：

```go
func (h *Inbound) NewConnection(
    ctx context.Context,
    conn net.Conn,
    metadata adapter.InboundContext,
    onClose N.CloseHandlerFunc,
) {
    err := socks.HandleConnectionEx(
        ctx,
        conn,
        std_bufio.NewReader(conn),
        h.authenticator,
        adapter.NewUpstreamHandler(
            metadata,
            h.newUserConnection,
            h.streamUserPacketConnection,
        ),
        h.listener,
        h.udpTimeout,
        metadata.Source,
        onClose,
    )
    N.CloseOnHandshakeFailure(conn, onClose, err)
}
```

实际 SOCKS5 解析位于
[sing/protocol/socks/handshake.go](../go/pkg/mod/github.com/sagernet/sing@v0.9.7-0.20261023115459-5dc452e537bf/protocol/socks/handshake.go)：

```go
case socks5.Version:
    var authRequest socks5.AuthRequest
    authRequest, err = socks5.ReadAuthRequest0(reader)
    // 协商认证方法...

    var request socks5.Request
    request, err = socks5.ReadRequest(reader)
    if err != nil {
        return err
    }

    switch request.Command {
    case socks5.CommandConnect:
        handler.NewConnectionEx(
            ctx,
            NewLazyConn(conn, version),
            source,
            request.Destination,
            onClose,
        )
        return nil
    }
```

`request.Destination` 是 Postman 在 SOCKS5 CONNECT 请求中给出的目标地址。
地址类型由 SOCKS5 请求中的 `ATYP` 决定：

```text
ATYP=DOMAINNAME -> Destination.Fqdn = 域名，Destination.Addr 无效
ATYP=IPV4/IPV6  -> Destination.Addr = IP，Destination.Fqdn = ""
```

如果 Postman 使用 `socks5h://` 发送域名，那么初始元数据是：

```go
metadata.Destination.Addr = netip.Addr{}
metadata.Destination.Fqdn = "jhjmanagement.jhj515.com"
metadata.Destination.Port = 443
```

如果 Postman 使用 `socks5://` 发送 IP，也就是本次实际观察到的行为，那么初始元数据是：

```go
metadata.Destination.Addr = <目标 IP>
metadata.Destination.Fqdn = ""
metadata.Destination.Port = 443
```

`adapter.NewUpstreamHandler` 将这个目标地址写入路由元数据：

```go
func (w *myUpstreamHandlerWrapper) NewConnectionEx(
    ctx context.Context,
    conn net.Conn,
    source M.Socksaddr,
    destination M.Socksaddr,
    onClose N.CloseHandlerFunc,
) {
    myMetadata := w.metadata
    if source.IsValid() {
        myMetadata.Source = source
    }
    if destination.IsValid() {
        myMetadata.Destination = destination
    }
    w.connectionHandler(ctx, conn, myMetadata, onClose)
}
```

随后 SOCKS 入站的 `newUserConnection` 补充入站信息：

```go
metadata.Inbound = h.Tag()
metadata.InboundType = h.Type()
h.router.RouteConnectionEx(ctx, conn, metadata, onClose)
```

对于当前配置，得到：

```go
metadata.Inbound = "socks-in"
metadata.InboundType = "socks"
```

### 3.1 `metadata.Domain` 与 `metadata.Destination.Fqdn` 的区别

这两个字段来源不同：

```go
type InboundContext struct {
    Destination M.Socksaddr // SOCKS5 CONNECT 给出的实际目标
    Domain      string      // 嗅探或反查得到的域名
}
```

具体区别是：

| 字段 | 来源 | 当前 IP 型 SOCKS5 请求中的值 |
|---|---|---|
| `Destination.Addr` | SOCKS5 CONNECT | 目标 IP |
| `Destination.Fqdn` | SOCKS5 CONNECT | 空字符串 |
| `Domain` | 嗅探前可能为空；TLS 嗅探后为 SNI | `jhjmanagement.jhj515.com` |

因此，SNI 嗅探成功后不能把 `metadata.Domain` 和
`metadata.Destination.Fqdn` 当作同一个字段。

### 3.2 SOCKS5 成功响应和 TLS ClientHello 的先后关系

SOCKS 解析器传给路由的是一个 `NewLazyConn`。成功响应不是在解析
`request.Destination` 后立即写出，而是在这个连接第一次被读取或写入时写出。

路由执行 `sniff` 时会尝试读取连接：

```text
route actionSniff
  ↓
PeekStream -> conn.Read
  ↓
LazyConn 先发送 SOCKS5 CONNECT 成功响应
  ↓
Postman 收到成功响应
  ↓
Postman 发送 TLS ClientHello
  ↓
sniff 读取到 ClientHello
```

因此，在调试日志中可能先看到 SOCKS 入站连接，然后才看到 TLS 嗅探结果。

### 3.3 如果 Postman 实际填写的是 10808

`10808` 是 `mixed-in`。如果 Postman 在 `10808` 上使用 SOCKS5，`mixed` 会读取第一个字节：

```go
switch headerBytes[0] {
case socks4.Version, socks5.Version:
    return socks.HandleConnectionEx(...)
default:
    return http.HandleConnectionEx(...)
}
```

SOCKS5 的第一个字节是 `0x05`，因此进入 `socks.HandleConnectionEx`。即使入口是
`mixed-in`，也不会进入 HTTP CONNECT 分支。

## 4. 为什么 `/user/login` 不会被路由代码看到

HTTPS 中，SOCKS5 代理首先只处理目标地址。本次实际发送的是：

```text
<目标 IP>:443
```

当 SOCKS5 TCP 隧道建立后，Postman 发送的 HTTPS 请求类似：

```http
<METHOD> /user/login HTTP/1.1
Host: jhjmanagement.jhj515.com
```

但这条 HTTP 请求已经位于 TLS 加密内容中。TLS ClientHello 只公开握手参数，不包括 `/user/login`。

因此，SNI 分析只能得到：

```text
jhjmanagement.jhj515.com
```

不能从 SNI 得到：

```text
/user/login
```

## 5. `matchRule` 如何进入 `sniff`

当前配置中的规则是：

```json
{
  "action": "sniff"
}
```

这条规则没有域名、端口或协议条件，因此会匹配所有经过该路由的流量。

相关代码位于 [route/route.go](route/route.go) 的 `matchRule`：

```go
switch action := currentRule.Action().(type) {
case *R.RuleActionSniff:
    newBuffer, newPacketBuffers, newErr := r.actionSniff(
        ctx,
        metadata,
        action,
        inputConn,
        inputPacketConn,
        buffers,
        packetBuffers,
    )
    if newBuffer != nil {
        buffers = append(buffers, newBuffer)
    } else if len(newPacketBuffers) > 0 {
        packetBuffers = append(packetBuffers, newPacketBuffers...)
    }
    if newErr != nil {
        fatalErr = newErr
        return
    }
}
```

执行 `sniff` 后会继续检查动作类型：

```go
actionType := currentRule.Action().Type()
if actionType == C.RuleActionTypeRoute ||
    actionType == C.RuleActionTypeReject ||
    actionType == C.RuleActionTypeHijackDNS {
    selectedRule = currentRule
    break match
}
```

`sniff` 不是终止动作，因此匹配不会在这里停止。

## 6. `actionSniff` 选择了哪些嗅探器

`actionSniff` 位于 [route/route.go](route/route.go)。

当前配置没有指定：

```json
{
  "action": "sniff",
  "sniffer": ["tls"]
}
```

因此会使用默认的流嗅探器列表：

```go
streamSniffers = []sniff.StreamSniffer{
    sniff.TLSClientHello,
    sniff.HTTPHost,
    sniff.StreamDomainNameQuery,
    sniff.BitTorrent,
    sniff.SSH,
    sniff.RDP,
}
```

这些嗅探器的用途如下：

| 嗅探器 | 识别内容 | 主要输出 |
|---|---|---|
| `TLSClientHello` | TLS 握手和 SNI | `Protocol=tls`、`Domain=<SNI>` |
| `HTTPHost` | 明文 HTTP Host 头 | `Protocol=http`、`Domain=<Host>` |
| `StreamDomainNameQuery` | DNS over TCP 查询 | `Protocol=dns` |
| `BitTorrent` | BitTorrent 握手 | `Protocol=bittorrent` |
| `SSH` | SSH Banner | `Protocol=ssh`、`Client=<客户端>` |
| `RDP` | RDP 报文特征 | `Protocol=rdp` |

对于本文的 HTTPS 请求，`TLSClientHello` 是第一个嗅探器，并且会识别成功。
后续的 `HTTPHost` 等嗅探器不会继续执行。

## 7. `PeekStream` 如何读取连接开头的数据

`PeekStream` 位于 [common/sniff/sniff.go](common/sniff/sniff.go)：

```go
func PeekStream(
    ctx context.Context,
    metadata *adapter.InboundContext,
    conn net.Conn,
    buffers []*buf.Buffer,
    buffer *buf.Buffer,
    timeout time.Duration,
    sniffers ...StreamSniffer,
) error {
    if timeout == 0 {
        timeout = C.ReadPayloadTimeout
    }

    deadline := time.Now().Add(timeout)

    for {
        err := conn.SetReadDeadline(deadline)
        if err != nil {
            return E.Cause(err, "set read deadline")
        }

        buffer.ReadOnceFrom(conn)
        conn.SetReadDeadline(time.Time{})

        for _, sniffer := range sniffers {
            reader := io.MultiReader(common.Map(
                append(buffers, buffer),
                func(it *buf.Buffer) io.Reader {
                    return bytes.NewReader(it.Bytes())
                },
            )...)

            err = sniffer(ctx, metadata, reader)
            if err == nil {
                return nil
            }
        }
    }
}
```

实际代码使用 `io.MultiReader` 合并已经读取的缓冲区，简化后的含义是：

1. 设置读取超时，默认值是 `300ms`。
2. 从连接读取一次数据。
3. 将已读取数据交给各个嗅探器。
4. 如果数据还不够，嗅探器返回 `ErrNeedMoreData`。
5. `PeekStream` 继续读取，然后重新尝试。
6. 任意嗅探器成功，就结束嗅探。

这里的“读取”不会直接丢弃数据，读取内容保存在 `sniffBuffer` 中，稍后会放回连接。

## 8. `TLSClientHello` 如何提取 SNI

核心代码位于 [common/sniff/tls.go](common/sniff/tls.go)：

```go
func TLSClientHello(
    ctx context.Context,
    metadata *adapter.InboundContext,
    reader io.Reader,
) error {
    var clientHello *tls.ClientHelloInfo

    err := tls.Server(
        bufio.NewReadOnlyConn(reader),
        &tls.Config{
            GetConfigForClient: func(
                argHello *tls.ClientHelloInfo,
            ) (*tls.Config, error) {
                clientHello = argHello
                return nil, nil
            },
        },
    ).HandshakeContext(ctx)

    if clientHello != nil {
        metadata.Protocol = C.ProtocolTLS
        metadata.Domain = M.ParseSocksaddrHostPort(
            clientHello.ServerName,
            0,
        ).Fqdn
        return nil
    }

    if errors.Is(err, io.ErrUnexpectedEOF) {
        return E.Cause1(ErrNeedMoreData, err)
    }
    return err
}
```

下面逐部分解释。

### 8.1 创建只读连接

```go
bufio.NewReadOnlyConn(reader)
```

嗅探阶段只有读取语义，不会真正向客户端发送 TLS ServerHello。

### 8.2 使用 Go TLS 服务端解析 ClientHello

```go
tls.Server(conn, tlsConfig).HandshakeContext(ctx)
```

这里把嗅探数据当作客户端发来的 TLS ClientHello。Go 标准库会解析：

```text
TLS Record
  └── Handshake
      └── ClientHello
          └── Extensions
              └── server_name
                  └── jhjmanagement.jhj515.com
```

项目没有自行读取 TLS 扩展的字节偏移，而是依赖 Go 的 TLS 实现完成解析。

### 8.3 捕获 `ClientHelloInfo`

```go
GetConfigForClient: func(
    argHello *tls.ClientHelloInfo,
) (*tls.Config, error) {
    clientHello = argHello
    return nil, nil
},
```

Go 解析完 ClientHello 后会调用这个回调，并将 `*tls.ClientHelloInfo` 传进来。

回调把指针保存到外部变量：

```go
clientHello = argHello
```

即使随后真正的 TLS 服务端握手因为只读连接或没有证书而失败，只要 ClientHello 已经被解析，外部变量就已经有值。

### 8.4 读取 `ServerName`

```go
clientHello.ServerName
```

`ClientHelloInfo.ServerName` 是 Go 从 TLS `server_name` 扩展中解析出的 SNI。

对于本文请求：

```go
clientHello.ServerName == "jhjmanagement.jhj515.com"
```

### 8.5 写入路由元数据

```go
metadata.Protocol = C.ProtocolTLS
metadata.Domain = M.ParseSocksaddrHostPort(
    clientHello.ServerName,
    0,
).Fqdn
```

最终得到：

```go
metadata.Protocol == "tls"
metadata.Domain == "jhjmanagement.jhj515.com"
```

`ParseSocksaddrHostPort` 用于规范化主机地址。这里的 SNI 本身已经是域名，因此结果仍然是原域名。

## 9. 为什么嗅探后真正的 TLS 握手不会丢失数据

`PeekStream` 已经从连接中读取了 ClientHello。如果直接继续连接，真正的 TLS 握手将看不到这段数据。

因此 `actionSniff` 返回读取成功的缓冲区：

```go
if !sniffBuffer.IsEmpty() {
    buffer = sniffBuffer
} else {
    sniffBuffer.Release()
}
```

`matchRule` 保存缓冲区：

```go
if newBuffer != nil {
    buffers = append(buffers, newBuffer)
}
```

`routeConnection` 在确定出站后，将缓冲区重新包装到连接前面：

```go
for _, buffer := range buffers {
    conn = bufio.NewCachedConn(conn, buffer)
}
```

`CachedConn.Read` 的逻辑简化后是：

```go
func (c *CachedConn) Read(p []byte) (int, error) {
    if c.buffer != nil {
        return c.buffer.Read(p)
    }
    return c.Conn.Read(p)
}
```

所以消费者的读取顺序是：

```text
先读取 sniff 缓存的 TLS ClientHello
            ↓
再读取原始连接中的后续 TLS 数据
```

这样 TLS 握手收到的数据与嗅探前完全一致。

## 10. 当前请求的完整结果

针对：

```text
https://jhjmanagement.jhj515.com/user/login
```

经过 `socks-in` 的 SOCKS5 CONNECT 和 `sniff` 后：

```go
metadata.Inbound = "socks-in"
metadata.InboundType = "socks"
metadata.Protocol = "tls"
metadata.Domain = "jhjmanagement.jhj515.com"

metadata.Destination.Addr = <目标 IP>
metadata.Destination.Fqdn = ""
metadata.Destination.Port = 443
```

当前路由规则没有继续使用这些字段来匹配出站，因此最终流程是：

```text
sniff
  ↓
Protocol=tls, Domain=jhjmanagement.jhj515.com
  ↓
没有终止规则
  ↓
route.final = direct
  ↓
通过 direct 出站连接 <目标 IP>:443
```

`/user/login` 仍然由 Postman 放入加密的 HTTPS 请求中，sing-box 的 SNI 嗅探不解析该路径。

`metadata.Domain` 只用于规则匹配、日志和追踪信息。当前没有启用目标覆盖，
因此 SNI 不会替换 `metadata.Destination`，实际拨号目标仍然是 SOCKS5 请求中的 IP。

## 11. 相关边界情况

### 11.1 普通 HTTP 请求

如果访问的是：

```text
http://example.com/path
```

则没有 TLS ClientHello。`HTTPHost` 嗅探器会从明文 HTTP 请求中读取：

```http
Host: example.com
```

并设置：

```go
metadata.Protocol = "http"
metadata.Domain = "example.com"
```

### 11.2 另一种入口方式：HTTP CONNECT

如果客户端使用 HTTP 代理而不是 SOCKS5，可能发送：

```http
CONNECT jhjmanagement.jhj515.com:443 HTTP/1.1
Host: jhjmanagement.jhj515.com:443
```

例如浏览器连接 `mixed-in` 时，`mixed` 会发现第一个字节不是 SOCKS 版本，
于是进入 HTTP 处理。HTTP CONNECT 的目标解析位于
[sing/protocol/http/handshake.go](../go/pkg/mod/github.com/sagernet/sing@v0.9.7-0.20261023115459-5dc452e537bf/protocol/http/handshake.go)。

HTTP CONNECT 和 SOCKS5 的区别只在于如何获得初始目标地址。隧道建立后，
两者都会进入相同的 `RouteConnectionEx`、`matchRule`、`actionSniff` 和
`TLSClientHello` 流程。

当前 Postman 使用 SOCKS5，因此这不是本次请求的主路径。

### 11.3 为什么当前 SOCKS5 目标是 IP

Postman 使用 `socks5://` 时会先在本地解析 DNS，然后向 SOCKS5 入站发送目标 IP。
这正是本次请求的实际路径，初始元数据是：

```go
metadata.Destination.Addr = <目标 IP>
metadata.Destination.Fqdn = ""
metadata.Destination.Port = 443
metadata.Domain = "" // 没有反向映射时为空
```

随后 TLS 嗅探仍会得到：

```go
metadata.Protocol = "tls"
metadata.Domain = "jhjmanagement.jhj515.com"
```

但默认不会因为嗅探结果自动改写实际连接目标。如果需要对基于 IP 的目标使用
域名出站，需要额外的目标覆盖。

如果改用 `socks5h://`，Postman 不进行本地 DNS 解析，SOCKS5 请求携带域名，
此时初始元数据才会是：

```go
metadata.Destination.Addr = netip.Addr{}
metadata.Destination.Fqdn = "jhjmanagement.jhj515.com"
metadata.Destination.Port = 443
```

当前规则只有：

```json
{
  "action": "sniff"
}
```

没有启用 `OverrideDestination`，所以 SNI 只写入 `metadata.Domain`。

### 11.4 没有 SNI

如果客户端没有发送 SNI，则：

```go
clientHello.ServerName == ""
```

此时仍然可能识别出：

```go
metadata.Protocol == "tls"
```

但 `metadata.Domain` 不能从 SNI 获得。对于本文基于域名的 HTTPS 请求，
Postman 使用的 TLS 客户端通常会发送 SNI。

### 11.5 QUIC/HTTP3

本文分析的是 TCP 上的 TLS。QUIC 使用 UDP，由另一组数据包嗅探器处理，包括：

```go
sniff.QUICClientHello
```

QUIC 嗅探同样可以提取协议、SNI 和部分客户端信息，但调用路径不是本文的 `PeekStream`。

## 12. 一句话总结

`sniff` 首先读取连接开头的 TLS ClientHello，把它交给 Go 标准库 TLS 解析器；Go 在
`GetConfigForClient` 回调中提供 `ClientHelloInfo`，项目读取
`ClientHello.ServerName`，将 SNI 写入 `metadata.Domain`，然后把嗅探时读取的 ClientHello
通过缓存连接放回，继续真正的 TLS 握手和转发。`metadata.Domain` 与
`metadata.Destination.Fqdn` 是两个不同字段；当前 IP 型 SOCKS5 请求中，
`Destination.Fqdn` 为空，direct 仍按 `Destination.Addr` 连接目标 IP。
