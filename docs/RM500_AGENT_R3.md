# R3：RM500 本地双向音频主控契约

2026-10-24，主控冻结并完成本轮验收。当前固件、厂商 16 kHz 语音时钟下的本地双向内容闭环已通过，用户确认系统语音清楚且听到自己的延迟回声。实机呼叫目标仅由主控从会话传入。当前有效参数见下文，诊断裁决 01–04 保留为历史依据，最终验收结论见文末。

## 范围与依赖

- 执行会话使用 GPT-6-Astra / medium，只按本契约执行；遇到事实冲突回报主控裁决。
- 可修改 `module/airsim-agent/` 与新建 `module/rm500/audio/`。主控维护本文件及调度总表。禁止修改旧 Agent/CLI、厂商服务、根文件系统、ECS/Worker/iOS。
- Go Agent 保持 CGO_ENABLED=0；新增 C 原生 `airsim-audiod`，静态链接 musl 与 TinyALSA，独立进程，禁止 shell 包装 tinycap/tinyplay、CLI 或旧 Agent。
- TinyALSA 固定官方 v2.0.0 commit `1c5fb68ced57d838f2b7ecd0c00bc1fefc9ab60d`。只 vendor 所需官方源码与完整许可证，记录来源和 SHA256；不从设备未知版本的 libtinyalsa.so 猜 ABI。官方来源：https://github.com/tinyalsa/tinyalsa/tree/1c5fb68ced57d838f2b7ecd0c00bc1fefc9ab60d 。
- 交叉工具链采用 Zig 0.15.2 `cc -target aarch64-linux-musl -static`。主控已下载并按官方 index SHA256 校验，路径 `/tmp/airsim-r3-toolchain/zig-aarch64-macos-0.15.2/zig`，归档 SHA256 `3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b`。构建脚本允许 ZIG 路径覆盖，不能静默下载未知版本。TinyALSA 源码允许从官方固定 commit 下载。

## 硬件和 PCM

- 仅当前已核对固件 RM500UCNAAR01A18M2G_01.001.01.001、card 0 capture 9 / playback 55。厂商 audiohal 继续管理 device 5，不打开/停止它的 PCM。
- 现有路由 DOWNLINK capture / UPLINK_MIX playback 保持不变。不写 mixer、QAUDMOD/QPCMV，不放大增益、不做静音门限/降噪来掩盖残留。
- 外部与 ASMP 固定 8000 Hz、mono、S16_LE、20 ms = 160 samples = 320 bytes；capture 硬件同为 8000 Hz。playback 只读厂商 device 5p 的 hw_params，跟随其 8000/16000 Hz 语音时钟；16 kHz 时按裁决 04 做有状态二倍线性插值，不改变增益。未知格式、closed 或流中时钟改变均关闭媒体，不修改厂商配置。当前实机内容验收仅覆盖厂商 16 kHz。
- 两方向 period_size=320、period_count=2、stop_threshold=640、avail_min=320，实际硬件 buffer=640 samples；capture start_threshold=320，playback start_threshold=640。先顺序 prepare capture/playback、显式 start capture，再 ready 并启动工作线程；playback 填满缓冲后自动启动。poll 最长 10 ms，真实驱动供时钟；每方向按 native_rate×elapsed_ms/1000+1280 检查累计真实样本，持续 2 秒无进展关闭媒体。
- 各方向使用独立工作线程，非阻塞 PCM + poll，正确处理部分读写/EAGAIN/EINTR。不要忙循环。PCM_NORESTART，显式统计 xrun；同方向最多 3 次/10 秒 prepare 恢复，超预算终止媒体会话，不重启厂商组件。
- 每方向应用缓冲最多 5 帧/100 ms；输入迟到丢完整旧帧并计数。上行无数据时补零，持续供时钟；下行静音也发送。单次 IPC 写最长 100 ms，部分帧失败关闭该流，不能继续拼接坏帧。统计样本数、xrun、drop、silence fill、队列峰值、最后进展时间，不记录 PCM 内容。

## 进程与 IPC

