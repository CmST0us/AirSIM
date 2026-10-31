# AirSIM iOS 与 watchOS

## v2 与当前界面

EG25 QDC507 与 RM500U 使用相同的 v2 配对、模块范围、通话、短信和 8 kHz/20 ms 媒体协议。App 从 ECS 的连接码查询结果显示型号，无需按 modem 类型选择另一套客户端。EG25 的实机边界见 [验收记录](../module/eg25/TESTING.md)。

App 统一使用 v2，首次启动直接显示设备连接页，设置不再提供版本或仅本地模式选择。已有 v1／本地偏好不参与启动路由；没有 v2 配对的安装通过“添加设备”重新连接。现有 v2 配对、模块选择与历史继续保留。导航使用“通话／联系人／短信／拨号键盘／号卡”五标签，短信位于第三个主标签，联系人发短信与短信通知也路由至该标签；号卡页保留设备、模块和外观设置。控制与凭据继续按服务、安装实例与模块隔离，历史保留每条记录的原模块归属。

v2 首先使用 `service/airsim/` 的 ECS Docker Compose 服务。正常流程是在电脑网页选择设备、核对模块身份、取得五分钟有效的八位连接码，再在 App 的“添加设备”中确认。部署者须在构建时通过 `AIRSIM_V2_PAIRING_ORIGIN` 配置自己的 HTTPS 配对服务地址；仓库默认值为空。新配对使用可撤销的长期设备会话，凭据保存在 Keychain，不要求定期打开 App 或重新配对；旧版限时会话继续支持刷新。没有自动回退 v1。号卡页提供设备连接、模块选择与名称、默认呼出号卡及外观设置；不提供导入连接文件、手动重连/断开、权限状态、诊断、系统通话设置或关于。模块名称保存在当前设备，按服务和模块隔离，设置和拨号页使用同一名称。用户须显式选择要使用的模块。未提供的 v2 功能不显示可执行的旧协议入口。

此前原视图接入已通过 15 项 UI 自动化；该轮单元测试 141 项中 139 项通过、1 项硬件音频测试按条件跳过，另有 1 项模拟器真实 Keychain 往返测试受当前测试签名环境限制。CallKit 与已有通话的后台生命周期按 [系统通话契约](../protocol/v2/CALLKIT.md) 实施，真机呼出、系统来电接听、后台保持及原 App 挂断已通过。v2 已接入独立 PushKit/APNs 注册、冷启动来电关联、后台短信通知和首次使用权限申请；真实后台推送仍要求 ECS 完整配置 APNs provider，见 [APNs 扩展](../protocol/v2/APNS_EXTENSION.md)。设备配对的 WebUSB、生产 ECS claim、模块范围绑定和完整原界面配对流程已通过；实现与剩余边界见 [配对记录](../docs/IOS_AIRSIM_PAIRING.md)。此前 [R5](../docs/IOS_AIRSIM_R5.md) 为模拟器前台闭环，[R6](../docs/IOS_AIRSIM_R6.md) 已确认实体双向音频，但通话质量尚未通过。Watch v2 暂不支持。

该目录包含面向三星 Android 电话端的 iPhone、Apple Watch、Live Activity 与共享模型。客户端通过 VoWLAN 直连三星手机，或通过独立 Cloudflare Relay 使用远程通话与短信。

当前应用构建为 `v0.9.6 (79)`，同版本公开 Release 提供 build `79` 的 unsigned IPA；配套 AVF Agent 为 [`v0.4.6`](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.4.6)。维护者 `com.eric3u.airsim` 构建使用 `https://airsim-push.remotepilot.site`；自行更换 Bundle ID 后必须使用自己的 Relay 和 APNs 凭据。

## 当前界面

当前界面采用“随身通信器”设计：与 iOS 电话 App 一致的 UIKit 动态系统色、系统语义字体和 SF Symbols。普通操作使用系统蓝色，呼叫与接听使用系统绿色，结束通话与错误使用系统红色。通话、联系人和短信的页面底色延伸至顶部，列表与导航栏保持连续。号卡与首次连接卡片使用系统分组表面和文字颜色，真实模块身份与线路标记贯穿通话、联系人、短信和拨号。主内容卡片采用 24 pt 连续圆角，输入框 12 pt，页面边距 20 pt；明暗模式共享导航、信息层级和操作语义。

