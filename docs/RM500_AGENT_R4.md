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
- 首次云部署到新目录、独立project/volumes，保留回滚产物。用户已明确授权暂时停止 iroh-relay（服务名 `iroh-relay.service`）并优先部署 AirSIM；主控已停止并禁用其开机启动，保留原配置，80/443 用于 AirSIM。后续由用户授权使用 eric3u.cc，API/媒体使用 airsim.eric3u.cc，设备 mTLS 使用 device.airsim.eric3u.cc；不接管旧 v1 域名。
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

## 已完成的部署准备里程碑

- `499a60c` 提交 Agent 实现。主控再次运行全量 Go race/vet 与本地引导脚本验证，通过后将 SHA256 `6a63c689ccf961dac9d2b9e7c997f656cf6306be2defb0934ac49aa070981689` 部署到 RM500 独立 release。原 R3 Agent/helper、设备身份和命令 journal 保留，哈希核对不变；本机 control ready、audio available，云端未配置，voice_ready 仍为 false。详见 [部署证据](R4_RM500_DEPLOYMENT.json)。数据分区剩余 1664KiB，不把单次空闲 RSS 样本当云端运行资源结论。
- ECS 已通过本机下载固定官方 amd64 镜像→Workbench传送→校验归档→Docker load→比对全部 rootfs layer identity→运行版本检查，准备 Caddy 2.11.7 与 PostgreSQL 17.11。完整来源、配置、归档与 ECS 实际镜像 ID 见 [ECS准备证据](R4_ECS_PREPARATION.json)。离线生产使用 ECS 实际验证的 `sha256:...` content-addressed image ID 与 `pull_policy: never`；Docker save/load 的 OCI manifest digest 不等于原 registry 压缩 manifest digest，不混称。
- 服务端正在完成最终 Compose/故障验证；公网域名仍待用户给出。主控已准备独立 HTTPS/WSS 验收客户端，但尚未通过云端拨号、发送短信或传输实机音频。

## 公网部署与设备接入里程碑

- `ba30a26` 已提交服务实现与完整本地 Compose 验证。主控在 Cloudflare 添加上述两个 DNS-only A 记录，解析至已授权 ECS；见 [DNS 证据](R4_DNS_DEPLOYMENT.json)。
- 固定 amd64 业务镜像传到 ECS 后校验归档与 rootfs，初始化独立数据库、身份及设备 CA。四个常驻服务均已启动；公开信任证书的 TLS 1.3 / discovery 正常，设备入口拒绝无客户端证书。旧版 curl 的 TLS 握手失败单独记录，未以关闭证书校验绕过。
- RM500 使用原设备私钥生成 CSR/持有证明，ECS 一次性签发 30 天设备证书，原 Agent 原位激活成功，已通过公网 mTLS/WSS 连接，cloud configured/connected 均为 true。设备私钥未导出。业务云端验收尚未执行，不能将登记在线等同通话/短信/音频通过。
- 实际部署发现证书卷初始化第二次递归 chown 会失败。修正为仅处理顶层目录，保留最小 CHOWN/FOWNER，隔离真实卷重复初始化及已有文件不变验证通过；不改变业务镜像。所有一次性 Compose 命令显式关闭 stdin，避免远程 shell 后续命令被消费。

## 实机联调修正：媒体票据时钟偏差

云端 SMS 发送状态为 sent，用户回复的约定测试文本已经公网 API 从当前 RM500 收到（不记录正文/号码）。云端呼出已观察 active，但听音未通过：首通为验收客户端过早将尚未同步的 call 当作结束；修正后发现媒体启动使 Agent control_protocol 断连。字段核对一致，ECS 与 RM500 的秒级时钟差使 Agent 的严格30秒未来上限误拒服务端新签票据。主控决定仅给合理性上限5秒偏差容忍，保持绝对到期/服务端30秒/ownership全部约束。

执行会话已补充单次 now 采样、精确纳秒边界及 startMedia owner 分支回归；cloud 与全量 race、vet 及固定 Go1.24.13 ARM64 构建通过。待主控部署修复并重新完成75秒真实内容测试；此前静音通话不记作音频成功。

## 2026-10-24 公网实测进展（尚未整体验收）

- ECS API/媒体入口 airsim.eric3u.cc、设备 mTLS 入口 device.airsim.eric3u.cc 已部署。受控客户端通过真实公网完成云端拨号并观察 active；重复相同拨号命令返回同 command_id/generation，不产生第二条命令。
- 云端短信发送为 sent，用户回复约定文本已从 RM500 经设备控制 WSS 同步到客户端 API，双向内容闭环已验证；没有把 sent 当作运营商送达报告。
- 8b54dcb 时钟修复构建已部署，原身份、cloud config、journal 哈希不变。保留原 R3 二进制及上一 R4 的经解压哈希核对的 gzip 回滚；详见 [升级证据](R4_RM500_SKEW_FIX_DEPLOYMENT.json)。
- 修复后建立真实云端媒体并传输12.304秒，但接收超时中止：客户端发送615帧、收到144帧，未完成75秒内容验收。目标电话已通过定向本地应急挂断清理，不将其计作云端挂断通过。
- 独立、无电话/无HAL的20秒合成数据流诊断：设备发送999帧、收到1000帧；客户端收到980帧并记录17个序号缺口、最大537ms到达间隔。空闲传输能维持节拍，但存在抖动；需要与通话期间对照，不能据此宣称云端音频稳定。
- ECS control 实际重启后先观察 offline，再在约2.31秒观察新connection_epoch在线；Agent boot/backend不变、journal与服务端4条命令数量不变，无重拨/短信重发。
- 当前所有电话 disconnected、媒体 closed、Agent在线。正等待用户确认可接听45秒诊断电话。未完成项为通话期间链路定位、75秒云端内容反馈、云端入站接听/拒接/DTMF及媒体故障恢复。详见 [实测进展证据](R4_CLOUD_ACCEPTANCE_PROGRESS.json)，包含失败尝试与解释，不将静音/短流测试计为通过。


## 通话期间上行积压定位里程碑

用户确认45秒本地提示语及回声都清楚、连续。同通电话中的独立 WSS 合成流（不经过 Agent 媒体桥）8.064秒仅有54帧到达客户端，而设备收到401帧；本地音频持续正常。下一通先关闭本地媒体，确认 audio state 为 closed，再保持运营商通话进行独立网络测试：约10秒设备 TCP 发送队列由1KB增长至128960字节，客户端仅收到104帧。两轮均已定向挂断，不能记为云端内容验收成功。

挂断后立即用同一版本 probe 复测20秒，设备发送999/收到999帧，客户端收到965帧、31个序号缺口。说明空闲仍有抖动，但通话期间持续上行积压可在没有音频采集的情况下复现。当前证据将问题定位到媒体桥之外的通话期间数据传输，尚不能区分无线网络、运营商策略或固件原因。保持现有协议和有界缓冲，不通过延长超时掩盖问题；主控继续检查低速合成流与 TCP 重传/时延。完整统计见 R4_CLOUD_ACCEPTANCE_PROGRESS.json 的 call_time_isolation。
