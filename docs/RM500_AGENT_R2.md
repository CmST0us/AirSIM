# RM500 Agent R2 主控执行契约

2026-10-24。用户已授权实施呼叫控制、短信收发，并用本次会话提供的号码完成实机闭环。技术决定由主控作出，执行会话使用 GPT-6-Astra / medium，仅在 `module/airsim-agent/` 落地本契约。主控维护本文件；未涵盖的技术选择先返回证据与问题，不自行替换方案。R1 的代码、身份与验收证据保留；R2 完成前不得把它写成通过。

## 1. 后端与范围

- 版本 `2.0.0-dev.r2`，沿用 Go 1.24.13 / Linux ARM64 / CGO=0。新增且只新增 `github.com/godbus/dbus/v5 v5.2.2` 及其声明依赖 `golang.org/x/sys v0.27.0`，提交 go.sum，使用官方 Go module proxy/sumdb 校验。独立实现，不 import 或运行旧 Agent/RM500 CLI。
- 长期连接系统总线，目的服务 `org.ofono`。通过 Manager.GetModems 发现 modem，要求恰好一个匹配当前 RM500 profile 且具备 VoiceCallManager、MessageManager 的对象；当前观测 `/ril_0` 只是证据，不能硬编码。缺失/多义报告 unavailable，不能自动选择第一项。
- 绑定裁决01：当前厂商 oFono 的 Manufacturer/Model 为占位字符串，不能用于硬件识别；不把它们加入白名单。硬件确认仍由 R1 的 Linux ARM64、专用端口 ATI 型号和完整 CGMR 固件精确校验负责。只有该验证成功，且同一系统总线恰好一个 modem、Powered=true、Online=true、具备 VoiceCallManager/MessageManager 时，才允许作为本机 RM500 的控制后端。初始未验证、验证失败、AT 失步或必要只读状态过期，禁止新拨号/发短信/接听/DTMF；如果已有本 Agent 管理的通话且 D-Bus owner/epoch 有效，允许针对它的定向挂断以完成清理。后续多 modem 平台必须另设可验证的绑定规则，不能沿用“唯一对象”假设。
- 调用 `VoiceCallManager.Dial(number,"default")`、具体 `VoiceCall.Answer()` / `Hangup()`、`VoiceCallManager.SendTones(tones)`、`MessageManager.SendMessage(to,text)`。不调用 HangupAll、转接、多方、SIM/RF/APN/USB 设置或任意 AT。拒接复用具体来电对象 Hangup。
- R1 AT manager 继续只读采样；写操作全部经 oFono，不抢厂商端口。只有本 Agent 一个业务写入者；本轮测试不用 CLI 或 dbus-send 绕过 Agent 执行副作用。
- 新增内部 `ofono` 适配、`control` 协调器、`journal` 有界操作记录；HAL 增加实际需要的呼叫和短信方法/类型。HTTP handler 仅验证/投递/读状态。没有音频 helper、录音、PCM、云端、开机自启或更新。`voice_ready` 仍固定 false。

## 2. 连接、快照和事件

