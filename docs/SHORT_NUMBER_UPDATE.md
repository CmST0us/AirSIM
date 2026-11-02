# 6 位短号修复与部署

2026-11-02：App、ECS、Agent 命令校验及 EG25 AT 拨号白名单统一接受 `+?[0-9]{6,15}`。拨号和短信使用同一规则，保留前导零，不补国家码；控制字符、MMI、超长号码继续拒绝。旧组件仍会拒绝 6 位号码，需配套更新。

## 本次发布

后续修复（2026-11-02 14:35）：EG25 短信还存在收件号码类型和 UCS-2 正文编码错误，已发布 `sms-pdu-20261102`，需再次更新模块 Engine；App 81 和 ECS 无需再次发布。下表哈希保留本节 13:26 的历史记录，最新 EG25 包与验收边界见 [短信编码修复](EG25_SMS_FIX.md)。

- 云端：通过 Workbench 发布至深圳 ECS `i-wz93dhbsy21quebidepg`、`airsim.eric3u.cc`，发布目录 `/opt/airsim-v2/releases/shortnumber-20261102`。13:28（北京时间）仅重建 control，媒体、edge、PostgreSQL 容器保持原实例，数据库仍为 schema 6，APNs、挂载、权限配置不变。
- Engine：13:26 发布 EG25 和 RM500 网页包，源站 HTTPS 核对全部 26 个文件，随后从公网下载两个 Agent 再验哈希。页面代码和启动器未变；即使版本文字仍为 `2.0.0-dev.webrtc`，安装器也会根据文件哈希识别更新。
- EG25：用户明确选择自行更新，本轮没有对实体模块安装、重启或实拨。刷新 [安装页](https://airsim.eric3u.cc/)，选择原模块并执行“更新并启用”。2026-11-01 的断电自启证据属于上一版 Agent，不算本版实机验收。
- App：SkySIM `0.9.6 (81)` 已于 13:53 上传，13:57 确认 Apple 处理完成，13:58 加入现有内部测试群组并显示“正在测试”。两个测试账号继续使用原群组，现有用户可在 TestFlight 更新。签名、符号、测试说明和截图见 [TestFlight 记录](IOS_TESTFLIGHT.md)；本轮未代用户安装或实拨。

| 产物 | SHA-256 |
| --- | --- |
| ECS control 运行二进制 | `5ec71b945fd04c8c180847eae9c96c4429dd1d5994508bccec3ba21dad99debd` |
| EG25 Agent | `39a8374a28526a60947421636ee75a323fa9233df00b5ee2fad0d4882fadcfcf` |
| RM500 Agent | `ec67e9e485de26717ba8bfacff7e119882561d62197d62507776fd8dcd38b261` |

## 验证与恢复

Agent 和 ECS 的 `go test -race ./...`、`go vet ./...` 通过；需要独立数据库夹具的集成测试未执行。iOS 模拟器两项回归通过，涵盖 6 位号码、前导零、原有长号码、非法输入及短信 UTF-16 边界。网页生产构建通过。修复前新增测试可复现 ECS、Agent 和 AT 对 6 位号码的拒绝。

上线后公网 `/healthz`、`/readyz` 均为 200，匿名 `/v2/modules` 为 401；四个容器健康，重启计数为 0。运行容器内的 control 二进制与本地已验证产物哈希一致。详细证据见 [部署 JSON](SHORT_NUMBER_DEPLOYMENT_20261102.json)。没有触发真实通话或发送短信。

旧 control 镜像 `sha256:d9d143db25607ecfca4d994ccaa313a491cc72fba52e3e815b13a7092192701b` 保留。回滚材料位于 `/opt/airsim-v2/backups/shortnumber-20261102/control`：原 `deployment.env`、原 current 链接目标、容器配置及受限权限的数据库备份；静态文件备份位于同级 `web/`。确认空闲后可恢复原配置和 current 链接，仅重建 control，再核对健康及 APNs 配置。本次没有数据库迁移，普通代码回滚无需恢复数据库。网页文件按备份原子恢复，入口 HTML 最后替换。备份含敏感配置，不得提交或输出内容。
