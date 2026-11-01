# v2 WebRTC 音频

v2 云端与 USB 本地通话媒体为 App 与模块之间的 WebRTC 音频连接。App 的 libwebrtc 负责采集、回声消除、Opus 编解码与 NetEQ 抖动缓冲；模块 Agent 内嵌 Pion 终结 ICE、DTLS-SRTP 与 RTP，原生 `airsim-audiod` 用定点 libopus 编解码并读写 PCM 硬件；ECS 只转交 SDP，并以 TURN 中继蜂窝 NAT 后的模块。字段、期限与帧格式见 [WebRTC 协议](../protocol/v2/WEBRTC.md)。

## 链路与参数

| 环节 | 配置 |
| --- | --- |
| 编码 | Opus，20 ms 包；模块 16 kHz 输入、32 kbps VBR、宽带上限、复杂度 3、带内 FEC 开启、DTX 关闭；模块应答要求 App 以同样的宽带参数发送 |
| App | stasel/WebRTC 155.0.0；`RTCAudioSession` 手动音频，随 CallKit 激活启停；连接失败后为同一通话自动建立新会话，保留静音与音频输出 |
| 模块 Agent | Pion WebRTC v4；云端只收集 relay 候选，USB 只收集 USB 地址的 host 候选；RTP 抖动缓冲 80 ms 起播，超过 12 帧裁剪至 4 帧，持续超过 6 帧时逐帧回落；媒体不随控制连接结束，同一通话的新会话替换旧会话 |
| 模块 helper | libopus 1.5.2 定点构建；工作线程栈 256 KB，采集、播放与收包线程为 SCHED_FIFO 优先级 10；播放队列四帧，空队列最多等 15 ms；丢包先用后一包的 FEC 恢复，再退回 PLC |
| ECS 中继 | airsim-media 内嵌 Pion TURN，主机网络；UDP／TCP 3478，中继 UDP 49160–49359 |

EG25 的 VoLTE 前端与 AFE 代理端口直接以 16 kHz 采集和播放；RM500 采集为 8 kHz，由 helper 插值到 16 kHz，播放按声卡实际速率直出或经 [1 2 1]/4 低通后降至 8 kHz。

每方向音频载荷为 32 kbps。计入 RTP、SRTP 认证标签、TURN ChannelData、UDP 与 IPv4 头，每方向约 6.7 KB/s；该数字用于容量估计，不是计费报价或吞吐实测。

## 资源

在 EG25 单核 Cortex-A7 上，实际通话中 Agent 进程约占 32% CPU（含系统调用），helper 约占 16%，其中 libopus 定点构建在复杂度 3 下编码加解码约占 8.6%。浮点软浮点构建同等编码约每帧 11 ms，不能用于模块。

WebRTC 版 Agent 为 11.3 MB（ARMv7，Go 1.24.13），在 EG25 的 UBIFS 用户分区上压缩后约占 7 MB；helper 为 331 KB。空闲 Agent 常驻内存约 9.2 MB，系统可用内存约 6.3–7.3 MB；EG25 上 Go 运行时内存上限为 6 MB、GOGC 为 25。

空闲 Agent 实测约占 6.8% CPU。控制连接每秒同步一次快照：连接截止时间已覆盖证书到期，不再逐秒重验证书链（本机基准中一次重验约为整次快照同步的 15 倍，含 4 次 Ed25519 验签）；短信收件箱直接比较结构，不再逐秒整箱序列化 JSON（40 条约 12 KB 临时分配）。

单核模块上任何占满 CPU 的进程都会推迟 Agent 与 helper。adb shell 会话异常结束后，adbd 可能残留一个持续运行的线程，占用约 90% CPU 且不会自行退出；遇到时重新插拔 USB 或重启模块即可清除。helper 的音频线程以实时优先级运行，不受此类进程影响。

## 构建与更新

libopus 源码子集位于 `third_party/opus/`（来源记录见 `UPSTREAM.md`），由 `module/rm500/audio/scripts/build_opus.py` 以 `FIXED_POINT` 编为静态库；helper 的 Opus 封装在 `module/rm500/audio/src/opus_codec.c`。RM500 与 EG25 helper 分别静态构建 ARM64 与 ARMv7。Go Agent 保持 `CGO_ENABLED=0`。iOS 通过 Swift Package Manager 固定 WebRTC 155.0.0。第三方许可随 App（`WebRTC-LICENSE.txt`）和网页安装包（`OPUS-LICENSE.txt`）分发。

App、ECS control／media、Agent 与 helper 必须配套更新，不能在通话中切换。未声明 `opus` 的旧 Agent 保持控制连接和短信，媒体申请返回不可用；Agent 校验 helper 的 codec 信息，拒绝旧 helper。

ECS 需要：安全组放行 UDP／TCP 3478 与 UDP 49160–49359；部署配置 `AIRSIM_TURN_IP` 为实例公网 IPv4；`identity/turn-secret` 为 32 字节随机十六进制，仅 control 与 media 读取。media 以主机网络运行，避免为两百个中继端口各起一个端口代理进程。

