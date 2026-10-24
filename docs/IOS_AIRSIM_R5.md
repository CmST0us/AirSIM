# R5：iOS AirSIM 接入 ECS v2

2026-10-24 用户启动，并指定先用模拟器。主控冻结技术方案，现有【执行】iOS AirSIM App 更新执行使用 GPT-6-Astra / medium 落地；主控保留云环境、RM500和真实通话操作权。执行边界与里程碑见 [R5契约](../protocol/v2/R5.md)。

R4已在当前RM500配置完成ECS Docker Compose、云端呼叫/SMS/75秒音频及故障恢复，最终提交10fd021。API/媒体为airsim.eric3u.cc；新App使用公开HTTPS和独立WSS，不访问Agent的本机Unix接口或mTLS设备控制入口。

现有iOS App以三星VoWLAN/v1 Relay为主，AppModel初始化及通知代理冷启动即有Watch/PushKit/CallKit副作用，stop未完全关闭所有任务。不能只加一个版本开关就声称隔离完成。M1先实现独立v2配置/协议/命令/ASMP基础；M2由主控冻结完整旧运行时停用和迟到事件策略后启动。

模拟器选择iPhone 17 Pro / iOS 26.5（E9D74168-796E-4675-9038-DCAF84F0BE87），独立DerivedData为/tmp/airsim-r5-deriveddata。实体iPhone/iPad已发现，但按用户最新选择暂不安装、不启动实机App。项目签名占位和用户本机开发身份保持在本机，不写私钥或凭据进仓库。

本轮前台实验能力与后台发布能力分开：服务当前无v2 APNs/正式登录，使用管理员短期连接配置；v2界面必须如实说明。模拟器音频联调不能冒充实体iPhone音频、锁屏/冷启动来电、Watch或长稳验收。R5分里程碑验收，公网业务闭环仍待M4。

M1已完成：独立配置/Keychain、严格JSON、HTTPS限额与拒绝跳转、单次命令与未知结果恢复、ASMP及固定节拍队列。主控审查修正正则尾随换行漏洞；完整模拟器测试68/68（旧47、新21），Go/Swift的360字节帧向量完全一致。一次测试启动卡在AcquiredPID、未进入用例，仅取消该轮专属进程后串行重跑通过；未影响其他项目。最初64项测试含并行新增代码，不能称为纯旧版基线。当前仍未做App公网业务/音频验收，详见R5_IOS_ACCEPTANCE_PROGRESS.json。

## 模拟器验收顺序（第1项已执行）

1. 检查已有v1安装迁移、v1→v2→v1切换、无配置v2界面与无效配置不回退；新安装无外联由独立状态/注入测试及干净App运行核验。旧版APNs到达不能在模拟器上宣称通过。
2. 主控到实测阶段才签发新的短期client，包装为严格绑定服务的配置文件，通过App文件导入进入Keychain；不预置token或自动选模块。临时配置与观察脚本仅保留在本机受限临时目录。
3. 从App选择RM500，检查新鲜状态与能力、发送一条测试SMS并收取用户回复。观察只记录消息ID/方向/状态，不记录号码或正文。
4. 从App拨号，启动明确标记的模拟器诊断注入，验证75秒App→ECS→RM500提示语及反向语音/回声。真实麦克风和普通扬声器路径另行检查，不用注入内容代替麦克风验收。
5. 用户回拨时由App接听，主动关闭本次媒体连接、观察回收、点击恢复音频生成新会话，最后检查App挂断或进入后台后的定向挂断；另行验证App拒接。每通电话有主控独立的有界超时保护，仅在超时后对同一call/boot/backend进行定向挂断，任何保护动作均使对应App自主挂断项不能判通过。
6. 记录截图与无内容统计，确认无活动通话、媒体/麦克风回收、ECS健康；撤销本轮client并验证401，完成里程碑提交。

当前XcodeBuildMCP构建/测试/截图可用；其AX工具因SimulatorKit路径错误不能工作。CUA通过`com.apple.dt.Devices`（Device Hub）的iPhone 17 Pro窗口可读取并操作模拟器App界面，不修改系统开发工具路径或影响其他项目。

M2已完成：模拟器83/83测试，主控实际验证已有安装v1迁移、v1/v2往返、无效JSON拒绝且不回退、干净安装先选择后启动。首次UI发现ActivityKit取消不返回导致切换卡死；修正为有界只读系统事件源和可结束的业务订阅，最终v2订阅为0。已有v1进程保留2个只读源，纯新装v2全为0，不声称系统observer全部销毁。快照与per-Activity悬挂账本均有界，达到16项时单独提示Live Activity观察需重启。假源24次往返、迟到事件、历史快照清理均覆盖。截图位于docs/evidence/r5。尚未验证实体机APNs、App云端通话/SMS或音频。

