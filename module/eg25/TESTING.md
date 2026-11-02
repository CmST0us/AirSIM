# EG25 QDC507 验证记录

2026-10-29，当前 ADB 模块：`EG25G_QDC507 / QDC507GLEFM21_02.004.03`，ARMv7、Linux 3.18.44、43,460 KiB RAM。本文记录 EG25，不沿用 RM500 的运营商验收结果。

## 已验证

- 精确固件识别、持久模块身份、受保护 Unix API、AT 控制后端；`CLCC` 的两条 data call 不计入语音通话。
- DATA11 字符设备和 QDC507 音频驱动加载，VoLTE ACDB 校准完成。ADB、ECM 保留。
- 一次真实来电，Agent 接听后进入 active；15 秒媒体会话完成并定向挂断，最后无活动语音通话，D4/D5/D6 均关闭。
- 外部媒体上行 750 帧、下行 752 帧，两方向序号缺口均为 0。采集 120,320 个样本，97,145 个非零，峰值 29,895，RMS 2,722.87。只统计信号，不保存 PCM。
- 原生 helper 在 14.273 秒统计点采集 113,920、播放 115,968 个样本；`input_drops=9`、`silence_samples=4000`、队列峰值 2。外部序号连续不等于内部无丢帧。
- 用户确认测试期间听到间歇提示音，声音清楚。
- 受控重启后内核 boot ID 改变，模块身份保持，电话控制 ready，ECS 自动恢复连接。
- 生产 Chrome WebUSB 完成安装并核验全部运行资源；重新选择模块后显示 `Engine 2.0.0-dev.eg25 · 开机自启`，真实模块证明和连接码生成成功。
- 更新后的实体 iPhone 完成 EG25 连接码配对，用户确认已连接；生产数据库中该模块只有一个未撤销的配对手机会话。
- 设备证书登记、激活和 ECS mTLS 控制连接成功。启动器使用官方 ISRG Root X1 补充固件根证书目录，保留证书校验。
- 生产 ECS control/edge 更新后健康，媒体服务与 PostgreSQL 保持健康，数据库 schema 6 不变；更新前已备份部署配置和数据库。
- Agent 全量 `go test -race ./...` 与 `go vet ./...` 通过；原生音频测试、ECS control/wire 测试通过；网页 37 项测试和生产构建通过。
- 当前 iOS 源码已完成设备目标构建，用本机有效开发签名更新到 iPhone 16 Pro Max；构建时注入本次部署的 `AIRSIM_V2_PAIRING_ORIGIN`，原 App 数据保留。
- iOS 模拟器构建通过；EG25 型号查询、claim 丢失响应后相同安装实例重试、持久配对配置提交测试通过。

## 首轮验收边界（APNs 接入前）

提示音可听性已确认；持续双向语音质量仍需独立验收。用户暂不方便继续测试，EG25 经实体 iPhone/ECS 的云端通话音频、运营商短信双向、长时间稳定性及后台通知尚未验收。最终检查无活动通话或 helper，D4/D5/D6 均关闭；电话和短信控制 ready、ECS connected，网页更新后的内核 boot ID 保持不变。当前固件不支持 `AT+CIREG?`，不据 LTE 注册推断 IMS。`voice_ready` 保持 false，音频为显式实验能力。ECS 当前未配置 APNs provider，Watch v2 和 Worker v2 未实现。

## 2026-10-29 APNs / CallKit 服务连接

Agent 接受 `airsim-v2-callkit` 的 `apns:true`，并保留 R4.1 与未知 profile 的限制。cloud 包测试覆盖两个有效 profile 的 APNs 开关组合和未知 profile。ARMv7 构建已部署到 `/usrdata/airsim-v2/releases/apns-callkit-20261029`，BusyBox init 拉起后确认 `connected:true`、`last_error` 为空。

回滚版本 `releases/acac9467f9dfe6a4` 留在模块；更早的 `cfbb0c2f825b20e2` 已备份到维护主机后移除。当前剩余空间约 5,008 KiB。iPad mini 的新 App 已安装启动并完成替换配对，ECS 确认 Sandbox VoIP 与通知 token 均已注册；真实 PushKit / CallKit 来电待验收。线上网页的 EG25 / RM500 Agent 安装资源已同步，旧资源保存在 ECS 的 `backups/engine-before-callkit-20261029`。

## iPad mini 音频诊断

真机 XCTest 读取到媒体启动失败为 `stale / openingSocket`，对应 `snapshotExpired`，快照年龄 8.076 秒。模块通话状态稳定时每秒发送快照，空闲时保持五秒；客户端八秒新鲜度限制不变。cloud 测试覆盖来电、拨号、活动通话和已断开状态的刷新行为。

