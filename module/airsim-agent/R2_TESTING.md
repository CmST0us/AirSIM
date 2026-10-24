# R2 实施与阶段验收记录

日期：2026-10-24。依据主控维护的 [R2 执行契约](../../docs/RM500_AGENT_R2.md)，仅在本工程实现。**R2 功能实机链路已完成，保留短信重复与延迟的可靠性限制。** 主控已实测呼出接通、入站接听/拒接、Agent 主动定向挂断、DTMF 后端接受、短信发送和接收至少一次双向闭环，以及相同短信命令 ID 重试。一次空闲同哈希重启已完成；主控已验证重启后原完整短信请求返回原回执，未新增发件记录或改写日志。业务测试由主控独占设备操作，接口就绪和 fake 通过不替代实测。

## 实现与本机验证

版本 `2.0.0-dev.r2`。Go 1.24.13，CGO=0，Linux ARM64。新增依赖仅为 godbus/dbus v5.2.2 及其 x/sys v0.27.0，官方 proxy/sumdb 获取；`go mod verify`、`go test -race ./...`、`go vet ./...` 和静态构建通过。

- R1 专用 AT 精确验证型号/完整固件并提供硬件就绪门禁；oFono 仅在唯一 modem 且 Powered/Online/所需接口有效时绑定。厂商占位产品字符串不参与识别。
- 系统 Unix socket 通过可取消的5秒 DialContext 建立私有连接；Auth/Hello 共用临时5秒传输 deadline，成功后清除。握手取消关闭阻塞连接的测试通过。
- 自定义同步非阻塞信号 handler，容量128；Manager 集合变化、owner/连接丢失、Powered/Online/Interfaces 失效撤销 ready。EmergencyNumbers 更新禁拨集合。溢出和重连使 inbox_gap 持续为 true；不重放业务写入。
- 初始 GetCalls/GetMessages 与缓存信号用 D-Bus response sequence 协调；GetMessages 只作为待发快照。未知状态保留 unknown。
- 串行协调器、容量各8的呼叫/短信队列和各一个 worker。worker 必须等完成处理 ack 后再取下一项；拨号 reservation 防止双请求穿过空通话检查。
- 迟到的 Dial 返回不复活已结束通话、不接管路径复用的新来电；无法唯一关联为 outcome_unknown。接听仅允许 incoming；unmanaged、多通话、waiting 等限制有 fake 覆盖。
- 短信 sent/failed→removed 早于方法回复时保留原 message_id 和已观察状态；同路径复用无法唯一关联则 unknown。sent 永不推断 delivered。
- 严格 HTTP/JSON、4096字节限制、号码/DTMF/UTF-16短信长度、boot/epoch/deadline、32并发相同ID只入队一次、冲突ID、重启相同请求查询等有测试。
- 持久记录0700/0600、2MiB/1024上限、原子替换/fsync、损坏/符号链接/临时文件/写失败关闭写入；prepared重启expired、dispatched重启unknown，不回放。正文/号码不出现在记录和回执中。
- 收件正文仅进程内存，128条/单条8KiB/总1MiB；环淘汰与溢出计数测试通过。进程重启不会恢复收件历史。

## 设备部署与观察

当前构建 SHA-256：`b603f0cf5958a0adfd131b5a52bb7eb359d9a5a93c56923ee4000e4022803cb8`。初次只读观察见 [本构建证据](R2_EVIDENCE.json)，最终进程见 [空闲重启证据](R2_RESTART_EVIDENCE.json)。R1 release 与 identity 保留；R1 原始验收证据不覆盖。

部署前重新枚举 ADB，核对 R1 PID/exe/hash、只读通话数量0和待发短信数量0。只停止本轮已核实的 Agent，未改动厂商服务。首次 R2 PID 9414 的只读和控制 readiness 均为 true；空闲 SIGTERM 退出约0.058秒，退出后无 AT 在途栅栏。

紧接着一次未使用 setsid 的启动返回 PID 9508，但后续发现进程不存在、日志为空，原因未确认；该启动不计为成功。恢复采用 R1 已验证的 `nohup setsid`，并在启动后等待1秒核验存活和实际 exe，再进行独立180秒观察。此项与业务崩溃恢复无关，未在业务在途状态重启。

观察脚本 `scripts/observe_r2.py` 仅读取脱敏 R1 快照、control/health/capabilities 与进程资源；不读取 calls/messages 业务正文。观察期间禁止业务调用，以保留容量1024和稳定epoch的基线。该只读观察阶段尚未生成业务命令记录；后续业务阶段见下文。

## 接管与限制

交接完成后，由主控统一调用新 Agent 的0600 Unix HTTP API，并同步电脑接听/短信 UI。执行会话停止设备写操作；只有主控明确交回设备控制权后才能重新部署。业务测试证据、nonce匹配布尔与计数由主控提供，执行会话据此修复和补充报告。