M3已完成本地验证：独立WSS、固定20ms音频节拍、真实AVAudioEngine采集/播放、显式恢复与停止屏障；模拟器诊断提示/回声仅在内存中处理。最终98项测试为97通过、0失败、1项硬件XCTest显式跳过，生产提示语生成515帧/10.3秒非静音PCM。iOS26.5的两次真实引擎尝试均在RemoteIO初始化SIGABRT，未取得采集统计，不能归为AEC不支持；没有关闭语音处理或重启全局音频服务。改用独立iOS27.0模拟器后，前台3秒生产引擎探测通过：44.1kHz单声道、VoiceProcessing开启、采集145帧/播放136帧、引擎停止。此证据不代表AEC听感、云端音频或实体iPhone验收。主控开始M4，仍通过App正常导入短期配置和UI完成业务操作。

## M4 模拟器 Keychain 构建修正（2026-10-24）

首次有效配置导入在 Keychain 写入阶段失败。20:54:46.519 的 securityd 日志给出 SecItemUpdate 的 OSStatus=-34018（errSecMissingEntitlement）：Client has neither application-identifier nor keychain-access-groups entitlements。此前 CODE_SIGNING_ALLOWED=NO 的安装包只有 linker-signed ad-hoc 签名；生产存储将该状态转为通用 keychain 错误，未写入配置元数据。

主控批准后，仅通过构建调用改用正常模拟器 ad-hoc 签名；项目 bundle ID、空 DEVELOPMENT_TEAM、实体机设置和 V2TokenStore 安全策略均未修改。XcodeBuildMCP 的 build_sim、test_sim、build_run_sim 使用相同 extraArgs：`["CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_REQUIRED=YES"]`。会话为 AirSIM / Debug，工程 iOS/AirSIM.xcodeproj，DerivedData=/tmp/airsim-r5-deriveddata，目标 F4D9D82D-3467-4210-A30D-C1F5B9FC52E5（AirSIM R5 Audio 27.0）。后续此模拟器构建/测试继续使用这三个参数，不再禁用签名。

构建成功，签名为正常 ad-hoc。注意模拟器的身份位于主可执行文件 `__TEXT,__entitlements`，单独 `codesign -d --entitlements -` 输出空字典不能据此断言身份缺失。Xcode 自动生成 application-identifier；没有手工设置开发团队或扩展 keychain-access-groups，默认应用身份已足够。

新增 testRealKeychainRoundTripWithIsolatedAccount，使用独立随机 account 和内存中生成的测试 token，通过生产 V2KeychainTokenStore 完成 save/read/delete，并确认删除后读取失败。仅定向运行该测试（`-only-testing:AirSIMTests/CloudV2Tests/testRealKeychainRoundTripWithIsolatedAccount -parallel-testing-enabled NO`），结果 1/1 通过；defer 负责异常路径清理。未读取既有 token/config，未将测试 token 输出或落盘。随后以相同签名参数构建、安装、启动 F4D9D82D 模拟器，未操作 App UI、导入配置或触发通话；公网业务仍由主控继续验收。

M4主控正常UI复测：签名修复后，通过文件选择器导入短期配置成功，不再出现Keychain错误；随后自动连接报transport且保持v2。截图：docs/evidence/r5/m4-config-import-network-blocked.jpg。公网入口出现环境阻塞：Mac和RM500带目标域名的TLS ClientHello后均被重置，Mac固定到正确公网IP后仍重现；ECS loopback及私网IP通过同一TLS入口读取discovery均200且身份/profile正确，4个Compose容器健康。Cloudflare两条A记录仍为预期ECS地址、DNS only。只采集TCP SYN/RST头摘要，未记录请求/语音内容。用户确认eric3u.cc尚未备案；域名接入/备案拦截为当前推断，未取得云厂商的拦截记录，不能将其写成已证实根因。阿里云排查参考：https://help.aliyun.com/en/icp-filing/basic-icp-service/support/web-site-suddenly-appeared-for-the-record-to-block-or-hang-and-so-on-and-so-forth 。

另发现RM500系统uptime约14分钟、原Agent未运行；主控校验原R4 Agent/helper SHA256后恢复原启动参数，身份/config不变，新的boot/backend已记录，通话/SMS控制ready，因上述公网问题cloud仍discovery_failed。未增加自启动，未改DNS/TLS认证/防火墙/服务端业务。香港和新加坡区域均未发现现成ECS，已向用户询问后续部署资源方向，未购买或迁移服务器。

本轮未发起App电话或短信，不能声称R5公网闭环通过。收尾无活动通话、媒体idle、无音频会话；App停止；短期client已撤销，通过ECS loopback的有效TLS入口核验401（不冒充公网401）。公网入口恢复后必须重新签发配置，继续App呼出、来电接听/拒接、SMS双向、提示/回声、媒体故障恢复及后台收尾验收。