当前模块版本为 `releases/call-snapshot-20261029`，回滚版本 `releases/apns-callkit-20261029` 保留。更早版本备份在维护主机。iPad mini 的本机三秒音频 UI 测试通过：48 kHz、单声道、语音处理开启，采集 150 帧、播放 131 帧。此结果验证本机采集和播放，不代表运营商通话双向音频验收。

## iPad mini / ECS 双向媒体

2026-10-29 23:41（北京时间），`com.eric3u.airsim2` 在实体 iPad mini 上通过 `testIncomingCallAudioOnDevice`：真实 SIM 来电，App 内接听，约二十秒后自动挂断。PushKit 结果为 `reported`，模块媒体会话进入 `streaming`，结束原因为 `media_closed`。

| 观测项 | 结果 |
| --- | ---: |
| iPad 接收 / 发送帧 | 276 / 558 |
| iPad 采集 / 播放帧 | 780 / 519 |
| iPad 序号缺口 / 播放补零帧 | 194 / 323 |
| 模块云端输入缺口 / 本地输入缺口 | 209 / 0 |
| 模块队列丢帧 / 补零帧 | 109 / 373 |

音频格式为 48 kHz 单声道，VoiceProcessing 开启，输入为内置麦克风、输出为扬声器；最后媒体失败和资格失败均为空。已验证双向媒体与本机采集播放，存在缺口和补零；持续语音质量、锁屏系统界面接听后的完整媒体流程仍待验收。

## 后台来电持续显示

2026-10-29 23:48、23:52（北京时间），新版 App 在 iPad mini 后台接收两次真实来电，PushKit 与 CallKit 上报均成功，来电核对未失败，未触发拒绝推送的占位提示。用户确认两次来电提示保持显示，不再出现“旧版通知”短暂闪现。

已上报到 CallKit 的来电，其系统错误回调不再创建额外占位来电。后台 UI 自动化未定位到系统接听控件，因此本项仅验收后台来电持续显示；系统界面接听与锁屏音频不计为自动化通过。前台 App 内自动接听的双向媒体结果见上一节。

## 控制会话稳定与短信去重

2026-10-31（北京时间），iPad mini 来电出现重复响铃与占位来电。Agent 日志定位到两处控制会话重建：QDC507 响铃期间 `AT+CLCC` 连续返回 CME 100，原实现连续三次即重建；SIM 中一条无法解码的存储短信使每次新会话的首轮 `AT+CMGL` 判为无效，会话约每 2 秒重建一次，每次分配新的 call_id 与 backend epoch。修复后空闲观察 55 秒无重建，后续来电 call_id 保持稳定。已上报短信改为持久摘要记录，部署时 SIM 中现存 4 条短信仅登记、未重复推送。

## 抖动缓冲与追播

同日连续实测 iPad mini 接听真实来电。修复前 57 秒通话中 Agent 补零 226 帧、队列丢弃 36 帧，helper 输入丢弃 51 帧。加大接收端缓冲并将晚到时隙改为逐包追播后：

| 观测项 | 28 秒通话（App 已追播） | 48 秒通话（Agent 已追播） |
| --- | ---: | ---: |
| 网络输入缺口（双向） | 0 | 0 |
| Agent 队列丢弃 / 补零 | 50 / 0 | 4 / 0 |
| helper 序号缺口 | 26 | 0 |
| App 补偿帧 / 序号缺口 | 21 / 23 | 6 / 4 |
| App 跳过时隙 / 播放丢帧 | 0 / 0 | 0 / 1 |

用户确认通话连贯。iPad 主线程计时最长延迟 60 ms，均由追播吸收。

## 16 kHz 宽带

通话中探针以 16 kHz 打开 VoLTE 前端、D5 与 D6 均成功；下行 4–7 kHz 有显著能量，8 kHz 采集无此频段；上行 6 kHz 提示音在对端可闻，确认运营商通话两方向均为宽带。探针仅统计频段能量，不保存音频。

2026-11-01 配套部署 16 kHz 版 ECS、Agent、helper `0.5.0-lc3-wb` 与 App 后，iPad mini 接听真实来电约 25 秒：helper 采集与播放均为 16 kHz，无 xrun、无序号缺口，静音补偿 120 ms；Agent 队列丢弃 2 帧、无补零；App 补偿 5 帧、播放无丢帧。用户确认听感良好。线上网页安装资源已同步，与模块运行版本一致。部署后有一次来电在接听前显示“呼叫失败”，ECS 未收到接听命令，后续通话未复现；Debug 构建保留通话路径诊断记录用于定位。

