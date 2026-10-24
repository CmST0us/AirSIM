# 测试和设备验收

CLI 已部署到 RM500U 的持久目录。已测控制项与蜂窝数据通路通过实测。2026-10-24 更换联通 SIM 后，真实呼出已达到 active，用户确认手机清楚听到模块注入的测试音；用户按顺序说话、静音时，模块采集到明显 PCM，但静音段仍有残余音频。双向音频已有实测证据，尚未完成语音清晰度、静音残留和持续双向 PCM 桥验收。此前电信 SIM 的快速断开保留为历史对照。

## 自动测试

15 个顶层测试（另含 TCP/PCM 两个子用例），`go test -race -count=1 ./...`、`go vet ./...` 均通过；Linux ARM64/ARMv7 静态交叉构建通过。注册表共 95 个命令入口。

覆盖内容：

- 命令帮助/schema、命令去重、参数校验、注入拒绝、dry-run 脱敏、REPL 引号解析。
- AT 分片响应、终止行、CME/CMS 错误、超时、短信提示符及 UTF-16 SMS-SUBMIT 已知向量。
- 短信格式恢复失败不得输出成功。
- HTTP 实际回环服务器：方法、路径、JSON、认证、禁止重定向和 URL 逃逸。
- TCP 实际回环连接：双向二进制、EOF 半关闭、PCM 握手，逐字节比对。
- 构建后的 CLI 子进程：help/schema、dry-run、非零退出与 JSON 错误。
- 音频管道的尾部 WAV 头与常规 WAV 头、截断/空数据/错误格式拒绝。
- 有符号 PCM 的峰值/RMS/直流偏置/削波统计，测试音音量和静音间隔。
- 固件 tinyplay 退出 0 但报告 EPIPE 的失败识别。

协议与音频格式测试使用可控输入；不能替代真实通话。ARMv7 仅编译验证。

## 设备与部署

2026-10-23 完成首次检查和持久部署，2026-10-24 复核。

| 项目 | 实机结果 |
| --- | --- |
| 型号 / 固件 | RM500U-CN / RM500UCNAAR01A18M2G |
| CPU / 系统 | UNISOC UDX710，ARM64，Linux 4.14.98 |
| CLI 路径 | `/mnt/data/airsim/bin/rm500` |
| 最终版本 | v0.1.1，95 个命令；SHA-256 `6ea765406d6aedf295bf3809cc4c7e3547e9c01ee5195d12ea6221a1903fea7b` |
| 部署验证 | ARM64 静态二进制，主机与设备 SHA-256 一致，设备执行 version 成功 |
| AT 入口 | `/dev/smd1`，ATI 确认型号与固件 |
| 设备退出码 | 通过设备端 `$?` 标记核对；旧 ADB shell 的主机退出码不可作为依据 |

根分区保持只读；没有安装开机服务或 Agent。可使用 `./deploy-adb.sh "$SERIAL"` 重复部署，保留一份 `rm500.previous`。

## 控制与数据实测

| 测试 | 结果与边界 |
| --- | --- |
| 只读控制基线 | 设备/功能状态、SIM PIN、信号、注册、RAT、APN/PDP、USB、NAT、短信存储、接口/路由、音频 inventory 等查询通过 |
| QCFG 枚举 | 返回 25 类配置；不代表这些配置的所有写操作已测试 |
| 静音控制 | CMUT 从 0 设置为 1，读回 1；随后恢复 0，读回 0 |
| 蜂窝附着/PDP | CGATT: 1，CID 1 与 11 处于激活状态 |
| DNS | CLI 解析 example.com 成功 |
| 蜂窝 ping | 绑定 sipa_eth0，到 1.1.1.1 的 3 个包全部返回；0% 丢包，平均约 268 ms |
| TCP 收发 | CLI stream tcp 经蜂窝向 1.1.1.1:80 发送 HTTP 请求，收到完整 HTTP 301 头与正文，设备退出码 0 |
| USB | 当前 RNDIS（usbnet=3）；只查询，没有切换，也未宣称 Mac 经 USB 网卡上网已验收 |
| 未支持查询 | AT+QGPS?、AT+CLAC 返回 CME ERROR 4，CLI 返回 5 |

