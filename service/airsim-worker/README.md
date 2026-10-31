# AirSIM v2 Cloudflare Worker

状态：2026-10-24 用户确定目录；当前仅有职责说明，尚无 Worker v2 实现或部署配置。

这是 Cloudflare Worker 的独立 v2 服务端实现，旧版继续留在 `push-relay-worker/`。不搬动或覆盖旧版 Worker、生产资源和迁移历史。

## 与 ECS 的关系

- ECS v2 位于 [`service/airsim/`](../airsim/README.md)，优先完成 ECS + Docker Compose 闭环；本实现等待主控单独调度。
- 两个服务端使用同一份 v2 身份、模块、命令、通话、媒体授权和错误语义契约，公共 schema 与跨端测试向量规划放在根目录 `protocol/`。
- App 只选择 v1/v2；v2 通过 Relay 地址、server_id 与 discovery 识别服务和支持能力，不另设“Cloudflare 协议”业务分支。
- 同协议不代表自动共享账户、数据库、设备凭据或实时会话；独立服务之间的迁移必须显式授权，不能复制 secret 或让两个服务同时控制同一模块。

模块信号沿用 R4 的可选、可为 null 的 `signal` 契约：snapshot 与 `GET /v2/modules` 每个在线模块均携带相同字段，离线不得展示缓存有效信号；旧 Agent 未携带该字段时仍须接受。Agent 每十秒采样，超过三十秒无有效样本时报告不可用。服务端须校验采样时间、CSQ RSSI 与 dBm 一致性。上线前先更新 App 的可选字段解码，旧严格 v2 客户端可能拒绝新增字段。当前目录仅记录要求，不代表 Worker 已实现或验收。

网络媒体须沿用 R4 固定 LC3-only 契约：20ms包包含两个10ms/40-byte编码帧，ASMP v2总长120 bytes；flags=1为全零payload的整包erasure，服务仅校验和透传。媒体创建必需 `codec:"lc3"`，响应、paired与设备启动消息使用统一七字段format。缺少LC3声明的旧Agent可保留控制连接，但媒体创建拒绝为409 `media_unavailable`。App、Agent与服务须协调升级，不能把旧PCM客户端当作兼容端。

## 平台边界

Worker 的存储、设备连接鉴权、媒体实现和后台任务需要按 Cloudflare 实际能力单独适配与验收。不能假设 ECS 的设备 mTLS 入口或 Go 媒体进程可以原样放入 Worker，也不能把最终一致存储用于要求原子仲裁的模块归属/命令/通话所有权。

具体 Cloudflare 状态组件、设备鉴权方式、媒体承载方式、资源配额及部署配置均待主控冻结；执行会话不得自行决定。不能满足公共 v2 的安全/路由语义时应报告阻塞；能力缺失需明确声明，不能通过弱化鉴权或模糊目标来声称兼容。

完整产品边界见 [系统架构](../../docs/SYSTEM_ARCHITECTURE.md)。当前保持待命。