## WebRTC 媒体

可行性验证：运营商网络可用 UDP，出口 NAT 为对称型（访问不同目的地时公网 IP 与端口均变化），模块须经 TURN 中继。Pion 两个对端同进程收发时常驻内存峰值 6.1 MB、约 18.7% CPU，即单路约 10%；libopus 定点构建复杂度 3 时编码加解码约 1.35–1.7 ms／20 ms 帧，浮点软浮点构建约 11 ms，不可用。

2026-11-01 部署 Agent `2.0.0-dev.webrtc` 与 helper `0.6.0-opus`，同日更新为断线保持与实时音频线程版本。Agent 在 UBIFS 上压缩后约占 7 MB，用户分区只容一个 Agent 发布目录：模块现存 `releases/stability-20261101` 与 helper `audio-releases/stability-20261101`（上一版 helper `webrtc-20261101b` 保留用于回滚），剩余约 6.8 MB；被替换的 Agent 与 LC3 版本均备份在维护主机。替换 Agent 时先把 `current` 指向只执行 `sleep` 的占位脚本，再删除旧版本、推送新版本并切回，离线约 20 秒。空闲 Agent 常驻内存约 9 MB，系统可用内存约 6–7 MB。

真实来电（iPad mini，约一分钟）双向通话正常：从接听到媒体连接约 3 秒；模块到 iPad 无丢包，iPad 抖动缓冲约 205 ms、补偿约 3%；iPad 到模块丢包约 2.9%，其中 54／76 由 FEC 恢复；helper 采集帧有 58 次超过 60 ms 的等待（最长 120 ms），Agent 发送只有 1 次超过 20 ms，App RTP 到达有 45 次超过 100 ms 的间隔（最长 172 ms）。通话中 Agent 进程约占 32% CPU、helper 约 16%；接通时 Agent 约有 1,200 次主缺页，即从压缩分区重新读入约 5 MB 代码。helper 工作线程固定 256 KB 栈：默认 8 MB 栈预留在可用内存不足 8 MB 时会被内核拒绝，导致 `thread_start`。


## 2026-11-01 Chrome / macOS 网页更新与断电自启

使用同一块 QDC507，在生产 `https://airsim.eric3u.cc/` 点击“更新并启用”。首次实测发现固定 70% 压缩率预估会错误拒绝更新；网页修复复用未变化文件，并在每批 256 KiB 传输前检查实际可用空间、保留 512 KiB 余量。57 项网页测试通过，修复通过 Workbench 发布为 `installer-20261101-spacefix`，26 个线上资源 HTTPS 校验通过，四个业务容器未重启。

23:19 网页显示 `Engine 2.0.0-dev.webrtc · 开机自启`。模块当前目录为 `releases/032488520694b1d4`，Agent SHA-256 为 `032488520694b1d41f30275a04f1f219d4e021801d3041998e0b1a33f4e49fc9`；唯一 Agent 的 PPID 为 1，`/etc/inittab` 只有一条正确的 `asm:12345:respawn:/usrdata/airsim-v2/run-agent.sh`。

用户实际断开 USB 电源至少 10 秒后接回。23:20:56 只读检查：内核 boot ID 从 `2e72bf84-9182-4a4f-991f-7fa3edb61235` 变为 `127de8bc-5d5f-448e-bb42-3b22da6a9d04`；开机约 70 秒时 Agent PID 728、PPID 1，运行文件哈希匹配上述发布包；health/ready 均为 200，cloud configured/connected 均为 true。没有执行手动启动命令。identity/cloud 配置哈希与更新前相同；根分区保持只读。启动过程中出现一次正常 USB 重枚举，首次过早接口读取未就绪，随后恢复。

以上验收仅覆盖安装更新、自启动、配置保留与云连接；不增加真实通话、短信或音频验收结论。首次安装与断电自启也已完成，见下节。

### ADB 关闭路径

同一块已授权模块将 `AT+QCFG="usbcfg"` 的 ADB 位由 1 改为 0，保留其他位，断电重启后 Chrome 原生选择器能显示 Baiwang；网页通过 USB AT 识别固件并显示“准备 EG25 模块”。此处复现的是 ADB 接口关闭状态，不把已有 QADBKEY 授权说成未授权出厂状态。

真机初次点击开启时，网页误把 CLCC 的 mode=1 蜂窝数据连接判为语音通话而阻止初始化。修复只跳过明确的 mode=1 连接，未知或语音模式仍拒绝；58 项网页测试通过，23:27 发布 `installer-20261101-clccfix`。随后在生产网页点击“开启 ADB 并重启”，实际完成授权、配置和重启，macOS 重新枚举出 interface 6 的 ADB（ff/42/01），内核 boot ID 为 `1cb5faab-fc33-4a82-bc1d-fdedbd9d9f8a`。