- 每个已授权媒体会话启动一个 helper；Agent 空闲不启动 helper、不开 PCM。helper 路径通过显式 `--audio-helper` 参数配置，要求正规可执行文件，不执行 shell；未配置时音频不可用。
- Agent 给 helper 继承两个独立 AF_UNIX SOCK_STREAM socketpair：fd 3 控制，fd 4 全双工 PCM；stdin=/dev/null，stdout/stderr 仅固定脱敏诊断，不输出 PCM。helper 参数仅 session UUID、固定 profile，不含号码/令牌。
- 控制消息为 uint32 little-endian 长度 + UTF-8 JSON，长度 1..2048。Agent 仅发精确 `{"op":"ping"}`、`{"op":"stop"}`。helper 回复 ready（实际格式/period/buffer）、每秒 stats、error（稳定错误码）；JSON 不包含 PCM、号码或路径中的凭据。
- helper 3 秒内没收到 ping、控制 EOF、PCM EOF 或父进程死亡时退出；Agent 每 500 ms ping。Linux PDEATHSIG=SIGTERM 并检查 parent race，退出时关闭自身 PCM。STOP 后最长 2 秒未退出由 Agent 针对其唯一 child PID kill/reap。即使驱动阻塞，生命周期也有上限。
- helper 进入停止和线程 join 前同时启动自身 2 秒最终退出保险（SIGALRM 默认终止），覆盖父 Agent 已死亡、无法再执行 child kill 的情况。Linux 不可中断的内核故障仍须单独报告，不能承诺用户态能强行释放该内核资源。
- PCM 每帧 360 bytes：0..3 ASCII ASMP；4 version=1；5 direction（1=上行/发给蜂窝，2=下行/来自蜂窝）；6..7 LE header length=40；8..23 session UUID 的 16 bytes；24..31 LE uint64 sequence（各方向从 1 递增）；32..35 LE payload length=320；36..39 reserved=0；后接 320 bytes PCM。严格校验方向、session、长度、版本与递增序号；允许有计数的序号跳跃，拒绝重复/倒退。无格式自动猜测。

## 通话 lease 与本机接口

- 音频管理器属于 Agent；coordinator 提供无敏感字段的音频资格快照。创建和连接媒体时都要求同一 boot/epoch 下唯一非断开通话，目标 call_id 存在、ownership=managed、state=active、控制状态可信。不能接管 unmanaged、来电振铃、held 或重启前通话。
- 挂断、离开 active、epoch 变化、状态丢失或 Agent 退出立即撤销媒体 lease。用 coordinator 事件通知加有界 100 ms 复核兜底，不能仅依赖客户端主动关闭。停止音频不隐式挂断电话；测试主控负责有界定向挂断。
- 一次只允许一个媒体会话。`POST /v2/local/audio/sessions` JSON 字段严格为 request_id（UUIDv4）、agent_boot_id、backend_epoch、call_id，body<=1024。成功 201 返回 session_id、32 随机 bytes 的 hex token、boot/epoch/call_id、格式和 media_socket。相同 request_id/内容的活动会话返回 200 原结果；冲突 409；已关闭 request_id 返回 410（最近 64 个以内），不重放副作用。
- `GET /v2/local/audio` 返回可用性、当前/最后一次会话脱敏状态和统计，不返回 token/号码/PCM。`DELETE /v2/local/audio/sessions/<session_id>` 幂等停止目标媒体，不能停止另一会话。
- media socket `/run/airsim-v2/media.sock`，0600，目录 0700，沿用现有安全 inode/陈旧 socket 规则。只监听 Unix，不新增设备 TCP 端口。
- 媒体客户端首先发送 uint32 LE 长度 + JSON（<=1024）：session_id、token；3 秒握手超时。成功回复同样封装的 JSON `{ "ok":true, "sample_rate":8000, "channels":1, "sample_format":"s16le", "frame_samples":160 }`，再双向 ASMP 帧。失败关闭。token 只可绑定一个连接；断线终止会话，不拿旧 token 重连。握手并发最多 4 个、拒绝额外连接；不可让慢连接阻塞 accept 或业务协调器。
- 创建后 5 秒未连接、连接后 2 秒无合法上行帧、任何方向 I/O 错误、helper 退出，均终止 session；总时长上限 30 分钟。媒体客户端即使无声音也每 20 ms 发零帧。所有队列、goroutine、deadline 与停止流程可回收。
- Agent 可通过主机 ADB 的 loopback TCP 转发连接该 Unix socket做验收，转发仅用于主控测试并在结束删除。生产 Relay/旧 AIRSIMPCM1 兼容入口留待 P4，R3 不发布未经认证的旧媒体流。
- `voice_ready` 本轮收尾仍为 false，能力描述为 implemented/unverified，实验接口 available=true。主控已确认当前固件、厂商 16 kHz 时钟的双向真实内容通过；考虑 8 kHz 实机分支及长稳尚未验证，暂保留运行时发布门槛。实测通过记录与软件能力标记分开，不能因 helper 启动、RMS 非零或单一配置短测自动开放所有 profile。R2 控制、短信、持久去重继续可用。

## 验证与交接

