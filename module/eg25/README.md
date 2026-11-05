# EG25 QDC507

2026-11-05：云端音频重构已合入 main，通过 Workbench 发布网页 Engine `2.0.0-dev.audio1` / helper `0.6.1-opus`，模块由用户更新；本轮未安装真机。App TestFlight 进度与包摘要见[发布记录](../../docs/CLOUD_AUDIO_DEPLOYMENT_20261105.md)。

2026-11-02 22:28：完整修复链已提交到 main（`f49b425`），并从独立工作区构建 `main-f49b425-20261102`。Workbench 已更新云端 control 和两平台网页 Engine，当前 EG25 已安装；最终包通过断电自启、新短信到达模块/云端及再次满仓自动清理验收。SkySIM 82 与 main 的 App 源码一致。详见 [main 部署](../../docs/MAIN_DEPLOYMENT_20261102.md)。

平台标识 `eg25-qdc507`，适用于本机固件 `EG25G_QDC507 / QDC507GLEFM21_02.004.03`、ARMv7、Linux 3.18.44。AT 自报 `Baiwang QDC507 / QDC507GLEFM21`。新 Agent 位于 [airsim-agent](../airsim-agent/README.md)，持久目录为 `/usrdata/airsim-v2`，运行目录为 `/run/airsim-v2`。

DATA11 是 USB AT 使用的 SMD 通道。启动器移除 USB serial 功能、释放 DATA11，并通过 `airsim_data11` 内核模块提供应用专用字符设备。ADB 和 ECM 保留。`smd7/8/9` 继续由厂商服务持有。

