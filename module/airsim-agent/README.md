# airsim-agent v2

本目录为独立 Go 工程 `airsim.local/airsim-agent`，当前源码版本 `2.0.0-dev.lc3`，依赖 godbus/dbus v5.2.2 与其 x/sys v0.27.0，不依赖旧 Agent 或 RM500 CLI；未配置云端时可独立运行。依据主控维护的 [R2 契约](../../docs/RM500_AGENT_R2.md)。R1 已完成主控验收，其 [证据](R1_TESTING.md) 保持为历史记录；R2 功能实机链路与重启后命令去重验证通过，短信重复到达/延迟仍未解释，voice_ready=false；详细边界见 [R2 记录](R2_TESTING.md)。RM500U 的 headless 启动与恢复见[开机启动说明](RM500U_AUTOSTART.md)。

支持 `rm500u-embedded` 与 `eg25-qdc507` 两个精确平台。RM500U 使用 oFono，EG25 使用 Agent 内的 AT 控制后端，两者共用 HAL、串行协调器、命令去重、本机 API、云端协议与媒体会话。EG25 固件、ARMv7 构建、DATA11、驱动、16 kHz mmap 音频和安装说明见 [EG25](../eg25/README.md)。短信 PDU 使用 `github.com/warthog618/sms v0.3.0`。

云端连接将 discovery 与设备 mTLS 控制握手分别限制为 30 秒和 15 秒。云媒体建连预算最多 20 秒，并受票据绝对到期时间和父上下文截止限制；每地址 TLS 仍为 15 秒、认证写读为 3 秒。媒体桥关闭保留首个固定原因：`cloud_read/write_timeout/closed`、`cloud_remote_closed`、`local_read/write_timeout/closed`、`cloud_invalid_frame`、`local_invalid_frame` 或 `media_cancelled`；清理取消不覆盖首错，不记录原始错误或媒体内容。建连失败按 `media_connect_dns`、`media_connect_tls`、`media_connect_refused`、`media_connect_timeout`、`media_connect_tcp_timeout`、`media_connect_tls_timeout`、`media_connect_http`、`media_connect_dial`、`media_connect_unknown` 分类；取消使用 `media_cancelled`。跨网 Cloudflare 路径可能明显慢于局域网测试，不能沿用原 5 秒总预算；外层仍按有界退避重连。

R3 已实现原生音频 helper、本机媒体会话与通话 lease；本机验证和构建见 [R3 交接记录](R3_TESTING.md)及[构建证据](R3_BUILD_EVIDENCE.json)。R3 裁决04构建已部署，当前固件、厂商16kHz语音时钟下75.004秒双向内容验收通过；用户确认听清提示语及自己的回声。运行时 voice_ready=false、verification=unverified 仍保留为实验发布门槛。权威事实见[验收证据](R3_ACCEPTANCE_EVIDENCE.json)与[历史诊断证据](R3_DIAGNOSTIC_EVIDENCE.json)。下文 R2 证据保留为历史基线。

设备配对在现有身份上增加网页配对所需的新鲜 Ed25519 证明，不导出私钥，也不新增网络监听。实现和验证边界见 [配对记录](PAIRING_TESTING.md)。

## 范围

R1 AT 只读采样与精确 RM500 profile 校验继续保留。R2 新增长期私有 oFono D-Bus 连接、串行控制协调器、有界持久去重记录及本机呼叫/短信控制。R3 Audio 已通过上述限定范围的本地内容验收，运行时 voice_ready 固定 false。

- `internal/ofono`：有界信号队列、连接/发现、快照与指定业务方法。
- `internal/control`：串行状态、两个独立 worker、epoch/期限/状态门禁与事件关联。
- `internal/journal`：不含正文或号码的原子操作记录。
- `internal/identity`、`internal/at`、`internal/platform/rm500u`、`internal/state`：沿用 R1 身份、串口、平台和只读快照职责。
- `internal/transport/local`：0600 Unix socket API，handler 不直接访问设备。

## LC3 音频

当前媒体格式固定为 LC3、16 kHz 单声道，解码 PCM 为 S16LE、320 samples/20 ms。每个 ASMP v2 包包含两个 10 ms、40 字节 LC3 帧，总长 120 字节；云端和 USB 使用同一格式。Go 继续禁用 CGO，编解码由原生 helper 和 App 执行。Agent 的 `hello.media_codec` 为 `lc3`；媒体格式握手和 helper ready 必须精确匹配，旧 PCM helper 不能接入。