- 先注册信号、再取初始 GetCalls / GetMessages 快照，协调快照期间排队事件，不能遗漏或重复应用。GetMessages 只代表待发消息，不是历史收件箱。
- 监听 NameOwnerChanged、Modem.Interfaces、CallAdded/Removed、VoiceCall.PropertyChanged/DisconnectReason、MessageAdded/Removed、Message.PropertyChanged、IncomingMessage/ImmediateMessage；本固件另有 MessageManager.MessageState(object,dict)，只消费已验证的 State 字段。未知值保持 unknown，不猜发送成功。
- 每次连接/服务 owner 变化生成随机 `backend_epoch`。过滤信号的实际发送者 unique name、接口、路径与本轮 epoch；旧 owner/epoch 的事件不能改变当前状态。连接或所需接口丢失立即失去控制就绪；未发送的命令失败，已提交但无确定结果的为 outcome_unknown。
- 连接重试采用 1/2/4/8/16/30 秒上限退避。重连只重新发现和同步，不重放副作用。重连时已经存在的通话标为 unmanaged；不自动补拨、接听或挂断。初始存在通话同样处理。
- 信号队列上限 128，投递不能创建无限等待 goroutine。满时设置事件丢失状态，失去控制就绪并重新取快照；收件短信丢失无法用 GetMessages 补回，必须持续暴露 `inbox_gap=true`（该进程内不得清除）。重连也设置该标志。不得把未知间隙当作收件完整。
- godbus 使用私有连接与 `WithSignalHandler` 自定义同步非阻塞 handler；其默认 handler 在满队列时创建 deferredDeliver goroutine，不满足本轮有界要求。自定义 Terminate 必须幂等并避免与 DeliverSignal 的 close/send 竞争。此决定基于 [v5.2.2 原码](https://github.com/godbus/dbus/blob/v5.2.2/default_handler.go)，不是用默认缓冲通道大小代替积压上限。
- 连接生命周期裁决02：本轮已核实系统总线 socket 为 `/var/run/dbus/system_bus_socket`。以 net.Dialer（5秒、可取消）连接该 Unix socket，再用 godbus.NewConn/WithContext、Auth/Hello 建立私有连接；初始化握手用 socket 临时5秒 deadline，成功后清除，失败关闭所有连接资源。不得让 Connect/Auth/Hello 在父 context 取消后无限挂起。不读取任意 session bus 或自动启动新总线。
- 同时监听根对象的 Manager.ModemAdded/ModemRemoved，设备集合改变立即失去控制就绪并重新发现；Modem.Powered/Online 变 false 或所需 Interfaces 缺失同样处理。VoiceCallManager.EmergencyNumbers 属性更新时更新禁止拨号集合。不能在失去唯一 modem 条件后仍沿用旧 ready。
- 控制状态在一个串行协调器中维护；D-Bus 方法在有界 worker 执行，不能卡住信号处理。呼叫与短信各有容量 8 的独立队列和单 worker；短信不能阻塞挂断。D-Bus 单调用 10 秒上限，读属性 5 秒；入队时和实际调用前均验证期限、boot、epoch、当前状态。不自动重试任何写调用。
- worker 回报完成后必须等待协调器确认记录/状态已处理，才开始下一条，不能因 select 调度顺序让下一次 begin 越过上一条完成。拨号在途保留 reservation，双并发拨号最多一次实际 Dial。CallRemoved 早于 Dial 返回时不得复活通话；同一路径已被新通话复用时不得把旧返回归属到新来电。用 epoch、事件顺序和保留的结束记录关联，无法唯一归属即 outcome_unknown。
- 每个新 call object 分配随机 UUID `call_id`，不以可复用的 D-Bus 路径做外部 ID。同 epoch 内保留至结束，结束记录保留最近 32 项。状态以硬件事件/快照为准：dialing、alerting、incoming、waiting、active、held、disconnected；其他值 unknown。通话所有权为 managed（本轮拨号/接听）、incoming（本轮新增来电）、unmanaged（启动/重连时已存在）。unmanaged 拒绝写入，报告主控后另行处置。
- 拨号只在没有任何现存通话时允许；接听只接受本轮 state=incoming 来电且没有其他活动通话，state=waiting 不调用 Answer；挂断/拒接只针对明确 call_id，禁止影响其他通话。DTMF 只在恰好一个 managed active 通话时允许。

## 3. 本机控制契约

沿用 0600 Unix socket，不开 TCP。R1 四个诊断接口继续保持只读语义、脱敏与 `scope=read_only`。新增以下明确的本机控制接口；这不是云端 v2 最终契约。

能力值随实现更新：R2 capabilities.messaging.support=supported，readiness 取 messaging_ready（未就绪则 unavailable 并给原因）；telephony 保留 R1 状态查询的 readiness，写控制以 `/v2/local/control.telephony_ready` 为准。Audio 仍 unknown/unavailable/not_implemented。R1 snapshot 不增添号码或短信正文。

```text
GET /v2/local/control
  {schema_version:1, agent_boot_id, backend_epoch, ready, reason,
   scope:"local_control", voice_ready:false,
   telephony_ready, messaging_ready, inbox_gap,
   inbox_dropped:uint64, command_capacity_remaining:uint64}
GET /v2/local/calls
  {agent_boot_id, backend_epoch, available, calls:[
    {call_id, state, ownership, direction, number, observed_at, disconnect_reason}]}
GET /v2/local/messages
  {agent_boot_id, backend_epoch, available, inbox_gap, inbox_dropped, messages:[
    {message_id, direction:"incoming"|"outgoing", sender, recipient, text,
     state:"received"|"queued"|"sent"|"failed"|"unknown",
     delivery:"unknown", observed_at}]}
POST /v2/local/commands
  {command_id:UUIDv4, agent_boot_id:UUIDv4, backend_epoch:UUIDv4,
   deadline:RFC3339Nano, action, args}
GET /v2/local/commands/<command_id>
  {command_id, action, state, result_code, call_id?, message_id?, updated_at}
```

动作与唯一允许的 args：

```text
call.dial   {number:string}
call.answer {call_id:UUIDv4}
call.hangup {call_id:UUIDv4}         # 包括拒接 incoming
call.dtmf   {call_id:UUIDv4, tones:string}
sms.send    {number:string, text:string}
```

- 严格 JSON：最大 4096 字节，精确大小写字段白名单、重复/未知字段/尾随内容/错误类型拒绝。每种 args 必须恰好匹配动作，不接受任意对象透传。Content-Type application/json；HTTP body 总上限由 MaxBytesReader 限制。
- 号码仅 `[+]?[0-9]{7,15}`，无空白、星井、分号或 MMI；拒绝设备报告的 EmergencyNumbers。不把测试号码固化到源码或默认配置。DTMF 为 `[0-9A-D*#]{1,16}`。短信非空有效 UTF-8、无 NUL、最多 70 个 UTF-16 code unit，不拆条。
- deadline 必须晚于模块当前时间且不超过 60 秒；接收后用单调时钟实施预算，不修改设备系统时间。boot/epoch 不匹配为 409。队列满 429，后端不可用 503，参数错 400，动作/路径不支持 404，方法错 405。新合法命令落盘并入队后返回 202；相同 ID 相同请求返回已有记录（200），不同请求返回 409，不能重新执行。
- 命令摘要用身份 seed 派生的 HMAC-SHA256（域 `airsim-r2-command-v1` + 规范化结构序列化），只暴露计算方法，不导出 seed/private key。摘要包含全部请求字段。已有 command_id 先比较摘要/返回记录，再校验新请求的 deadline/boot，以便重启后安全查询/重试相同请求。
- 号码/正文仅在明确的受限本机业务接口返回，在内存中使用；R1 snapshot、日志、验收报告、命令记录都不能包含这些内容。调用者负责限制读取；不增加任意 shell/AT/文件接口。

## 4. 操作记录与失败语义

- 持久目录 `state/commands.json`（目录0700、文件0600）。schema_version=1，记录只包含 command_id、request_digest、action、state、result_code、call_id/message_id、时间与 epoch/boot 元数据，不含号码、正文、DTMF 内容、原始错误文本或 D-Bus 参数。
- 原子更新：同目录临时文件、chmod0600、write/fsync/close、rename、fsync 目录。严格解码、大小上限 2 MiB、最多 1024 条。不可读、损坏、符号链接、残留未完成临时文件使写命令 fail closed，保留只读诊断。不得自动删除记录/重建身份或操作日志。R2 不做过期淘汰；容量满拒绝新命令，已有记录仍可查询，避免旧 ID 再次执行。
- 状态为 `prepared → dispatched → accepted|observed|failed|outcome_unknown`；未执行过期用 expired。调用前必须 durable dispatched，落盘失败不调用设备。prepared 在进程重启后变 expired，dispatched 变 outcome_unknown，两者均不重放。终态记录原样保留。用持久化存储锁/协调避免并发写覆盖。
- `Dial` 返回新路径只表示创建/提交；记录 accepted + call_id，并靠通话状态报告 dialing/alerting/active，不把接受当作接通。Answer/Hangup 返回后最多观察 10 秒，确实 active/removed 才 observed，否则 accepted 或 outcome_unknown（仅有方法返回为 accepted，调用超时/断线则 unknown）。DTMF 方法返回记录 accepted，不能宣称远端听到。
- SendMessage 返回路径仅表示 queued：命令 accepted + message_id。收到本固件已验证的 sent 状态才把消息标 sent；仍不能标 delivered。错误和超时不能自动重发；MessageRemoved 本身不能推定成功。消息状态与命令提交状态分别保存，不伪造 strict exactly-once。
- 若 MessageAdded、sent/failed、MessageRemoved 早于 SendMessage 的返回处理，必须保留同 epoch 的有界已结束对象关联，让迟到返回仍指向原 message_id 和已知终态，不能另建 queued 消息。关联随128条环淘汰；路径复用导致无法唯一归属时记录 outcome_unknown，不串到新消息。
- 收件/发件正文仅在本进程内存环中，最多128条、单条 UTF-8 文本8KiB，总正文1MiB，超限丢弃并统计/设置 gap。R2 不提供跨重启收件箱或删除 SIM 短信。重启后收件历史为空需明确文档说明。
- SIGTERM 停止接收新命令，取消未提交项并记录失败；在途调用在原预算内收敛，未确定即 unknown。退出总预算15秒。退出不自动挂断现有通话，不删除消息。测试只在确认没有活动通话/在途短信时重启；业务在途崩溃由 fake 测试。

## 5. 验收与分工

执行会话先完成实现、单元/fake测试、race/vet、静态构建、SHA-256核对、只读启动/事件订阅验收，再回报主控准备实机呼叫并暂停设备写操作。业务联调阶段由主控统一操作电脑电话/信息应用及新 Agent 的 Unix HTTP API，保证接收端与模块命令同步；执行会话根据证据修复实现，在主控明确交回设备控制后才重新部署。不能同时有两个测试者操作通话，也不绕过新 Agent 用 CLI/dbus-send 控制业务。

- 必测：严格请求与命令去重（同时提交、相同 ID 不同参数、重启后重试）、prepared/dispatched 崩溃边界、日志损坏/容量上限/写失败、旧 boot/epoch、信号在快照前后到达、owner丢失与恢复、队列溢出/短信缺口、对象路径复用、未知状态、拒绝 unmanaged/多通话、短信回执不等于送达、正文不落盘/日志。
- 部署保留 R1 release 与设备 identity，当前数据空间允许一份 R1 和一份 R2；不要覆盖映射中的二进制。只停止核对 exe 后的本轮 Agent；不改动厂商服务。复核 R1 只读接口、身份保持、资源、权限与旧安装。
- 实机测试目标仅用会话中的授权号码，不从历史记录提取。计划一次呼出（最长等待60秒，接通后短暂保持，再定向挂断），一次来电接听/挂断，一次来电拒接；DTMF只在测试通话 active 时发送一次 `12#`，记录后端接受，不用它宣称音频验收。
- 发送一条带本轮随机标记的短测试短信；电脑/手机接收端必须观察到同一标记才算发出闭环。由该接收端回复一条带另一随机标记的短信，新 Agent IncomingMessage 与本机 messages 接口必须一致才算接收闭环。发送前主控确认接收端已准备，不以延时或未知结果触发自动重发。
- 重复提交同一个已发送短信命令 ID，验证无第二次发送（fake 调用计数 + 实机接收端/事件证据），不为了测试去重重新生成 ID。
- 不清空/删除历史短信、通话记录，不读取与本轮测试无关的正文。仅输出脱敏状态、nonce匹配布尔、计数与性能；号码及正文不写仓库/报告。新增 `R2_TESTING.md` 与按实际 hash 标记的脱敏证据。
- 只有来电、呼出、定向挂断/拒接、短信发送与接收各有本轮真实证据才算 R2 业务闭环；若电脑的 iPhone 连续互通不可用，主控继续完成独立工作，并向用户索取必要的接听/回复协助，不把接口存在或 fake 通过作为替代。

依据：[godbus v5.2.2](https://github.com/godbus/dbus/tree/v5.2.2)、[VoiceCallManager](https://kernel.googlesource.com/pub/scm/network/ofono/ofono/+/master/doc/voicecallmanager-api.txt)、[MessageManager](https://kernel.googlesource.com/pub/scm/network/ofono/ofono/+/master/doc/messagemanager-api.txt)。实际方法/信号签名已于本轮通过设备 introspection 复核，当前没有通话和待发消息。公开文档不足以证明当前固件实际业务成功，按本次实测收敛。
