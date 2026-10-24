# RM500 airsim-agent 执行决策与验收

日期：2026-10-24。主控下发；本文件区分已冻结决策和执行证据，不代表功能已经实现。

当前状态：R1 只读阶段已完成实机验收，结果见文末与 [详细记录](../module/airsim-agent/R1_TESTING.md)。R2 已按 [主控契约](RM500_AGENT_R2.md) 实现，呼出、来电接听、定向挂断/拒接和短信双向收发已有本轮实机证据，详见 [R2 记录](../module/airsim-agent/R2_TESTING.md)。收件延迟与重复通知原因仍未查明。R3 已按 [双向音频契约与最终裁决](RM500_AGENT_R3.md) 完成当前固件、厂商 16 kHz 时钟的本地双向内容验收：75 秒真实通话，用户确认语音清楚并听到自己的回声，真实 helper 故障、会话重建及挂断回收通过，详见 [R3 记录](../module/airsim-agent/R3_TESTING.md) 和 [原始验收元数据](../module/airsim-agent/R3_ACCEPTANCE_EVIDENCE.json)。运行时 voice_ready=false / verification=unverified 暂保留为实验发布门槛；8 kHz 厂商时钟实机、长稳与云端/App 端到端尚未验证。R4 云端接入已启动（见下一段），R5 尚未启动。

用户已授权在当前通过 ADB 连接的 RM500 上落地新架构并闭环测试。真实呼出/短信测试目标由会话临时传入，不写入仓库、日志或默认配置。

2026-10-24 后续调度：R4 已正式启动，按 [R4 主控执行计划](RM500_AGENT_R4.md) 与 [公共契约](../protocol/v2/R4.md)，Agent 和 ECS 执行会话并行实现云端接入与 Docker Compose 服务，主控负责目标环境、部署和真实验证。R5、Worker 与 iOS 执行会话暂待命；当前不宣称云端链路已通过。

## R1：独立 Agent 与本机只读闭环（已验收）

范围仅 `module/airsim-agent/`：新建 Go 工程、测试、构建/ADB 部署辅助与脱敏验收记录。保留旧 Agent、CLI、iOS 和服务端现有改动。新工程不 import、执行或包装 RM500 CLI，也不直接依赖旧 Agent。

### 冻结的实现决定

