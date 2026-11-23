# 统一单二进制实时 Rust Engine 与 SkySIM Build 89 发布（2026-11-23）

用户明确要求采用方案 B（统一单二进制零 GC 实时 Rust 模块引擎）一步到位优化通话上下行音质并全部发布部署。

## 1. 模块 Engine 发布（`rust-engine-20261123`，`2.0.0-rs.1`）

北京时间 21:39，通过 `alibabacloud-workbench-cli` 的 `default` profile 发布到 ECS `i-wz93dhbsy21quebidepg`（`https://airsim.eric3u.cc`），发布目录 `/opt/airsim-v2/releases/rust-engine-20261123`。

- 源码目录：`module/airsim-engine-rs/`（单进程静态 musl 可执行文件，合并原 Go `airsim-agent` 与 C `airsim-audiod`；零 GC、`SCHED_FIFO` 优先级 10 三线程隔离、无锁 SPSC 环 + `eventfd`、定点 `libopus 1.5.2` 64 kbps VBR 宽带 + 5% LBRR FEC、`str0m` 原生 RED depth=2、纯 Rust RFC 5766/8656 UDP+TCP TURN、16 kHz 基音同步 WSOLA 耦合 ALSA `pcm_get_delay()` 闭环反馈、EG25 QDSP6 `-3.01 dB` / C¹ 软膝限幅）。
- 归档 `rust-engine-20261123-final.tar.gz`：`5,434,066` 字节，SHA-256 `9de1324c31c4d2419aa6181abdbae5e37d810c363ffcb75af9f9b7167be7ed31`。
- 发布前核对远端目标、发布与备份目录均不存在；旧 Engine 备份至 `/opt/airsim-v2/backups/rust-engine-20261123/engine`，通过 Linux `renameat2(RENAME_EXCHANGE)` 原子切换至 `/opt/airsim-v2/releases/usb-local-20261030/web/dist/engine`，旧目录保留于 `/opt/airsim-v2/backups/rust-engine-20261123/exchanged-engine`。
- 源站 HTTPS（`--resolve airsim.eric3u.cc:443:127.0.0.1`）共 23 个资源全部通过字节长度与 SHA-256 校验；`/healthz` 返回 `{"alive":true}`、`/readyz` 返回 `{"ready":true}`、匿名 `/v2/modules` 返回 `401`。`control`、`postgres`、`media`、`edge`、`cloudflared` 五个容器均未重启或替换。

| 平台与文件 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `eg25-qdc507/manifest.json` | 2,230 | `9d32e379270db741d3f604ac9378ff1885d9a16989eac5fba9c1581fc6525862` |
| `eg25-qdc507/airsim-agent` | 5,006,660 | `6c3f58f63bd4be7fc887d5e50f0481c7a5021219a6ccb3f5d45b2c40ce5c0a44` |
| `eg25-qdc507/airsim-audiod`（兼容垫片） | 769 | `2db528f48b1d969ef1e3e148f1728f5160302384d7494870a74afe8607e925ff` |
| `rm500u-embedded/manifest.json` | 1,168 | `1deb34217df0e08c1571cebf25eb43afdf7a2f66c1c9e3ab6cd1e6dac319d50f` |
| `rm500u-embedded/airsim-agent` | 5,026,808 | `601beb915b79bbfa6621291f503ebd5a29ccbe84b4a816f56aff28606c5243f0` |
| `rm500u-embedded/airsim-audiod`（兼容垫片） | 769 | `2db528f48b1d969ef1e3e148f1728f5160302384d7494870a74afe8607e925ff` |

## 2. 本机 EG25 QDC507 真机部署与实测边界

已在当前 USB 连接的 EG25（`ee04e0e9-9eba-4068-a60e-f7730e444faf`，Linux `3.18.44`）上安装与线上完全同哈希的 `2.0.0-rs.1`（`/usrdata/airsim-v2/releases/6c3f58f63bd4be7f/airsim-agent` 及兼容垫片 `audio-2db528f48b1d969e`），保留原 Go 版本 `0f7a8abaadda0a55` 作为模块内即时回滚：

- **内存与存储实测**：`VmRSS` 从原 Go 版 `8,244 KiB` 降至 **`1,964 KiB`（-76.2%）**，`VmSize` 从 `543,332 KiB` 降至 **`9,812 KiB`（-98.2%）**，线程数 `5`；系统 `free` 内存由 `1,456 KiB` 增至 `5,356 KiB`（`mem_available_kb` 约 `11.2 MB`）；在同时保留旧 Go 回滚包的情况下 `/usrdata` 仍有 `3.8 MiB` 可用。
- **本机功能实测**：`SIGTERM` 优雅退出并由 BusyBox init 在 4 秒内拉起新进程通过；`/healthz` 返回 `2.0.0-rs.1`；`/v2/local/control` 返回 `ready=true`、`telephony_ready=true`、`messaging_ready=true`（复用原 `commands.json`）；`/v2/local/diagnostics/sms` 正常解码既有 22 条 PDU / 14 条短信且零重复；USB 本地 HTTPS 监听 `192.168.225.1:8577`。
- **公网连通性阻塞说明（外部网络因素）**：21:26 起观测到从本机宽带与 EG25 移动 4G 网络发起带 `*.eric3u.cc` SNI 的 443 端口 TLS ClientHello（即便目标为 `1.1.1.1:443`）均在 ServerHello 前收到即时 TCP RST（`os error 104`），而无 SNI 或使用其他域名 SNI 均可正常抵达 Caddy/对端；因此本次暂未能通过公网完成 EG25 -> ECS 建连与真实蜂窝通话听感验收，需先恢复域名公网连通或通过 USB 本地/可用域名完成真实通话验收。

## 3. SkySIM `0.9.6 (89)` TestFlight 上传

- 基于包含 `iOS/AirSIM/CloudV2/V2WebRTC.swift` 蜂窝 NetEq（99% 分位延迟目标、慢遗忘因子、禁用激进加速、`48 kHz / 20 ms` `AVAudioSession`）优化的源码构建 `0.9.6 (89)`，继续使用 `com.eric3u.airsim2` / Team `2VQ94C2355` / ASC `6829440499`。
- 已补入 UUID 完全匹配的 WebRTC 155.0.0 iOS arm64 dSYM（`4C4C44F0-5555-3144-A190-21F9C2A35CDA`）；三项 Target 严格签名、`aps-environment=production`、`get-task-allow=false`、隐私清单及 `NSCameraUsageDescription` 均校验通过。
- 分发 IPA SHA-256：`6fc2714d863d44ec949ed0fa3e686cd54ccfd9b37a49f11153ce8e36a436000c`。
- 北京时间 21:40:36，`xcodebuild -exportArchive`（`destination=upload`）返回 `Uploaded package is processing`、`Upload succeeded` 与 `** EXPORT SUCCEEDED **`。Apple 端处理完成状态及 TestFlight 内部测试群组分配待在 App Store Connect 确认。