为测试完整安装，停止自启动后移除 Engine 程序文件（Agent、启动器、helper、驱动与许可证），保留 `config/` 和 `state/`；用户分区空闲 15,436 KiB。23:38 经网页“安装并启用”完成全部文件写入，启动时 USB composition 从含 serial 切换为 `diag,ecm,ffs`，网页提示重新选择以确认结果。模块侧只读核验 14 个资源全部匹配 manifest；唯一 Agent PID 1564、PPID 1，Agent/launcher/helper 哈希正确，health/ready 均为 200，cloud configured/connected 均为 true，身份与配置哈希未变，用户分区空闲 7,616 KiB。安装后的第二次真实断电检查已通过。用户确认 USB 断电至少 10 秒并重新接入，未手动启动 Agent。23:52:57 核验：内核 boot ID 从 `1cb5faab-fc33-4a82-bc1d-fdedbd9d9f8a` 变为 `6aae827c-8749-44bf-9058-dcdb60c8340b`；开机约 87 秒时只有 Agent PID 732、PPID 1，运行哈希匹配最新发布；health/ready 均为 200，cloud connected 为 true，identity/cloud 哈希未变，根分区只读。网页重新检查后显示 `Engine 2.0.0-dev.webrtc · 开机自启`。

更新和完整安装两条路径的断电自启均通过。四次只读快照见 [结构化验收证据](WEB_INSTALLER_TESTING_20261101.json)。最终网页为 `installer-20261101-reconnectfix`（23:39），仅修正重连核验页沿用旧“未安装/需要开启 ADB”标签；模块运行包不变。58 项网页测试、TypeScript 和 Vite 构建通过。新云端登记、未授权出厂状态、崩溃恢复和写入途中断电不包含在本轮实测范围。

## 2026-11-02：短信编码回归与发布（非真机发送验收）

用户反馈 6 位短号短信未发送。脱敏云端收据为 `failed/backend_rejected`；已修复 EG25 目的地址误标国际号码和 UTF-8 误作 UCS-2。30 组 AT 层发送数据回归、单条限制、失败不重发、Agent 全量 race 测试与 vet 通过；旧源码 overlay 可复现错误。14:35 经 Workbench 发布网页包 `sms-pdu-20261102`，Agent SHA-256 `a52867a0c963a59805c99ade4ea32b449fe6974e605c4c002b1693af8081f6e2`，公网下载复核通过。未代用户更新模块或发送短信，运营商发送/送达与断电验收仍待用户实测；[修复详情](../../docs/EG25_SMS_FIX.md)。

## 2026-11-02 短信满仓回收与真实收件

固件仍为 QDC507GLEFM21_02.004.03。诊断确认读取、写入、接收存储均为 ME，23/23，CNMI 为 2,1,0,0,0；原 Agent 只读不删除，存储无法腾出位置。

用户授权清理旧短信并要求满仓自动清理后，安装 `acaaade7337fc2db…`。21:56:36 自动回收 6 个存储槽位，23/23 降为 17/23；随后新增 5 条收件。21:58:36 再次满仓并回收 5 个槽位，21:59 模块与云端均有 7 条 incoming、1 条 outgoing，用户确认 SkySIM 显示刚发送的测试短信。21:59 的存储为 20/23，读取与回收错误均为空。仅记录数量、时间和固定错误，不保存号码或正文。

配置文件摘要前后相同，运行二进制哈希与网页安装包一致；唯一 init 项、原启动器哈希不变，TERM 后 init 自动拉起新版并恢复云连接。保留诊断版 `946def0c9a87d6ba…` 回滚，安装后用户分区剩余 584 KiB。本轮没有对最终修复版执行物理断电自启验收，11-01 的断电测试记录不变。

21:30 维护准备期间发生过一次整机自重启，用户确认未拔插。此前没有执行短信删除；恢复后仍为 23/23。固件未提供前次内核持久日志，现存日志无明确 OOM、panic 或复位原因，不能归因于电源或软件；到 22:02 未再次整机重启。该项仍待独立定位。

网页诊断与匹配 Engine 已经 Workbench 发布，源站 26 文件及公网关键文件校验通过，ECS 业务容器未重启。完整记录见 [收件修复](../../docs/EG25_SMS_RECEIVE_INVESTIGATION.md) 与 [部署证据](../../docs/EG25_SMS_RECEIVE_DEPLOYMENT_20261102.json)。
