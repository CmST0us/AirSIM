# main 提交与端到端部署（2026-11-02）

代码提交 `f49b425f6d7bed4b48e591a8f2857308daade45a` 已推送到 `origin/main`（`CmST0us/AirSIM`）。包含 EG25 网页首次安装/更新与自启动、6 位短号及 PDU 编码、短信满仓回收、只读诊断、SkySIM 命名/发布及短信发送交互的完整修复链。发布名称为 `main-f49b425-20261102`。

## 构建与发布

从上述提交的独立、干净工作区构建 Go 1.24.13 Linux AMD64 云端二进制、ARMv7 EG25 和 ARM64 RM500 Agent，以及网页生产包。驱动、音频 helper、启动器、许可证和平台资源逐项与前次验收包核对，保持一致。发布清单将源提交和产物 SHA-256 关联；不以可执行文件中的 dev 版本文字判断是否更新。

Agent 与 ECS 全量 Go race 测试和 vet 通过，网页 60 项测试、TypeScript 与生产构建通过。需要独立数据库夹具的 Go 测试未据此宣称完成生产集成验收；实际生产检查见下文。

使用 `alibabacloud-workbench-cli` 的 `default` profile 部署到指定 ECS `i-wz93dhbsy21quebidepg` / `airsim.eric3u.cc`：

- 22:20，网页 26 个文件在源站经 HTTPS 校验；公网入口、JS 和两个 Agent/manifest 再次核对。EG25 与 RM500 网页包均更新到本次 main 构建。
- 22:21，确认数据库 schema 6、无通话占用及待执行命令后，仅重建 control。新镜像标签含源提交，运行二进制哈希与本机构建一致；healthz/readyz 正常，匿名模块接口 401。
- media、edge、PostgreSQL 保持原容器；数据库无迁移，APNs 环境、密钥挂载、Bundle ID、UID、权限与只读设置不变。
- `/opt/airsim-v2/current` 指向 `/opt/airsim-v2/releases/main-f49b425-20261102/service`。网页仍使用 edge 现有挂载目录，并原子替换内容。
- 备份为 `/opt/airsim-v2/backups/main-f49b425-20261102`，含静态文件及受限权限的 control 配置、数据库备份；不会输出或提交备份内容。控制切换失败会恢复原镜像、配置和 current 链接。

| 产物 | SHA-256 |
| --- | --- |
| control 镜像 | `115edb7852e0b7c66ee6b69e117cc4e10e1910a888dcd5c3d037182a1197e837` |
| control 运行二进制 | `99c8e0a99efe73092f1ab6ac25739556894775cdd177f4f10b37abc0056788e4` |
| EG25 Engine | `e7fe5f6f8e0c176fd8a4f321ff28aeb07991c4e344a8c17c913b47b6ee6756d9` |
| RM500 网页 Engine | `0387ef8ba72cc32650dd30efafd38f58194895e6e7dd6214ca3cf2c59e2b9632` |

## EG25 实机与断电验收

通过当前 USB 安装相同的 main 构建，设备固件仍为 `QDC507GLEFM21_02.004.03`。安装前后身份/配置文件摘要一致，无活动通话，保留 `acaaade7337fc2db` 回滚；安装后剩余 604 KiB，满足 512 KiB 空间保护。

用户将 USB 断电至少 10 秒后重接并发送测试短信。随后只读取状态，未手动启动 Agent：

- 内核 boot ID 改变，唯一 Agent 进程自行启动，其 `/proc/.../exe` 哈希匹配上述 EG25 包。
- 唯一 init 项仍为 `asm:12345:respawn:/usrdata/airsim-v2/run-agent.sh`；启动器哈希仍为 `05c2d0eea116f9460a4e118160e495394d118e2b5136413ea549dd693bd290f8`。
- 启动时等待内核随机源，日志记录超过 60 秒等待，之后自动 ready 并连接云端。等待期 socket 尚不可用不代表安装失败；没有绕过随机源等待。
- 22:27，模块和云端均收到 2 条新 incoming，最新时间一致为 22:27:10，未记录号码或正文。云端诊断临时客户端在读取后正常撤销并删除凭据。
- 22:27:15 再次满仓后自动回收 6 个槽位；最后 CPMS 为 ME 17/23，CNMI 保持 `2,1,0,0,0`，轮询及回收错误为空。

本轮重新完成最终 main 构建的物理断电自启和模块→云端新短信验收。较早的相同功能修复已由用户确认 SkySIM 显示测试短信；本轮不额外宣称通话、音频、后台 APNs 或 RM500 实机已验收。21:30 的历史自主重启原因仍不明确，见 [收件调查](EG25_SMS_RECEIVE_INVESTIGATION.md)。

## App 对应关系

SkySIM `0.9.6 (82)` 的发布源码清单与 main 比对：244 个 iOS 文件中 243 个相同，唯一差异是 README；代码、工程配置和依赖锁文件一致，因此本轮保留已经发布的 Build 82，无需重复上传相同 App。22:29 App 发布会话已恢复 Apple 登录并确认 Build 82 仍可供现有内部测试员更新，Apple 同时显示用户的 iPhone Duo 已安装此版本。群组曾暂时空白，随后恢复正常，未删除或重新分配构建。核对结果见 [TestFlight 对应证据](IOS_TESTFLIGHT_MAIN_VERIFICATION_20261102.json) 与 [发布说明](IOS_TESTFLIGHT.md)。

机器可读的云端、二进制、USB 安装和断电收件证据见 [部署 JSON](MAIN_DEPLOYMENT_20261102.json)。
