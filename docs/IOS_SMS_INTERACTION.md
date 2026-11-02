# SkySIM 短信发送交互

2026-11-02：短信发送改为即时显示。点击发送时先将正文写入受保护的本机短信历史，立即显示气泡并清空当前草稿；新信息关闭编辑页并打开对应会话。发送按钮不转圈，会话不显示“发送中”“结果待核对”“草稿已保留”等中间提示。

确认失败时，气泡左侧出现系统红色 `exclamationmark.circle.fill`，触控区域为 44 × 44 pt。VoiceOver 朗读“发送失败，点击重发”，并提示原号卡。点按后复用同一气泡发送，失败再次显示图标，成功移除图标。重发不会清空正在编辑的下一条草稿。键盘或消息布局变化后再滚动至底部，确保 iPad 横屏中气泡及重发图标完整露出。

本机记录按客户端身份、模块和收件人隔离，保留正文、气泡 ID、提交命令及回执中确认的消息 ID。同步历史以精确消息 ID 合并，不通过相同正文猜测，因此两次主动发送相同正文不会被误合并。App 重启后仍保留失败气泡；结果未知的命令只查询原回执，禁止再次提交或切换传输重发。命令日志仍只保存元数据，正文留在受保护的短信历史中。

如果本机记录无法保存，不提交网络请求，并保留输入内容。进程在写入气泡后、命令提交前终止，重启后显示失败图标；已提交但回执未知的消息继续核对。

## 文件范围

- `iOS/AirSIM/A1MessagesViews.swift`：即时提交、新会话跳转、左侧失败图标与无中间态输入区。
- `iOS/AirSIM/AppModel.swift`：同步创建气泡、清空当前草稿、原号卡发送与重发、防重复点击。
- `iOS/AirSIM/CloudV2/CloudV2Model.swift`、`V2LocalStore.swift`、`V2Commands.swift`：本机记录、提交前持久化、回执关联、重启恢复和去重。
- `iOS/AirSIM/CloudV2/AppRouting.swift`、`iOS/AirSIMTests/CloudV2Tests.swift`、`iOS/AirSIMUITests/MessagingTests.swift`：延时拒绝／重发成功夹具、状态与界面回归。

## 验证

iPhone 16 Pro / iOS 18.5 模拟器通过 107 项相关单元测试及 6 项界面测试，结果包 `/tmp/airsim-optimistic-verified-20261102.xcresult`。覆盖即时气泡、清空输入、失败图标左侧位置、44 pt 触控、重发复用气泡、新信息跳转、草稿隔离及未知命令保护。另在 iPad 上通过回执去重和清空本机记录的补充断言。最终滚动修复后，iPhone 与 iPad Pro 11-inch (M4) / iOS 18.5 各重新通过 2 项发送界面测试，确认键盘上方气泡和失败图标完整可见，新信息关闭后进入正确会话。结果包为 `/tmp/airsim-sms-final-phone-20261102.xcresult` 与 `/tmp/airsim-sms-final-ipad-20261102.xcresult`。截图已目视核对，构建源码哈希与结果见 [验证记录](IOS_SMS_INTERACTION_VERIFICATION.json)。

首次全量运行遇到既有的真实 Keychain 往返用例失败；该用例依赖签名环境，后续无签名模拟器运行显式排除 `testRealKeychainRoundTripWithIsolatedAccount`，不将其算作通过。iPad 首轮界面测试在旧脚本的标签选中状态断言处停止，已改为确认短信页面实际出现，并限定弹层内可用的发送按钮，再执行发送流程；后续测试通过。

本次仅修改 App，不需要更新 ECS 或 Engine；没有通过助手发送真实短信。SkySIM `0.9.6 (82)` 已于 2026-11-02 完成 Apple 处理并加入原 TestFlight 内部测试群组，两位既有测试员可安装更新。发布签名、源码摘要及状态证据见 [发布记录](IOS_TESTFLIGHT.md) 与 [验证记录](IOS_SMS_INTERACTION_VERIFICATION.json)；本轮未代用户安装 Build 82 或执行真实短信验收。
