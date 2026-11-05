# 云端音频 Engine 与 TestFlight 发布（2026-11-05）

用户明确选择不再等待真机测试，直接部署 Engine 与发布 TestFlight。音频重构已合入并推送 `main`，源提交 `f2bb817ac8cfe73c33c77774b3a157966b3d805d`。此前的离线验证与已知边界见 [重构记录](CLOUD_AUDIO_REBUILD_20261105.md)，本次没有追加功能测试或真实通话验收。

## Engine 已发布

北京时间 23:31:39，通过 alibabacloud-workbench-cli 的 `default` profile 发布到 ECS `i-wz93dhbsy21quebidepg`、`https://airsim.eric3u.cc`，发布名 `audio-red-f2bb817-20261105`。

- EG25 QDC507 与 RM500U 网页 Engine：Agent `2.0.0-dev.audio1`、helper `0.6.1-opus`。
- 正式产物从源提交的干净独立工作区构建，Go 1.24.13、Zig 0.15.2、定点 libopus 1.5.2；两平台 helper 与离线验证产物逐字节一致。
- 归档 SHA-256：`3e10e25c199a71cc0ea2f787d64bac955255cdb85c59411d0b51a6bbccae9e0a`，9,512,229 字节。
- 上传前确认归档目标、发布目录与备份目录均不存在。远端归档校验后，备份旧 Engine，并使用 `renameat2(RENAME_EXCHANGE)` 原子切换目录；源站校验失败会自动换回。
- 源站 HTTPS 与公网 HTTPS 的全部 23 个资源均通过长度及 SHA-256 校验。源站匿名 `/v2/modules` 返回 401；源站和公网 `/healthz`、`/readyz` 正常。
- 只更新两平台的 Agent、helper、manifest，共六个文件。网页安装器、启动器、驱动与许可证保持；control/media/edge/PostgreSQL/cloudflared 的容器 ID、镜像和启动时间均未改变。

业务信令、所有权与 TURN 接口兼容，没有新的云端业务代码需要替换，因此本次云端变更是静态 Engine 发布。

## App 已上传，内部测试待确认

SkySIM `0.9.6 (84)` 已完成 Release 分发构建、导出和签名校验，于 23:38:54 上传成功，无上传警告，Apple 返回正在处理。IPA SHA-256 为 `b2c93cf11dcc50a5543c3bed76729baf600e1322361a35627ba811941d7c9c42`。App Store Connect 网页会话已过期，内部测试分配待登录恢复；当前不能据此宣称 Build 84 已可安装。使用既有用户 Team、Bundle ID `com.eric3u.airsim2` 和 ASC App `6829440499`，继续由既有“构建 Release 并上传 TestFlight”聊天处理。最新结果见 [SkySIM TestFlight](IOS_TESTFLIGHT.md)。

## 生效与回退

用户先在网页更新模块 Engine，再安装对应 SkySIM TestFlight。网页发布不会自动更新模块；本次没有通过 USB 或远程命令安装模块。当前控制、配对、自启动和低空间安装流程沿用已发布的安装器。

| 位置 | 路径 |
| --- | --- |
| 在线 Engine | `/opt/airsim-v2/releases/usb-local-20261030/web/dist/engine` |
| 本次发布与结果 | `/opt/airsim-v2/releases/audio-red-f2bb817-20261105` |
| 旧 Engine 备份 | `/opt/airsim-v2/backups/audio-red-f2bb817-20261105/engine` |
| 原子交换保留的旧目录 | `/opt/airsim-v2/backups/audio-red-f2bb817-20261105/exchanged-engine` |
| 本地正式包 | `/tmp/airsim-audio-red-f2bb817-20261105/engine` |

回退时先核对在线文件仍是本次哈希，再把旧目录与在线目录原子交换并重新验证 HTTPS 和服务健康。网页回退不自动回退已安装的模块；模块 Agent/helper 需成对切换。各文件摘要、容器状态、部署和公网验证时间见 [发布证据](CLOUD_AUDIO_DEPLOYMENT_20261105.json)。

固定冗余增加带宽，时钟偏差仍采用有界重同步。真实蜂窝通话听感、CPU、硬件 DELAY 支持及端到端延迟尚未验收，不把此次成功发布当作真实音质验收。