- module path 为 `airsim.local/airsim-agent`；使用本机已经校验的 Go 1.24.13 工具链，`go 1.24.0`，R1 仅使用标准库。正式设备构建 `CGO_ENABLED=0 GOOS=linux GOARCH=arm64`。其他目标本轮仅保留明确未实现的 profile 状态，不修改或操作 EG25/AVF。
- `cmd/airsim-agent/` 只负责配置与生命周期；内部划分 `hal`、`identity`、`at`、`platform/rm500u`、`state`、`transport/local`。依赖由入口装配，HTTP handler 不直接读写设备。
- 只启用明确指定的 `rm500u-embedded` profile。未知或尚未实现的 profile 启动失败，不 fallback。仅允许明确配置的 `/dev/smd1`，不扫描试开其他设备节点。启动验证 Linux ARM64、ATI 的 RM500U-CN 及固件 RM500UCNAAR01A18M2G；不匹配时停止设备适配，报告原因，不套用已测能力。
- 本轮 Telephony 只观察通话状态，Radio/SIM 提供 SIM 就绪、信号、注册、IMS 快照；Network 只读取本机接口状态；Platform 提供启动、版本和资源信息。Messaging 和 Audio 明确返回未实现/未就绪，不通过存在节点宣告可发短信或双向语音。六类 HAL 的本轮接口只定义这些查询与能力描述，不擅自设计后续写操作。
- 实机查询严格限于 `ATI`、`AT+CGMR`、`AT+CPIN?`、`AT+CSQ`、`AT+CREG?`、`AT+CGREG?`、`AT+CEREG?`、`AT+CIREG?`、`AT+COPS?`、`AT+CLCC`。允许按需使用其中子集。错误报告 unknown/unavailable，不转成零信号、未注册或无通话。快照不包含号码、短信、IMEI、IMSI、ICCID 或原始 AT 文本。
- AT manager 是一个长期 reader、有界请求队列、单在途事务、URC 分流；单事务上限 5 秒，完整轮询上限 30 秒，正常间隔 10 秒。首次启动验证后先生成快照，HTTP 只读取快照，不为每个请求再次访问 AT。响应大小和队列必须有上限；超时/丢连接后不得把迟到响应当作下一条结果。先关闭、隔离失步连接并退避恢复；无法证明重新同步时保持不可用。
- 打开端口期间持有按字符设备 rdev 对应的非阻塞 flock，采用已存在的 `/run/lock/rm500-<十进制rdev>.lock` 互斥约定，独立实现，不依赖 CLI 代码。另用运行目录的实例锁防止重复进程。不得 unlink 被持有的锁文件或误删其他进程 socket；退出释放自己的 FD/锁/socket。
- 持久目录 `/mnt/data/airsim-v2/`，运行目录 `/run/airsim-v2/`，目录 0700。发布程序放在持久目录独立 `releases/` 下，配置/身份独立于二进制；不覆盖 `/mnt/data/airsim/bin/rm500` 或任何 v1 安装。
- 使用标准库 Ed25519 生成设备密钥；随机 UUID module_id 与密钥一起原子持久化（0600 文件、同步文件及目录），重启保留。身份损坏/部分写入/读取失败时 fail closed，不能自动换身份。每次进程启动产生不同 agent_boot_id。当前身份状态为未入网，不能声称有账户归属、设备证书或 Relay 激活完成。私钥不输出到 HTTP、日志、测试报告或主机。
- 本轮本机接口只监听 `/run/airsim-v2/control.sock`，socket 0600；不开放 TCP、任意 AT、shell 或写操作。GET `/healthz` 表示进程存活；GET `/readyz` 表示本轮只读适配与快照就绪；GET `/v2/local/capabilities` 与 GET `/v2/local/snapshot` 返回类型化数据；其他路径/方法拒绝。诊断接口不是冻结的云端 v2 协议。
- 快照含 schema_version=1、module_id、agent_boot_id、单进程单调 revision、observed_at、freshness、字段级可用性；无法刷新必须体现过期/错误，不能继续以旧值报告就绪。30 秒未成功更新的必要只读状态不得保持 ready。Audio 未实现本身不阻止只读 ready，但必须明确 `scope=read_only`、voice_ready=false。
- 本轮无开机自启、根分区写入、固件更新、RF/USB/APN/路由写入、基带/厂商服务重启、云端连接和媒体采集。允许部署、启动/停止/重启本轮 Agent、验证异常退出及恢复；SIGKILL 仅针对本轮确认的 PID。

### 验收门槛

1. 本机 `go test -race ./...`、`go vet ./...`、Linux ARM64 静态构建通过；测试覆盖身份不变/损坏拒绝、未知 profile、AT 分片/URC/超时迟到响应、锁冲突、过期快照、接口路径/方法白名单及正常退出。
2. ADB 每次部署前重新枚举并核对目标，不复用旧 transport ID。核对目标二进制 SHA-256，所有设备操作显式检查设备侧退出码；旧 ADB 主机退出码不足以证明成功。
3. 实机通过 curl 的 Unix socket 查询四个接口，取得当前真实信号/注册/IMS/SIM/通话状态或具体不可用原因。连续观察至少 3 分钟，记录 RSS/峰值、FD、线程与 revision 进展，不保存敏感原始响应。
4. 第二实例被拒且原实例健康；正常 SIGTERM 后无残留进程/设备 FD；重新启动 module_id 相同且 boot_id 改变；针对本进程 SIGKILL 后也可恢复身份与锁/socket。只停止本轮启动的进程，不对厂商组件故障注入。
5. 报告新 Agent 的实机证据、资源、剩余空间、部署文件与 PID，以及未验证项。R1 不代表永久安装、TLS/Relay、通话、短信、音频或 EG25/AVF 验收。

