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