导航保留“通话／联系人／短信／拨号键盘／号卡”五标签，使用原生 `TabView`。短信位于第三个标签，联系人发短信与短信通知均路由至该标签；联系人、短信和号卡详情使用原生返回。搜索保持布局与筛选状态一致，编辑与命名保护未保存内容，辅助字号下内容允许换行、纵排和滚动。设计规范、官方参考与验证状态见 [界面设计与验证](../docs/IOS_UI_REVIEW.md)。[原 Figma 稿](https://www.figma.com/design/QN34vy88ViWu1s45pE97BO?node-id=25-1146)保留为历史设计来源。

iPad 和 iPhone Duo 展开后的宽窗口采用通话、联系人、短信及号卡的列表与详情双栏；窄窗口回到单栏导航。号卡页显示真实模块名称和连接状态，提供添加设备、命名、默认呼出与外观设置；模块未提供本机号码时显示“未提供号码”。连接自动恢复，号卡不可用时不自动改用其他号卡。

模块名称旁统一显示该模块的蜂窝信号图标，覆盖通话、联系人、短信、拨号和号卡的展示与选择入口。Agent 的 CSQ 采样经 ECS 模块目录、快照或 USB 本地接口传递；App 按模块身份读取，切换模块不会沿用上一台的信号。CSQ 0–1／2–9／10–14／15–19／20–31 分别显示 0／1／2／3／4 格，这是界面分级。采样超过 30 秒、模块离线或未提供有效数据时显示不可用图标，不使用云端连接状态推断蜂窝强度。详情见 [v2 契约](../protocol/v2/R4.md)。

2026-10-31，EG25 → ECS → 已配对 iPad 的真实信号显示测试通过，App 显示 3 格，随后模块采样为 CSQ 18／−77 dBm；新版已签名安装，既有配对保留。USB 直连的实体信号显示尚待验证。

拨号键盘包含空态、已输入号码和本次呼出号卡选择三种状态，保留长按 `0` 输入 `+`、长按连续删除，以及预填号码的新增联系人入口。本次选择仅用于当前呼叫，不更改默认号卡；所选号卡不可用时不会改用另一张号卡。USB 本地链路仍由现有路由选择与授权机制处理。

短信包含列表、会话、失败提示与重试、新信息界面。双栏列表使用行内导航标题，搜索栏位于导航下方；收件箱缺口标记仅供内部同步使用。回复固定使用会话的原号卡；不同模块上的同一号码保留独立会话，不合并历史或草稿。新信息允许明确选择发送号卡；提交结果未确认时不向其他号卡或传输路径重复发送。原号卡草稿在明确成功后清除，明确失败时保留；已成功重试的记录在 App 重启后也不再提供重复重试。

收藏与每位联系人的首选号卡保存在本机。联系人按姓名拼音首字母分组，新增和编辑通过系统通讯录保存。通话页在窄窗口使用顶部搜索按钮，宽窗口使用列表内搜索；设备与外观设置从号卡页进入。通话历史按日期分组，记录正文首行显示姓名，次行显示通话方向与原号卡；时间独立位于右侧，与整块正文垂直居中，长内容和辅助字号自动换行。回拨使用记录的原模块，原模块缺失或未连接时不会改用当前号卡。联系人指定号卡的通话和短信先切换并确认连接。号卡使用已有模块名称，未提供号码时不生成号码尾号。

整体布局回归已通过 23 项 UI 场景验证：iPhone 19 项、iPad 3 项、Duo 1 项，覆盖明暗主题、辅助字号、宽窄窗口、编辑与配对流程。对应签名版本已在 iPad mini 更新安装并启动。本轮系统配色回归通过 iPhone 8 项、iPad 1 项，系统配色版本已在 iPad mini 更新安装并启动，记录见 [界面设计与验证](../docs/IOS_UI_REVIEW.md#验证记录)。本轮未执行真实通话、短信收发或 USB 验收；既有配对、CallKit 与 USB 的验收范围分别见对应记录。

## USB 本地通话与短信

已配对的 EG25 QDC507 可通过 USB 直接连接 iPad / iPhone，在拨号键盘和短信界面使用本地链路，App 继续固定使用 v2。模块须安装并启用支持 USB 本地服务的 Agent，Apple 设备须能枚举对应 USB 网络接口；模块安装配置见 [EG25 说明](../module/eg25/README.md)。

1. 通过“添加设备”完成配对，选中目标模块，并让 App 与模块在线连接 ECS。App 自动取得模块本地证书和授权。
2. 将 EG25 接到 iPad / iPhone 的 USB 接口，打开 App。空闲时 App 的拨号与短信自动优先使用已授权且身份验证通过的 USB 本地链路。设置中的模块名称与云端使用同一份本机名称。
3. 授权保存在 Keychain，有效期为签发后 24 小时；有效期内 ECS 不可达仍可通过 USB 通话和收发短信。剩余不足一小时时，App 在可联网时自动续期；续期暂时失败不删除仍有效的授权。

连接中断后 App 自动重试。通话、媒体及待确认命令固定在原路由，USB 拔线后不会把同一操作重发到云端；原操作状态确认且没有活动业务后才重新选择路由。更换配对会清除原本地授权，完全离线模块的远程撤销最迟在授权到期时生效。协议见 [USB 本地接入](../protocol/v2/USB_LOCAL.md)。

### USB 验证边界

Mac 端已验证 EG25 ECM 枚举、DHCP 地址分配、模块证书校验及未授权请求拒绝。iPad / iPhone 的 USB 枚举、呼入/呼出、短信双向、音频双向以及拔线重插尚待联合验收。已有云端真机记录不代表 USB 已通过。完全离线时，不承诺唤醒被系统挂起或终止的 App；后台和冷启动来电仍依赖 APNs/PushKit。

## Xcode 工程

打开：

```text
iOS/AirSIM.xcodeproj
```

主要 target：

- `AirSIM`：iPhone / iPad 主 App
- `AirSIMWatchApp`：Apple Watch App
- `AirSIMLiveActivityExtension`：锁屏与灵动岛实时活动
- `AirSIMTests`：传输选择和协议边界测试

## 客户端能力

- 三星设备一次性加密配对
- VoWLAN 服务发现、HMAC 鉴权和健康检查
- CallKit 拨号、来电、接听、挂断、静音与 DTMF
- PushKit、通知 APNs 与 ActivityKit
- 首次进入前台优先申请麦克风权限；完成麦克风授权决策后才启动本地发现和通知授权。若系统暂缓弹窗，下次进入前台会重试，不需要重新配对。
- Apple Watch 拨号、接听和通话媒体
- 短信列表、发送、通知和联系人整合
- VoWLAN 与云端 Relay 传输选择
- 云端 PCM 使用有界缓冲与 20 毫秒发送节奏，降低突发网络抖动时的卡顿风险。
- 设置页实时显示当前 VoWLAN / 云端模式与 Agent 心跳状态
- 云端模式在 App 进入前台时查询一次 Relay 状态；需要走云端拨号时再核对一次，灵动岛显示通话前等待一次状态查询（后台来电也适用）。本地模式不查询 Relay，VoWLAN 失联和后台待机更新不会启动定时云端查询，避免反复消耗请求额度。
- 四阶段云端自检：本机 Push 凭据、Relay 身份、设备注册、Agent 心跳
- 本地通话记录、诊断和媒体健康状态

VoWLAN 接听、拒接和挂断请求在已知当前通话时携带 `/api/calls/status` 返回的 `call_id`（JSON 字段 `call_id`）。Standalone 与新版 AVF Agent 会校验它，避免旧来电通知误操作后续通话；未取得通话 ID 时仍可发送兼容旧版 Agent 的空请求。

### 短信收发与推送

AirSIM 与 DJOneHub 采用相同的通道分工，但使用各自独立的 Relay 和 APNs topic：iPhone 发短信时，VoWLAN 就绪则直接调用 Agent；离线且云端模式开启时，向 Relay 提交经设备鉴权的 `send_sms` 命令，由 AVF Agent 执行并回传结果。Agent 收到短信后，把带 `delivery_id` 的事件送到 Relay；Relay 使用主 App topic 的普通 APNs `alert` 通知 iPhone，App 保存本地历史并按 `delivery_id` 与下次 Agent 同步去重。点开通知会进入发件人会话，冷启动时也会保留这一导航请求。

PushKit VoIP push 仅用于真实来电并交给 CallKit，不能拿它承载短信正文或唤醒发信任务。短信通知需要用户允许普通通知、iPhone 已取得 alert token，且 Relay、Agent 注册与心跳正常。普通 APNs 的送达及后台执行由 iOS 决定；正式验收必须分别测试前台、锁屏、冷启动和云端发信，不应把控制面自检通过等同于短信实测通过。

## 旧版客户端首次配置（v1）

1. 在三星手机启动 AirSIM，并确认 Agent 与 Shizuku 音频桥就绪。
2. 将 iPhone 连接到三星热点或同一局域网。
3. 在三星端打开两分钟配对窗口。
4. 在 iPhone 输入三星端显示的六位配对码。
5. 等待 VoWLAN 状态显示为就绪。
6. 如需远程模式，在“云端 Relay”填写与当前签名身份匹配的独立 Relay 地址，点击“保存 Relay 地址”，再启用“远程通话与短信”。维护者 `com.eric3u.airsim` 构建使用 `https://airsim-push.remotepilot.site`；其他 Bundle ID 必须使用自行部署的 Relay。
7. 打开“设置 → 云端模式自检”。四项全部通过才代表云端控制链路可用；“Relay 身份”会拒绝 DJOneHub 或其他服务，“Agent 心跳”要求 AVF Agent 在最近 90 秒内上报。自检不会拨号或发送短信。

## 构建与测试

```sh
xcodebuild -project iOS/AirSIM.xcodeproj \
  -scheme AirSIM \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing
```

在指定模拟器运行测试：

```sh
xcodebuild -project iOS/AirSIM.xcodeproj \
  -scheme AirSIM \
  -destination 'platform=iOS Simulator,name=iPhone Air' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

## 签名与推送

这是源码可见、仅限非商业用途的工程，不提供原作者的 Apple Developer Team、App ID、证书或 provisioning profile。当前工程的主 Bundle ID 为 `com.eric3u.airsim2`，Watch 为 `.watchkitapp`、Live Activity 为 `.liveactivity`，单元测试和 UI 测试分别为 `.tests`、`.uitests`，Watch companion 指向主 App。使用其他 Apple 身份时需要换成自己控制的标识。首次真机构建前必须使用自己的 Apple Developer 账号重新配置并签名：

1. 在 Xcode 为 `AirSIM` 选择自己的 Team，将 Bundle Identifier 改为自己控制的唯一标识，例如 `org.example.airsim`。
2. 将 Watch App 改为主标识加 `.watchkitapp`，例如 `org.example.airsim.watchkitapp`，并将 `WKCompanionAppBundleIdentifier` 设置为主 App 标识。
3. 将 Live Activity Extension 改为主标识加 `.liveactivity`，例如 `org.example.airsim.liveactivity`；测试 Target 可使用主标识加 `.tests`。
4. 在 Apple Developer 为三个正式 Target 创建 Explicit App ID，启用所需 capabilities，并重新生成属于自己 Team 的开发/分发 provisioning profile。
5. 在 Relay 的 `ALLOWED_BUNDLE_ID` 使用同一个主 App 标识；PushKit、Watch 和 Live Activity 的 APNs topic 会以它为基础生成。

只替换签名证书而保留其他人的 Bundle ID 不会获得对应 App ID/APNs topic 的权限。主 App、Watch、Live Activity、provisioning profile 与 Relay 必须使用同一套标识关系。

Relay 地址通过 `AIRSIM_PUSH_RELAY_URL` 注入，APNs 环境通过 `AIRSIM_APNS_ENVIRONMENT` 配置。默认 Debug 构建配置使用 `sandbox`，Release 使用 `production`；最终以签名后的 `aps-environment` 为准：`development` 对应 `sandbox`，分发签名和 TestFlight 对应 `production`。重签时同步 `AIRSIM_APNS_ENVIRONMENT`，安装前核对 Info.plist、签名 entitlement 和描述文件一致。ECS 可在同一业务服务中按环境使用两把独立 `.p8`，见 [部署配置](../service/airsim/deploy/compose/README.md#apns)。

不要把 DJOneHub 的 `https://push.remotepilot.site` 填入 AirSIM。该地址只允许 DJOneHub Bundle ID；AirSIM 与 DJOneHub 的设备注册、命令队列、媒体会话和 Dashboard 相互隔离。维护者 AirSIM 地址也只接受 `com.eric3u.airsim`，开源使用者更换 Bundle ID 后必须同步更换 Relay `ALLOWED_BUNDLE_ID` 和 APNs 凭据。

更换 Bundle ID 后会作为独立 App 安装，原 App 的容器和 Keychain 配对不会自动转移。新 App 需要重新授权并配对；v2 模块已有手机绑定时，通过网页的重置连接流程换绑。APNs 配置需使用新主 Bundle ID 及对应 provisioning profile。

GitHub Release 中的 `AirSIM-iOS-<version>-unsigned.ipa` 是供重签的 arm64 构建产物，不包含 `_CodeSignature` 或 `embedded.mobileprovision`，不能直接安装。不能只签主 App：必须同步替换并签署 Watch App 与 Live Activity Extension 的 Bundle ID、entitlements 和 provisioning profile。公开 Release 不应上传包含开发设备 UDID 的 development/ad hoc IPA。

## 安全与隐私

- VoWLAN Secret 保存在 Keychain，不写入 UserDefaults 或日志。
- 配对使用 X25519、HKDF-SHA256 与 AES-256-GCM。
- 控制请求使用 HMAC-SHA256、时间窗口和 nonce 防重放。
- 通话 PCM 仅在内存和网络流中处理，不落盘。
- 日志与错误界面不得显示设备 Secret、HMAC、Push token 或完整媒体地址。

## 当前状态

模拟器构建与测试已覆盖主要协议和传输选择。正式发布前仍需完成 Apple 签名、实体 iPhone/Apple Watch 安装、三星实机拨号接听、双向语音、短信与后台推送验收。

连接在前台及系统通话允许的生命周期内自动保持；首次网络连接失败按 1/2/4/8/15 秒退避，状态和短信轮询也会自动恢复。进入后台且无通话时遵循 iOS 挂起机制，来电由 PushKit 唤醒；不承诺后台永久网络连接。凭据确已失效时需要重新添加设备，临时续期网络错误不撤销现有会话。

后台 PushKit 来电在校验前刷新模块目录；模块重新建立连接和 App 冷启动均重新核对连接代次。诊断保留在开发日志和测试中，不提供 App 内诊断页，不保存 payload、号码或 token。真机诊断 XCTest 通过 `TEST_RUNNER_AIRSIM_LIVE_DEVICE_TESTS=1` 显式启用，普通测试默认跳过；`testIncomingCallControlsOnDevice` 需要外部测试手机呼入，自动接听二十秒后挂断；双向媒体通过日志及实际通话另行确认。

模块范围配对完成后持久化当前模块；App 重新启动时从配对配置恢复绑定模块，管理员多模块配置仍使用显式选择。

PushKit 通过 CallKit handler 单次进入来电核对流程，上报完成回调仅确认推送处理结果。同一通来电由前台快照先创建系统通话时，后续 PushKit 继续关联该系统 UUID；仍须用推送域和新鲜快照核对模块、连接代次与 call_id 后才能接听。

已调用 CallKit 上报的来电，其系统拒绝或结束回调只完成原 PushKit 回调，不创建另一通占位来电。Debug 日志记录拒绝路径和域核对结果，不记录号码、payload 或 token。真机测试可额外设置 `TEST_RUNNER_AIRSIM_BACKGROUND_CALL_TEST=1`，保持 App 在后台并直接操作系统接听界面。
