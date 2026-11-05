# v2 WebRTC 通话媒体

2026-11-05 下述媒体与播放规则已通过离线验证，网页 Engine 已发布，模块须更新后生效。App 发布进度见[发布记录](../../docs/CLOUD_AUDIO_DEPLOYMENT_20261105.md)，验证及兼容边界见[重构记录](../../docs/CLOUD_AUDIO_REBUILD_20261105.md)。

通话媒体使用 WebRTC：iPad／iPhone 与模块之间建立一条 DTLS-SRTP 音频连接，ECS 转交 SDP 并提供 TURN 中继，USB 本地经模块 USB 地址直连。App、ECS control／media、Agent 与 helper 必须配套更新。

2026-11-03 源码将双向 Opus 目标码率提高到 96 kbps；这是兼容现有 WebRTC 的参数调整。模块须同时更新 Agent（SDP 应答）和 helper（采集编码器）。现有 App 的 libwebrtc 按应答设置上行目标，ECS 仍透明转发。2026-11-04 已通过 Workbench 发布两平台网页 Engine 包，模块须更新 Engine 后生效；本轮未安装真机。

## 媒体

| 项目 | 配置 |
| --- | --- |
| 编解码 | Opus，RTP 时钟 48 kHz，单声道编码 |
| 帧长 | 20 ms 主帧；协商 RED 后附带最多两帧先前的原始 Opus 包 |
| 模块编码 | 16 kHz 输入，96 kbps VBR 目标码率，宽带上限，AUDIO 应用（保留已解码蜂窝音频，避免 VOIP 输入整形），复杂度 3，带内 FEC 开启（按 10% 丢包率），DTX 关闭 |
| 模块应答偏好 | `a=fmtp:<pt> minptime=10;useinbandfec=1;maxplaybackrate=16000;sprop-maxcapturerate=16000;maxaveragebitrate=96000` 与 `a=ptime:20` |
| 安全 | DTLS-SRTP；证书指纹随已认证信令交换 |
| 传输 | 一条 `sendrecv` 音频轨道，BUNDLE 与 RTCP-mux；不使用数据通道或视频 |

App 使用 libwebrtc（stasel/WebRTC 155.0.0）的采集、回声消除、Opus 与 NetEQ 抖动缓冲。音频由 `RTCAudioSession` 手动控制：有 CallKit 时随 `didActivate`／`didDeactivate` 启停；没有 CallKit 时由媒体会话自行激活和释放语音会话。

模块侧 Agent 内嵌 Pion 处理 ICE、DTLS、SRTP 与 RTP，原生 helper 用定点 libopus 编码采集、解码播放；Go Agent 保持 `CGO_ENABLED=0`，不编解码。

## 中继与网络

蜂窝模块处于对称型 NAT 后，云端会话的 Agent 只收集 relay 候选；App 收集全部候选，由 ICE 选择。ECS 的 airsim-media 以主机网络运行 TURN：UDP 3478 为主、TCP 3478 回退，中继端口为 UDP 49160–49359，对外通告 `AIRSIM_TURN_IP`。中继拒绝许可私网、回环、链路本地、CGNAT 与多播地址，只允许公网对端（含中继自身公网地址，两个 relay 候选可经回环互通）。TURN 只转发，不解密媒体。

凭据为 TURN REST 形式：用户名 `<到期 Unix 秒>:<session_id>:<client|agent>`，密码为共享密钥对用户名的 HMAC-SHA1 再 Base64，realm `airsim`。有效期30分钟，覆盖最长媒体会话，期间的分配刷新仍可鉴权。中继不保存会话状态，按用户名中的到期时间与签名校验。

USB 本地会话不下发 ICE 服务器，Agent 只在 USB 地址（如 `192.168.225.1`）上收集 host 候选，App 经 ECM 链路直连。

## 信令

采用非 trickle ICE：一次性交换含候选的完整 SDP，SDP 最长 32768 字节。

