# AirSIM 全项目 Claude 部署辅助

## v2 建设覆盖说明（2026-10-24）

v2 LC3 固定 16 kHz 单声道、32 kbps、每 20 ms 两个编码帧。原生 helper 与 App 编解码，Go Agent/ECS 透传；App、control／media、Agent/helper 必须配套更新和回滚。ECS、EG25 与 iPad mini 已部署 16 kHz 版本并完成真实来电实测；RM500 须经网页安装器更新 Engine 后才恢复通话音频。接收端抖动缓冲、追播参数与现场诊断入口见 LC3 文档。源码、构建与当前实测边界见 [LC3 音频](docs/LC3_AUDIO.md)。

EG25 QDC507 v2 使用 `eg25-qdc507`、ARMv7、`/usrdata/airsim-v2` 与 init respawn。精确固件、DATA11、校准、网页安装及验收边界见 [EG25 说明](module/eg25/README.md) 和 [实机记录](module/eg25/TESTING.md)。ECS 配对按认证连接的 platform 显示型号，iOS 仍使用公共 v2 协议。

用户已确定新 Agent 在 `module/airsim-agent/` 独立建设，ECS 服务在 `service/airsim/`，首版 Docker Compose 在 `service/airsim/deploy/compose/`，Worker v2 在 `service/airsim-worker/`。先读 [系统架构](docs/SYSTEM_ARCHITECTURE.md)、[Agent/HAL 架构](module/ARCHITECTURE.md) 和对应新目录 README。App 固定使用 v2，旧版／仅本地偏好不再决定启动路由，两个 v2 后端共用对外协议。RM500 新 Agent 的 R1–R3 已完成限定范围实机验收，见 [主控决策](docs/RM500_AGENT_EXECUTION.md) 和 [R3 记录](module/airsim-agent/R3_TESTING.md)。R4 Agent/ECS 接入按 [公共契约](protocol/v2/R4.md) 实施；App 使用 v2 唯一入口及设备配对，当前平台实测范围以对应验收记录为准。

