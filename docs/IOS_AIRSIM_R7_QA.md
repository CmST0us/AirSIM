# iOS AirSIM R7 QA

## 基线与范围

2026-10-25，分支 `codex/airsim-v2-r6`，初始提交 `a5eff44`。R7 将 ECS v2 接入原 App 的拨号、最近、短信、联系人、设置视图，保留本地与云端 v1/v2 选择，重点验收 CallKit v2 系统通话集成。M2 以 App 前台快照发现来电为入口，覆盖系统动作与已有通话的后台生命周期。

本阶段使用无生产配置的 iPhone Air / iOS 27.0 模拟器，UDID `4F538B71-FB80-4755-A593-BEDFD72C5CF0`。DerivedData 为 `/tmp/airsim-r7-qa-derived`，截图与报告附件目录为 `/tmp/airsim-r7-qa`。不连接真实 iPhone、RM500 或 ECS，不拨号、不发送真实短信。

依据：[系统架构](SYSTEM_ARCHITECTURE.md)、[iOS 说明](../iOS/README.md)、[R6 记录](IOS_AIRSIM_R6.md)、[R4 契约](../protocol/v2/R4.md)、[R7 契约](../protocol/v2/R7.md)、[设计审核](IOS_AIRSIM_R7_DESIGN.md)。

## 测试切入点

优先验证原五页导航在 v2 下保持可达，随后验证版本切换、来电身份与系统控制分发、短信历史及会话导航。CallKit 身份、动作与生命周期方案由主控确定，QA 按冻结契约补充测试。

现有 `AirSIMTests.swift` 有 47 个测试方法，`CloudV2Tests.swift` 有 70 个。覆盖本地/云端传输选择、来电拒接路由、权限顺序、短信去重、云端自检、Live Activity、v2 配置与 Keychain、命令未知结果恢复、模块/会话隔离、ASMP、切换屏障、轮询与历史持久化。数量为源码盘点，不等于运行通过数。

工程已接入 AirSIMUITests target。QA 独占 `iOS/AirSIMUITests/R7NavigationTests.swift` 与 `iOS/AirSIMUITests/R7MessagingTests.swift`；iOS 执行会话负责 `iOS/AirSIM.xcodeproj/project.pbxproj` 和 `iOS/AirSIM.xcodeproj/xcshareddata/xcschemes/AirSIM.xcscheme`。文件归属已由主控冻结。QA 已编写上述两文件，共 15 个 UI 测试：M3 `a0d5b44` 的 13 项与 `7e85c9c` 新增的 2 项通话页面测试均通过。

## 功能用例

层级：U 为 XCTest 纯逻辑或 fake transport，S 为模拟器 UI 自动化，D 为实体设备端到端。S 中的通话与消息只能使用明确隔离的 fixture；不把测试操作发送到真实后端。

