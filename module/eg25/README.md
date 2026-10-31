# EG25 QDC507

平台标识 `eg25-qdc507`，适用于本机固件 `EG25G_QDC507 / QDC507GLEFM21_02.004.03`、ARMv7、Linux 3.18.44。AT 自报 `Baiwang QDC507 / QDC507GLEFM21`。新 Agent 位于 [airsim-agent](../airsim-agent/README.md)，持久目录为 `/usrdata/airsim-v2`，运行目录为 `/run/airsim-v2`。

DATA11 是 USB AT 使用的 SMD 通道。启动器移除 USB serial 功能、释放 DATA11，并通过 `airsim_data11` 内核模块提供应用专用字符设备。ADB 和 ECM 保留。`smd7/8/9` 继续由厂商服务持有。

USB 本地 v2 使用 ECM 的 `bridge0=192.168.225.1/24`。启动器在桥地址就绪后提供 DHCP，范围为 `192.168.225.10–30`；已有厂商 DHCP 服务时不接管。DHCP 不提供 DNS，也不下发 IPv4 默认路由，厂商 IPv6 行为保持不变。授权后的控制、短信和媒体访问 `https://192.168.225.1:8577`，使用方式见 [iOS USB 本地接入](../../iOS/README.md#usb-本地通话与短信)。

## 构建

Go 固定使用 1.24.13，`CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7`。进程设置 6 MiB Go 内存软限制；它不等于 RSS 上限。

`kmod/airsim_data11.c` 使用 GPL-2.0-only。内核基线为 [quectel_eg25_kernel 82ed009](https://github.com/the-modem-distro/quectel_eg25_kernel/tree/82ed00908b3e8efc3ff0de27d2b5a7c0524ecd7f)，使用设备 `/proc/config.gz` 准备，运行 `make ARCH=arm ... olddefconfig modules_prepare` 后执行 `kmod/build.sh`。目标 vermagic 为 `3.18.44 preempt mod_unload ARMv7 p2v8`，CONFIG_MODVERSIONS 关闭。

原生 helper：`ZIG=/path/to/zig-0.15.2 sh audio/scripts/build.sh`。共用现有 TinyALSA 与媒体 IPC，增加 EG25 的 AFE 路由、D4 hostless PCM、D5 播放与 D6 采集。DSP 映射缓冲区为 4096 字节；VoLTE 前端、D5 与 D6 均以 16 kHz 打开，单声道 S16_LE、256 帧 × 8 周期。mmap 路径负责硬件周期，外部媒体使用 320 样本的 20 ms 帧。

LC3 版 helper 在原生采集后编码、播放前解码或补偿丢帧，网络与 Unix 媒体均采用 120-byte ASMP v2 包；驱动、路由和硬件周期不变。Agent 与 helper 必须成对更新／回滚，App 与 ECS control／media 同步使用 LC3。配置和资源实测见 [LC3 音频](../../docs/LC3_AUDIO.md)。

音频驱动 `qdc507_aprv3.ko` 和 `qdc507_voice.ko` 使用 [MaVo 0443dfd 的 ModuleVoice](https://github.com/moluncn/mavo/tree/0443dfdaf8aec086fd76ba2ee9152fd908114524/Resources/ModuleVoice)。对应 GPL 许可与来源说明随运行时保留。启动器通过厂商 `alsaucm_test` 完成 VoLTE ACDB 校准，原生 helper 通过 `voc_svr` 启停媒体时钟。

## 已知限制

用户分区约 15 MiB，保留一个回滚 Agent 时剩余约 4 MiB，放不下第二个约 8 MiB 的 Agent；更新前需评估安装资源大小，网页安装器会先清理非活动版本。当前固件不支持 `AT+CIREG?`，IMS 注册状态显示为不可查询，不用 LTE 注册状态推断 IMS。`CLCC` 中 mode=1 的数据连接不作为语音通话。短信采用 PDU 模式，正文仅存于进程内存；读取存储短信可能更新模块中的已读标志。已上报的存储短信以 PDU 的 SHA-256 摘要记录在 `state/eg25-sms-seen`（0600，不含正文），Agent 重启或控制会话重建后不再重复上报；首次建立记录时只登记 SIM 中已有短信。无法解码的单条 PDU 被跳过，AT 帧格式错误仍终止会话。QDC507 响铃期间 `AT+CLCC` 可能连续数秒返回 CME 100，连续失败 15 秒内保留通话对象与 call_id，超过后才重建控制会话；断开原因写入 `agent.log`。短信发送限定单条 UCS2（最多 70 个 UTF-16 单元），接收支持 PDU 与多段合并。

## 安装与配对

1. 准备上述精确内核配置与 ARM EABI 编译器，构建 `kmod/airsim_data11.ko`。执行 `python3 module/eg25/prepare_runtime.py`，生成 `dist/` 中的驱动、源代码及 GPL 说明。
2. 构建 `module/rm500/audio` 与本目录的原生 helper，在 `service/airsim/web` 执行 `npm ci && npm run build`。构建器固定 Go 1.24.13，为两个平台分别生成安装资源。不要把 ARM64 包用于 EG25。
3. 模块独立供电、连接电脑数据 USB，在 Chrome/Edge 的配对页选择设备并安装 Engine。主机 `adb server` 占用 USB 时先关闭它。当前固件 USB 不提供序列号，USB 断开重连后 Chrome 需要重新选择设备授权；网页随后核验安装结果。安装器按文件传输，保留活动版本和身份，空间不足时停止；`/etc/inittab` 写入 `asm:12345:respawn:/usrdata/airsim-v2/run-agent.sh`。
4. 新模块由服务管理员按 [R4 登记协议](../../protocol/v2/R4.md) 执行本机 prepare、`issue-module` 和 activate。设备私钥留在模块，网页不会签发管理员证书。已登记模块更新 Engine 后保留服务配置。
5. 网页核对 EG25 QDC507 与短模块标识，生成五分钟连接码；在 iOS 原“添加设备”输入并确认。ECS 通过认证 hello 的 `platform` 显示型号，App 的模块范围、通话/短信接口和 ASMP 媒体协议不变。

固件根证书库缺少当前服务所需的 ISRG Root X1。安装资源包含 [Let's Encrypt 官方证书](https://letsencrypt.org/certs/isrgrootx1.pem)，启动器通过 `SSL_CERT_DIR` 补充该根，同时继续使用系统 CA 文件；不跳过 TLS 校验。

## 恢复

安装前的 inittab 保存在 `/etc/inittab.airsim-backup`。Agent 正常退出后由 init respawn 恢复；平台驱动和音频校准在开机启动器中准备。维护期间先确认无活动通话。需要停用时，在根分区临时可写状态下仅移除 `asm:` 项并通知 init，正常停止 Agent；启用了 USB DHCP 时，还需核对并停止 `/run/airsim-v2/usb-dhcp-watch.pid` 与 `usb-dhcp.pid` 对应的 AirSIM DHCP 进程，再恢复根分区原挂载模式；不要删除 `config/` 或 `state/`。下次重启恢复固件的原 USB composition。若活动版本仍可用，优先保留并检查 `/run/airsim-v2/agent.log`、`/run/airsim-calibration.log`，不要用删除身份或在途命令标记的方法掩盖故障。

真实测试结果和剩余边界见 [验证记录](TESTING.md)。

Agent 支持 `airsim-v2-callkit` 服务的 APNs 开启和关闭状态；`airsim-v2-r4.1` 仍要求 APNs 关闭。启用 ECS 推送前须使用支持该能力的 Agent。