遇到任何需要改变上述决定的事项，先给出事实/证据与阻塞点，交主控裁决，不自行选择替代技术方案。

### R1 主控补充裁决 01

以下为执行端提出的三项问题的决定，优先于上文的概括表达。

**只读就绪**：必要条件是型号/固件验证通过、AT 未失步，SIM 查询、CSQ 查询、CLCC 查询和至少一种注册查询取得可解析结果且距观察时间不超过 30 秒。`CPIN` 非 READY、CSQ=99、注册状态为未注册都可以是有效观察，不等于字段采集失败，也不等于语音就绪。IMS 查询失败时字段 unavailable、overall degraded，但只要上述必要条件成立，`/readyz` 返回 200、ready=true、degraded=true。缺任一必要条件返回 503。没有 SIM 导致 CPIN 查询返回无法解析的错误时，该字段不可用，不能凭空构造状态。任何情况下 R1 voice_ready=false。

**AT 失步**：R1 不实现自动恢复不明事务。超时、部分写入、响应超限或在途 I/O 失败立即使本次 AT session 不可用，取消队列、关闭端口并保留进程/诊断接口，不再发 AT；保留实例锁，报告 `at_desynchronized`。在 `/run/airsim-v2/at-inflight.json` 记录开始发送的只读命令名称（无参数/响应），只有收到该事务明确终止且成功完成分帧才删除；失步或异常退出时保留该记录。启动时存在记录则只提供诊断，不重开端口、不自动删标记。该标记是 tmpfs 的进程恢复栅栏，不是掉电后的硬件事务日志。故障后的解锁/物理恢复由主控另行决定，本轮不得自动通过重启擦除栅栏。

正常新建 session 在没有栅栏时先读取并丢弃残留数据，须连续安静 500ms、总等待上限 5 秒；随后用 ATI/CGMR 的精确预期内容验证设备，不能仅 OK 就算通过。查询中 NO CARRIER/RING 等作为 URC，不将它们当作只读查询的成功终止。响应关联按命令的预期前缀，未知/不合预期响应保持不可用。真实 SIGKILL 验收选择两次轮询之间、明确没有在途标记的空闲窗口；在途 kill 留栅栏并拒绝恢复的行为用隔离 fake/进程测试验证。不得故障注入到厂商进程。

**身份编码**：`config/identity.json` 为严格 JSON，大小上限 4096 字节，字段仅 `schema_version`（1）、`module_id`（随机 UUID v4）、`algorithm`（`ed25519`）、`seed_base64`（标准带 padding Base64，解码 32 字节）、`public_key_base64`（解码 32 字节）。读取时验证字段/类型/UUID/长度和派生公钥一致；未知字段、重复字段、尾随数据、损坏、部分文件及符号链接均拒绝，不能自动再生。创建时临时文件 0600、fsync、同文件系统原子安装且不覆盖已有身份，再 fsync 目录；持有实例锁避免并发初始化。内部 Go 字段按此结构机械映射，seed 不进入任何外部响应。

**本地 JSON 结构**：以下字段是本轮主控固定契约，执行端只实现其序列化，不新增业务语义：

```text
healthz: {status: "ok", version: string, agent_boot_id: UUID}
readyz: {ready: bool, scope: "read_only", degraded: bool,
         voice_ready: false, reasons: [固定错误码]}
capabilities: {schema_version: 1, module_id: UUID, profile: "rm500u-embedded",
               capabilities: {telephony: Capability, messaging: Capability,
                 radio_sim: Capability, audio: Capability,
                 network: Capability, platform: Capability}}
Capability: {support: "unknown"|"supported"|"unsupported",
             readiness: "ready"|"unavailable"|"degraded", reason: string}
snapshot: {schema_version: 1, module_id: UUID, agent_boot_id: UUID,
           revision: uint64, observed_at: RFC3339Nano UTC,
           freshness: "fresh"|"stale"|"unavailable", scope: "read_only",
           voice_ready: false, identity_state: "unenrolled",
           fields: {sim: Field, signal: Field, registration: Field, ims: Field,
                    calls: Field, network: Field, platform: Field}}
Field: {status: "available"|"unknown"|"unavailable", observed_at: timestamp|null,
        source: string, error_code: string, data: 指定对象|null}
sim.data: {state: string}                         # CPIN 状态，不含卡标识
signal.data: {rssi: int, ber: int, dbm: int|null}   # CSQ=99 时 dbm=null
registration.data: {cs: int|null, packet: int|null, eps: int|null}
ims.data: {registration: int}                     # CIREG 的注册字段，不是 URC 模式
calls.data: {count: int, states: [int]}             # CLCC 状态，不含号码/原文
network.data: {interfaces: [{name: string, up: bool, loopback: bool}]}
platform.data: {os: "linux", arch: "arm64", kernel: string,
                mem_total_kib: uint64, mem_available_kib: uint64}
```