| ID | 关键用例 | 预期 | 层级 |
| --- | --- | --- | --- |
| NAV-01 | 全新启动，尚未选择连接方式 | 展示本地/v1/v2；选择前无发现、注册或权限请求 | U、S |
| NAV-02 | 旧安装升级后启动 | 保留原 v1 或本地选择及配置，不自动转 v2 | U、S |
| NAV-03 | 在三种模式访问五个标签 | 拨号、最近、短信、联系人、设置均使用原视图，选择状态明确 | S |
| NAV-04 | 切换后杀进程重启 | 记住选择；版本地址、凭据、历史不串用 | U、S |
| NAV-05 | 通话/媒体/在途或结果未知命令时切换 | 拒绝切换并提示原因；不丢操作、不自动重发 | U、S |
| NAV-06 | 切换后收到旧网络回调或 CallKit 动作 | 不写入新会话，不控制新模块；旧 handler 代次和 UUID 不进入新会话 | U、S |
| SET-01 | 首次权限允许、拒绝及弹窗延迟 | 麦克风决策先于发现/通知；延迟后可重试，拒绝有明确状态 | U、S、D |
| SET-02 | v1 Relay 地址保存、云端开关、自检 | 本地模式禁用云端项；自检逐项报告且不拨号/发信 | U、S |
| SET-03 | v2 配置缺失、过期、401、服务身份不符 | 明确不可用原因；不误报在线，不泄露凭据 | U、S |
| SET-04 | v2 模块选择、离线、快照过期、无能力 | 当前模块清晰；不可执行动作禁用；历史保持模块归属 | U、S |
| SET-05 | 浅色/深色、大字体、窄屏与 iPad | 标签、号码、错误及操作按钮可读可达，无遮挡或截断关键信息 | S |
| PAIR-01 | 配对入口、无设备、错误/过期配对码、取消 | 状态可理解且可重试；失败不保存半成品凭据 | U、S、D |
| CALL-01 | 拨号盘输入、删除、空号码、联系人回拨 | 号码正确；无有效路由不提交；fixture 下命令仅一次 | U、S |
| CALL-02 | 来电、接听、拒接、挂断、重复系统动作 | 绑定正确版本/服务/模块/call ID/generation；过期动作不影响后续电话 | U、S、D |
| CALL-03 | 前台快照发现来电、重复事件、旧设备代次与过期快照 | 只上报有效来电；相同通话复用系统身份，不重复响铃或执行命令 | U、S |
| CALL-04 | 系统接听、拒接、挂断、静音、DTMF | 通过 CallKit handler 分发到正确 v2 binding；重复或过期动作不控制其他通话 | U、S、D |
| CALL-05 | 静音、扬声器、DTMF、通话结束 | UI 状态与会话一致；结束后不留活动界面或媒体占用 | U、S、D |
| CALL-06 | 断网、结果未知、重连、重启恢复 | 查询原操作，不补拨；显示实际状态，禁止旧回调复活通话 | U、S、D |
| CALL-07 | 远端结束与 provider reset | 回收对应系统通话和媒体；reset 对已拥有通话按契约定向清理，未知结果不重发 | U、S、D |
| CALL-08 | 已有系统通话进入后台，再返回前台 | 不因普通后台切换主动挂断；只保留所属通话必要状态与媒体，无通话时停止后台轮询 | U、S、D |
| CALL-09 | CallKit didActivate / didDeactivate 及迟到回调 | 激活后才启动音频，停用时暂停；旧回调不启动或停止新会话媒体 | U、S、D |
| REC-01 | 最近通话空态、来去电/未接、回拨及发短信 | 显示与排序正确；回拨/发信保留所属模块 | U、S |
| SMS-01 | 会话空态、列表、详情、输入与发送 | 空内容/无路由不可提交；fixture 回执区分成功、失败、未知 | U、S |
| SMS-02 | 重复同步、乱序记录 | 按身份与消息 ID 去重，时间排序正确，不跨模块混合 | U、S |
| SMS-03 | 联系人、最近通话与 im 入口打开短信 | 打开正确收件人与原编辑器；模块切换不携带旧会话或草稿 | U、S |
| CONTACT-01 | 无权限、空通讯录、搜索、联系人详情 | 状态明确；拨号与短信入口可达且使用当前合法路由 | S、D |
| SYSTEM-01 | tel/im 外部入口 | 正确解码目标与导航；版本归属明确，无路由时不误提交 | U、S |
| LIVE-01 | Live Activity 开关、通话状态与结束 | 正确显示当前模块，关闭或结束时回收；旧 token 不注册到新版本 | U、D |
| WATCH-01 | Watch 拨号/接听/挂断、手机模式切换 | 按主控冻结的支持范围提示与路由；不得隐式共用错误版本凭据 | U、D |

## 模拟器基线结果

| 项目 | 结果与证据 |
| --- | --- |
| Debug 构建与启动 | 通过；`CODE_SIGNING_ALLOWED=NO`，运行 `com.example.airsim` |
| 首次启动截图 | `/tmp/airsim-r7-qa/01-launch.jpg`；三种连接方式可见 |
| UI 语义快照 | 可读取三种连接按钮 |
| 现有 XCTest（模拟器本地签名） | 共 117 项：116 通过、1 跳过、0 失败；结果包 `/tmp/airsim-r7-qa/baseline-signed.xcresult`，完整日志 `/tmp/airsim-r7-qa/baseline-signed.log` |
| 实际 Keychain 读写 | 本地签名下通过；测试构建需要 `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` |
| 硬件音频测试 | `testV2RealSimulatorEnginePrepareAndStopWithoutNetwork` 按 opt-in 条件跳过；本轮不开展音质优化 |
| M1 首批 UI 测试 | 9 项全部通过；结果包 `/tmp/airsim-r7-qa/m1-ui-first.xcresult`，日志 `/tmp/airsim-r7-qa/m1-ui-first.log` |
| M1 聚焦单测 | 3 项中 2 通过、1 失败；结果包 `/tmp/airsim-r7-qa/m1-focused.xcresult`，日志 `/tmp/airsim-r7-qa/m1-focused.log` |
| M1 UI 截图 | 32 张，`/tmp/airsim-r7-qa/m1-screenshots/`；manifest 对应测试与附件，按测试类子目录提供可读文件名 |

## 已知问题与待验收

