# 96 kbps 网页 Engine 发布（2026-11-04）

源提交 `7f5e8d94170eb59c3834aa613fa3362ed443b0c9` 已推送到 `origin/main`（`CmST0us/AirSIM`）。发布名称为 `opus96-7f5e8d9-20261104`。北京时间 00:31:55，通过 alibabacloud-workbench-cli 的 `default` profile 发布到 ECS `i-wz93dhbsy21quebidepg` / `airsim.eric3u.cc`。

## 变更与生效范围

模块采集编码与 SDP 中请求 App 发送的 Opus 目标码率由 32 kbps 提高到 96 kbps VBR。16 kHz 单声道、20 ms 帧长、复杂度 3、FEC、PLC 和 DTX 设置保持。VBR 的实际输出随内容变化，96 kbps 为目标，不是恒定吞吐或无损保证。

网页提供 EG25 QDC507 与 RM500U 两个平台的新 Agent 和 helper；模块须通过网页安装器更新 Engine 后生效。本轮未通过 USB 或远程命令安装到模块，也未执行真实通话。现有 SkySIM 82 可以协商，无需为本次参数调整重新上传 TestFlight。

## 构建与检查

- 从源提交的独立、干净工作区构建，Go 固定 1.24.13，原生 helper 使用 Zig 0.15.2、定点 libopus 1.5.2；两平台重新构建的 helper 与此前通过测试的二进制逐字节相同。
- Agent race 测试、helper ASan／UBSan 编解码与 FEC 测试，以及未修改 App 源码和 WebRTC 155.0.0 的模拟器实际协商已通过，详见 [WebRTC 音频](WEBRTC_AUDIO.md#验证)。模拟器音频设备保持关闭，不据此声称实发码率、真机 CPU 或听感已验收。
- 上传包 SHA-256 为 `ba36403ccebae40474d14389b497756429e913b8f8c42bfeea05c814bd20157f`；本地清单、远端上传包、源站 HTTPS 与公网 HTTPS 的全部 23 个 Engine 文件均核对长度和 SHA-256。
- 发布前 Secret 扫描的 5 处匹配均为旧文档描述、布尔配置、源码类型检查或 PEM 头处理正则，无明文密钥。macOS Git 的 ERE 不接受原扫描表达式中的空分支，使用等价 `(EC )?` 完成检查。

| 产物 | SHA-256 |
| --- | --- |
| eg25-qdc507 Agent | `b40638aa0c96b62dc9330429f7070252acd3477a31e8f7829de03ebd6e3a8484` |
| eg25-qdc507 helper | `0edce3cfb8d874badf1e2443b044c19ebd890fcfae5f86ef6e53d29eb38e4243` |
| rm500u-embedded Agent | `a10c8da6f2ac92347712273dcdd7c71660cb7ea2d31605872857ce8cc610d281` |
| rm500u-embedded helper | `aac0d1968d6c92b3845ab38326006f8d5f8ad767b85ff2e5d6b893b3e8dc9b6d` |

## 发布与回滚

使用 Workbench 上传独立归档，目标文件与发布目录事先确认不存在。先保存当前 Engine 目录，再将新目录与现有 `engine` 通过 Linux `renameat2(RENAME_EXCHANGE)` 原子交换；部署脚本在源站校验失败时自动换回旧目录。

- 静态网页挂载：`/opt/airsim-v2/releases/usb-local-20261030/web/dist`。
- 发布与远端校验记录：`/opt/airsim-v2/releases/opus96-7f5e8d9-20261104`。
- 回滚备份：`/opt/airsim-v2/backups/opus96-7f5e8d9-20261104`，其中 `engine` 为校验后的备份副本，`exchanged-engine` 为原子交换留下的原目录。
- 实际变化只有两平台的 `airsim-agent`、`airsim-audiod`、`manifest.json`，共 6 个文件。启动器、驱动、许可证、HTML、JS 与 CSS 不变。
- control、media、edge、PostgreSQL 和 cloudflared 的容器 ID、镜像与启动时间均保持；没有业务容器重启、数据库迁移、APNs 或域名配置变化。
- 发布后源站与公网 `/healthz`、`/readyz` 正常；源站匿名 `/v2/modules` 返回 401。

如需回退本次网页发布，先核对当前文件仍为本次哈希，再通过 Workbench 将备份目录与当前 `engine` 原子交换，重复下载与健康检查。网页回退不会自动回退已经更新的模块；模块 Agent 与 helper 必须成对回滚。

机器可读证据见 [OPUS96_WEB_ENGINE_DEPLOYMENT_20261104.json](OPUS96_WEB_ENGINE_DEPLOYMENT_20261104.json)。96 kbps 的真实通话听感、丢包表现、资源占用和长时间稳定性仍待验收。