待处理接听命令经定时轮询或 `receipt_query` 返回 `accepted`／`observed` 时，统一更新通话声明和媒体所有权，后续 `media_start` 使用同一客户端与 generation。回执查询即使状态未变化也返回结果。

缺包通过 erasure 标志传给解码端执行 PLC；桥接重写 session/sequence 时保留该标志及未补偿的源序号缺口；已补PLC的空槽抵扣后续缺口，避免重复补偿。`zero_frames` 统计桥接补出的 erasure 包，helper 的 `silence_samples` 仍只统计实际全零 PCM。硬件路由、音频 lease、队列期限与 PCM 配置保持既有约束。Agent 与 helper 必须配套构建、切换和回滚；当前 LC3 尚未完成实机通话验收。

## 本机验证与构建

在本目录执行，使用 Go 1.24.13：

```sh
go test -race ./...
go vet ./...
GO=/path/to/go ./scripts/build.sh
```

构建固定 `CGO_ENABLED=0 GOOS=linux GOARCH=arm64`，输出 `dist/airsim-agent` 与 SHA-256。产物未签名，不是 OTA 包。

## 已授权部署辅助

`scripts/adb_device.py` 的 `Device(serial)` 每次构造都重新枚举 ADB、取得当前 transport ID、核对 Linux/aarch64/udx710-module。`shell` 校验设备侧退出码标记；`deploy` 将文件写入独立的 `/mnt/data/airsim-v2/releases/<hash前16位>/airsim-agent` 并复核设备 SHA-256，不覆盖已存在的不同内容。该 helper 仅用于本阶段开发部署。

设备运行参数：

```sh
<release-directory>/airsim-agent --profile rm500u-embedded --at-device /dev/smd1
```

持久目录 `/mnt/data/airsim-v2`，运行目录 `/run/airsim-v2`，均为 0700。实例先取得持久目录与运行目录两份 flock，再初始化身份；端口另持有按 rdev 命名的资源锁。身份在 `config/identity.json`（0600），私钥不返回接口或日志，也不要复制到主机。

R1 诊断接口保留在 `control.sock`（0600），仅接受 GET：

- `/healthz`：进程存活。
- `/readyz`：必要查询新鲜且 AT 同步时返回 200，否则 503。
- `/v2/local/capabilities`：本轮六类能力状态。
- `/v2/local/snapshot`：脱敏只读快照。

R2 增加 GET `/v2/local/control`、`/v2/local/calls`、`/v2/local/messages`、`/v2/local/commands/<UUID>` 和 POST `/v2/local/commands`。请求与动作精确结构见主控契约。业务接口可返回号码/正文，仅限本机受控调用；只读 snapshot 不含这些内容。

设备配对增加 GET `/v2/local/pairing` 和 POST `/v2/local/pairing/authorize`。前者只返回模块身份、服务绑定和连接状态；后者对网页生成的五分钟请求签名。两者仍只存在于 0600 Unix socket；调用方必须已经能访问该 socket。证明不替代手机确认，也不创建 App token。

云端使用 [R4](../../protocol/v2/R4.md) 的 HTTPS/WSS 与设备 mTLS，配对遵循 [PAIRING](../../protocol/v2/PAIRING.md)。未配置 `--usb-listen` 时本机不监听 TCP；EG25 启动器启用下述 USB v2 入口。Agent 不执行自行更新。RM500U 通过
BusyBox init 重启已退出进程，并由本机启动器等待串口和内核随机池就绪；网页通过
WebUSB 访问 0600 的 Unix socket。R3 音频仅在授权本地媒体会话及通话 lease 内运行。
消息正文仅保留进程内存；命令记录最多1024条且不自动淘汰。

## 停止与故障边界

正常 SIGTERM 停止新事务，让当前事务在原 5 秒预算内收完终止行；总退出预算 15 秒；R2 停止新命令、取消未提交项并让已提交调用在原预算内收敛，不自动挂断或删除消息。端口在支持 TCGETS 时保存并设置经验证的 raw 8N1 115200，正常关闭恢复原 termios；保持 CR 结尾。未知/超时事务关闭端口，保留 `at-inflight.json` 并停止所有 AT。存在该文件时重启只提供诊断，不打开设备；不得删除它绕过失败。主控决定后续恢复。

SIGKILL 实机验证只允许针对已核对的本轮 PID，且必须处于无在途标记的轮询间隔。该项已按空闲窗口完成，详见验收记录。

## R1 历史验收构建