error_code/reasons 使用 `query_failed`、`invalid_response`、`timeout`、`stale`、`not_implemented`、`at_desynchronized`、`identity_invalid`、`profile_mismatch`、`initializing`，无错误为空字符串。注册字段允许个别查询失败为 null，但全部失败则 Field 不可用。未实现的 Messaging/Audio support=unknown、readiness=unavailable、reason=not_implemented。其余 support=supported 只表示本轮查询范围，不代表写操作或语音支持。

快照 revision 每次完整采样结果提交时递增（失败结果也提交）；字段 observed_at 只在该字段真正取得新观察时更新，失败字段 data=null，不拿旧值当新值。时效用 Go 单调时钟判断，墙上时间仅用于 observed_at；设备时间未校准不通过改系统时钟修复。源码方法名、循环和局部变量可按以上固定行为直接编码，不属于额外技术选型。

R1 固定实现参数：版本标记 `2.0.0-dev.r1`；AT 请求队列 16、URC 队列 64、单行上限 4096 字节、单事务响应上限 16384 字节。队列满立即返回明确错误，不无限阻塞/分配；URC 溢出使当前状态失效，在健康的 AT session 下一轮完整采样后再恢复，不按丢失事件推断状态。HTTP ReadHeaderTimeout=5 秒、WriteTimeout=5 秒、IdleTimeout=30 秒、MaxHeaderBytes=8192；正常退出总预算 10 秒。测试专用超时可注入缩短，但发布默认值不变。实例锁先于身份初始化/端口/socket 操作；检测同一持久目录的多实例还需持有该目录内的 flock，避免用不同 runtime-dir 绕开身份初始化锁。

Linux SMD 端口 adapter 直接使用非阻塞 syscall.Read/Write；EAGAIN/EWOULDBLOCK/EINTR 使用可取消的 10ms 等待，不视为故障、不忙转，也不依赖 os.File 对字符设备的 poll/阻塞转换。此专用字符设备读取返回 0 字节且无错误时同样等待，不能套用普通文件/管道的 EOF 假设。测试必须覆盖暂无数据时取消、关闭以及退出预算；独立实现，不使用 CLI 代码作为库。

正常 SIGTERM 先停止新请求/新采样，让当前只读事务在原有 5 秒预算内收完终止行再关闭，不能因全局 context 取消而必然遗留栅栏。没有收完或发生 I/O 异常才保留栅栏，总退出预算仍为 10 秒。异常 SIGKILL 的栅栏语义不变。Unix socket 清理仅限持有实例锁、探测明确为 ECONNREFUSED 且删除前目标仍为同一 socket inode；超时、权限或其他连接错误不能作为陈旧证明，必须拒绝清理/启动。

### R1 主控补充裁决 02：实机 ATI 失败调查

实机首次运行出现 ATI 错误终止，型号验证失败；不得视为型号不匹配或放宽型号。允许在停止本轮 Agent 并确认其退出后，以独立测试探针在相同 rdev 锁下调查 `/dev/smd1`，不借助 CLI 作为后端。