1. App 在所有权确认后 `POST /v2/modules/{module_id}/calls/{call_id}/media-sessions`，body `{request_id,connection_epoch,generation,codec:"opus"}`。control 按 reservation 行锁校验所有权、代次与 active 通话，返回201 `{session_id,expires_at,ice_servers}`；`ice_servers` 为 `[{urls,username,credential}]`，云端为 `turn:<ip>:3478?transport=udp` 与 `transport=tcp` 两个地址。同一 request_id 重试返回同一结果。同一 App 对同一通话已有未关闭的会话时，新会话通过校验后关闭旧会话（原因 `replaced`，已发出 `media_start` 的向 Agent 发 `media_stop`）；其他 App 或其他通话的未关闭会话仍返回409 `session_conflict`。
2. App 用这些服务器创建 PeerConnection，候选收集完成、或首个可用候选（云端为 relay，USB 为 host）出现250 ms后（最长8秒）`POST .../media-sessions/{session_id}/offer`，body `{sdp}`，须在会话创建后30秒内提交。
3. control 再次锁定 reservation 校验所有权，只发出一次 `media_start` `{request_id,session_id,call_id,agent_boot_id,backend_epoch,client_installation_id,generation,expires_at,offer,ice_servers}`；`expires_at` 为10秒后的应答截止时间，Agent 允许最多5秒时钟偏差。
4. Agent 校验通话所有权后创建 PeerConnection，候选收集（最长8秒）完成后回传 `media_answer` `{session_id,answer}`，随后在 ICE 与 DTLS 连接期间启动 helper。模块同时只有一个媒体会话：新会话先停止旧会话，并等旧 helper 退出后再启动自己的 helper。control 在 offer 请求中返回200 `{sdp}`；相同 offer 的重试返回同一应答，不同 offer 返回409。Agent 拒绝或关闭返回502 `media_unavailable`，10秒内无应答返回504 `media_timeout`；这两类失败不影响通话控制状态。
5. 双方 ICE 与 DTLS 连接后开始媒体，Agent 上报 `media_status` `streaming`。

USB 本地使用模块本机 HTTPS 的同一路径与字段，响应中 `ice_servers` 为空数组；Agent 在请求内直接返回应答。

## 期限与失败

| 端 | 条件 | 结果 |
| --- | --- | --- |
| control | 会话创建后30秒未提交 offer、提交后10秒无应答、所有权或代次变化 | 关闭会话，向在线 Agent 发 `media_stop` |
| control | 模块控制连接断开或被新连接取代 | 关闭该连接下的会话记录；Agent 侧媒体不受影响 |
| Agent | 从 `media_start` 起20秒内未完成应答、helper 启动与 ICE 连接 | `media_setup_timeout` |
| Agent | 5秒没有收到有效音频 RTP，或 ICE 断开后未在5秒内恢复 | `rtp_timeout`／`ice_failed` |
| App | 提交应答后10秒未连接、断开超过3秒、3秒没有入站包 | 关闭连接，为同一通话自动建立新会话 |
| App | 新鲜快照显示通话结束或不再 active、所有权转移、模块启动或后端代次变化 | 关闭连接，不再恢复 |

单次媒体会话最长30分钟。挂断、lease 撤销、代次变化或任一端关闭时双方关闭 PeerConnection 与 helper。

## 断线与恢复

模块与运营商之间的通话不经过 ECS，模块到 ECS 或 App 到 ECS 的链路中断都不结束通话：

