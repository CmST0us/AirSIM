# SkySIM TestFlight 发布

## 应用身份

v2 Apple 客户端显示名称为 **SkySIM**。它使用独立的 [App Store Connect 记录](https://appstoreconnect.apple.com/apps/6829440499/distribution)，Apple ID 为 `6829440499`，主要语言为简体中文。旧 AirSIM 记录 `6820454075` 对应不兼容的 v1 客户端，不作为 v2 的上传目标。

| Target | Bundle ID | 显示名称 |
| --- | --- | --- |
| 主 App | `com.eric3u.airsim2` | SkySIM |
| Live Activity | `com.eric3u.airsim2.liveactivity` | SkySIM 通话 |
| Watch | `com.eric3u.airsim2.watchkitapp` | SkySIM |

项目文件、scheme、可执行文件、协议字段、Keychain 和本地持久化键继续使用 AirSIM。更名不会改变现有 v2 配对身份。Watch 随工程构建，但仍不代表 Watch v2 业务已支持。

## 构建与导出

先检查工作区及 Secret，再核对 App Store Connect 的 Bundle ID、团队与既有签名配置。使用部署者自己的 Team 和 HTTPS 配对服务地址；不要把它们硬编码回公共工程。

```sh
xcodebuild -project iOS/AirSIM.xcodeproj \
  -scheme AirSIM -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath iOS/build/SkySIM.xcarchive \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$AIRSIM_DEVELOPMENT_TEAM" \
  AIRSIM_V2_PAIRING_ORIGIN="$AIRSIM_PAIRING_ORIGIN" \
  archive
```

Release 使用 `AIRSIM_APNS_ENVIRONMENT=production`。归档阶段可能使用开发签名；须以 `app-store-connect` 导出后检查最终签名，不能把归档的 development entitlement 当作最终分发签名。

导出选项使用 `method=app-store-connect`、`signingStyle=automatic`、指定的 `teamID`、`manageAppVersionAndBuildNumber=false` 和 `uploadSymbols=true`。先用 `destination=export` 导出并验证，获得上传授权后改用 `destination=upload`。本机 Xcode 账户可用时可通过自动签名获取分发资源；不导出私钥，也不把身份或描述文件写入仓库。

上传前确认：

- 主 App、Watch、扩展的版本与 build 一致，Bundle ID 和 companion 关系正确。
- 最终主 App 与 Watch 的 `aps-environment=production`，`get-task-allow=false`，签名校验通过。
- 主 App 的 `AirSIMAPNSEnvironment=production`，`AirSIMV2PairingOrigin` 指向本次部署服务。
- 主 App、Watch、扩展均包含自己的 `PrivacyInfo.xcprivacy`；应用自身 UserDefaults 使用 `CA92.1`，主 App 音频发送计时使用 `35F9.1`。WebRTC 随框架携带独立清单。依据 [Apple required reason API 文档](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)。这些 API 用途声明不替代 App Store Connect 的完整隐私信息。
- `WebRTC.framework`、字体与第三方许可证随归档保留。
- 主 App 包含 `NSCameraUsageDescription`。WebRTC 二进制引用相机 API，Apple 的上传后处理仍会检查该字段，即使 App 只创建音轨。说明必须如实表明当前只提供语音通话、不请求相机权限或采集视频；补齐说明不会开启相机功能。

SwiftPM 的 WebRTC 二进制包不附带 dSYM。正式上传前，从与 `Package.resolved` 完全相同版本的 [WebRTC 上游 Release](https://github.com/stasel/WebRTC/releases/tag/155.0.0) 获取独立的 dSYM 包；用 `xcrun dwarfdump --uuid` 比较归档中框架和 iOS arm64 dSYM 的 UUID，完全一致后将其放入归档的 `dSYMs/WebRTC.framework.dSYM`。`uploadSymbols=true` 不会自动下载缺失的第三方符号。

## 上传成功但没有构建时

不要仅查看 TestFlight 默认首页的“无构建版本”。直接打开该应用的 [iOS 构建页面](https://appstoreconnect.apple.com/apps/6829440499/testflight/ios)，展开“构建版本上传”，点击“失败”或其他上传状态查看 Apple 的错误详情。默认首页可能隐藏已经失败的首次上传。Xcode 的 `Upload succeeded` 只表示上传完成，不能替代 Apple 后续处理结果。参见 [Apple 构建上传状态说明](https://developer.apple.com/help/app-store-connect/manage-builds/view-builds-and-metadata/#view-build-upload-status)。

## 2026-11-01 执行记录

使用工程现有版本 `0.9.6 (79)`，在新的 Bundle ID 应用记录下独立上传；旧版 TestFlight 的构建号不影响此记录。

- Xcode 27.2：初始 Release 无签名归档、开发签名归档，以及包含 SkySIM 更名和隐私清单的最终 Release 归档、App Store Connect 分发导出均通过。
- 最终分发包已确认主 App 与 Watch 使用 production APNs、三个 Target 均不可调试且通过签名校验；三个显示名称、Bundle ID、Watch companion 关系、隐私清单和第三方许可证均已核对。
- SkySIM 新应用记录已创建并保存名称。北京时间 21:17:43，Xcode 返回 `Upload succeeded`、`Uploaded package is processing` 和 `EXPORT SUCCEEDED`；版本为 `0.9.6 (79)`。Apple 接收成功不等于已完成 TestFlight 处理或可供测试员安装。
- 上传后复查时，TestFlight 网页仍显示“无构建版本”，因此处理完成和可安装状态尚未确认。上传回执截图保存为本地产物目录内的 `skysim-uploaded.png`，App Store Connect 页面保存为 `skysim-testflight.jpg`。
- 上传有一项 WebRTC dSYM 缺失警告。随后从上游 `155.0.0` Release 取得 iOS arm64 符号包并确认 UUID 与框架完全一致，已补入本地最终归档；本次已上传构建的符号没有单独补传，不能声称 Apple 端警告已消除。后续上传须在上传前补齐符号。
- 本地产物位于已忽略的 `iOS/build/testflight-20261101/`：最终归档 `SkySIM.xcarchive`、分发包 `export/AirSIM.ipa`、签名检查 `verification.json`、符号检查 `symbols-verification.json` 和脱敏日志 `upload-skysim.log`。导出 IPA 的 SHA-256 为 `11b0cbd270c5dac98e1fcab062fb1f18de98fb2d3e5f8ff8028103437e65e217`。
- 本次不部署 ECS/Agent，不安装真实设备，不邀请外部测试员，不提交 App Store 审核。TestFlight 安装后的真实通话、短信、production PushKit/APNs、USB 和 Watch 仍须分别验收。

### Build 79 失败原因与 Build 80 修复

后续排查在 iOS“构建版本上传”中确认 `0.9.6 (79)` 状态为“失败”，Apple 报告 `90683: Missing purpose string in Info.plist`，具体缺少主 App 的 `NSCameraUsageDescription`。这是 WebRTC 二进制包含相机 API 引用引起的用途声明要求，并非等待处理或 dSYM 警告造成。此前默认首页的“无构建版本”不足以判断状态。

主 App 已补齐与纯语音行为一致的相机说明，三个发布 Target 的 build 统一递增为 `80`，Watch 的冗余显示名配置也同步为 SkySIM。`0.9.6 (80)` 的 Release 归档通过，上传前已补入 UUID 完全匹配的 WebRTC dSYM。产物独立保存在 `iOS/build/testflight-20261101-build80/`，保留 Build 79 归档和失败证据以供比较。

- 最终 IPA 的三个 Target 均通过严格签名校验，使用不可调试的分发描述文件；主 App 与 Watch 为 production APNs，版本均为 `0.9.6 (80)`。相机说明与三个隐私清单均已进入分发包。
- 分发导出 IPA 的 SHA-256 为 `8a9cea28a65d6b9b64221745d08f0acff3d6ee58297167eea2852099ebd2129e`，检查结果保存于该产物目录的 `verification.json`。
- 北京时间 22:24:32，Build 80 上传返回 `Upload succeeded` 和 `EXPORT SUCCEEDED`，无 WebRTC 符号缺失警告；约 22:27，App Store Connect 的上传状态已显示“完成”，并出现可用的 Build 80。
- Build 80 已分配至“内部测试”群组，页面确认“2 个测试员 · 1 个构建版本”，`0.9.6 (80)` 状态为“正在测试”。群组保留现有两位测试员，双方状态均为“已邀请”；尚未观察到接受邀请或实际安装。后续构建仍需手动分配，未启用自动分发。
- 已保存简体中文测试说明，覆盖 v2 兼容要求、配对、云端通话、短信、后台来电及 USB 恢复，并注明 Watch v2 通话尚未支持。测试员接受 Apple 邮件邀请后可通过 TestFlight 安装。
- Apple 处理完成截图为 `skysim-processed.jpg`，内部群组“正在测试”截图为 `skysim-internal-testing.jpg`，均位于 Build 80 产物目录。本轮未执行真机安装或通话、短信、推送及 USB 验收。

## 2026-11-02：6 位短号更新

本次基于当前 v2 源码发布 `0.9.6 (81)`，主 App、Watch 和扩展统一使用 build `81`。拨号与短信共用的号码校验接受可选 `+` 和 6–15 位 ASCII 数字，保留前导零。

- `testSixDigitNumberContract` 与 `testCommandArgumentsAndUTF16Boundaries` 已在 iPhone 16 Pro / iOS 18.5 模拟器通过，结果为 `/tmp/airsim-sixdigit-20261102-tests.xcresult`；发布二进制也已确认包含新的 6 位下限校验。
- Release 归档和 App Store Connect 分发导出通过；三项 Target 严格签名校验通过，主 App 与 Watch 为 production APNs，相机用途说明、隐私清单及匹配的 WebRTC 155.0.0 dSYM 保留。
- 产物位于 `iOS/build/testflight-20261102-build81/`，分发 IPA 的 SHA-256 为 `b799e5d9ea1b1b6748d526663ce3aff6507c02272c677acedb161037155f92ae`。`source-manifest.json` 保存归档源码摘要，归档期间 iOS 源码没有变化；检查结果为 `verification.json`、`symbols-verification.json` 和 `short-number-verification.json`。
- App Store Connect 登录恢复后已确认线上最新构建为 `80`，Build `81` 无冲突；北京时间 13:53:53，上传返回 `Uploaded package is processing`、`EXPORT SUCCEEDED`，没有上传警告。13:57，Apple 上传状态已显示“完成”。
- 13:58，Build 81 已加入原“内部测试”群组并确认状态为“正在测试”。群组保留两位测试员和 Build 80，现有用户可在 TestFlight 更新至 `0.9.6 (81)`；本轮未代用户安装或确认其已更新。
- 已保存本版简体中文测试说明，重点覆盖 6 位短号、前导零、普通及国际号码回归，并提示先更新模块 Engine。最终截图为产物目录中的 `skysim-internal-testing.jpg`，状态记录为 `release-status.json`。
- 本次 Apple 发布会话递增 `iOS/AirSIM.xcodeproj/project.pbxproj` 的构建号，并同步 `iOS/README.md`、本文、`docs/SHORT_NUMBER_UPDATE.md`、`docs/SHORT_NUMBER_DEPLOYMENT_20261102.json`、根 `README.md`、`AGENTS.md`、`LLM.txt`、`codex.md`、`claude.md` 与 `docs/AVF_INSTALL_GUIDE.md` 中的发布状态。短号源码和测试沿用配套修复会话的 `V2Commands.swift` 与 `CloudV2Tests.swift`，未改动服务或模块代码；最终 `git diff --check` 通过。
- 本会话仅负责 Apple 发布，云端和模块 Engine 的配套更新由另一执行会话处理；未执行真实短号呼叫或短信发送。

## 2026-11-02：短信发送交互更新（Build 82）

已核对 App Store Connect 最新构建为 `81`，本次使用 `0.9.6 (82)`，继续上传到 SkySIM 独立应用记录。点击发送立即显示气泡并清空输入框；新信息立即进入会话。确认失败时，气泡左侧显示红色感叹号，点按后用原号卡重发并复用同一气泡。另修复 iPad 横屏键盘遮挡末条消息；实现与范围见 [短信交互](IOS_SMS_INTERACTION.md)。

- 已逐项比对 [验证 JSON](IOS_SMS_INTERACTION_VERIFICATION.json) 中的八个源码和测试文件 SHA-256，均与归档输入一致。归档期间 iOS 文件未变。
- 核对三份 xcresult：113 项相关单元和界面回归通过；最终滚动修复后，iPhone 与 iPad 各 2 项界面回归通过。既有无签名模拟器真实 Keychain 用例仍按交接记录排除，不算通过。
- Release 归档及 App Store Connect 分发导出通过，三个 Target 严格签名校验通过，主 App 与 Watch 使用 production APNs。已补入 UUID 匹配的 WebRTC 155.0.0 iOS arm64 dSYM；相机用途说明、三个隐私清单和此前 6 位短号修复保留。
- 北京时间 15:14:24，Build 82 上传返回 `Uploaded package is processing`、`EXPORT SUCCEEDED`，无上传警告；15:17，Apple 上传状态已显示“完成”。
- 15:20，已确认 Build 82 加入原“内部测试”群组，状态为“正在测试”。群组保留两位测试员和 Build 81、80，现有用户可在 TestFlight 更新至 `0.9.6 (82)`。测试员页面已显示此前 Build 81 安装记录，本轮未代用户安装或确认 Build 82 已安装。
- 已保存简体中文测试说明，重点覆盖即时气泡、失败图标及原号卡重发、重启后的消息保留和 iPad 键盘遮挡。构建 ID 为 `396ff354-0d13-46d8-91bb-8da8b9028728`；最终截图为产物目录中的 `skysim-internal-testing.jpg`，状态记录为 `release-status.json`。
- 产物独立保存在 `iOS/build/testflight-20261102-build82/`，包括源码摘要 `source-manifest.json`、原始交接验证副本 `sms-handoff-verification.json`、分发检查 `verification.json` 和脱敏构建日志。导出 IPA 的 SHA-256 为 `0cf86dc5bad49cf7dfc456af6b05b52aabec2683ee6308ce84e47fee7a20398e`。
- 本次仅发布 App，不重新部署 ECS 或 Engine，不执行真实短信发送或设备安装。

本次发布会话仅递增 `iOS/AirSIM.xcodeproj/project.pbxproj` 构建号并同步 `docs/IOS_SMS_INTERACTION_VERIFICATION.json`、`docs/IOS_SMS_INTERACTION.md`、本文、`iOS/README.md`、根 `README.md`、`AGENTS.md`、`LLM.txt`、`codex.md`、`claude.md` 与 `docs/AVF_INSTALL_GUIDE.md` 的发布状态；短信源码和测试沿用已核对的交接版本。最终 `git diff --check` 通过。

## 2026-11-02：main 提交与 Build 82 对应核验

本轮核对提交 `f49b425f6d7bed4b48e591a8f2857308daade45a`，开始时本地 HEAD 与 `origin/main` 均指向该提交，工作区干净。将该提交的 244 个 iOS 文件逐个计算 SHA-256，与 Build 82 的 `source-manifest.json` 比较：243 个一致，仅 `iOS/README.md` 发布说明不同，无新增或缺失文件；实际 App 源码、测试、工程配置、资源和 `Package.resolved` 均一致。当前 iOS 工作区也与该提交一致。

保留的 Build 82 分发 IPA SHA-256 再次核对为 `0cf86dc5bad49cf7dfc456af6b05b52aabec2683ee6308ce84e47fee7a20398e`。因此源码无需重新构建或递增 build；本轮未重新上传、安装真机或修改 ECS/Engine，也未执行 Git commit/push。

用户重新登录后，北京时间 22:29 在线复核完成：Build 82 仍为“正在测试”，原“内部测试”群组保留两位测试员和 Build 82、81、80，测试说明保留；构建 ID 仍为 `396ff354-0d13-46d8-91bb-8da8b9028728`。首次群组页面短暂显示 0 个构建，打开 Build 82 详情确认群组关联后返回，列表恢复为 3 个；未执行重新分配或其他发布变更。

Apple 测试员页面已报告用户的 iPhone Duo / iOS 27.2 安装 `0.9.6 (82)`；这是 Apple 的安装状态证据，本轮未代用户安装，也未重新执行真实通话、短信、推送或 USB 验收。main 的 App 发布端继续使用 Build 82，不需要新增构建。

文件对比与在线状态见 [main 核验记录](IOS_TESTFLIGHT_MAIN_VERIFICATION_20261102.json)。最新截图 `main-verification-internal-testing.jpg`、`main-verification-build-detail.jpg`、`main-verification-installed.jpg` 保存在 Build 82 产物目录。此次仅更新本文及该 JSON，`git diff --check` 和 JSON 解析检查通过；改动留在工作区，交由主控会话统一提交。

## 2026-11-04：挂断待确认阻塞恢复（Build 83）

基于 main `1fdf5874ae995373ab9b6abaeff07e4b623b058f`，三个发布 Target 的版本为 `0.9.6 (83)`。修复旧挂断无回执或 Engine 运行实例替换后永久阻塞拨号/接听；仅在可信的新鲜状态确认旧通话结束或运行代次替换时清除本机挂断等待，不重发命令或修改云端回执。具体边界见 [挂断恢复](IOS_HANGUP_RECOVERY_20261104.md)。

- 已核对交接 JSON 的三个源码/测试文件 SHA-256 与 main 一致，实际 xcresult 为 108 项通过、0 失败；既有未签名模拟器真实 Keychain 用例仍被明确排除。
- Release 归档通过，244 个 iOS 文件在归档期间未变；WebRTC 155.0.0 iOS arm64 dSYM 与归档框架 UUID 完全一致并已补入。分发导出和三个 Target 严格签名校验均通过，主 App 与 Watch 使用 production APNs，相机说明与隐私清单保留。
- 产物目录为 `iOS/build/testflight-20261104-build83/`，包含 `source-manifest.json`、`hangup-handoff-verification.json`、`symbols-verification.json`、`release-status.json` 和脱敏构建日志。
- 最终分发 IPA SHA-256 为 `bd1cedd9530d96553ccd8e03979657e6132c05fd0192477bfa22d5e5d5e713bb`，检查结果为产物目录中的 `verification.json`。Apple 登录恢复后，已核对全部上传记录，最高构建仍为 82，Build 83 无冲突；北京时间 19:24:49 上传返回 `Upload succeeded`、`Uploaded package is processing` 和 `EXPORT SUCCEEDED`，无上传警告。19:29，Apple 上传状态已显示“完成”。
- 19:30，Build 83 已加入原“内部测试”群组，状态为“正在测试”，现有用户可在 TestFlight 更新。群组保留两位测试员和 Build 82、81、80，共四个构建；本轮未确认 Build 83 已在真实设备安装。
- 简体中文测试说明已保存，重点覆盖模块重连或 Engine 更新后的拨号/接听恢复，以及重启 App 后旧挂断不再阻塞。构建 ID 为 `a72979b3-f262-49c2-946f-a8987e14dc10`；最终截图为产物目录中的 `skysim-internal-testing.jpg` 和 `testflight-build83-details.jpg`，状态记录为 `release-status.json`。
- 本轮仅负责 App 发布，未修改业务源码、ECS 或 Engine，未代用户拨打电话或安装真机；版本号与发布记录随本次 main 提交保存。

本次发布修改 `iOS/AirSIM.xcodeproj/project.pbxproj` 构建号，同步本文、挂断恢复 Markdown/JSON、`iOS/README.md`、根 `README.md`、`AGENTS.md`、`LLM.txt`、`codex.md`、`claude.md` 和 `docs/AVF_INSTALL_GUIDE.md` 的状态。业务源码保持 main `1fdf587`，文档与状态 JSON 检查通过。


## 2026-11-05：云端音频双包冗余（Build 84，已上传待内部测试）

基于已推送 main 的 `f2bb817ac8cfe73c33c77774b3a157966b3d805d`，本次 App 启用 WebRTC Opus/RED 最多两包冗余，并在音频会话或 Peer 工厂初始化前设置 SDK 选项。配套 Engine 为 `2.0.0-dev.audio1`、helper 为 `0.6.1-opus`，由主控会话发布；方案与真实设备边界见 [云端音频重构](CLOUD_AUDIO_REBUILD_20261105.md)。

- 继续使用 SkySIM / `com.eric3u.airsim2` / App Store Connect `6829440499` 和原用户 Team。本次使用 `0.9.6 (84)`；Apple 网页会话已过期，登录控件曾持续空白加载，未能从网页读取最高构建号。随后通过 Chrome 原生界面退出网页调试连接，恢复正常密码输入框；现等待用户完成密码和验证。通过仍有效的 Xcode 分发账户上传，Apple 已接受 Build 84；北京时间 23:38:54 返回 `Uploaded package is processing`、`EXPORT SUCCEEDED`，无上传警告。处理完成与内部测试分配仍待网页登录恢复后确认，不能据此宣称已可安装。
- Release 归档与 App Store Connect 分发导出通过，三个发布 Target 的严格签名、Bundle ID、分发 profile 和隐私清单检查通过，主 App 与 Watch 为 production APNs。相机、麦克风及通讯录用途说明保留，WebRTC 155.0.0 arm64 dSYM 与框架 UUID 匹配。
- 244 个 iOS 文件在归档期间未变；`V2WebRTC.swift` SHA-256 与音频交接证据一致。本轮按用户要求不重复功能或真机测试；交接记录的 108 项 iOS 回归及实际 SDK 双向合成音频互通通过属于此前验证，不等于本轮真实通话验收。
- 产物保存在 `iOS/build/testflight-20261105-build84/`：`source-manifest.json`、`audio-handoff-verification.json`、`symbols-verification.json`、`verification.json`、`release-status.json`、脱敏日志、测试说明草稿和登录阻塞截图。分发 IPA SHA-256 为 `b2c93cf11dcc50a5543c3bed76729baf600e1322361a35627ba811941d7c9c42`。
- 本发布会话仅修改 `iOS/AirSIM.xcodeproj/project.pbxproj` 构建号、本文及忽略目录下的发布证据；保留其他会话改动，不自行 commit/push。网页 Engine 发布及统一文档状态由主控会话处理。本轮未安装真实设备或执行通话。