- 允许读取 TCGETS 与 errno。打开端口增加 O_NOCTTY。若 TCGETS 成功，保存原 termios，再采用局部 raw 模式（Iflag/Oflag/Lflag=0，8N1、CREAD/CLOCAL、115200、VMIN/VTIME=0）；退出恢复原 termios。若 ENOTTY，不调用 TCSETS、不把它当作错误。其他 ioctl 错误报告主控，不盲改。
- 调查只使用 ATI 和 AT+CGMR。先测试现有 CR 结尾；若事务明确错误终止且没有在途请求，可在独立探针中比较 CRLF，一共最多四次查询。不得切换 RF、USB、回显模式或厂商服务，也不发送任意恢复命令。超时仍保留栅栏，不以重开端口代替恢复。
- 记录 ioctl 支持情况、终止类型及数值 CME/CMS 错误码、已知型号/固件是否精确匹配，不记录其他原始文本。只有采到实际差异后才能确定根因；行结束符如需变更，报告主控后定案。termios raw 支持属于已授权的端口局部适配。

调查回报：TCGETS 可用，设置 raw 后 ATI + CR 已成功并精确匹配 RM500U-CN，故保持 CR，不尝试 CRLF。CGMR 成功但文本形式未匹配。主控追加一次单独的 CGMR 查询，允许仅在会话内查看最多四行、每行 128 字符的产品固件文本以确定匹配规则；不输出其他标识，不进入运行日志或仓库，不重跑整组探针。

主控定案：本次 CGMR 实际产品版本为 `RM500UCNAAR01A18M2G_01.001.01.001`。这是可公开的固件版本元数据，允许在档案中记录。R1 固件白名单改为这个完整字符串（允许协议规定的外部空白修剪），不使用前缀/包含匹配，不接受任意后缀。型号仍精确匹配 RM500U-CN；CR 和已验证的 raw 端口设置保持不变。测试补同前缀不同后缀的拒绝案例，之后继续完整 Agent 实机验收。

### R1 结束时的后续阶段设备证据（历史记录）

主控通过当前设备 `org.ofono.Manager.GetModems` 与 Introspect 查询确认：当前唯一 modem 对象为 `/ril_0`，提供 VoiceCallManager 的 Dial/GetCalls/SendTones 与 CallAdded/CallRemoved，提供 MessageManager 的 SendMessage/GetMessages、IncomingMessage/MessageAdded/MessageState 等接口。实际实现须通过发现绑定对象，不硬编码这个临时路径。接口存在不代表方法或运营商链路已经通过新 Agent 实测。

