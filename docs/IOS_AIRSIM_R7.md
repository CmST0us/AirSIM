# R7：原 App 视图接入 v2

2026-10-25，实施依据为 [R7 契约](../protocol/v2/R7.md)。保留原拨号、最近、短信、联系人和设置五标签，接入 ECS v2 的设备状态、通话、消息及 CallKit。通话质量优化留待界面与功能闭环完成后编排。

## 协作与里程碑

- 主控冻结协议、运行时和生命周期方案，审核并按里程碑提交。
- iOS 执行会话负责原视图、模型、系统回调和 Xcode 工程；当前 ECS 服务保持 R4.1。
- [设计审核](IOS_AIRSIM_R7_DESIGN.md)覆盖产品与交互一致性，依据 QA 截图补充视觉验收。
- [QA 记录](IOS_AIRSIM_R7_QA.md)覆盖功能用例、模拟器 UI 自动化和异常路径。测试场景只使用隔离的虚构数据。

M1 为共用原视图；M2 为 CallKit 与通话生命周期；M3 为设计反馈、自动化回归和真实环境验证。

## 签名准备

独立验收 App 沿用 `com.eric3u.airsim.r6`，保留原安装数据。已取得该 Explicit App ID 的 development provisioning profile，包含目标 iPhone 15 Pro 和 `aps-environment=development`。仓库仍使用部署者自行配置的占位 Bundle ID，不提交个人 profile 或签名密钥。

CallKit 验收使用部署者签名的真机 App；APNs provider 密钥不属于本阶段前置条件。v2 空闲后台与冷启动来电唤醒不在本阶段范围。

## 验收状态

M1 原视图适配已实现并通过 `build-for-testing`：所有版本进入原五标签，v2 配置及模块选择纳入原设置，通话与短信动作通过原 AppModel 接入 v2。回复失败保留正文，清理失败保留历史，已清理的本机消息不会立即被同一轮询重新显示。新增 UI target、隔离场景及三项模型回归测试。首轮 9 项 UI 自动化通过；三项模型测试中两项通过，一项切换状态断言正在定位。

可选服务端推送预备实现已提交 `411bf38`，数据库迁移、去重、授权、HTTP/2/JWT 与竞态测试通过，见 [服务端记录](../service/airsim/R7_TESTING.md)。生产保持 R4.1，推送扩展未启用。

CallKit 真机系统动作与已有通话进入后台尚未验收，不复用前台通话或回声测试结论。