- **控制连接**：Agent 每次连接尝试的 discovery 与 mTLS 握手各限10秒，断开后按250 ms 起、5秒封顶的带抖动退避重连；网络恢复后下一次尝试即可连上。控制连接断开不取消媒体：媒体走 TURN／USB 路径，不经过控制连接，仍以证书到期与30分钟为上限。
- **所有权**：重连只换连接代次，ECS reservation 与 Agent 的所有权都不含连接代次，因此保持不变。App 看到同一模块、同一启动与后端代次、通话仍在的新鲜快照时，把自己持有的通话绑定到新连接代次并持久化；CallKit 系统通话同步改绑。模块离线或快照过期期间系统通话与运行中的音频都保持，只有看到通话结束、模块重启或后端代次变化才结束。
- **媒体**：运行中的音频不因控制链路状态停止。媒体连接失败后，App 在通话仍归属自己时立即以新 request_id 建立新会话，连续失败按1、2、4、5秒间隔重试，直到连接恢复或通话结束；新会话保留静音和音频输出选择。ECS 与 Agent 都以新会话替换同一通话的旧会话。
- **App 与 ECS**：通话期间状态轮询失败最多间隔2秒重试；模块重连后 App 在快照所示连接代次与模块目录不一致时立即刷新目录，后台也能完成改绑。

不使用 ICE 重启：每次恢复都是完整的新会话，覆盖模块换 IP、TURN 分配失效和控制连接重建等情况。

## 模块内部

Agent 与 helper 之间沿用 Unix 媒体通道，帧格式为 ASMP v3：40 字节头（`ASMP`、版本 3、方向、头长 40、会话 UUID、64 位序号、载荷长度、标志）后接一个 Opus 包，载荷最长1275字节。标志 0 为普通 Opus 包；1 为丢失帧，载荷为空，解码端执行 PLC；2 为 FEC，载荷是下一包，解码端用其带内冗余恢复丢失帧。helper ready 声明 `codec:"opus"`、`codec_frame_us:20000`、16 kHz、320 样本。

helper 就绪起 Agent 每 20 ms 向 helper 送出一帧；连接建立前送丢失帧，期间采集包丢弃。协商 `audio/red` 时，双方以 RFC 2198 发送主 Opus 包与此前最多两包的逐字节副本；未提供可匹配 RED 的对端保持纯 Opus。RED 内层类型使用实际协商的 Opus PT，时间戳偏移使用 48 kHz 时钟；RED 只存在于网络端，ASMP 仍是一个 20 ms Opus 包。业务 API 的 `codec:"opus"` 不变，ECS 不需要解析 RED。

模块按 RTP 时间戳而非到达顺序安排播放，起播等待 60 ms；每个截止时间消费一格，缺失时也推进：优先原包／RED 精确副本，其次用下一包尝试带内 FEC，最后 PLC。64 格有界缓存拒绝异常时间戳与过期帧；时间戳按 32 位回绕处理。调度晚醒跳过过期音频，不以 5 ms 间隔补发。连续缺失并确认三包持续晚到，或三包持续领先超过 160 ms，重建 60 ms 起播时间线并统计 `playout_resyncs`，避免永久欠载或无界延迟。这是有界重同步，不是无损时钟漂移补偿。

模块采集编码后立即发送；ASMP 缺口同步推进 RTP 时间戳；RTP 序号只随实际发送包递增，缺口后清空 RED 历史。helper 的采集 xrun 至少暴露一个帧缺口。helper 四帧队列和空队列最多 15 ms 等待保留，播放前增加硬件 DELAY 反馈：排队高于 40 ms／硬件起播阈值时等待，单次最多 10 ms；EG25 16 kHz 下写入后目标不超过约 60 ms，物理 buffer 仍为 256×8。DELAY 不可用时回退既有写入路径，硬件排队不前进则按两秒预算结束。实际驱动支持仍待验收。实时调度优先级降低调度干扰，不能保证没有内核阻塞或资源停顿。

## 诊断

模块本机 `/v2/local/cloud/media-stats` 与 App Debug 记录只保存计数：收发包、缺失帧、晚到、RED 精确恢复、FEC 尝试、PLC、过期帧、无效包、重复包与重同步、停顿次数与最长停顿、会话期间 Agent 的垃圾回收次数与存活堆、抖动缓冲时延、往返时间与选中的候选类型。不保存音频、SDP 原文、凭据或号码。
