# AirSIM v2 Cloudflare Worker

状态：2026-10-24 用户确定目录；当前仅有职责说明，尚无 Worker v2 实现或部署配置。

这是 Cloudflare Worker 的独立 v2 服务端实现，旧版继续留在 `push-relay-worker/`。不搬动或覆盖旧版 Worker、生产资源和迁移历史。

## 与 ECS 的关系

- ECS v2 位于 [`service/airsim/`](../airsim/README.md)，优先完成 ECS + Docker Compose 闭环；本实现等待主控单独调度。
- 两个服务端使用同一份 v2 身份、模块、命令、通话、媒体授权和错误语义契约，公共 schema 与跨端测试向量规划放在根目录 `protocol/`。
- App 只选择 v1/v2；v2 通过 Relay 地址、server_id 与 discovery 识别服务和支持能力，不另设“Cloudflare 协议”业务分支。
- 同协议不代表自动共享账户、数据库、设备凭据或实时会话；独立服务之间的迁移必须显式授权，不能复制 secret 或让两个服务同时控制同一模块。

## 平台边界

Worker 的存储、设备连接鉴权、媒体实现和后台任务需要按 Cloudflare 实际能力单独适配与验收。不能假设 ECS 的设备 mTLS 入口或 Go 媒体进程可以原样放入 Worker，也不能把最终一致存储用于要求原子仲裁的模块归属/命令/通话所有权。

具体 Cloudflare 状态组件、设备鉴权方式、媒体承载方式、资源配额及部署配置均待主控冻结；执行会话不得自行决定。不能满足公共 v2 的安全/路由语义时应报告阻塞；能力缺失需明确声明，不能通过弱化鉴权或模糊目标来声称兼容。

完整产品边界见 [系统架构](../../docs/SYSTEM_ARCHITECTURE.md)。当前保持待命。