1. 执行会话先完成代码、fake/helper protocol 测试、race/vet、两个 ARM64 静态构建，报告哈希、依赖及部署命令；此时不自行拨号/播放/采集/写 mixer。覆盖旧 lease、串话、错误帧、双连接、阻塞写、EOF/超时、异常 child、调用结束清理及重复 create。不要保存测试音 PCM 文件。
2. 主控复核后才调度部署，在无通话时切换 R2→R3，保留身份/命令状态和 R2 回滚构建；部署前后量空间，检查 ELF 无动态加载器，helper --version 不打开音频。
3. 主控独占真实通话操作。用户说明不在电脑旁并要求直接呼叫授权 iPhone，因此本轮采用低音量提示语 + 主机内存中的有限延迟回声：iPhone 临时说出的内容经新 Agent 下行到主机，再经同一会话上行返回 iPhone，获得用户对未知临时语句的内容确认。回声以有限增益、有限缓存运行，结束立即清空；不捕获 Mac 麦克风。这样验证两个方向真实内容与并行流动，Mac 扬声器/麦克风的客户端体验另行验收。仅样本非零、发送成功或振铃均不算音频通过。
4. 统计 PCM 时间与墙钟、实际硬件参数、说话/静音段差异、xrun/丢帧、RSS/FD/线程及 CPU。静音残留必须描述实际听感与可解释证据，不以 RMS 门限掩盖。所有声音仅内存/匿名 pipe/socket，不生成录音文件，不输出 PCM/base64。
5. 测试媒体断开、helper 子进程故障、过期 token 和通话结束关闭；故障后需要新 session，不自动复用旧代次。核对自有进程/PCM FD 回收，厂商 5c/5p/9c/55p 最终 closed，身份与 R2 控制正常。
6. 30 分钟连续/100 次会话是后续长稳目标，若本轮未做必须明确未验证，不能把短时闭环宣称完整生产验收。实现、实机事实、用户听感分别记录。

## 主控诊断裁决 01

首次 R3 呼出已 active，但 helper 在 ready 前报告 pcm_config，发送/接收均 0 帧，主控已定向挂断，9c/55p 回到 closed。允许在确认无通话、无 helper 时使用独立测试探针申请相同 PCM 参数并读取实际 hw_params；探针只 pcm_open/get_config/get_buffer_size/close，不 prepare/start/read/write，不采集或播放声音，不改 mixer。此为定位固件参数的有限例外，不放开正常 Agent 的通话 lease。执行会话实现并构建探针，主控部署运行并据证据决定后续参数。

实机结果：两个方向均将 period_size=160 refine 为 320，period_count=4；实际 hw_params buffer_size=1280，TinyALSA get_buffer_size 却仍为 640（固定源码用请求值计算）。8000 Hz / mono / S16_LE 一致。主控据此将正式参数改为 period_size=320、period_count=2、start_threshold=320、stop_threshold=640、avail_min=320，预期实际硬件缓冲 640 samples / 80 ms；必须用新版探针再次核实，失败不拨号。对外和 helper 工作帧仍为 160 samples / 20 ms，允许一个硬件周期内分两帧传输；不改 vendor、不自动重采样。正式 helper 采用 strip 静态构建节约用户分区。

## 主控诊断裁决 02

320×2 配置探针和实际媒体握手已通过，但实机第三次呼出中两秒无下行，首秒 playback_samples=45123360，明显不是 8000 Hz 的真实传输。静态比对发现两处可验证差异：固定 TinyALSA 的 pcm_state 使用 flags=0 的 SYNC_PTR，可能把陈旧 appl_ptr 写回；官方 commit a36d521c328b16b53360a016aa543491d0aad05e 已将该调用修正为 SNDRV_PCM_SYNC_PTR_APPL | SNDRV_PCM_SYNC_PTR_AVAIL_MIN。设备自带 pcm_read 则在首次读取前显式 prepare/start，而当前 helper 每次只请求 160 frames，低于 320 的自动启动门槛。

主控冻结最小修正如下，执行会话不自行扩大技术方案：

- 保留原 vendor 文件和哈希，只在构建副本应用上述官方 pcm_state 单一补丁；记录上游链接、补丁和应用后文件 SHA256，补丁不能模糊匹配。配置探针若使用构建副本须保持一致。
- capture 在线程开始读之前显式 pcm_prepare 然后 pcm_start；capture 的 EPIPE/ESTRPIPE 恢复也 prepare 后 start。playback 显式 prepare 后通过正常写入达到门槛自动启动，不空缓冲强行 START。失败关闭媒体。
- 两方向累计成功 samples 不得超过 8×elapsed_ms+1280；超过按 pcm_io 失败关闭，不能以 sleep、丢计数或假时钟掩盖。现有 2 秒无进展上限不变。
- 用 fake ioctl/PCM 测试覆盖状态查询不覆盖指针、首次和恢复 capture 启动、playback 不主动 START，以及异常速率退出。重建静态 helper；Go 协议和 API 不改。
- 部署、实际拨号、采样及真实故障注入继续由主控独占。短时运行通过前不能提升 voice_ready，也不以源码推断替代听感验收。