SHA-256：`b9659d09758375ba8597654339d7b76f63603c7588134b478e7a9b3481569707`。原设备 PID 6367 已由本轮 R2 部署正常停止，release 保留；历史部署描述在 `/tmp/airsim-r1-run.json`。

最终构建与加固前构建的证据分别保存在 [最终连续观察](R1_EVIDENCE.json)、[最终生命周期](R1_LIFECYCLE.json) 与 [加固前历史记录](R1_PRE_HARDENING.json)，不混用 hash。

当前 R2 hash、最终进程与验收边界见 [R2_TESTING.md](R2_TESTING.md)、[业务证据](R2_BUSINESS_EVIDENCE.json)和[重启证据](R2_RESTART_EVIDENCE.json)；[初次只读观察](R2_EVIDENCE.json)保留为历史基线。实机业务测试由主控统一触发，执行会话交接后不并发操作设备。


## R3 验收范围与剩余门槛

75.004秒上下行各3750帧，外部序号零缺口、xrun为零（零字段省略）；helper input_drops=14，约0.37%，不能称零丢帧。silence_samples=5760为native16k样本，约0.36秒；echo_dropped=1435主要是主机提示语/非回声窗口主动丢弃，不是网络丢包。真实helper SIGKILL后的helper_exit、PCM关闭/子进程回收、新session成功、旧token拒绝、客户端EOF的media_read及通话结束lease_revoked均通过。最终无活动通话或自有helper，5c/5p/9c/55p closed，控制ready、身份保持。

精确构建哈希、资源采样及最终状态以[主控验收证据](R3_ACCEPTANCE_EVIDENCE.json)为准。此前失败保留在[主控诊断证据](R3_DIAGNOSTIC_EVIDENCE.json)，已由最后成功内容闭环取代。8kHz vendor时钟只有单测；30分钟/100会话长稳、Mac麦克风/扬声器、本段不覆盖后续 ECS/iOS 验证；Worker v2 未实现。没有保存录音或声音内容。

Agent 支持 `airsim-v2-callkit` 服务的 APNs 开启和关闭状态；`airsim-v2-r4.1` 仍要求 APNs 关闭。启用 ECS 推送前须使用支持该能力的 Agent。

Agent 将现有每 10 秒 AT 采样的信号同步到云端与 USB 快照，包含实际采样时间、CSQ RSSI 和 dBm；CSQ 99、采样不可用或超过 30 秒时报告不可用，不额外访问 AT。字段契约见 [R4](../../protocol/v2/R4.md)。

2026-10-31，EG25 已部署 `signal-20261031`，控制就绪、云端连接与采样时间推进均已确认。已配对 iPad 的真实 ECS 信号显示测试通过，App 显示 3 格，随后模块采样为 CSQ 18／−77 dBm。旧 USB 版本保留用于回滚；USB 直连的实体显示尚待验证。

Agent 在通话期间每秒发布状态快照，空闲时每五秒发布；App 保留八秒快照有效期。iOS Debug 诊断页支持真机三秒本机音频测试。

## USB 本地 v2

EG25 启动器在 USB 私网 `192.168.225.1:8577` 提供 v2 HTTPS/WSS，沿用现有通话、短信、ASMP 和音频 helper。首次授权和24小时续期通过 ECS 的已配对客户端及模块 mTLS；本地使用独立 P-256 TLS 证书、客户端授权、时间窗/nonce/HMAC。证书与授权在配置目录0600保存，App固定校验证书并将授权保存到Keychain。监听地址消失时关闭本地媒体；控制请求和媒体只走USB网卡。

EG25 启动器等待厂商建立 `bridge0=192.168.225.1/24`，再通过固件自带 DNSMasq 提供 USB DHCP，地址池为 `192.168.225.10–30`。已有 DHCP 服务时保留其所有权；等待和恢复在后台执行，不阻塞云端 Agent。此服务关闭 DNS，不下发 IPv4 默认路由或 DNS；厂商原有 IPv6 配置保持不变。

App空闲时可选择USB，已提交操作和通话保持原传输；本地与云端在Agent统一仲裁。命令关联持久保存客户端、generation及非敏感元数据，重启后查询原结果，不保存号码或短信正文。ECS在线撤销通过设备控制帧清除授权；完全离线时最迟24小时到期。完整契约见 [USB_LOCAL](../../protocol/v2/USB_LOCAL.md)。RM500保留 `--usb-listen <私网IPv4:端口>` 显式配置，当前未验收其USB地址。没有有效本地授权时不能纯离线首次配对；完全离线不保证唤醒已挂起/终止的App。