1. M1 的 `testR7ProjectionAndLocalClearRemainDomainScoped` 切换状态断言已在 M2 `6f9a03f` 全量单测中复测通过。原失败结果包保留作基线证据。联系人短信入口已在 M3 `a0d5b44` 通过首次及重复进入原编辑器验收。
2. M2 CallKit 的 handler 代次隔离、来电去重、音频激活、后台作用范围、定向拒接及 provider reset 等替身测试已通过；系统 UI 与实体设备行为仍未验收，不能用这些结果推断真实系统通话已可用。
3. README 版本选择器说明已解决：根目录与 iOS README 已同步现有入口和 R7 范围。
4. 首批 UI 构建早于 M1 提交 `6f1882c`，仅覆盖未配置、本地和 v1 场景。ready fixture 的 capability 修正及新增闭环 UI 尚未进入该构建，不据此宣称模块与发送闭环已通过。聚焦单测使用同一 M1 产物 `test-without-building`，不包含后续 M2 改动。

## UI 自动化场景

主控批准仅在 `DEBUG && targetEnvironment(simulator)` 生效的 `--r7-ui-scenario` 参数，枚举为 `fresh`、`local-unpaired`、`v1-unpaired`、`v2-unconfigured`、`v2-offline-fixture`、`v2-ready-fixture`、`v2-send-failure`、`v2-command-unknown`、`v2-incoming-fixture`、`v2-active-fixture`。由 iOS 执行会话在最早初始化入口接入，隔离 UserDefaults、Keychain 和历史目录，整个测试进程关闭真实网络、发现和 Push，切换版本也不能解除隔离。真实设备及 Release 忽略该参数。fixture 走生产视图、模型和命令路径，使用固定虚构数据与 fake transport。

已通过的 9 项 UI 测试覆盖：v2 五标签、隐藏旧设置入口、往返导航、空短信禁发与取消；fresh 选择与本地引导；local 五标签与配对设置；v1 五标签与 Relay 设置；深色和大字体五页截图。每页保留 XCTest 截图附件，失败也保留截图。除 fresh 外，场景直接显示 RootView。

新增的 4 项 UI 测试：ready 模块甲/乙切换后短信、最近通话与回复草稿隔离；联系人短信入口；send-failure 保留正文；command-unknown 禁止发送、阻止版本切换并保留查询入口。原来电和活动通话控件已补充覆盖；联系人/最近回拨、活动通话切换阻止仍未进行 UI 自动化验收。M2 按 CALL-03、CALL-04、CALL-07 至 CALL-09 覆盖系统通话；先验证纯逻辑与替身分发，再记录模拟器可执行的系统 UI 行为。

## 验收边界

本阶段不以 APNs 密钥、PushKit 离线唤醒或短信推送作为交付条件，不安排推送实验，也不宣称这些能力已验证。既有推送相关测试记录保留其原有结论，不作为本轮 CallKit 验收证据。

当前仅操作模拟器与固定替身。真实 CallKit 锁屏/后台行为、实体设备音频路由、Watch、运营商通话与短信均未执行。后续实体设备验收需主控另行安排签名构建、授权设备与测试号码；模拟器及替身通过只证明对应的状态、动作分发与 UI 行为。

## M1 闭环 UI 验收（6f1882c）

从提交导出独立构建副本 `/tmp/airsim-r7-qa-m1-src`，使用 `/tmp/airsim-r7-qa-m1-derived`；未重跑首批已通过的 9 项 UI 或已知失败单测。

| 用例 | 结果 | 证据 |
| --- | --- | --- |
| 发送失败保留回复正文 | 通过 | `/tmp/airsim-r7-qa/m1-closure.xcresult` |
| 模块切换后短信、最近通话与草稿隔离 | 通过 | `/tmp/airsim-r7-qa/m1-return-path.xcresult` |
| 未知命令禁发、阻止版本切换、保留查询入口 | 通过 | `/tmp/airsim-r7-qa/m1-return-path.xcresult` |
| 联系人发短信进入原编辑器 | 失败，产品缺陷已确认 | `/tmp/airsim-r7-qa/m1-closure.xcresult` |

联系人缺陷复现：`v2-ready-fixture` → 联系人 → QA虚构联系人 → 发短信；实际仅进入短信列表，没有打开新信息编辑器。首次进入短信标签时已有 `pendingRecipient` 未被消费。主控已批准在 `onAppear` 与 `onChange` 共用待撰写入口处理，纳入 M3，M3 首次及重复进入编辑器均已通过。

