# R4：airsim-agent 接入 ECS v2 / Docker Compose

2026-10-24 主控启动。用户授权实现、部署并完成云端通话、短信、双向音频闭环。技术决策由主控维护，执行会话 GPT-6-Astra / medium 仅执行。

## 冻结边界与分工

- 公共协议以 [R4 契约](../protocol/v2/R4.md) 为准。主控维护 protocol/ 与本文件；协议缺项先回报主控。
- Agent 执行会话只改 `module/airsim-agent/`，接入设备持有证明、受控激活、mTLS 控制WSS、定向命令/收据/状态/短信和R3媒体桥。C helper及R3有效硬件参数不变。先fake/TLS集成、race/vet及静态ARM64构建，未经主控调度不接触实机。
- ECS 执行会话只改 `service/airsim/`，实现两个Go进程、PostgreSQL适配、迁移/admin一次性工具、Compose/Caddy、隔离测试与部署脚本。与Agent仅通过公共协议联调，不导入对方internal包。主控独占云环境变更与设备实测；执行会话可运行本机隔离Docker项目，不能操作无关容器。
- Worker/iOS会话暂不启动；本阶段测试客户端使用HTTPS+独立媒体WSS，运行于主控电脑，只通过ECS调用模块。ADB仅用于部署、设备身份引导及状态核对，不能替代公网业务链路。

## 部署裁决

- Compose常驻 `edge`、`control`、`media`、`postgres`，一次性 `migrate`/`admin`。不添加Redis/MQTT/K8S。control/media为CGO=0静态Go镜像；read_only、非root、cap_drop ALL、no-new-privileges、有限tmpfs/pids/memory。postgres独立持久卷，只有必要服务可访问。
- Caddy固定官方2.11.7；PostgreSQL官方17-alpine分支在准备时解析实际patch与镜像digest，写入lock文件并以digest运行，不保留浮动tag。Go构建固定1.24.13并记录builder digest；若实际仓库缺版本或不兼容，回报主控。运行镜像使用scratch（嵌入/只读挂载所需CA），不在运行期拉工具。
- 本地集成使用独立 `airsim-r4-test` project name、随机/显式loopback高端口、测试CA，证书严格校验；不把本机CA安装到系统信任、不触碰其他Docker项目。
- Secrets全部文件注入，源码只占位；CA签发私钥只挂admin，数据库密码只挂postgres/control/migrate/admin，edge-token仅edge/control，media内部token仅control/media，客户端token不进Compose环境日志。禁止运行期打印完整env/inspect secret/HTTP body。
- Compose healthcheck区分liveness/readiness，postgres healthy→migrate successful→control ready→media/edge ready；迁移使用PG advisory lock及显式版本，失败停止发布。提供backup/restore到隔离库验证脚本；禁止对生产volume执行down -v。
- 首次云部署到新目录、独立project/volumes，保留回滚产物。用户已明确授权暂时停止 iroh-relay（服务名 `iroh-relay.service`）并优先部署 AirSIM；主控已停止并禁用其开机启动，保留原配置，80/443 用于 AirSIM。域名仍待用户配置，不接管旧 v1 域名。
- 官方 Caddy 2.11.7 二进制带 `cap_net_bind_service=ep`。edge 在 `cap_drop: ALL` 基础上仅 `cap_add: NET_BIND_SERVICE`，保留 non-root/read_only/no-new-privileges；control/media 不放宽权限。生产使用标准 80/443，本机测试仍只绑定 loopback 高端口。

## 验收次序

1. 双端实现与契约测试；全Go race/vet、ARM64 Agent及amd64 server构建。
2. 本机完整Compose：真实PostgreSQL、TLS/mTLS、认证、两模块/两客户端不串路由、重复命令、离线拒绝、媒体限额/超时/故障回收、DB备份恢复；不模拟为生产证据。
3. 确认ECS/域名/端口/TLS后部署，记录image digest、schema、health与凭据权限。Agent先独立网络/DNS/时间/TLS检查，保留R3构建/身份/journal，在idle升级。
4. 证书持有证明与云端登记、snapshot/SMS只读同步；然后受控云端拨号/接听/拒接/DTMF/挂断、SMS收发及75秒提示语/有限延迟回声。用户号码只从当前授权会话传入，不写仓库、日志或配置。
5. 控制/媒体断连不重拨、不重发短信；新session恢复、旧票据失效、模块/云端资源回收、身份保持。分别记录实现、本机集成、ECS、真实内容和用户反馈。

30分钟/100会话长稳、8k厂商时钟实机、正式账户/浏览器安装、APNs及iOS/Watch界面不纳入本轮完成声明。

## 目标确认

用户已确认深圳 ECS `i-wz93dhbsy21quebidepg`（worker，120.25.235.237）作为本轮目标，域名稍后配置。只读预检为 Alibaba Cloud Linux 4.0.6 / x86_64，约3.5GiB内存、根分区余9.9GiB。2026-10-24 主控从 Alibaba Cloud Linux 官方仓库安装 Docker/Moby 29.5.1、Compose 2.26.1、containerd 1.7.34，并启用 Docker 服务。创建 `/opt/airsim-v2/{releases,secrets,backups}`（0700）。

按用户后续指令执行 `systemctl disable --now iroh-relay.service`，确认 inactive/disabled 且 TCP80/443 空闲；服务配置不变。需要恢复时，在 AirSIM 释放冲突端口后执行 `systemctl enable --now iroh-relay.service`。ECS 直接拉取固定 Caddy 镜像发生 Docker Hub 连接超时，改为准备本机验证镜像后传送；公网TLS/域名联通及实际容器部署尚待验证，不得宣称ECS业务闭环完成。
