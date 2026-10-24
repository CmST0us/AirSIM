# R5：iOS AirSIM 接入 ECS v2

2026-10-24 用户启动，并指定先用模拟器。主控冻结技术方案，现有【执行】iOS AirSIM App 更新执行使用 GPT-6-Astra / medium 落地；主控保留云环境、RM500和真实通话操作权。执行边界与里程碑见 [R5契约](../protocol/v2/R5.md)。

R4已在当前RM500配置完成ECS Docker Compose、云端呼叫/SMS/75秒音频及故障恢复，最终提交10fd021。API/媒体为airsim.eric3u.cc；新App使用公开HTTPS和独立WSS，不访问Agent的本机Unix接口或mTLS设备控制入口。

现有iOS App以三星VoWLAN/v1 Relay为主，AppModel初始化及通知代理冷启动即有Watch/PushKit/CallKit副作用，stop未完全关闭所有任务。不能只加一个版本开关就声称隔离完成。M1先实现独立v2配置/协议/命令/ASMP基础；M2由主控冻结完整旧运行时停用和迟到事件策略后启动。

模拟器选择iPhone 17 Pro / iOS 26.5（E9D74168-796E-4675-9038-DCAF84F0BE87），独立DerivedData为/tmp/airsim-r5-deriveddata。实体iPhone/iPad已发现，但按用户最新选择暂不安装、不启动实机App。项目签名占位和用户本机开发身份保持在本机，不写私钥或凭据进仓库。

本轮前台实验能力与后台发布能力分开：服务当前无v2 APNs/正式登录，使用管理员短期连接配置；v2界面必须如实说明。模拟器音频联调不能冒充实体iPhone音频、锁屏/冷启动来电、Watch或长稳验收。当前未完成任何R5验收。