## 主控诊断裁决 03

裁决 02 helper 的真实通话在约 64 ms 内以 xrun_budget 结束，尚无下行帧。为避免反复呼叫用户，允许主控在确认无通话、无 helper 后运行独立短时 PCM 诊断：仅 device 9/55，既定参数，无路由修改；允许 prepare/start/read/write/poll，播放仅全零，采集数据仅存在固定内存并立即丢弃。每次最多 3 秒，alarm 保险，结束关闭两个 PCM；只输出调用返回值、errno、状态、样本计数和 proc 状态等脱敏元数据。执行会话只实现构建探针，不接触设备。该例外不改变正式 Agent 必须持有 active 通话 lease 的约束，空闲诊断也不能替代真实通话验收。

空闲探针事实：capture prepare/start 成功，立即读出 320 samples 后不再前进；playback prepare 返回 EINVAL，内核报告 FE_VOICE_PCM_P 无启用的 backend。空闲不具备完整通话音频路由，不能据此确认上行节拍。第四通内核日志则显示 playback 在启动后约 30 微秒内停止，重复四次；capture 随后才 START。这把本次故障定位为 playback 启动欠载，并未证明 capture 无法流动。

主控下一项最小试验裁决：playback start_threshold 从 320 改为整个硬件 buffer 640，先预填完整缓冲再由内核自动启动；capture 仍 320，stop_threshold/avail_min/period 均不变。hw_verify 分方向检查。两个 PCM 的初始 prepare 及 capture start 在主线程顺序完成，成功后才发送 ready、创建工作线程，避免并行启动争用厂商 DSP 命令；线程恢复仍各自 prepare，capture 再 start。停止时在关闭媒体之前发送最终 stats 和稳定 error，使亚秒失败也保留两个方向的计数。保持速率保护，不以扩大 xrun 预算掩盖失败。此为待实机验证的启动修正，不能提前宣称解决。

第五通结果：capture_samples=160、playback_samples=1440，最后进展均在启动 3 ms 内；52 ms 最终 stats 无 xrun，以 pcm_io（速率保护）关闭。不能仅凭此区分启动预填与持续异常。主控允许在下一通受控 active 通话内先运行同一独立探针 2 秒（仍只零播放、内存丢弃采集），再据证据决定正式媒体试验；正常 Agent 不绕过 lease。探针只记录前 32 操作但持续处理至 2 秒，每方向超过 32000 samples 提前停止并记录失败，首 32 操作完成后及结束时采集 bounded proc 状态。保留 3 秒 alarm；不改正式 helper 的限速阈值。

第六通 active 探针 2 秒：capture 16000 samples，playback 30400 samples，零 xrun；playback hw_ptr 从约 206 ms 的 2240 增至约 2028 ms 的 30080，实际进展接近 16 kHz，而申报为 8 kHz。厂商主通话 device 5 日志为 16 kHz。poll 多数超时而不通知就绪，100 ms 等待长于硬件缓冲，不能作为正常等待策略。下一轮仅探针对照：保持 capture 8 kHz，分别申请 playback 8/16 kHz，native 工作帧各为对应 20 ms；固定 period320×2、playback start640，poll 上限改10 ms，不加人为音频节拍；每个 variant 2 秒、每方向上限64000 samples，500 ms输出累计采样元数据。可在同一受控通话内顺序跑两个 variant，并只读 device 5 hw_params；不执行 mixer 操作，也不提前改变正式 helper 的格式。

## 主控诊断裁决 04：分离客户端格式与设备上行时钟

第七通同一 active 通话的 8/16 kHz 对照已证实：vendor 5p/5c 均 16 kHz；两秒 capture 均 16000 samples；playback 申请 8k 时 32320、申请16k时32960，两个 variant 均零 xrun。后者500/1000/1500/2000ms累计8960/16960/24960/32960，符合16k持续时钟加启动预填。不能继续把上行当8k输出。以下由主控确定、执行会话机械落地：