以上证明模块本机蜂窝数据通路可用；不是带宽压测，也不代表 Relay 或手机 App 媒体通路已验证。

## 首张 SIM 的语音实测（历史对照）

已获用户授权，向用户提供的测试号码执行两次 AT 呼出和一次 oFono 呼出。号码不写入本文或代码。用户确认测试手机未收到来电。

1. `AT+QCFG="ims"` 为 1；`AT+CIREG?` 返回 `2,1,0005`。oFono 的 IMS 属性为 Registered / VoiceCapable / SmsCapable 均 true。
2. 当前运营商 CHN-TELECOM、LTE 已注册；voice_domain=3、srv_domain=2，呼出限制查询 `CLCK: 0,7`。
3. `calls dial` 收到 OK；独立 oFono Dial 也曾返回 `/ril_0/voicecall01`。这些只表示请求被接受。
4. 在另一次 AT 呼出前启动 oFono 信号观察，捕获 CallAdded，State=dialing、Type=PS。约 **0.392 秒**后收到 DisconnectReason=network、State=disconnected、CallRemoved。未观察到 alerting 或 active。
5. 之后 AT CLCC 和 oFono GetCalls 均为空；AT+CEER 仅返回 unknown。没有取得更具体的 SIP/基带失败码。

network 是 oFono 的分类，不能直接推断“SIM 一定不支持语音”或“运营商一定拒绝”。用户尚不确定这张 SIM 是否已开通且可正常使用语音。没有在相同条件下继续反复拨号。

## 首张 SIM 测试期间的音频证据与边界

- `/etc/audio/config/audio_pcm.xml` 将通话采集配置为声卡 0、设备 9、单声道 8 kHz；设备 5 由 audiohal 用作 modem UL/DL。
- 普通 shell 对厂商 quec-voice 二进制的静态检查发现 hw:0,9、hw:0,55、voice_cap/voice_play 和 /dev/ttyGS4 字符串。这些与实际 PCM 节点相符，但未进行完整反编译；字符串不能证明运行成功。
- mixer 的默认方向为 VOICE_CAPTURE_DOWNLINK、VOICE_PCM_PLAY_UPLINK_MIX。QPCMV 当前为 0,0，未开启 USB 语音转发。
- 通过 `audio probe --card 0 --device 9 --rate 8000 --seconds 3` 在内存中采集到 74,240 字节 PCM，采样时长 4.64 秒，峰值 3,856、RMS 约 1,838.56。两次无活动通话的结果具有相同统计值，不能当作真实下行语音证据。
- 提交过本地测试音后，v0.1.1 复核采集仍为 74,240 字节，实际耗时约 3.02 秒、峰值 2,067、RMS 约 1,462.08。数值变化也不能证明远端语音；当时没有活动通话，采样时长与实际耗时也不一致。
- 向设备 55 提交两秒 660 Hz 测试音时，tinyplay 报 `Error playing sample.ret:-32`，但进程退出码为 0。CLI 已将其识别为失败并返回 5；未确认远端可听。
- audiohal 日志还显示部分 codec mixer 设置失败；尚未证明这些错误与呼出失败有因果关系。

全部 PCM 只经过匿名管道和内存，没有录音文件或 PCM 日志。没有修改 QAUDMOD/mixer、停止厂商服务或开启厂商 PCM dump。

清理时发现没有活动通话，但 audiohal 仍保持设备 5 的 UL/DL 节点 RUNNING；空闲状态执行 CHUP 后仍未释放。对设备 `libvoice.so` 的局部反汇编确认 `audio_set_mode(0)` 向 `/dev/mmi.audio.ctrl` 写入十字节 `set_mode=0`。按该厂商接口恢复普通模式后，设备 5 播放/采集、9 采集、55 播放均为 closed；AT CLCC 仍为空，CMUT 为 0。测试过程未遗留采集、播放或 D-Bus 监控进程。