R2 的 D-Bus 客户端候选已核对为 [godbus/dbus v5.2.2](https://github.com/godbus/dbus/tree/v5.2.2)，其 [go.mod](https://github.com/godbus/dbus/blob/v5.2.2/go.mod) 声明 Go 1.20 与 golang.org/x/sys v0.27.0；R1 仍只用标准库，不能提前添加此依赖。oFono [短信接口文档](https://kernel.googlesource.com/pub/scm/network/ofono/ofono/+/master/doc/messagemanager-api.txt) 中 SendMessage 返回对象只代表成功入队，不能报告为手机已收到；后续还需消息状态和接收端证据。

## 后续阶段

- R2（功能实机闭环通过）：[主控契约](RM500_AGENT_R2.md) 已实现 oFono 通话控制、短信、统一命令状态机与去重/未知结果语义；[验收记录](../module/airsim-agent/R2_TESTING.md) 区分真实业务证据、fake 测试及收件重复/延迟等未解释现象。DTMF 仅证明后端接受，voice_ready 仍为 false。
- R3：独立音频 helper 与持续双向 PCM；先验证实际格式/路由，PCM 仅内存和匿名管道，不录音。真实接收端和持续可辨识音频是完成条件。
- R4：与 ECS v2 的身份、激活、控制和媒体契约联合验收；已调度两端实现，不能用 fake 通过代替真实云端闭环。
- R5：匹配当前固件的稳定启动器、独立更新与回滚；永久启动入口需另行确认，手动运行不算开机可用。

## R1 验收结论（2026-10-24）

新工程、设备部署与只读闭环通过。最终 SHA-256 为 `b9659d09758375ba8597654339d7b76f63603c7588134b478e7a9b3481569707`，设备路径 `/mnt/data/airsim-v2/releases/b9659d09758375ba/airsim-agent`，验收结束保留 PID 6367。主控独立构建的 SHA-256 与设备文件一致，并独立检查当前 PID 对应 executable、四个 Unix socket 接口与目录/文件权限。

- 最终构建完成 180 秒观察，19 个采样点均为 fresh/ready，revision 从 1 增至 19；RSS 为 6768–11568 KiB，FD 恒为 10，线程为 7–8。这是短时验收，不是长时间运行或内存泄漏证明。
- 当前 SIM 为 READY，EPS 和 IMS 注册字段均为 1，无通话；信号随实测变化。保留 `scope=read_only`、`voice_ready=false`、`identity_state=unenrolled`，Messaging/Audio 明确未实现。
- 重复实例被拒；SIGTERM 退出约 0.095 秒；正常重启与空闲 SIGKILL 后恢复均保持 module_id，生成新的 boot_id。异常在途退出保留栅栏通过 fake 子进程验证，未对真实基带进行在途故障注入。
- 正常探针退出的 termios 恢复与回读校验通过；SIGKILL 无法执行恢复，不宣称其恢复原终端设置。旧诊断构建与探针已从设备清理，保留身份与最终构建，持久分区剩余 21376 KiB。
- race、vet、静态 ARM64 构建通过；主控复核并补齐身份 JSON 字段名严格区分大小写的拒绝测试。没有访问设备私钥内容，没有拨号、发送短信或采集音频；测试号码只保留在会话上下文。

最终构建的采样与生命周期证据分别见 [R1_EVIDENCE.json](../module/airsim-agent/R1_EVIDENCE.json) 和 [R1_LIFECYCLE.json](../module/airsim-agent/R1_LIFECYCLE.json)。旧构建证据按对应 hash 归档，不混作最终产物验收。Agent 执行会话结束本轮进入待命，其余执行会话继续待命。

## R2 主控验收结论（2026-10-24）

`2.0.0-dev.r2` 已在同一 RM500U-CN 实机完成呼出接通、授权号码来电接听、具体通话挂断与拒接、DTMF 后端接受、短信发送与接收的功能闭环。执行会话按主控契约实现，业务实测由主控操作新 Agent Unix API，用户手机配合接听与回拨；没有使用旧 CLI 绕过新 Agent 执行业务。

- 本机 race、vet、依赖校验和静态 ARM64 构建通过，180秒只读观察通过。最终构建 SHA-256 为 `b603f0cf5958a0adfd131b5a52bb7eb359d9a5a93c56923ee4000e4022803cb8`。
- 通话控制观察到 active、定向挂断/拒接后的 disconnected/local，接听与挂断命令达到 observed。DTMF accepted 仅代表后端接受，音频未验收，voice_ready=false。
- 发出短信的随机标记在 Mac 接收端匹配；回复短信的发送者与标记在 Agent 匹配。同一发送命令在进程内及空闲重启后均返回原回执，未新增发件记录。一次回复在 Agent 至少出现3条匹配接收记录，延迟与重复原因未确定；保留原始事件，不按正文去重，不宣称网络严格去重或生产可靠性通过。
- 空闲 SIGTERM 约0.062秒退出，身份、二进制与9条命令记录保持。最终 PID 14054，boot `390e3983-b60d-4df6-971e-4ed04bc27d33`，backend epoch `c44cf913-4fb7-4807-9259-83465faecb11`。交接时只读和控制就绪，无活动通话。收件历史仅在内存，重启后清空；没有开机自启。

详细结果见 [R2_TESTING.md](../module/airsim-agent/R2_TESTING.md)、[业务证据](../module/airsim-agent/R2_BUSINESS_EVIDENCE.json) 和 [空闲重启证据](../module/airsim-agent/R2_RESTART_EVIDENCE.json)。Agent 执行会话完成本轮后待命，其他执行会话及 R3–R5 仍等待主控调度。
