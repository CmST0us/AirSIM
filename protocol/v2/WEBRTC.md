# v2 WebRTC 通话媒体

通话媒体使用 WebRTC：iPad／iPhone 与模块之间建立一条 DTLS-SRTP 音频连接，ECS 转交 SDP 并提供 TURN 中继，USB 本地经模块 USB 地址直连。App、ECS control／media、Agent 与 helper 必须配套更新。

## 媒体

| 项目 | 配置 |
| --- | --- |
| 编解码 | Opus，RTP 时钟 48 kHz，单声道编码 |
| 帧长 | 20 ms，每个 RTP 包一帧 |
| 模块编码 | 16 kHz 输入，32 kbps VBR，宽带上限，VOIP 应用，复杂度 3，带内 FEC 开启（按 10% 丢包率），DTX 关闭 |
| 模块应答偏好 | `a=fmtp:<pt> minptime=10;useinbandfec=1;maxplaybackrate=16000;sprop-maxcapturerate=16000;maxaveragebitrate=32000` 与 `a=ptime:20` |
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

1. App 在所有权确认后 `POST /v2/modules/{module_id}/calls/{call_id}/media-sessions`，body `{request_id,connection_epoch,generation,codec:"opus"}`。control 按 reservation 行锁校验所有权、代次与 active 通话，返回201 `{session_id,expires_at,ice_servers}`；`ice_servers` 为 `[{urls,username,credential}]`，云端为 `turn:<ip>:3478?transport=udp` 与 `transport=tcp` 两个地址。同一 request_id 重试返回同一结果。
2. App 用这些服务器创建 PeerConnection，候选收集完成、或首个可用候选（云端为 relay，USB 为 host）出现250 ms后（最长8秒）`POST .../media-sessions/{session_id}/offer`，body `{sdp}`，须在会话创建后30秒内提交。
3. control 再次锁定 reservation 校验所有权，只发出一次 `media_start` `{request_id,session_id,call_id,agent_boot_id,backend_epoch,client_installation_id,generation,expires_at,offer,ice_servers}`；`expires_at` 为15秒后的应答截止时间，Agent 允许最多5秒时钟偏差。
4. Agent 校验通话所有权后创建 PeerConnection，候选收集（最长8秒）完成后回传 `media_answer` `{session_id,answer}`，随后在 ICE 与 DTLS 连接期间启动 helper。control 在 offer 请求中返回200 `{sdp}`；相同 offer 的重试返回同一应答，不同 offer 返回409。Agent 拒绝或关闭返回502 `media_unavailable`，15秒内无应答返回504 `media_timeout`；这两类失败不影响通话控制状态。
5. 双方 ICE 与 DTLS 连接后开始媒体，Agent 上报 `media_status` `streaming`。

USB 本地使用模块本机 HTTPS 的同一路径与字段，响应中 `ice_servers` 为空数组；Agent 在请求内直接返回应答。

## 期限与失败

| 端 | 条件 | 结果 |
| --- | --- | --- |
| control | 会话创建后30秒未提交 offer、提交后15秒无应答、所有权或代次变化、控制断连 | 关闭会话，向在线 Agent 发 `media_stop` |
| Agent | 从 `media_start` 起20秒内未完成应答、helper 启动与 ICE 连接 | `media_setup_timeout` |
| Agent | 5秒没有收到 RTP，或 ICE 断开后未在5秒内恢复 | `rtp_timeout`／`ice_failed` |
| App | 提交应答后15秒未连接、断开超过5秒、5秒没有入站包、所有权失效 | 关闭连接并提示手动恢复音频 |

单次媒体会话最长30分钟。挂断、lease 撤销、代次变化或任一端关闭时双方关闭 PeerConnection 与 helper；恢复由用户显式重新发起，不做 ICE 重启或自动重连。

## 模块内部

Agent 与 helper 之间沿用 Unix 媒体通道，帧格式为 ASMP v3：40 字节头（`ASMP`、版本 3、方向、头长 40、会话 UUID、64 位序号、载荷长度、标志）后接一个 Opus 包，载荷最长1275字节。标志 0 为普通 Opus 包；1 为丢失帧，载荷为空，解码端执行 PLC；2 为 FEC，载荷是下一包，解码端用其带内冗余恢复丢失帧。helper ready 声明 `codec:"opus"`、`codec_frame_us:20000`、16 kHz、320 样本。

helper 就绪起 Agent 每20 ms向 helper 送出一帧；连接建立前送丢失帧，期间采集的包直接丢弃，连接后不补发。RTP 按序号排队，首包到达80 ms后起播：有下一包则送出；下一包缺失而更后的包已到时视为丢包，能取到后一包则送 FEC 帧，否则送丢失帧；队列为空时送丢失帧但不推进，晚到包仍可播放。超过12帧时裁剪至最新4帧，持续1秒超过6帧时丢弃一帧以回落延迟。helper 播放队列为四帧，空队列最多等待15 ms 新帧后补偿。模块采集的 Opus 包编码后立即发送。

## 诊断

模块本机 `/v2/local/cloud/media-stats` 与 App Debug 记录只保存计数：收发包、丢包、晚到、FEC 恢复、PLC、队列裁剪、停顿次数与最长停顿、抖动缓冲时延、往返时间与选中的候选类型。不保存音频、SDP 原文、凭据或号码。
