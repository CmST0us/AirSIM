# AirSIM 全项目 Codex 部署辅助

## v2 建设覆盖说明（2026-10-24）

v2 LC3 固定 16 kHz 单声道、32 kbps、每 20 ms 两个编码帧。原生 helper 与 App 编解码，Go Agent/ECS 透传；App、control／media、Agent/helper 必须配套更新和回滚。ECS、EG25 与 iPad mini 已部署 16 kHz 版本并完成真实来电实测；RM500 须经网页安装器更新 Engine 后才恢复通话音频。接收端抖动缓冲、追播参数与现场诊断入口见 LC3 文档。源码、构建与当前实测边界见 [LC3 音频](docs/LC3_AUDIO.md)。

当前 iOS 界面采用 Figma `QN34vy88ViWu1s45pE97BO` 页面 `25:1146`，覆盖通话与联系人、拨号键盘、短信、号卡与连接、呼入／呼出／接通状态及空状态。iPad 和 iPhone Duo 展开后的宽窗口采用通话、联系人、短信及号卡的列表与详情双栏，窄窗口使用单栏导航；五标签使用原生 `TabView`，随系统和窗口形态适配。导航为“通话／联系人／短信／拨号键盘／号卡”五标签，短信位于第三个主标签，联系人发短信与短信通知也路由至该标签；号卡页保留设备、模块和外观设置。本次呼出选择不更改默认号卡；短信回复锁定原号卡，不同模块上的同一号码保持独立会话。收藏与联系人首选号卡本机持久化，新增和编辑写入本机系统通讯录；历史按时间展示同一客户端身份下各模块记录，回拨使用原模块，原模块不可用时拒绝回拨。

界面已按 Apple HIG 调整动态字号、44 pt 点击区域、明暗及高对比度配色、减少动态效果与透明度。联系人、短信和号卡详情采用原生返回导航；辅助字号支持纵向重排，短窗口内容可滚动。详见 [界面审查](docs/IOS_UI_REVIEW.md)。

iPhone 模拟器已验证五标签导航、联系人与通话记录的短信跳转、跨标签草稿保留，以及呼出、来电和通话中界面。iPad 与 iPhone Duo 模拟器已验证双栏操作和三种通话状态，并核对展开屏截图。`com.eric3u.airsim2` 签名版本已更新安装到 iPad mini。本轮未执行真实通话、短信收发或 USB 验收。

EG25 QDC507 v2 使用 `eg25-qdc507`、ARMv7、`/usrdata/airsim-v2` 与 init respawn。精确固件、DATA11、校准、网页安装及验收边界见 [EG25 说明](module/eg25/README.md) 和 [实机记录](module/eg25/TESTING.md)。ECS 配对按认证连接的 platform 显示型号，iOS 仍使用公共 v2 协议。

用户已明确新建多平台 v2：`module/airsim-agent/`（新 Agent）、`service/airsim/`（ECS Go 服务）、`service/airsim/deploy/compose/`（首版 Docker Compose）、`service/airsim-worker/`（独立 Worker v2）。先读 [系统架构](docs/SYSTEM_ARCHITECTURE.md) 和 [Agent/HAL 架构](module/ARCHITECTURE.md)，再读相应新目录 README。App 固定使用 v2，旧版／仅本地偏好不再决定启动路由，ECS 与 Worker v2 共用对外协议。新 Agent 的 RM500 R1–R3 已完成限定范围实机验收，见 [主控决策](docs/RM500_AGENT_EXECUTION.md) 和 [R3 记录](module/airsim-agent/R3_TESTING.md)。设备配对已在原 App 设置中完成 WebUSB、五分钟连接码、模块证明、claim 和自动续期接线，见 [配对契约](protocol/v2/PAIRING.md) 与 [iOS 记录](docs/IOS_AIRSIM_PAIRING.md)；生产 ECS claim 和完整 UI 流程已通过，实体 iPhone Keychain 与长期刷新仍需复验。

