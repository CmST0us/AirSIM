# 统一单二进制实时 Rust Engine 与 SkySIM Build 89 发布（2026-11-23）

用户明确要求采用方案 B（统一单二进制零 GC 实时 Rust 模块引擎）一步到位优化通话上下行音质并全部发布部署。

## 1. 模块 Engine 发布（`rust-engine-20261123-rs2`，`2.0.0-rs.2`）

北京时间 22:17，将 Rust Engine TLS 后端从试验版 `rustls-rustcrypto 0.0.2-alpha` 升级为 `rustls 0.23.46` 官方默认生产后端 `aws-lc-rs`（启用标准 TLS 1.3 `X25519MLKEM768`，与 Go 1.24 / iOS / Caddy 对齐），并通过 `alibabacloud-workbench-cli` 的 `default` profile 原子发布到 ECS `i-wz93dhbsy21quebidepg`（`https://airsim.eric3u.cc`），发布目录 `/opt/airsim-v2/releases/rust-engine-20261123-rs2`。

- 源码目录：`module/airsim-engine-rs/`（单进程静态 musl 可执行文件，合并原 Go `airsim-agent` 与 C `airsim-audiod`；零 GC、`SCHED_FIFO` 优先级 10 三线程隔离、无锁 SPSC 环 + `eventfd`、定点 `libopus 1.5.2` 64 kbps VBR 宽带 + 5% LBRR FEC、`str0m` 原生 RED depth=2、纯 Rust RFC 5766/8656 UDP+TCP TURN、16 kHz 基音同步 WSOLA 耦合 ALSA `pcm_get_delay()` 闭环反馈、EG25 QDSP6 `-3.01 dB` / C¹ 软膝限幅）。
- 归档 `rust-engine-20261123-rs2.tar.gz`：`5,187,415` 字节，SHA-256 `b6bbbc374ecdb3d5b823ddaddbfa215e85753e14a46e9c754760ed7c3a4b86d9`。
- 通过 Linux `renameat2(RENAME_EXCHANGE)` 原子切换至 `/opt/airsim-v2/releases/usb-local-20261030/web/dist/engine`，备份保留于 `/opt/airsim-v2/backups/rust-engine-20261123-rs2/`（原 Go 版备份保留于 `/opt/airsim-v2/backups/rust-engine-20261123/`）。
- 源站 HTTPS（`--resolve airsim.eric3u.cc:443:127.0.0.1`）共 23 个资源全部通过字节长度与 SHA-256 校验；`/healthz` 返回 `{"alive":true}`、`/readyz` 返回 `{"ready":true}`、匿名 `/v2/modules` 返回 `401`。`control`、`postgres`、`media`、`edge`、`cloudflared` 五个容器均未重启或替换。

| 平台与文件 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `eg25-qdc507/manifest.json` | 2,230 | `2c086884b2275297f9ada6fb9c06c70e16ea35f4b67e2bdaac1f2ffa9d1fe8ed` |
| `eg25-qdc507/airsim-agent` | 4,713,316 | `8c103c3dcfb93b5e7fff1983967fd0bb0cb499d4e7123bab54039a3da452622e` |
| `eg25-qdc507/airsim-audiod`（兼容垫片） | 769 | `2db528f48b1d969ef1e3e148f1728f5160302384d7494870a74afe8607e925ff` |
| `rm500u-embedded/manifest.json` | 1,168 | `66fe2a3d5f4496def8608de8214bbdbd435dc56b41d48a72b2cf039b84831360` |
| `rm500u-embedded/airsim-agent` | 4,858,664 | `a1015e943a15d443d88b01e4d9b9d24fef0d09c86d2d8d5c5f02dabccf36d7de` |
| `rm500u-embedded/airsim-audiod`（兼容垫片） | 769 | `2db528f48b1d969ef1e3e148f1728f5160302384d7494870a74afe8607e925ff` |

## 2. 本机 EG25 QDC507 真机部署与实测结果

已在当前 USB 连接的 EG25（`ee04e0e9-9eba-4068-a60e-f7730e444faf`，Linux `3.18.44`）上安装与线上完全同哈希的 `2.0.0-rs.2`（`/usrdata/airsim-v2/releases/8c103c3dcfb93b5e/airsim-agent` 及兼容垫片 `audio-2db528f48b1d969e`）：

