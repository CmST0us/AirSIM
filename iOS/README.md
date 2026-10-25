# AirSIM iOS 与 watchOS

## v2 与原界面

App 保留仅本地、云端 v1、云端 v2 选择；已有安装继续使用原选择。v2 已接入原拨号、最近、短信、联系人和设置五标签，配置导入与模块选择也在原首次连接及设置视图中。控制、凭据和历史按服务、安装实例与模块隔离，活动通话或结果未确认的操作会阻止版本切换。

v2 首先使用 `service/airsim/` 的 ECS Docker Compose 服务。管理员签发的连接文件通过系统文件选择器导入，凭据存 Keychain；没有公开交互登录或自动回退 v1。用户须显式选择要使用的模块。通话和短信沿用原界面，未提供的 v2 功能不显示可执行的旧协议入口。

原视图接入已通过 15 项 UI 自动化；全量单元测试 132 项中 131 通过、1 项硬件音频测试按条件跳过。CallKit 与已有通话的后台生命周期按 [R7 契约](../protocol/v2/R7.md) 实施，真机呼出、系统来电接听、后台保持及原 App 挂断已通过。v2 空闲后台及冷启动来电唤醒不在本阶段范围。此前 [R5](../docs/IOS_AIRSIM_R5.md) 为模拟器前台闭环，[R6](../docs/IOS_AIRSIM_R6.md) 已确认实体双向音频，但通话质量尚未通过。当前状态、设计审核与 QA 记录见 [R7](../docs/IOS_AIRSIM_R7.md)。Watch v2 暂不支持。

该目录包含面向三星 Android 电话端的 iPhone、Apple Watch、Live Activity 与共享模型。客户端通过 VoWLAN 直连三星手机，或通过独立 Cloudflare Relay 使用远程通话与短信。

当前应用构建为 `v0.9.6 (79)`，同版本公开 Release 提供 build `79` 的 unsigned IPA；配套 AVF Agent 为 [`v0.4.6`](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.4.6)。维护者 `com.eric3u.airsim` 构建使用 `https://airsim-push.remotepilot.site`；自行更换 Bundle ID 后必须使用自己的 Relay 和 APNs 凭据。

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

## 首次配置

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

这是源码可见、仅限非商业用途的工程，不提供原作者的 Apple Developer Team、App ID、证书或 provisioning profile。工程中的 `com.example.airsim` 是占位符，不能直接用于发布。首次真机构建前必须使用自己的 Apple Developer 账号重新配置并签名：

1. 在 Xcode 为 `AirSIM` 选择自己的 Team，将 Bundle Identifier 改为自己控制的唯一标识，例如 `org.example.airsim`。
2. 将 Watch App 改为主标识加 `.watchkitapp`，例如 `org.example.airsim.watchkitapp`，并将 `WKCompanionAppBundleIdentifier` 设置为主 App 标识。
3. 将 Live Activity Extension 改为主标识加 `.liveactivity`，例如 `org.example.airsim.liveactivity`；测试 Target 可使用主标识加 `.tests`。
4. 在 Apple Developer 为三个正式 Target 创建 Explicit App ID，启用所需 capabilities，并重新生成属于自己 Team 的开发/分发 provisioning profile。
5. 在 Relay 的 `ALLOWED_BUNDLE_ID` 使用同一个主 App 标识；PushKit、Watch 和 Live Activity 的 APNs topic 会以它为基础生成。

只替换签名证书而保留其他人的 Bundle ID 不会获得对应 App ID/APNs topic 的权限。主 App、Watch、Live Activity、provisioning profile 与 Relay 必须使用同一套标识关系。

Relay 地址通过 `AIRSIM_PUSH_RELAY_URL` 注入，APNs 环境通过 `AIRSIM_APNS_ENVIRONMENT` 配置。Debug 开发签名对应 APNs `sandbox`，Release/TestFlight 对应 `production`。

不要把 DJOneHub 的 `https://push.remotepilot.site` 填入 AirSIM。该地址只允许 DJOneHub Bundle ID；AirSIM 与 DJOneHub 的设备注册、命令队列、媒体会话和 Dashboard 相互隔离。维护者 AirSIM 地址也只接受 `com.eric3u.airsim`，开源使用者更换 Bundle ID 后必须同步更换 Relay `ALLOWED_BUNDLE_ID` 和 APNs 凭据。

新安装需要重新完成三星配对、通知授权、CallKit/PushKit 注册和 Watch 配套安装。

GitHub Release 中的 `AirSIM-iOS-<version>-unsigned.ipa` 是供重签的 arm64 构建产物，不包含 `_CodeSignature` 或 `embedded.mobileprovision`，不能直接安装。不能只签主 App：必须同步替换并签署 Watch App 与 Live Activity Extension 的 Bundle ID、entitlements 和 provisioning profile。公开 Release 不应上传包含开发设备 UDID 的 development/ad hoc IPA。

## 安全与隐私

- VoWLAN Secret 保存在 Keychain，不写入 UserDefaults 或日志。
- 配对使用 X25519、HKDF-SHA256 与 AES-256-GCM。
- 控制请求使用 HMAC-SHA256、时间窗口和 nonce 防重放。
- 通话 PCM 仅在内存和网络流中处理，不落盘。
- 日志与错误界面不得显示设备 Secret、HMAC、Push token 或完整媒体地址。

## 当前状态

模拟器构建与测试已覆盖主要协议和传输选择。正式发布前仍需完成 Apple 签名、实体 iPhone/Apple Watch 安装、三星实机拨号接听、双向语音、短信与后台推送验收。