电话目标与短信正文仅保留在授权会话/内存中，不固化为默认配置或报告。先前一次只读输出过滤过宽，意外在工具输出中包含设备序列字段；该字段未持久化到源码/报告，后续不再输出。

voice_ready 固定 false，音频仍未实现；本轮不声称端到端音频、短信送达、云端协议或严格 exactly-once。收件历史不跨重启，记录容量满后拒绝新命令而不淘汰去重历史。拨号结果未知或路径关联不明确时保留 reservation 阻止再次拨号，需要主控核对状态后安排恢复。

## 初次只读交接结果（历史基线）

180秒/19次样本全部 fresh、read-only ready 与 control ready；revision 1→19，epoch 不变，inbox_gap=false、dropped=0、命令剩余容量1024。该阶段 PID **9588**，boot `ae08a58a-a1f5-4626-97f6-70e59ffeaa3f`，epoch `5404b15d-5c7c-4af4-986f-bbba22b3a224`。模块身份 `3138c264-cd46-4370-86d7-0e15c0c89bc5` 保持，identity 文件在部署/重启前后本地哈希一致（不导出文件）。

资源：FD 11；线程8–9；RSS 7548–11992KiB，HWM最高12056KiB。持久/状态/运行目录0700、identity与Unix socket0600；运行日志0字节。R1 release哈希保持，剩余空间见JSON证据。在该交接时点业务命令尚未创建，commands.json 尚不存在；后续主控已完成业务记录与权限审计，见下文。

交接瞬间只读通话数量0，业务命令数量0，呼叫/短信控制ready=true，voice_ready=false。**设备控制权已交还主控；执行端停止设备写入和重启。** 本报告保留未存活启动事实；此处为业务测试前的历史交接基线，后续进度如下。

## 主控实机业务进度（早期部分完成快照）

来源为主控提供的脱敏 `/tmp/airsim-r2-live-evidence.json`，本次快照及来源哈希保存在 [R2_BUSINESS_EVIDENCE.json](R2_BUSINESS_EVIDENCE.json)。构建与上文一致。以下时间按北京时间（Asia/Shanghai）显示，JSON 原始时间保留 UTC。本次仅更新文档，未改代码或操作设备。

| 项目 | 实测证据 | 当时结论 |
| --- | --- | --- |
| 首次呼出 | dialing → disconnected/remote，约19秒；未观察到 active | 不计为接通 |
| 第二次呼出 | 14:52:26.876 提交；elapsed 0.250 dialing、11.378 alerting、33.085 active、40.645 disconnected/remote | 已观察接通，active观察区间约7.56秒；无音频验收结论 |
| 短信发出 | Agent sent，Mac 接收端同轮 nonce 完全匹配，UI传输类型 SMS | 本轮发出闭环成功；delivery仍为unknown |
| 相同短信命令重试 | HTTP200、相同message_id，匹配发件记录数量1→1 | 本次重试未产生第二条Agent发件记录；不声称网络exactly-once |
| 短信接收 | 两条received的nonce和授权发送者均匹配，gap=false、dropped=0 | 至少一次接收闭环成功；存在长延迟及重复到达，原因未确定 |
| 入站接听/拒接、Agent定向挂断、DTMF | 早期尚无完成证据 | 后续已完成，见下节 |

第二次呼出的 command_id 为 `adfd0e00-036c-4e2b-a0b7-37eb4f67e9f4`，call_id 为 `f156fafa-93a7-4ea1-ba66-ec310c6ab842`。主控准备发送 DTMF 时通话已远端结束，因此未发 DTMF 或挂断命令；远端挂断不能替代 Agent 主动挂断验收。Mac接听UI没有被直接观察到，接通结论来自本轮 Agent 的 active 状态。

主控报告 Mac 约14:48:40只做一次 Return 发送回复。Agent 两条接收记录分别为14:50:11.836与14:51:24.545，正文长度均21字符（报告不保留正文）。`observed_at` 是协调器处理时间，不能据此定位网络、设备或UI的延迟来源。两条记录保持原样，不按正文去重。

只读诊断确认：PID对应的一个 D-Bus 连接确实安装7条订阅规则；IncomingMessage/ImmediateMessage实机签名均为`sa{sv}`，CallAdded为`oa{sv}`，VoiceCall.PropertyChanged为`sv`，与代码一致。设备还公布未处理的MessagePDU(`sv`)和IoTDMMessage(`sa{sv}`)，但没有证据表明它们参与本轮接收。当前模型未保留收件信号成员、序号或完整属性，无法追溯两条记录属于传输重投、不同信号或设备重复通知。后续是否增加诊断元数据由主控裁决。

网络注册差异也不是持续不变：后续14:52:48 AT样本为cs=0、packet=0、eps=1、ims=1；oFono为registered/LTE，IMS Registered/VoiceCapable/SmsCapable均true。这些观察不足以解释此前回拨未产生incoming。