更新前确认无活动通话并保留回滚：服务器保存原部署配置、Caddyfile 与 `current` 指向；模块切换 `current` 与 `audio-current` 后由既有 init 监督恢复，失败时两个链接一并恢复。网页安装器在 UBIFS 分区按原始大小的 70% 估算所需空间，并清理当前版本以外的旧 helper 发布目录。

## 诊断

模块 `control.sock` 的 `/v2/local/cloud/media-stats` 提供当前或上一次会话的候选类型、收发包、丢包、晚到、FEC、PLC、裁剪、本地输入缺口，以及四类停顿的次数与最长毫秒数：等待 helper 采集帧、RTP 发送、App RTP 到达间隔与送往 helper 的播放节拍，并给出会话期间 Agent 的垃圾回收次数与存活堆；`/v2/local/audio` 提供 helper 的采集、播放、xrun 与静音计数。两者在 Agent 重启后清空。iPad Debug 构建的 `airsim.v2.last-media-stats` 记录收发包、丢包、隐藏样本、抖动缓冲时延、往返时间、候选类型与失败阶段。ECS media 日志只记录中继分配与释放的会话 ID、角色和协议。统计只含计数，不含音频、SDP、凭据或号码。

## 验证

- Agent 全部 Go 测试通过，包括：回环上的 Pion 对端完成 offer／应答并双向收发 Opus；经 Pion TURN 的 UDP 与 TCP 中继建立 relay 连接；USB 本地会话的 host 直连、重复 offer 拒绝与删除回收；抖动缓冲的乱序、FEC、欠载、晚到、裁剪、回落与序号回绕；ICE 连接期间持续向 helper 送帧并丢弃采集包；流式转发的首个失败原因；控制连接断开后经 TURN 的媒体继续双向收发，重连后同一通话的新会话替换旧会话且旧 helper 先释放。
- helper 宿主测试在 AddressSanitizer 与 UndefinedBehaviorSanitizer 下通过：ASMP v3 帧校验、队列取帧、Opus 编解码（合成语音平均 67 字节／帧），以及丢帧时 FEC 恢复误差为 PLC 的四分之一。ARMv7 与 ARM64 静态构建通过，EG25 上 `--version` 正常。
- ECS 测试通过：TURN 凭据签发与到期、中继端口范围与对端地址限制；control 的会话创建、offer 转交、应答返回、超时与所有权复核；隔离 PostgreSQL 中从接听到 `media_start` 与应答的完整流程，以及同一通话的新会话替换正在运行的旧会话；Docker Compose 整栈中主机网络 TURN 健康检查与信令测试。
- iOS CloudV2Tests 全部通过，覆盖信令、期限、看门狗、CallKit 音频激活与所有权恢复；模块重连后通话所有权改绑与持久化；模块离线与重连期间系统通话和音频保持、通话结束后结束；媒体失败后自动以新会话恢复并保留静音与音频输出；快照过期时音频保持、通话离开 active 时停止；本机呼出振铃期间播放回铃音。模拟器中的 libwebrtc 与 Agent 的应答代码完成真实协商，接受模块应答的 Opus 偏好并以 host 候选连接。

2026-11-01 已部署 ECS control／media（TURN 主机网络、`/v2/media` 路由移除）与 EG25 Agent `2.0.0-dev.webrtc`、helper `0.6.0-opus`，网页安装包同步发布两种模块的 WebRTC 版 Engine，EG25 部分与模块上运行的文件一致。从公网对 `120.25.235.237:3478` 的 UDP 与 TCP STUN 绑定均成功。

同日部署断线保持与媒体自动恢复：ECS control／media 更新为同一通话新会话替换旧会话、10 秒应答等待；EG25 Agent 与 helper 更新为媒体不随控制连接结束、实时优先级音频线程与 GC 统计；iPad mini 安装对应 App。重建 control 时模块约 1 秒内重新连上。

EG25 经 iPad mini 的真实来电已在新链路上双向通话约一分钟：从接听到媒体连接约 3 秒；模块到 iPad 无丢包，iPad 抖动缓冲约 205 ms、补偿约 3%；iPad 到模块的蜂窝下行丢包约 2.9%，其中约七成由 FEC 恢复。

## 已知限制

- 去电、长时间通话、锁屏接听与 USB 本地通话尚未在新链路上验收；控制连接断线、媒体自动恢复与回铃音尚未经真实通话验证。
- 模块离线期间在 CallKit 上挂断时，挂断命令无法送达，系统通话在本机结束，蜂窝通话持续到对方挂断或用户在模块恢复后从 App 内再次挂断。
- RM500 须经网页安装器更新为 WebRTC 版 Engine，更新前没有通话音频。
- 上述实测通话期间 adbd 残留线程正占用约 90% CPU，期间 helper 送出的采集帧间隔偶有 60–120 ms 的停顿，iPad 的抖动缓冲随之维持在约 200 ms；helper 改为实时优先级后的停顿待下一通实测。每次接通时 Agent 需从压缩分区重新读入约 5 MB 代码，延长建连。
- 单次媒体会话最长 30 分钟。