- 外部和 ASMP 保持 8k mono S16LE/160 samples/20ms；capture硬件也保持8k。playback硬件跟随只读 `/proc/asound/card0/pcm5p/sub0/hw_params` 中的厂商语音时钟，仅接受S16_LE、mono、8000或16000；其他/closed/解析失败以pcm_config关闭，不开device5、不改其参数。ready前复核，每秒复核，时钟改变则结束媒体，不在流中切换格式。
- playback每20ms消费一个ASMP帧：8k直接160samples；16k用有状态的因果二倍线性插值生成320samples。公式 y[2i]=(previous+x[i])/2（int32运算、向零取整），y[2i+1]=x[i]，previous=x[i]；跨帧保留previous，初始及xrun恢复后归零。使用640byte工作区原地从后向前转换，避免额外排队，零补帧同样经过转换。不改变增益。
- 两方向period320×2、stop640、avail320不变；capture start320，playback start640。PCM poll最多10ms，实际传输仍由驱动控制，不用sleep伪造节拍。累计速率保护按该方向native_rate×elapsed_ms/1000+1280，计数始终是真实native samples。
- helper ready中capture/playback各新增sample_rate，Go严格校验capture=8000、playback∈{8000,16000}，其余PCM形状不变；外部握手格式仍8k，GET音频诊断明确保留native rate。相应Go/C测试及两端静态构建同步部署。
- 覆盖8k直通、16k插值正负/极值/跨帧/零帧/xrun重置、native帧长度与速率保护、厂商时钟解析和变更拒绝、ready严格字段。当前实机只验证了16k厂商时钟，8k分支的单测不能宣称窄带真实通话验收。voice_ready仍false，必须继续内容实测。

## 主控最终验收：当前 16 kHz 厂商时钟的本地双向音频通过

2026-10-24 16:14–16:18（Asia/Shanghai），裁决 04 构建完成真实通话内容与故障回收验证。用户先确认“听清楚了！声音质量还可以”，随后明确确认“是，听到了自己的回声”。临时说话内容经 RM500 capture 到主机，再由同一会话 playback 返回 iPhone，满足本轮双向内容验收；声音始终仅在内存、匿名 pipe 和 socket 中处理，没有生成录音文件。

- 75.004 秒主媒体阶段，上下行各 3750 个外部 20 ms 帧，下行 600000 samples，外部序号无缺口，helper xrun 为零。helper 有 14 个有界输入队列丢帧（约 0.37%），补零 5760 个 native 16 kHz samples（约 0.36 秒，含启动等），不能宣称零丢帧。主机 echo_dropped=1435 主要为提示语及非回声窗口的主动丢弃，不代表网络丢包。
- 实际 helper capture=8000 Hz、playback=16000 Hz，均 period320×2 / buffer640。真实终止唯一自有 helper 后 session 以 helper_exit 关闭，PCM 关闭、child 回收；新会话能流动，旧 token 被拒绝。客户端 EOF 以 media_read 关闭；再次创建媒体并在通话中定向挂断，以 lease_revoked 关闭。两段恢复流各约 2.4 秒、120 帧。
- 最终核对无活动通话、无自有 helper，PCM 5c/5p/9c/55p 均 closed；control_ready=true，持久 module_id 与部署前一致。Agent 最终 RSS 12300 KiB / FD 12，用户分区剩余 9376 KiB。通话观测 Agent RSS 8516–12696 KiB，helper RSS 152 KiB；单核采样 CPU 均值约 12.44% / 3.51%，包含观测开销，不能视为独立性能基准。
- 部署目录 `/mnt/data/airsim-v2/releases/ea836044de25662b/`：Agent SHA256 `ea836044de25662bb92dad365d49cac3ce3686fb3de232b1526f7d87d443c171`；helper SHA256 `39ff88dabce16196defdacc72637a15695f171a65f080179dde4382df3cc41dc`。保留 R2 回滚目录 `/mnt/data/airsim-v2/releases/b603f0cf5958a0ad/`，身份及命令持久状态保留，未改开机启动。

主控结论：R3 当前设备与时钟组合的本地内容闭环及上述故障回收验收通过，执行会话收尾后待命。运行时 voice_ready=false / verification=unverified 暂保留为实验发布门槛。30 分钟连续与 100 次会话、厂商 8 kHz 时钟实机、Mac 麦克风/扬声器体验及 ECS/Worker/iOS 端到端均尚未验证；没有做校准的静音底噪/AEC 测量。R4–R5 未启动。

事实源：[完整验收元数据](../module/airsim-agent/R3_ACCEPTANCE_EVIDENCE.json)、[历史诊断元数据](../module/airsim-agent/R3_DIAGNOSTIC_EVIDENCE.json)、[执行验收记录](../module/airsim-agent/R3_TESTING.md)。其中历史失败保留用于解释修正原因，不覆盖本节最后成功结果。