下面有关当前发布、三星 Android、旧 AVF 包/端口和 Worker 的规则继续适用于 v1；不得用这些历史范围禁止用户已确认的 RM500/EG25/Android AVF v2 建设，也不得把旧安装脚本直接用于新 Agent。保留旧 `module/module-agent/`、`push-relay-worker/` 和现有改动。v2 独立建设、ECS 优先；四个执行会话使用 GPT-6-Astra / medium，仅执行主控决定，遇到技术决策交回主控，未明确调度则待命。

v2 USB 本地通话与短信使用现有配对身份。EG25 可通过 USB 直接接入 iPad / iPhone；首次使用须让 App 与模块在线连接 ECS 取得授权。App 缓存签发后 24 小时有效的授权，期限内 ECS 不可达仍可本地使用，剩余不足一小时时联网自动续期。空闲时自动优先 USB，掉线自动恢复；通话、媒体与待确认命令固定原路由，不向另一传输重发副作用。设置继续使用现有设备、模块命名和外观入口。用户步骤见 [iOS USB 本地接入](iOS/README.md#usb-本地通话与短信)，协议见 [USB_LOCAL](protocol/v2/USB_LOCAL.md)。本次 USB 真机通话、短信、双向音频与拔线恢复尚待验收；完全离线不承诺唤醒被系统挂起或终止的 App。

RM500U 使用 BusyBox init 的 `respawn` 启动 `/mnt/data/airsim-v2/run-agent.sh`。启动器等待 `/dev/smd1`，并通过 `airsim-agent --wait-random` 阻塞到内核随机源初始化后再启动服务；不要用可能漏掉瞬时峰值的 `entropy_avail` 轮询。安装、验证和回滚见 [RM500U 开机启动](module/airsim-agent/RM500U_AUTOSTART.md)。配置完成后网页配对使用 Chrome WebUSB，不依赖主机 `adb server`。

本文为 AI 编码代理提供 AirSIM 全仓库的事实来源、构建顺序、部署边界和安全约束。开始任务前先阅读根目录 `README.md`，再阅读所修改组件的 README 和实际源码。涉及 AVF 安装、配对或恢复时，还要阅读 `docs/AVF_INSTALL_GUIDE.md` 和 `LLM.txt`。源码与测试是协议事实来源；本文不能替代它们。

当前发布基线（2026-10-12）：Android AVF/Standalone/iOS Apps `v0.9.6`（build `79`），兼容用 AVF Agent `v0.4.6`（Debian `0.4.6-1`），Relay 协议 `0.2.1`。维护者 AirSIM Relay 为 `https://airsim-push.remotepilot.site`；DJOneHub 的 `https://push.remotepilot.site` 不得用于 AirSIM。历史 Release 文档中的旧版本号属于归档事实，不能机械替换。

## 1. 项目目标

AirSIM 以 Android 手机作为蜂窝电话与短信终端：

- 推荐的 Android Standalone APK 对接 Android Telecom、短信、Shizuku 音频桥，并在前台服务中内置 Agent。
- 内置 Agent 维护设备状态、命令编排、Relay 会话与媒体状态，不使用 AVF、Terminal、Debian、`8575/8576` 或 `airsim-installerd`。
- 旧 Android AVF Agent 与 `airsim-installerd` 仅用于兼容和回退。
- iPhone 与 Apple Watch 通过 VoWLAN 或 Cloudflare Relay 使用通话和短信能力。
- Cloudflare Relay 负责公网事件、APNs、命令队列、Dashboard 与媒体中继。

不要把 AirSIM 描述为软 SIM、运营商替代品或紧急呼叫服务。不要恢复历史品牌、历史硬件模块方案或与当前三星 Android 架构不一致的说明。

AirSIM 使用 `PolyForm-Noncommercial-1.0.0`，属于源码可见项目而不是 OSI 开源软件。只协助个人学习、研究、实验及许可证列明的其他非商业用途；商业使用、收费服务、商业产品集成和预期商业应用需要版权所有者单独书面授权。修改或分发时必须保留 `LICENSE`、`NOTICE` 和第三方声明。

## 2. 组件地图与事实来源

| 范围 | 先读 | 核心入口 | 验证命令 |
| --- | --- | --- | --- |
| Android Standalone | `android-standalone/README.md` | `android-standalone/`、`android/phone-control-app/src/` | `./android-standalone/test.sh` |
| 三星控制 App | `android/phone-control-app/README.md` | `android/phone-control-app/src/`、`build.sh` | `./android/phone-control-app/test.sh` |
| 三星音频桥 | `android/phone-audio-bridge/README.md` | `android/phone-audio-bridge/src/`、`run-device-bridge.sh` | `./android/phone-audio-bridge/build.sh` |
| AVF Agent | `module/module-agent/README.md` | `module/module-agent/main.go`、`router.go` | `(cd module/module-agent && go test ./...)` |
| AVF Installer | `module/packaging/README.md` | `module/avf-installerd/` | `(cd module/avf-installerd && go test ./...)` |
| Debian 发布 | `module/packaging/README.md` | `module/packaging/build-avf-deb.sh` | `./module/packaging/test.sh` |
| iOS / watchOS | `iOS/README.md` | `iOS/AirSIM.xcodeproj`、`iOS/AirSIM/` | `xcodebuild ... build-for-testing` |
| Cloudflare Relay | `push-relay-worker/README.md` | `push-relay-worker/src/index.mjs` | `(cd push-relay-worker && npm test && npm run check)` |
| 协议 | `docs/` | VoWLAN 与三星热点配对文档 | 对照双方实现与测试 |

修改跨组件协议时，必须同时搜索所有生产者、消费者、模型、持久化字段、测试和文档。不要只修改一端。

## 3. 不可破坏的架构契约

1. Android 端面向三星 Android 与系统电话能力，紧急呼叫交回系统电话 App。
2. AVF Linux 只发布一个 `airsim-avf-agent_<version>-<release>_arm64.deb`；硬件差异由 Android App 的能力探测与适配层处理。
3. 主 Agent 不自更新。Android App 调用独立 `airsim-installerd` 完成检查、安装、修复和回滚。
4. Installer 只接受包名 `airsim-avf-agent`、架构 `arm64` 且 Ed25519 签名有效的 Debian 包，不能执行任意 shell。
5. AVF 控制和 PCM 服务只监听内部私网或 loopback，不得暴露到通用 Wi-Fi、热点、蜂窝或公网接口。
6. VoWLAN 控制面必须执行路由白名单、时间戳、nonce、HMAC 和消息大小校验。
7. 通话建立时确定 VoWLAN 或 Relay 传输；本次通话结束前不得静默切换路径。
8. PCM 只在内存与网络中处理，不保存到磁盘或诊断日志。
9. iOS 主 Bundle ID 为 `com.eric3u.airsim2`，Watch、Live Activity 和测试 Target 使用对应后缀。部署者必须使用自己的 Apple Team、唯一 Bundle ID、证书和 provisioning profile。
10. Relay 的 `ALLOWED_BUNDLE_ID` 必须等于重新签名后的主 iOS App Bundle ID。
11. AirSIM 与 DJOneHub 必须使用不同 hostname、Worker、KV、Durable Objects 和 Dashboard token。维护者 AirSIM hostname 是 `airsim-push.remotepilot.site`；`push.remotepilot.site` 属于 DJOneHub，不得由 AirSIM 接管。

## 4. 安全与 Secret 规则

以下内容绝不能提交、输出到日志或写入示例配置的明文值：

- Apple APNs `.p8` 私钥与 `APNS_P8`
- `DASHBOARD_TOKEN`
- Cloudflare API token
- Agent bearer token、设备 Secret、配对密钥与 HMAC
- AVF Debian 发布私钥
- Android keystore、Apple 签名身份和 provisioning profile
- 真实号码、完整短信、Push token 与 PCM 数据

Relay 的 `APNS_P8` 和 `DASHBOARD_TOKEN` 是必需的 Cloudflare Worker Secret。`wrangler.example.toml` 只能声明名称；生产值使用 `wrangler secret put`、versions secret 流程或 CI Secret Store 提供。不要把 Secret 放入 `[vars]`。

任何部署操作前都要检查：

```sh
git status --short
git diff --check
git grep -nE 'BEGIN (EC |)PRIVATE KEY|APNS_P8[[:space:]]*=|DASHBOARD_TOKEN[[:space:]]*=' -- ':!push-relay-worker/README.md' ':!push-relay-worker/wrangler.example.toml'
```

示例命令中的占位文本不等于真实 Secret；如果扫描命中，必须逐项判断且不得在回复中回显敏感值。

## 5. 推荐工作顺序

1. 阅读根 README、目标组件 README、源码和现有测试。
2. 检查 `git status --short`，保留用户已有改动；不得重置、覆盖或清理无关文件。
3. 用 `rg` 定位协议字段、环境变量、Bundle ID、端口和所有消费者。
4. 先修改最小必要范围，再同步测试与文档。
5. 先运行目标组件验证，再按跨组件影响扩大验证范围。
6. 涉及安装流程、端口、版本或恢复方式时，同步更新相关组件 README、`docs/AVF_INSTALL_GUIDE.md`、`LLM.txt`、`codex.md` 与 `claude.md`；不要只改 App 文案或脚本一端。
7. 部署前做 Secret、占位符、Bundle ID、Cloudflare 资源和目标环境检查。
8. 最终报告列出已改文件、验证结果、未执行的真机/生产步骤和剩余风险。

未经用户明确要求，不执行 Cloudflare 生产部署、Apple 发布、GitHub Release、真实设备安装、远程推送或 Git push。即使用户要求部署，也必须使用其明确指定的账户、设备、域名和签名身份，不得猜测。

## 6. 构建与验证

### Android

```sh
./android/phone-control-app/test.sh
./android/phone-audio-bridge/build.sh
./android/phone-control-app/build.sh
sh ./android/phone-control-app/verify-apk.sh
```

APK 路径以组件 README 和构建脚本输出为准。真实通话验收还需检查默认电话角色、Shizuku、AVF 私网、拨号、接听、挂断、短信、双向音频和重启恢复。

### AVF Agent、Installer 与 Debian 包

```sh
(cd module/module-agent && go test ./...)
(cd module/avf-installerd && go test ./...)
./module/packaging/test.sh
```

正式构建需要仓库外的 Ed25519 私钥与对应公钥。无私钥构建只能视为开发产物，不能声称通过生产 installerd 验签。

v0.4.5 启用新的发行公钥；旧 v0.4.4 私钥未留存。已安装 `0.4.4-1` 的设备不能通过旧 installerd 直接升级，须按 `docs/AVF_INSTALL_GUIDE.md` 在 AVF Terminal 执行一次性 `rotate-avf-key.sh`，验签、保留旧包并做健康检查。新私钥仅在仓库外保存，并备份为 GitHub Actions Secret `AIRSIM_RELEASE_PRIVATE_KEY_PEM`；发布包必须用本地受限私钥或经授权的 CI 签名，不能从 Secret 导出私钥。不得用旧签名配新包或跳过验签。

### iOS / watchOS

```sh
xcodebuild -project iOS/AirSIM.xcodeproj \
  -scheme AirSIM \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing
```

模拟器构建不能验证 PushKit、CallKit 真机生命周期、APNs、Watch 配套安装、蜂窝通话或通话音频。真机安装前必须完成 Bundle ID、Team、capabilities、entitlements 和 provisioning profile 的整套替换。

### Cloudflare Relay

维护者生产事实（截至 2026-10-08）：Worker 名为 `airsim-push-relay`，hostname 为 `https://airsim-push.remotepilot.site`，只允许 `com.eric3u.airsim`。它与 `https://push.remotepilot.site` 上的 DJOneHub Worker 完全隔离，不是供任意重签 Bundle ID 使用的公共 Relay。已验证两边 `/healthz`、AirSIM Dashboard 匿名 `401` 与正确凭据 `200`；AirSIM 环境当前没有设备注册，不能声称真实 APNs、Agent 心跳或云端 PCM 已验收。

```sh
cd push-relay-worker
npm ci
npm test
npm run check
npx wrangler deploy --dry-run --config wrangler.toml
```

`wrangler.toml` 是本地/生产配置并被忽略；从 `wrangler.example.toml` 创建。生产部署前必须确认 KV ID、Durable Object migrations、`ALLOWED_BUNDLE_ID`、APNs Team/Key ID、自定义域名以及两个必需 Secret。

## 7. 部署清单

### 三星 Android 与 AVF

- AirSIM APK 已构建、签名并安装。
- AirSIM 已设为默认电话 App；Shizuku 已运行并授权。
- AVF Linux 已启动，首次安装脚本的来源和签名公钥已核对。
- Android App 保存了正确的 AVF 私网地址和控制 token。
- `airsim-agent` 与 `airsim-installerd` 分别在 8575、8576 通过设备侧检查，并核对 Agent `/api/health` 的 `product=airsim`。已有 DJOneHub 可保留在 7575；旧 AirSIM Release 仍占用 7575，未发布端口迁移版前不得在共存设备执行旧在线安装命令。Agent 健康成功不能替代 installerd、控制令牌和真实通话验收；AVF 网段会动态变化。
- `cannot create runner / VM is not in stopped state` 是 Android Terminal 启动状态问题，不能直接清除 Linux 数据或当作 Debian 安装失败；按 `docs/AVF_INSTALL_GUIDE.md` 无损排障。
- App 的“一键安装”入口仅复制命令，不会在 AVF Debian 内自动执行。若 Agent `8575` 在线而 installerd `8576` 离线，先按指南检查并恢复已有服务；修复版引导脚本能复用保留的 `current.deb`，旧 Release 仍可能拒绝重复安装。不得删除回滚包来绕过检查，未获明确发布授权不得把源码修复称为线上已生效。
- 若 Debian 提示 `udev` / `libudev1` 版本不匹配，先看 `apt-cache policy udev libudev1` 与 `sudo apt-get -s -f install`；AirSIM 包无直接 `libudev1` 依赖。引导脚本应提前 `apt-get check` 并停止，不自动修复系统包、移除组件或降级。
- Agent、installerd 与音频桥健康；外部网络无法访问内部端口。
- 拨号、接听、拒接、挂断、DTMF、短信、双向 PCM 和重启恢复已验证。

### iPhone 与 Apple Watch

- 主 App、Watch App、Live Activity、测试 Target 的 Bundle ID 关系正确。
- Team、证书、provisioning profile、capabilities 和最终签名 entitlement 正确。
- Relay `ALLOWED_BUNDLE_ID` 与主 App 完全一致。
- sandbox 和 production token 未混用。
- VoWLAN 配对、CallKit、PushKit、Watch、Live Activity 和媒体已在真机验证。

### Relay

- 使用部署者自己的 Cloudflare 账户、KV、Durable Objects 和域名。
- AirSIM hostname 不得复用或覆盖 DJOneHub 的 `push.remotepilot.site`；维护者部署使用 `airsim-push.remotepilot.site`。
- `APNS_P8` 与 `DASHBOARD_TOKEN` 仅存在于 Secret Store。
- 测试、语法检查和 dry-run 通过。
- `/healthz`、Dashboard 鉴权、设备注册、Agent 心跳、APNs 和 WebSocket 已验证。
- 发布后使用 `wrangler tail` 观察错误，但日志不显示敏感内容。

## 8. 完成标准

“构建通过”只说明本地编译或测试成功；“部署完成”必须有目标环境的部署结果；“真机可用”必须有实际三星 Android、iPhone/Apple Watch、AVF 和网络链路证据。不能把未执行的步骤写成已完成。

AirSIM v2 ECS 支持分别配置 Sandbox / Production APNs 密钥，按 App 注册环境选择；两者可共用同一业务服务和数据库。开发签名的 `aps-environment=development` 对应 Sandbox，TestFlight / 分发签名对应 Production。重签须保持 App 配置与最终签名环境一致，使用新 Bundle ID 可并列安装并保留旧版数据。见 [APNs 部署配置](service/airsim/deploy/compose/README.md#apns)。

Agent 支持 `airsim-v2-callkit` 服务的 APNs 开启和关闭状态；`airsim-v2-r4.1` 仍要求 APNs 关闭。启用 ECS 推送前须使用支持该能力的 Agent。

Agent 在通话期间每秒发布状态快照，空闲时每五秒发布；App 保留八秒快照有效期。iOS Debug 诊断页支持真机三秒本机音频测试。

模块范围配对完成后持久化当前模块；App 重新启动时从配对配置恢复绑定模块，管理员多模块配置仍使用显式选择。