v2 USB 本地通话与短信使用现有配对身份。EG25 可通过 USB 直接接入 iPad / iPhone；首次使用须让 App 与模块在线连接 ECS 取得授权。App 缓存签发后 24 小时有效的授权，期限内 ECS 不可达仍可本地使用，剩余不足一小时时联网自动续期。空闲时自动优先 USB，掉线自动恢复；通话、媒体与待确认命令固定原路由，不向另一传输重发副作用。设置继续使用现有设备、模块命名和外观入口。用户步骤见 [iOS USB 本地接入](iOS/README.md#usb-本地通话与短信)，协议见 [USB_LOCAL](protocol/v2/USB_LOCAL.md)。本次 USB 真机通话、短信、双向音频与拔线恢复尚待验收；完全离线不承诺唤醒被系统挂起或终止的 App。

RM500U 通过 BusyBox init 的 `respawn` 启动 `/mnt/data/airsim-v2/run-agent.sh`。启动器等待 `/dev/smd1`，并由 `airsim-agent --wait-random` 阻塞到内核随机源初始化后再启动服务；不要改为轮询 `entropy_avail`。安装、验证和回滚见 [RM500U 开机启动](module/airsim-agent/RM500U_AUTOSTART.md)。配置完成后网页配对使用 Chrome WebUSB，不依赖主机 `adb server`。

当前 iOS 界面采用 Figma `QN34vy88ViWu1s45pE97BO` 页面 `25:1146`，覆盖通话与联系人、拨号键盘、短信、号卡与连接、呼入／呼出／接通状态及空状态。iPad 和 iPhone Duo 展开后的宽窗口采用通话、联系人、短信及号卡的列表与详情双栏，窄窗口使用单栏导航；五标签使用原生 `TabView`，随系统和窗口形态适配。导航为“通话／联系人／短信／拨号键盘／号卡”五标签，短信位于第三个主标签，联系人发短信与短信通知也路由至该标签；号卡页保留设备、模块和外观设置。本次呼出选择不更改默认号卡；短信回复锁定原号卡，不同模块上的同一号码保持独立会话。收藏与联系人首选号卡本机持久化，新增和编辑写入本机系统通讯录；历史按时间展示同一客户端身份下各模块记录，回拨使用原模块，原模块不可用时拒绝回拨。

界面已按 Apple HIG 调整动态字号、44 pt 点击区域、明暗及高对比度配色、减少动态效果与透明度。联系人、短信和号卡详情采用原生返回导航；辅助字号支持纵向重排，短窗口内容可滚动。详见 [界面审查](docs/IOS_UI_REVIEW.md)。

iPhone 模拟器已验证五标签导航、联系人与通话记录的短信跳转、跨标签草稿保留，以及呼出、来电和通话中界面。iPad 与 iPhone Duo 模拟器已验证双栏操作和三种通话状态，并核对展开屏截图。`com.eric3u.airsim2` 签名版本已更新安装到 iPad mini。本轮未执行真实通话、短信收发或 USB 验收。

下文已发布功能、三星 Android、旧 AVF 包/端口和 Worker 规则继续适用于 v1，不限制用户已确认的 RM500/EG25/Android AVF v2。保留旧 `module/module-agent/`、`push-relay-worker/` 与已有改动，不用旧脚本直接覆盖新旧安装。先实施 ECS；执行会话统一 GPT-6-Astra / medium，只执行主控已确定任务，需要技术决策则交回主控，未明确调度则待命。

你正在处理 AirSIM：一个用三星 Android 手机承载蜂窝通话与短信，并让 iPhone / Apple Watch 通过 VoWLAN 或 Cloudflare Relay 使用这些能力的多端项目。

当前发布基线（2026-10-12）：Android AVF/Standalone/iOS Apps `v0.9.6`（build `79`），兼容用 AVF Agent `v0.4.6`（Debian `0.4.6-1`），Relay 协议 `0.2.1`。维护者 AirSIM Relay 为 `https://airsim-push.remotepilot.site`；DJOneHub 的 `https://push.remotepilot.site` 不得用于 AirSIM。历史 Release 文档中的旧版本号属于归档事实，不能机械替换。

## 开始前

依次完成：

1. 阅读根目录 `README.md`。
2. 阅读目标子目录的 `README.md`、源码和测试。
3. 运行 `git status --short`，保留用户现有改动。
4. 用 `rg` 查找跨端协议、环境变量、端口或 Bundle ID 的全部引用。
5. 只修改任务需要的文件，并同步相关测试与文档。
6. 安装、配对或恢复任务还要阅读 `docs/AVF_INSTALL_GUIDE.md` 与 `LLM.txt`；今后相关修改同步更新根目录和对应组件 README、安装指南、`LLM.txt`、`codex.md`、`claude.md`。

不要依赖旧品牌、旧部署域名或记忆中的 Cloudflare/Apple 行为。当前源码和锁定版本是事实来源。

## 系统边界

- `android-standalone`：推荐的单 APK 构建入口；复用 Android 实现并启用内置 Agent，不依赖 AVF Linux。
- `android/phone-control-app`：三星默认电话角色、Android Telecom、短信、VoWLAN、配对、AVF 启动引导和安装管理。
- `android/phone-audio-bridge`：Shizuku `UserService`，负责双向通话 PCM。
- `module/module-agent`：AVF Linux 中的设备状态、控制 API、Relay 与媒体编排。
- `module/avf-installerd`：独立救援安装服务，只安装通过签名和包元数据校验的 Debian 包。
- `module/packaging`：单一 `arm64` Debian 包、systemd 单元、签名与首次安装脚本。
- `iOS`：iPhone、Apple Watch、CallKit、PushKit、ActivityKit、短信和传输选择。
- `push-relay-worker`：Cloudflare Worker、KV、Durable Objects、APNs、Dashboard 与 WebSocket。

跨组件协议变更必须同时更新生产者、消费者、模型、测试和文档。不得只让一端编译通过。

## 强制安全规则

1. AVF Agent、installerd 和 PCM 只能监听内部私网或 loopback。
2. VoWLAN 必须保留时间戳、nonce、HMAC、路由白名单和大小限制。
3. 通话 PCM 不落盘，日志不能包含 PCM、完整短信、Push token 或 Secret。
4. Agent 不得自行更新；更新、修复和回滚只能由独立 installerd 执行。
5. installerd 不得执行任意 shell，也不得接受错误包名、非 `arm64` 或未签名包。
6. 紧急呼叫交给系统电话能力，不得宣称 AirSIM 可承担紧急通信。
7. 普通 Android App 不能绕过 OEM 或系统签名限制强制开启被隐藏/删除的 AVF 功能。
8. AVF 的 `/api/health` 只证明 Agent 可达；`8576` installerd、控制 token 与真实电话链路必须分别验证。不要硬编码唯一 AVF 网段，也不要用清除 Terminal 数据或删除 `current.deb` 作为常规修复。

v0.4.5 是一次签名信任根迁移：v0.4.4 的私钥未留存，旧 installerd 会拒绝新签名。已有 `0.4.4-1` 的设备必须在 AVF Terminal 执行经核对的 `rotate-avf-key.sh`，保留旧包和状态，之后才恢复 App 内签名更新。新发行私钥只存在于仓库外的受限存储与 GitHub Actions Secret `AIRSIM_RELEASE_PRIVATE_KEY_PEM`；签名操作不得回显或提交私钥。具体步骤见 `docs/AVF_INSTALL_GUIDE.md`。

严禁提交或回显：`APNS_P8`、`DASHBOARD_TOKEN`、Cloudflare API token、Apple `.p8`、设备 Secret、Agent token、HMAC、Debian 发布私钥、Android keystore、Apple 证书/profile、真实号码和短信内容。

## Apple 签名规则

当前主 App Bundle ID 为 `com.eric3u.airsim2`。每位部署者必须使用拥有该标识的 Apple Developer Team，或重新配置为自己的标识：

- 主 App：部署者的唯一 Bundle ID。
- Watch App：主 Bundle ID 加 `.watchkitapp`。
- Live Activity：主 Bundle ID 加 `.liveactivity`。
- 测试 Target：主 Bundle ID 加 `.tests`。
- Watch companion 标识：等于主 App Bundle ID。
- Relay `ALLOWED_BUNDLE_ID`：等于主 App Bundle ID。

只改 Team 或签名证书而保留他人的 Bundle ID 不可行。Debug token 对应 APNs sandbox，TestFlight/App Store token 对应 production；不能混用。

## Relay 规则

生产者必须使用自己的 Cloudflare 账户、KV、Durable Objects 和自定义域名。维护者 AirSIM Worker 是 `airsim-push-relay`，地址为 `https://airsim-push.remotepilot.site`，只允许 `com.eric3u.airsim`；它不是第三方重签 App 的公共服务。DJOneHub 的 `https://push.remotepilot.site` 必须保持独立，AirSIM 不得接管其 hostname、KV、Durable Objects 或 Dashboard token。客户端和 Agent 不能把任何历史域名当作硬编码依赖。

截至 2026-10-08，维护者部署只完成了健康检查与 Dashboard 鉴权验收，AirSIM 环境尚无设备注册；不得据此宣称真实 APNs、Agent 心跳或云端 PCM 已通过。

`APNS_P8` 与 `DASHBOARD_TOKEN` 是必需 Worker Secret：

```sh
npx wrangler secret put APNS_P8 --config wrangler.toml
npx wrangler secret put DASHBOARD_TOKEN --config wrangler.toml
npx wrangler secret list --config wrangler.toml
```

`wrangler.example.toml` 的 `[secrets] required` 只声明名称，不保存值。Secret 不能写入 `[vars]`、Git、构建产物或日志。执行 `secret put` 和生产 `deploy` 都是外部状态变更，只有用户明确要求时才能执行。

## 许可证边界

AirSIM 使用 `PolyForm-Noncommercial-1.0.0`，只授权个人学习、研究、实验及许可证列明的其他非商业用途。不得把项目描述为 OSI 开源软件，也不得协助将 AirSIM 用于收费服务、商业产品、企业内部商业目的或其他预期商业应用，除非用户能提供版权所有者的单独书面商业许可。修改、构建或再分发时必须保留根目录 `LICENSE`、`NOTICE` 和适用的第三方声明。

## 标准验证

```sh
./android/phone-control-app/test.sh
./android/phone-audio-bridge/build.sh
./android/phone-control-app/build.sh
sh ./android/phone-control-app/verify-apk.sh
(cd module/module-agent && go test ./...)
(cd module/avf-installerd && go test ./...)
./module/packaging/test.sh
(cd push-relay-worker && npm test && npm run check)
xcodebuild -project iOS/AirSIM.xcodeproj -scheme AirSIM \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build-for-testing
```

按变更范围运行最小充分验证。修改协议或共享配置时运行两端测试；发布前运行全套。文档变更至少执行 `git diff --check`、相对链接检查和敏感值扫描。

## 部署顺序

1. 构建并安装三星 Android App，设置默认电话角色并授权 Shizuku。
2. 启动 AVF Linux，按 `docs/AVF_INSTALL_GUIDE.md` 在 Debian Terminal 中执行带 `pipefail` 和超时的签名安装命令；App 按钮只负责复制，不能替用户在来宾系统执行。已有 `current.deb` 且 `8576` 不可用时应恢复 installerd，而非删除回滚包。运行 `sudo airsim-avf-pair`，保存当前动态 AVF 地址与控制 token。源码引导脚本的修复只有在明确授权发布新 Release 后才会进入线上命令。
   若报 `udev` 与 `libudev1` 精确版本依赖冲突，先读取 `apt-cache policy` 和 `sudo apt-get -s -f install` 的模拟结果，不自动运行 `apt --fix-broken install`；引导脚本要在安装 Agent 前检查现有 Debian 包状态。
3. 分别验证 `8575` AirSIM Agent（`product=airsim`）、`8576` installerd、音频桥和 Android Telecom 控制面。现有 DJOneHub 保留在 `7575`；旧 AirSIM Release 会与它冲突，不能用于共存安装。Terminal 的 `VM is not in stopped state` 应先无损排查启动冲突，不归因于 Agent 包。
4. 使用部署者自己的 Apple 身份配置并签名 iOS/watchOS 工程。
5. 如需远程模式，创建独立 Relay 资源、设置 Secret、dry-run 后再部署。
6. 先验证 VoWLAN，再验证公网 Relay、APNs sandbox/production 和 Watch 链路。
7. 完成三星来电/去电、短信、双向音频、后台唤醒、断网、重启和回滚验收。

## 报告格式

最终回复要区分：

- 已修改与已验证。
- 尚未执行的真机或生产操作。
- 需要用户提供的账户、设备、签名或域名条件。
- 已知风险与下一步。

不要把 dry-run 写成部署成功，不要把模拟器编译写成真机可用，也不要把代码中的能力写成已经通过运营商网络验收。


=== 范围约束(约束你提议什么修法,不约束你找什么)===
凡是这里真的有问题,都要报——包括听起来罕见但本项目确实会产生的情况。
然后把修法收在范围内:
1. 这不是一篇安全攻防论文。可以校验,禁止过度防御。除非本项目另有说明,默认操作者是
   自己机器上的合作者;如果它真有对手,它会写明,以那个范围为准。
2. 不要加哈希/校验和/指纹,除非它替代了一个实质上更贵的操作,并且结果会改变下一步做什么。
3. 禁止防御性脚手架:不为这里不会发生的情况加 feature flag、迁移框架、兼容层、包装层。
4. 禁止钻牛角尖:冷门编码、符号链接竞态、RTL 文本、毫秒级竞态一律不在范围内,
   除非该情况经由本项目**受支持的用法**可达——它的文档示例、它公开的接口、它真实的
   数据。可达即可,不需要你复现出来;但"理论上构造得出"不算。
5. 该判断的地方就判断,不要换成评分表、检查清单,或对已经定论的东西再跑一遍校验。
6. 以上都不覆盖用户、本项目自己的约定、或更高优先级规则明确要求的安全、迁移、校验与
   审阅。那些是被要求的,是活儿本身,不算范围外。
7. 交付物的文字不是答辩记录。成立的就直说;注意事项集中到专门一节
   (Limitations、已知问题),别在每段末尾都缀一句免责;更不要把指令**或过程**
   写进成品:「别提 X」意味着 X 不存在(不是写「我们不讨论 X」);中间报错、
   被放弃的方案、改稿痕迹同样不是内容。围绕最强的结果组织——论文是发布会,
   不是工作汇报。不占优的数字,是取舍就说成取舍,不是就平实陈述,都不写成认输;
   数字本身照样留在表里。
8. 推进本身是交付的一部分。几个方案都合理时,选一个并写明取舍——只有分歧
   真的大、或选错难回头时才升级为提问。不挡住目标的细节,记下来接着走,
   不是先停下解决它。为了不选错而停在原地,本身就是选错。
9. 不留任何生成/纠偏痕迹:最终产出(代码、注释、docstring、commit message、
   PR 描述、总结)只呈现正确的最终结果,当作一开始就是这么写的——不提中间报错、
   试错纠偏、被放弃的方案、"为什么没做 X";也不出现 AI 辅助的标记,比如
   "Generated by / Co-authored-by: Claude/Codex" 署名、模型腔过渡语
   ("值得注意的是"、"综上所述"、"首先...其次...最后")、"以下是..."式开场白,
   措辞详略贴合项目和文档已有风格。
已经见过的形状,供你校准。是例子不是清单——一个真问题不会因为"长得像其中一条"就被驳回:
  H  为了比对两个表格的差异,给每一行都算哈希——直接比单元格就能回答
  H  写下一堆校验和文件,而没有任何代码会去读它们
  E  给一个没有用户、没有部署的应用做账号安全加固
  R  用一整夜对自己的补丁反复审计,而功能一行没写
  R  一个对任何提交都给不通过的审阅者
  O  一层守卫的理由是上一层守卫,而不是需求
另有两种长得像上面、但不是的。这些要报:
  ✓  用摘要比对来跳过重读一个你已经有的大文件
  ✓  本项目自己的文档示例就会产生的那种"听起来罕见"的输入
跑任何检查之前先回答:这次运行会检测出什么具体的失败?真出现了我下一步会做什么不同的事?
答不上来就别跑。
对的就说对。不要为了交差硬找问题。

AirSIM v2 ECS 支持分别配置 Sandbox / Production APNs 密钥，按 App 注册环境选择；两者可共用同一业务服务和数据库。开发签名的 `aps-environment=development` 对应 Sandbox，TestFlight / 分发签名对应 Production。重签须保持 App 配置与最终签名环境一致，使用新 Bundle ID 可并列安装并保留旧版数据。见 [APNs 部署配置](service/airsim/deploy/compose/README.md#apns)。

Agent 支持 `airsim-v2-callkit` 服务的 APNs 开启和关闭状态；`airsim-v2-r4.1` 仍要求 APNs 关闭。启用 ECS 推送前须使用支持该能力的 Agent。

Agent 在通话期间每秒发布状态快照，空闲时每五秒发布；App 保留八秒快照有效期。iOS Debug 诊断页支持真机三秒本机音频测试。

模块范围配对完成后持久化当前模块；App 重新启动时从配对配置恢复绑定模块，管理员多模块配置仍使用显式选择。