主控日志审计：schema=1、3条记录（两次call.dial、一次sms.send，均accepted）；未包含测试对端号码、发出正文或收到正文，权限检查值为700/600/600；控制仍ready、epoch保持、容量剩余1021。此为证据快照时点，不替代后续实测状态。

上述为早期快照，后续已完成项目与重启结果如下。

## 主控后续功能实测完成

同一构建的最新脱敏证据已同步至 [R2_BUSINESS_EVIDENCE.json](R2_BUSINESS_EVIDENCE.json)，保留7项原始业务事件、用户确认和主控重启前状态；其中早期3条记录的journal_audit仍为历史快照，不冒充最终记录数。

| 后续项目 | 实测证据 | 结论边界 |
| --- | --- | --- |
| 第三通呼出、DTMF与主动挂断 | 北京时间14:58:30.109开始；elapsed17.592进入active；DTMF命令accepted；定向挂断observed，通话disconnected/local | 呼出与主动挂断完成，DTMF仅证明后端接受，不证明远端听到 |
| 手机回拨、Agent接听与挂断 | 15:00:25.361 incoming，25.849 active；answer observed；随后定向hangup observed，disconnected/local；授权对端匹配 | 入站接听与Agent挂断完成 |
| 再次回拨拒接 | 15:01:45.076 incoming；具体call_id的hangup observed，45.558 disconnected/local；授权对端匹配 | 入站拒接完成 |

用户确认前两通接听；第一次Agent仍未观察到active，保留这一区别。所有业务操作由主控调用新Agent Unix HTTP API执行。功能链路已完成，不扩大为音频验收或无保留可靠性结论。

短信方面，主控最终快照含3条匹配本轮回复的received，而Mac UI发出测试和回复各只有1条。稍后执行端在授权重启前仅计数发现内存incoming总数4；没有读取/核对该新增记录正文，不能把这4条全部认定为相同nonce。重复与长延迟原因继续未知，不做正文去重、不声称exactly-once。

## 功能测试后的一次空闲重启

主控结束所有watcher后临时交回设备控制，仅授权一次SIGTERM与现有同哈希二进制重启。执行端再次核对PID9588/exe/hash、无活动通话、无queued/unknown发件，持久记录9条且无prepared/dispatched，再执行SIGTERM。没有删除历史、记录、锁或fence，没有改代码、发新电话或短信。

SIGTERM退出耗时 **0.062秒**；随后使用`nohup setsid`及1秒存活检查启动。证据见 [R2_RESTART_EVIDENCE.json](R2_RESTART_EVIDENCE.json)。

- 新PID：**14054**；exe：`/mnt/data/airsim-v2/releases/b603f0cf5958a0ad/airsim-agent`。
- SHA-256保持：`b603f0cf5958a0adfd131b5a52bb7eb359d9a5a93c56923ee4000e4022803cb8`。
- 新boot：`390e3983-b60d-4df6-971e-4ed04bc27d33`；新epoch：`c44cf913-4fb7-4807-9259-83465faecb11`，均已改变。
- identity文件哈希与module_id保持；commands.json文件哈希及全部9条记录逐项保持，容量仍1015。
- 内存incoming总数4→0，重启后messages总数0、活动通话0；此为重启后首次检查的观察，不保证之后没有新到达事件。
- 只读ready、telephony_ready、messaging_ready均true，voice_ready=false；state目录0700，commands.json、identity、Unix socket均0600。

**设备控制已再次交还主控，执行端停止设备写入与重启。** 主控随后已完成原SMS请求重试验证，结果见下节。短信重复原因仍未裁决，技术方案与代码保持不变。

## 重启后原SMS请求重试与最终状态

主控使用原完整payload重新POST：相同command_id `1ad0eae5-70cd-401a-931f-0cf347370875`、旧boot/epoch及已过期deadline。HTTP **200**返回原accepted回执和原message_id `60f94448-2a65-4005-a6bf-58ec0f6e74c6`；journal SHA不变，容量保持1015，新进程messages仍0、active_calls为0，只读和控制均ready。该次重试支持“已有命令先返回原记录，未重新发起短信”的验收结论，不扩大为网络exactly-once。

主控原始脱敏结果保存在业务证据的`restart_retry`。空闲重启证据单独保留原样；其中`pending_main_controller`描述执行端交回设备的历史时点，已由后续`restart_retry`完成，不代表当前仍待验证。

最终PID **14054**，boot `390e3983-b60d-4df6-971e-4ed04bc27d33`，epoch `c44cf913-4fb7-4807-9259-83465faecb11`，二进制hash与身份保持不变，持久命令记录9条。**R2功能实机链路及重启后命令去重验证通过；短信重复到达和长延迟仍未解释，voice_ready=false，音频未验收，无开机自启。** 设备继续由主控掌管，执行端完成文档后待命，不再设备写入或业务调用。