模块隔离与未知命令测试从会话返回列表后再进入设置，导航步骤已同步主测试文件。草稿断言只覆盖此正常导航路径下旧模块正文未带入新模块；返回会话列表会销毁视图局部草稿，因此该结果不能单独证明保留中的编辑器草稿由模块切换清理。未知命令用例证明发送按钮禁用、切换提示及查询入口可用，未验证查询后命令终态恢复。

截图分别位于 `/tmp/airsim-r7-qa/m1-closure-screenshots/` 与 `/tmp/airsim-r7-qa/m1-return-screenshots/`，已交设计审核。M2 `6f9a03f` 已完成全量单测复测，结果见下节。

## M2 CallKit 全量单测（6f9a03f）

冻结副本 `/tmp/airsim-r7-qa-m2-src`，独立 DerivedData `/tmp/airsim-r7-qa-m2-derived`，使用模拟器本地签名。只执行 `AirSIMTests`，未重跑首批 9 项 UI。

共 124 项：123 通过、1 项硬件音频 opt-in 测试跳过、0 失败。结果包 `/tmp/airsim-r7-qa/m2-unit.xcresult`，完整日志 `/tmp/airsim-r7-qa/m2-unit.log`。

原 M1 切换断言、清理隔离及发送终态测试均通过。新增 CallKit 测试覆盖旧 handler 代次拒绝、来电去重、音频激活、后台通话范围、针对已验证来电的拒接，以及 provider reset 只提交一次所属通话挂断。全量回归同时覆盖原 v1/local 与已有 v2 逻辑。该结果属于模型与替身验证，不构成系统来电 UI、真实 AudioSession 激活或实体设备后台通话验收。

## M3 原视图与短信闭环（a0d5b44）

冻结生产源码 `/tmp/airsim-r7-qa-m3-src`，叠加 QA 测试断言，使用独立 DerivedData `/tmp/airsim-r7-qa-m3-derived` 和模拟器本地签名。

13 项 UI 全部通过。覆盖原五页与三种模式、浅色/深色/大字体、模块历史隔离、失败正文保留、未知命令切换屏障；联系人首次与重复发短信均进入原编辑器并预填正确号码。未配置短信恢复入口可到达配置设置，诊断入口可打开诊断页。结果包 `/tmp/airsim-r7-qa/m3-ui.xcresult`，日志 `/tmp/airsim-r7-qa/m3-ui.log`。

新增 `testR7MessageGapUsesOnlySelectedModuleHistory` 单独执行通过，证明 gap 场景仅使用选中模块历史。结果包 `/tmp/airsim-r7-qa/m3-gap.xcresult`，日志 `/tmp/airsim-r7-qa/m3-gap.log`。M2 已通过的 124 项单测未重复执行。

42 张 UI 截图位于 `/tmp/airsim-r7-qa/m3-a0d5b44-screenshots/`，目录包含测试附件 manifest 与 `BUILD.txt`，已交设计审核。原来电及活动通话页面已在 `7e85c9c` 补测通过。

## 原通话页面与 profile 兼容验收（7e85c9c）

冻结源码 `/tmp/airsim-r7-qa-call-src`，独立 DerivedData `/tmp/airsim-r7-qa-call-derived`，使用同一独占模拟器和本地签名，仅执行新增用例。

两项 UI 测试全部通过：来电页接听、拒接按钮可达且无录音入口；活动通话页挂断、键盘可达，无媒体时静音与扬声器禁用且无录音入口。打开通话键盘后可返回原通话页。结果包 `/tmp/airsim-r7-qa/call-ui.xcresult`，日志 `/tmp/airsim-r7-qa/call-ui.log`。

`testKnownDiscoveryProfilesWithoutAPNsRetainIdentityAndOriginChecks` 通过。测试分别接受无推送的 `airsim-v2-r4.1` 与 `airsim-v2-r7`，拒绝 server ID、API/media origin 不符、APNs 能力开启及未知 profile；拒绝路径未读取凭据或保留连接配置。结果包 `/tmp/airsim-r7-qa/profile-unit.xcresult`，日志 `/tmp/airsim-r7-qa/profile-unit.log`。

三张截图位于 `/tmp/airsim-r7-qa/call-7e85c9c-screenshots/`，包含来电、活动通话和键盘，附 `manifest.json` 与 `BUILD.txt`，已交设计审核。这两项 UI 使用固定虚构状态，未执行接听、拒接或挂断命令，不构成系统 CallKit 或真实通话验收。

主控真机验收发现 CallKit 将 HTTP 202 等待收据误判为失败，已安排执行修复；本记录等待该修复的独立回归，不宣称系统 CallKit 真机通过。
