# 合成媒体网络探针

此工具用于隔离诊断 WSS 网络吞吐与 TCP 状态，仅发送合法 ASMP v2 erasure 帧，不拨号、不接触 HAL。它不是音频验证工具；探针完成或吞吐正常不能据此宣称真实音频、通话或端到端音频验收通过。

## 配置与运行

由主控为每次执行生成独立的合成 session 和单次 ticket，并安排对应测试对端。不得复用真实通话媒体会话或已使用的票据。工具不生成会话、不重连、不重试票据。

唯一参数是配置文件路径。配置必须为普通文件、非符号链接、权限恰好 `0600`，且不超过 4096 字节。配置只允许以下字段：

| 字段 | 要求 |
| --- | --- |
| `url` | 固定为 `wss://airsim.eric3u.cc/v2/media`，不能添加查询参数或替换端点 |
| `session_id` | 主控提供的小写 UUID v4 |
| `ticket` | 主控提供的 32 字节票据，以 64 个小写十六进制字符表示 |
| `seconds` | 固定为 `20` |
| `send_interval_ms` | 可省略，缺省 `20`；显式值只允许 `20` 或 `200` |

配置中的未知、重复、缺失必需字段以及 null 值均被拒绝。不要把实际配置或票据放入仓库。

```sh
chmod 600 /secure/path/netprobe.json
/path/to/airsim-netprobe-tcpinfo /secure/path/netprobe.json
```

20 ms 模式约发送 50 帧/秒，用于标准媒体发送节拍的网络诊断；200 ms 模式约发送 5 帧/秒，用于主控安排的低速对照。两种模式始终使用 120 字节、方向 2、递增序号的合法 ASMP v2 帧，flags=1、payload全零，不改变协议或帧格式。接收方向 1 时校验长度、头部、会话和序号。

TLS 使用系统根证书或通过 `SSL_CERT_FILE` 指定的非空公开 CA，并保留正常证书校验。Agent 配置中的 `server_ca_pem` 为空时，沿用实际系统证书包及启动器的 `SSL_CERT_DIR`，不能将空文件作为 CA 覆盖系统信任，禁用代理、重定向与压缩，子协议固定为 `airsim.media.v2`。配对后运行 20 秒；连接与配对总预算 20 秒，认证读写各最多 3 秒；媒体写超时 100 ms、读超时 2 秒，进程硬限时 45 秒。无应用帧队列。

## 输出

只输出 JSON 统计及退出类别：发送/接收帧数、序号缺口、耗时、最大接收间隔，以及 TCP 采样。不会打印 IP、票据、配置、PCM 或原始错误。

TCP 每秒采样一次，最多保留 45 条，在最终 JSON 的 `tcp_samples` 中输出：

- `elapsed_ms`、`local_port`、`tcp_info_available`
- `rtt_us`、`rto_us`
- `snd_cwnd`、`unacked`、`total_retrans`（段数）

Linux 从本工具 Transport 的 DialContext 所保存的 TCPConn 读取 TCP_INFO；内核未支持的字段省略，读取失败标记为不可用。非 Linux 平台使用 stub，仍能验证采样周期和本地端口。最终时限边界上可能发送了最后一帧但尚未读取其回包。

## 构建与测试

使用 Go **1.24.13**，在 `module/airsim-agent` 模块根目录执行；沿用该模块现有依赖，不建立独立模块。

本机构建（不运行生产探针）：

```sh
go version
GOTOOLCHAIN=local go build -o /tmp/airsim-netprobe-host ./tools/media-netprobe
```

Linux ARM64 静态产物：

```sh
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 GOTOOLCHAIN=local go build -trimpath -ldflags='-s -w' -o /tmp/airsim-netprobe-tcpinfo ./tools/media-netprobe
```

本机验证：

```sh
GOTOOLCHAIN=local go test -race -v ./tools/media-netprobe
GOTOOLCHAIN=local go vet ./tools/media-netprobe
GOOS=linux GOARCH=arm64 GOTOOLCHAIN=local go vet ./tools/media-netprobe
```

测试使用本地 TLS fixture，不访问生产端点；两种节拍各运行 20 秒，另覆盖严格配置、帧/配对校验、读超时、TCP 采样周期与无 IP 输出。

二进制和临时凭据不纳入仓库；实机、云端及通话诊断由主控单独调度。

当前探针使用120字节ASMP v2 erasure包和LC3格式握手，只验证网络帧传输；它不生成有效LC3音频，也不能用于音质验收。