USB 本地 v2 使用 ECM 的 `bridge0=192.168.225.1/24`。启动器在桥地址就绪后提供 DHCP，范围为 `192.168.225.10–30`；已有厂商 DHCP 服务时不接管。DHCP 不提供 DNS，也不下发 IPv4 默认路由，厂商 IPv6 行为保持不变。授权后的控制、短信和媒体访问 `https://192.168.225.1:8577`，使用方式见 [iOS USB 本地接入](../../iOS/README.md#usb-本地通话与短信)。

## 构建

Go 固定使用 1.24.13，`CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7`。进程设置 6 MiB Go 内存软限制；它不等于 RSS 上限。

`kmod/airsim_data11.c` 使用 GPL-2.0-only。内核基线为 [quectel_eg25_kernel 82ed009](https://github.com/the-modem-distro/quectel_eg25_kernel/tree/82ed00908b3e8efc3ff0de27d2b5a7c0524ecd7f)，使用设备 `/proc/config.gz` 准备，运行 `make ARCH=arm ... olddefconfig modules_prepare` 后执行 `kmod/build.sh`。目标 vermagic 为 `3.18.44 preempt mod_unload ARMv7 p2v8`，CONFIG_MODVERSIONS 关闭。

原生 helper：`ZIG=/path/to/zig-0.15.2 sh audio/scripts/build.sh`。共用现有 TinyALSA 与媒体 IPC，增加 EG25 的 AFE 路由、D4 hostless PCM、D5 播放与 D6 采集。DSP 映射缓冲区为 4096 字节；VoLTE 前端、D5 与 D6 均以 16 kHz 打开，单声道 S16_LE、256 帧 × 8 周期。mmap 路径负责硬件周期，外部媒体使用 320 样本的 20 ms 帧。

Opus 版 helper 在原生采集后编码、播放前解码，或用后一包的 FEC 恢复、执行丢帧补偿；Agent 以 WebRTC 与 App 交换 Opus 包，Unix 媒体通道使用 ASMP v3 帧；驱动、路由和硬件周期不变。Agent 与 helper 必须成对更新／回滚，App 与 ECS control／media 同步使用 WebRTC。WebRTC 版 Agent 在 UBIFS 用户分区上压缩后约占 7 MB。配置和资源实测见 [WebRTC 音频](../../docs/WEBRTC_AUDIO.md)。

音频驱动 `qdc507_aprv3.ko` 和 `qdc507_voice.ko` 使用 [MaVo 0443dfd 的 ModuleVoice](https://github.com/moluncn/mavo/tree/0443dfdaf8aec086fd76ba2ee9152fd908114524/Resources/ModuleVoice)。对应 GPL 许可与来源说明随运行时保留。启动器通过厂商 `alsaucm_test` 完成 VoLTE ACDB 校准，原生 helper 通过 `voc_svr` 启停媒体时钟。

## 已知限制

EG25 短信收件存储可能只有 23 个槽位。新版 Agent 在存储已满时，按短信中心时间回收最旧、已在前一轮成功解码的完整短信；每批目标为容量的四分之一（1–8 个槽位），长短信整组删除。本轮新消息、未收齐的长短信和无法解码的记录保留。该策略按用户授权淘汰模块存储，不删除 App 历史，也不代表 App 已确认持久保存。诊断和实测状态见 [收件调查](../../docs/EG25_SMS_RECEIVE_INVESTIGATION.md)。

用户分区约 15 MiB。2026-11-02 收件修复版 Agent 为 11,141,304 字节（UBIFS 压缩后占用较小），保留一个诊断版回滚时实测剩余 584 KiB；更新前必须评估实际空间，网页安装器会先清理非活动版本，并保留 512 KiB 余量。ARMv7 构建通过架构分支排除无法运行的 RM500 后端，避免无效代码挤占空间。当前固件不支持 `AT+CIREG?`，IMS 注册状态显示为不可查询，不用 LTE 注册状态推断 IMS。`CLCC` 中 mode=1 的数据连接不作为语音通话。短信采用 PDU 模式，正文仅存于进程内存；读取存储短信可能更新模块中的已读标志。已上报的存储短信以 PDU 的 SHA-256 摘要记录在 `state/eg25-sms-seen`（0600，不含正文），Agent 重启或控制会话重建后不再重复上报；首次建立记录时只登记 SIM 中已有短信。无法解码的单条 PDU 被跳过，AT 帧格式错误仍终止会话。QDC507 响铃期间 `AT+CLCC` 可能连续数秒返回 CME 100，连续失败 15 秒内保留通话对象与 call_id，超过后才重建控制会话；断开原因写入 `agent.log`。短信发送限定单条 UCS2（最多 70 个 UTF-16 单元），接收支持 PDU 与多段合并。

## 安装与配对

2026-11-02 22:01：EG25 收件故障确认为 ME 短信存储满（23/23）。新版 Engine 满仓时按时间回收旧的完整短信，已在真机两次触发清理并恢复模块→云端→SkySIM 收件；用户确认测试短信已显示。网页诊断与 Engine 已通过 Workbench 发布 `sms-receive-20261102`。App、ECS 业务容器和启动器不变；另一次修复前的自主重启原因未定，详见 [收件修复](../../docs/EG25_SMS_RECEIVE_INVESTIGATION.md)。

2026-11-02 14:35：已发布 `sms-pdu-20261102`，修复短号被标记为国际号码及 UTF-8 被误作 UCS-2 的短信编码问题。即使已安装当日早些时候的短号版，也需要再更新一次 Engine；App 保持 SkySIM 81。部署和未实测边界见 [短信修复](../../docs/EG25_SMS_FIX.md)。

2026-11-02：网页已提供 6 位短号修复版 Engine，云端 control 同步更新。用户自行更新本块 EG25，本轮没有新增实机安装、断电或短号实拨验收；见 [短号部署](../../docs/SHORT_NUMBER_UPDATE.md)。

2026-11-01 网页安装器已发布 macOS 的出厂模块入口：选择器包含 `2ca3:4006` 和 `2c7c:0125`，通过 USB AT 核对 QDC507 固件后显式开启 ADB、重启并重新选择原模块。ADB 已开启而 Agent 未安装/尚未启动时直接显示安装或启动等待，不误报 USB 断开。兼容范围、自启动检查、首次云端登记与本轮实机边界见 [网页安装器说明](../../docs/MODULE_WEB_INSTALLER.md)。

1. 准备上述精确内核配置与 ARM EABI 编译器，构建 `kmod/airsim_data11.ko`。执行 `python3 module/eg25/prepare_runtime.py`，生成 `dist/` 中的驱动、源代码及 GPL 说明。
2. 构建 `module/rm500/audio` 与本目录的原生 helper，在 `service/airsim/web` 执行 `npm ci && npm run build`。构建器固定 Go 1.24.13，为两个平台分别生成安装资源。不要把 ARM64 包用于 EG25。
3. 模块独立供电、连接电脑数据 USB，在 Chrome/Edge 的配对页选择设备并安装 Engine。主机 `adb server` 占用 USB 时先关闭它。当前固件 USB 不提供序列号，USB 断开重连后 Chrome 需要重新选择设备授权；网页随后核验安装结果。安装器按文件传输，保留身份并清理非活动发布目录。若实测空间不足或设备报告 ENOSPC，会在完整新包下载校验后暂停 Agent/helper、删除旧程序并自动重试一次；中断后重新选择模块继续安装，不再保留旧程序回滚。安装完成恢复原启动器与自启动。普通路径清理当前版本以外的旧 helper 发布目录，复用哈希一致的文件，先清理中断暂存并同步，再按实际余量以 4–64 KiB 分块写入（文件尾可更小），保留 512 KiB 余量，不足时清理暂存并停止；`/etc/inittab` 写入 `asm:12345:respawn:/usrdata/airsim-v2/run-agent.sh`。
4. 新模块由服务管理员按 [R4 登记协议](../../protocol/v2/R4.md) 执行本机 prepare、`issue-module` 和 activate。设备私钥留在模块，网页不会签发管理员证书。已登记模块更新 Engine 后保留服务配置。
5. 网页核对 EG25 QDC507 与短模块标识，生成五分钟连接码；在 iOS 原“添加设备”输入并确认。ECS 通过认证 hello 的 `platform` 显示型号，App 的模块范围、通话/短信接口和 WebRTC 媒体协议不变。

固件根证书库缺少当前服务所需的 ISRG Root X1。安装资源包含 [Let's Encrypt 官方证书](https://letsencrypt.org/certs/isrgrootx1.pem)，启动器通过 `SSL_CERT_DIR` 补充该根，同时继续使用系统 CA 文件；不跳过 TLS 校验。

## 恢复

安装前的 inittab 保存在 `/etc/inittab.airsim-backup`。Agent 正常退出后由 init respawn 恢复；平台驱动和音频校准在开机启动器中准备。维护期间先确认无活动通话。需要停用时，在根分区临时可写状态下仅移除 `asm:` 项并通知 init，正常停止 Agent；启用了 USB DHCP 时，还需核对并停止 `/run/airsim-v2/usb-dhcp-watch.pid` 与 `usb-dhcp.pid` 对应的 AirSIM DHCP 进程，再恢复根分区原挂载模式；不要删除 `config/` 或 `state/`。下次重启恢复固件的原 USB composition。若活动版本仍可用，优先保留并检查 `/run/airsim-v2/agent.log`、`/run/airsim-calibration.log`，不要用删除身份或在途命令标记的方法掩盖故障。

真实测试结果和剩余边界见 [验证记录](TESTING.md)。

Agent 支持 `airsim-v2-callkit` 服务的 APNs 开启和关闭状态；`airsim-v2-r4.1` 仍要求 APNs 关闭。启用 ECS 推送前须使用支持该能力的 Agent。