## 2026-10-24 换卡复测

用户更换 SIM 后，在同一固件、同一 CLI 上复测；未调整 IMS、RAT、音频模式或 mixer。

| 项目 | 结果 |
| --- | --- |
| 网络 | CHN-UNICOM，LTE 注册，CSQ=8，SIM READY |
| IMS | CIREG=2,1,0005 |
| 数据 | DNS 成功；绑定 sipa_eth0 的 ping 3/3 返回，平均约 268 ms；TCP 收到完整 HTTP 301 响应 |
| 呼叫控制 | 用户授权测试号码；oFono 依次报告 dialing、alerting、active |
| 首次接通时间 | CallAdded 后约 1.50 秒 alerting，约 6.35 秒 active；设备报告接通时刻 2026-10-24 00:31:28 +08:00 |
| PCM 注入 | 活动通话期间向 hw:0,55 写入 8 kHz、单声道 S16LE、660 Hz、3 秒测试音，48,000 字节；tinyplay 未报告错误，CLI 退出 0 |
| 手机听感 | 用户明确确认听到了清楚的测试音，验证模块 → 手机的音频注入路径 |
| 首次 PCM 采集 | 同时从 hw:0,9 采集约 4 秒，66,560 字节，峰值 2,067、RMS 约 286.74、非零样本 2,172/33,280；与测试音并行且未确认说话时间，不能单独据此证明下行语音 |
| 挂断与清理 | 最后一次 calls hangup 后，复核 oFono GetCalls 和 AT CLCC 均为空；设备 5 播放/采集、9 采集、55 播放均 closed，CMUT=0，无遗留采集、播放或 D-Bus 监控进程；本轮无需手动恢复 audiohal 模式 |

随后按用户要求重试说话/静音对照。最后一通保持 active：先播放一秒提示音，结束后一秒开始采集十秒；再播放两秒提示音，结束后两秒开始采集六秒。采集窗口内没有同时注入测试音。用户确认在第一声后连续说话、第二组提示音后静音。

| 最后一通的采集窗口 | 说话段 | 静音段 |
| --- | --- | --- |
| PCM 字节 / 样本数 | 163,840 / 81,920 | 99,840 / 49,920 |
| 采样时长 / 实际耗时 | 10.24 s / 约 10.11 s | 6.24 s / 约 6.09 s |
| 峰值 | 32,057 | 28,842 |
| RMS / AC RMS | 约 4,626.98 / 4,626.98 | 约 2,463.27 / 2,463.27 |
| 非零样本 | 46,013 | 19,592 |
| 削波样本 | 0 | 0 |

说话窗口采到了明显音频，相比此前未确认说话操作的一次采集（RMS 约 2.67）有显著变化。这支持手机 → 模块的下行采集路径已取得音频，但仅凭统计量尚不能确认语音内容可辨识。用户确认已静音的窗口仍有信号，残留来源尚未定位；不能将该静音对照记为通过。没有保存或回放通话录音，PCM 始终只经过匿名管道与内存。

当前证据确认模块可建立真实语音呼叫，模块注入的测试音可被手机听清，模块也可在远端说话时采到明显音频。持续双向 PCM 桥及语音质量尚未验收；也不能仅凭换卡成功断定首张 SIM 未开通语音。

## 后续验收条件

接下来需要定位静音段残留，并通过实时监听或受控信号验证下行音频的内容、时序和清晰度；再实现并验收 RM500U 持续双向 PCM 桥。

呼出接通和接通后的挂断已实测。接听/拒接、DTMF、短信收发、SIM 切换、APN/RAT/频段/USB 写配置、重启恢复仍未验收。未进行 Relay、iOS/watchOS 端到端测试。
