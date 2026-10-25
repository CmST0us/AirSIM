# R6 iPhone 15 Pro 真机验收

2026-10-25，主控按 [R6 契约](../protocol/v2/R6.md) 调度。基础版本为 R5 `e1fdcce`，网络仍使用 `airsim-v2-r4.1`。本阶段不重复提示语或回声注入测试。

## M1a：诊断与安装

- 目标：连接中的 iPhone 15 Pro，iOS 26.5.2；用户确认两部手机均在身边。
- 已安装独立验收 App `com.eric3u.airsim.r6`，显示名 AirSIM R6，版本 0.9.6 (79)。`codesign --verify --deep --strict` 通过，嵌入的有效 development profile 包含目标设备。未卸载或替换其他 App。
- 真机 DEBUG 增加实际输入/输出路由分类、输入格式和 VoiceProcessing，显示已有媒体/失败统计；新增发送成功和有效接收 PCM 的有界能量汇总。数据不是录音，也不代表人耳已听到。
- 提示语、回声注入、本机合成音及主动断媒体按钮仍只在 DEBUG simulator 可见；真实通话使用生产麦克风/播放路径。
- 聚焦测试 5 项全部通过，0 失败、0 跳过：路由分类、真实路径能量停止冻结/重置、采集静音、重复停止保留统计、watchdog。执行会话使用 iPhone 17 / iOS 27.0 模拟器及独立 R6 DerivedData；这些纯测试不能代替实体音频验收。
- Device Hub 无法镜像本机 iOS 26.5.2。独立 XCTest UI runner 已签名安装，并实际读取欢迎页、点击云端 v2；UI 驱动不在生产 App 内，不调用业务 API。
- 因源码占位 bundle 无法注册，使用本地独立源码副本和空 entitlement 构建。仓库 bundle、团队、发布 entitlement 不变。本轮不验证推送、系统默认通话/短信 App、Watch 或后台来电能力。

## 待验收

正常配置导入与连接、实际麦克风权限、真人双向内容、静音/扬声器、约 5 分钟持续通话仍未通过，不能由安装和纯测试推断。短期配置仅暂存受限本地目录、ECS 受保护目录和目标 App 的 Documents，结束后撤销并清理本轮副本。
