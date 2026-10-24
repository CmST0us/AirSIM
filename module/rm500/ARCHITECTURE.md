# RM500 airsim-agent 架构入口

统一架构已扩展为 RM500、EG25（模块内部 Linux）与 Android AVF 三个正式目标，详见 [多平台 Agent 架构](../ARCHITECTURE.md)。

新 Agent 在 [`module/airsim-agent/`](../airsim-agent/README.md) 独立建设，旧 `module/module-agent/` 保留。RM500 CLI 是独立工具，不属于新 Agent 架构。已有 [实机诊断记录](cli/TESTING.md) 仅作为设备能力证据；Agent 的实现与验收计划尚未完成。