- **云端连通性实机验收通过**：升级至 `rustls` 官方默认 `aws-lc-rs`（`X25519MLKEM768`）后，EG25 通过移动 4G 完成 HTTPS Discovery（`/.well-known/airsim`）、Let's Encrypt `YE2` 四级证书链校验、Ed25519 客户端证书 mTLS 握手与 `wss://device.airsim.eric3u.cc/v2/device/control` 控制连接；模块 `/v2/local/cloud` 为 `connected=true`，ECS `airsim-v2-control-1` 实时记录 `device_connected`。
- **内存与存储实测**：在线建连后稳态 `VmRSS` 从原 Go 版 `8,244 KiB` 降至 **`2,936 KiB`（2.87 MB，-64.4%）**，`VmSize` 从 `543,332 KiB` 降至 **`9,836 KiB`（-98.2%）**，二进制体积由 Go+C `12.1 MB` 降至 **`4.5 MB`（-62.8%）**，保留旧 Go 回滚包后 `/usrdata` 仍余 `4.0 MiB`。
- **本机控制面实测**：`SIGTERM` 优雅退出并由 BusyBox init 拉起通过；`/healthz` 返回 `2.0.0-rs.2`；`/v2/local/control` 返回 `ready=true`、`telephony_ready=true`、`messaging_ready=true`；既有 22 条 PDU / 14 条短信零重复解码；USB 本地 HTTPS 监听 `192.168.225.1:8577`。

## 2.5 首通真机通话遥测与 `2.0.0-rs.3` 上行连贯性优化（22:38）

在 `2.0.0-rs.2` 上完成首通 136 秒真实蜂窝通话（会话 `66c9123e-5325-4cff-bfe1-5c9d10bbfc8b`）：

- **实测听感**：SkySIM 端下行声音清晰（`packets_sent=6807`、`local_stalls=0`、`send_stalls=0`、`capture_xruns=0`、`gc_cycles=0`、`heap_live_kb=4304`）；对端（非 SkySIM 端）听到的上行声音偶有断续。
- **遥测定位**：实测 `/v2/local/cloud/media-stats` 显示 EG25 在 VoLTE 通话期间 QCI=9 数据承载存在 `rtp_stalls=138`（最大 `639 ms`）的 4G 突发到达，同时暴露出旧抖动缓冲的 4 个问题：`playout_resyncs=23`（`start_of_talkspurt` 误触发清空缓冲并写入 220 ms 静音）、`wsola_accelerated=585`（`alsa_delay_ms >= 56` 在缓冲偏低时仍强制加速抽干缓冲）、`packets_late=127`（空缓冲 PLC 期间推进 `play_slot` 丢弃晚到帧）、`plc_frames=846`（220 ms 上限不足且 `PreemptiveExpand` 因 `alsa_delay <= 28` 极少触发）。
- **`2.0.0-rs.3` 修复与发布**（`rust-engine-20261123-rs3`，21/21 测试通过含 640 ms QCI=9 突发回放测试零重同步/零晚到丢帧）：
  - 抖动缓冲扩至 128 槽（2.56 s），蜂窝目标 `100–440 ms`（起播 140 ms）并放慢峰值衰减（每 8 帧 -1 ms）；仅 >1.92 s 真断层才重同步。
  - 采用 NetEq 空缓冲驻留策略：空缓冲等待 4G 突发时 `play_slot` 驻留不前冲，晚到语音帧零丢弃且保留 LBRR FEC 恢复机会。
  - WSOLA 改由纯抖动缓冲滞回区间驱动（`<= target/2` 提前扩帧、`>= target+3` 才温和加速），不再受正常 EG25 32–56 ms ALSA DMA 延迟误触发；同时放大 TURN UDP `SO_RCVBUF` 至 256 KiB。
  - 已通过 Workbench 原子发布至 `airsim.eric3u.cc`（源站 HTTPS 23 项资源哈希校验通过：EG25 `4,713,188 B` SHA-256 `e142c59ab0f0ce52801170750d2c50ab9dccf07d422bce94c06d53627751e291`；RM500U `4,858,664 B` SHA-256 `b9e67dca25cb5263392eda60e8f0d83bc55031d4e9d88ca6e856a2dd3f43730b`）并同步安装至本机 EG25，待再次实拨验收对端上行听感。

## 3. SkySIM `0.9.6 (89)` TestFlight 上传

- 基于包含 `iOS/AirSIM/CloudV2/V2WebRTC.swift` 蜂窝 NetEq（99% 分位延迟目标、慢遗忘因子、禁用激进加速、`48 kHz / 20 ms` `AVAudioSession`）优化的源码构建 `0.9.6 (89)`，继续使用 `com.eric3u.airsim2` / Team `2VQ94C2355` / ASC `6829440499`。
- 已补入 UUID 完全匹配的 WebRTC 155.0.0 iOS arm64 dSYM（`4C4C44F0-5555-3144-A190-21F9C2A35CDA`）；三项 Target 严格签名、`aps-environment=production`、`get-task-allow=false`、隐私清单及 `NSCameraUsageDescription` 均校验通过。
- 分发 IPA SHA-256：`6fc2714d863d44ec949ed0fa3e686cd54ccfd9b37a49f11153ce8e36a436000c`。
- 北京时间 21:40:36，`xcodebuild -exportArchive`（`destination=upload`）返回 `Uploaded package is processing`、`Upload succeeded` 与 `** EXPORT SUCCEEDED **`。Apple 端处理完成状态及 TestFlight 内部测试群组分配待在 App Store Connect 确认。
