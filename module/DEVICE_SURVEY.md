# EG25 在线设备与架构只读审查

日期：2026-10-24。用户已确认模块为 EG25；实测固件项目标识为 EG25G_QDC507，具体硬件型号后缀与 SDK 对应关系仍待核对。

| 项目 | 观察结果 |
| --- | --- |
| ADB | 当前只有一个设备，无序列号；使用本次发现的 transport ID 选择，重连后重新发现，不把 ID 固化到配置 |
| 系统位置 | 已进入模块内部 Linux；PID 1 为 init，存在 SysV init 脚本 |
| 项目标识 | /etc/quectel-project-version: EG25G_QDC507 |
| 固件版本 | QDC507GLEFM21_02.004，子版本 QDC507GLEFM21_02.004.03 |
| 构建 | 2024-06-20，9x07_R07_NEW |
| CPU / 内核 | armv7l；CPU info 为 Qualcomm MDM9207，uname 主机名 mdm9607；Linux 3.18.44 |
| 运行库 / ELF | /lib/ld-2.22.so、/lib/ld-linux.so.3；厂商服务与两份厂商库的 ELF 为 32 位小端 ARM、EABI5；flags=0x05000000 未声明浮点调用 ABI，仍需 SDK/ELF attributes 核对 |
| 内存 | MemTotal 43,460 KiB（约 42.4 MiB）；首次 MemAvailable 16,216 KiB，再次复核为 16,120 KiB（约 15.7 MiB），属于瞬时值 |
| swap | SwapTotal=0；内核配置 CONFIG_SWAP 未启用，不能把开启交换文件作为现成兜底 |
| 持久空间 | userdata UBIFS 共 15,712 KiB，剩余 15,496 KiB；/cache、/data、/usrdata 挂载同一 /dev/ubi2_0，不能相加 |
| 根文件系统 / 易失目录 | 根 UBIFS 只读；/var/lib、/run、/var/volatile 为 tmpfs；不能沿用 Agent 默认 /var/lib/airsim 保存持久身份与状态 |
| 设备服务 | ql_manager_server、qmuxd、netmgrd、atfwd_daemon 等；与 RM500U 的服务组合不同 |
| 控制端口 | ql_manager_server 持有 /dev/smd7，quectel-remotefs 持有 /dev/smd8，UART 桥持有 /dev/smd9；旧 Agent 的 /dev/airsim_data11 不存在；尚未确认应用专用 AT 入口，SMD 节点不等于 AT 接口 |
| 音频 | /proc/asound/cards 为 no soundcards；/proc/asound/pcm 为空，/dev/snd 仅观察到 timer |
| 音频软件 | 存在 libql_lib_audio、libaudioalsa、audio HAL 库和 qti_audio_server_daemon 等；文件存在不能证明语音路径可用 |
| 音频内核 | CONFIG_SND、CONFIG_SND_PCM、CONFIG_SND_SOC 已启用；CONFIG_SND_SOC_MDM9607、CONFIG_SND_SOC_QDSP6V2 未启用；/proc/modules 为空，已安装 modules.dep 没有对应音频模块 |
| 原生 SDK 线索 | libql_mgmt_client、libql_mam_ipc、QMI 库存在；没有 /usr/include；尚未验证 SDK 调用和 IPC 契约 |
| 启动 | SysV rc5.d 启动 qmuxd、netmgrd、ql_manager_server 等；misc-daemon 条件引用 init_qcom_audio，但该脚本不存在；没有验证用户分区自启动入口 |
| 网络 | ecm0、rmnet0、rmnet_data0、rmnet_data1、bridge0 存在；本次未发数据探针，不代表联网、IMS 或 VoLTE 已验收 |

没有部署程序、打开未知 AT 通道、加载驱动、停止厂商服务或修改配置。固件标识不单独证明硬件销售型号；后续应通过硬件/SDK 信息及安全的厂商查询接口交叉确认。

架构影响：保持 RM500、EG25、AVF 三个正式目标；把当前样机按实际固件单独建档，作为 EG25 的 QDC507 固件变体进行适配评估。先验证最小 Go 运行资源和对应音频驱动/API，再推进完整 Agent。旧 QDC507 代码可作为线索，未经版本核对不可直接运行驱动加载或 USB 恢复流程。

## 与现有代码逐项对照

| 现有假设 / 实现 | 复核结论与处理 |
| --- | --- |
| main.go 只允许 Android Telecom profile | 当前 Agent 不能直接切一个环境变量就在 EG25 工作；先实现 EG25 的装配与 HAL |
| atDevice=/dev/airsim_data11 | 设备没有此节点；旧 DATA11 桥不可假定存在，也不能回退抢占 smd7/8/9 |
| voice_runtime.go 加载 qdc507_aprv3.ko / qdc507_voice.ko，并等待 D4/D5/D6 | 当前没有这些 PCM 节点；旧代码是待验证的接入线索，不能将同名项目/同内核版本视为驱动兼容证明 |
| 默认 AIRSIM_DATA_DIR=/var/lib/airsim | 此设备 /var/lib 是 tmpfs；EG25 必须显式选择持久用户分区，候选 /usrdata/airsim |
| 当前 Debian 发布只构建 ARM64 | EG25 需要单独 ARMv7 产物与固件/原生 ABI 校验，不能安装 AVF 包 |
| 原架构 P0 的通过条件只有 ARM64、P5 只写 RM500 启动 | 已修正为三端门槛，并明确 EG25 的资源、持久化、启动和更新容量验收 |

## 验证顺序

1. 用对应工具链构建最小 ARMv7 Go 探针，分阶段验证启动、TLS 握手/重连、常驻资源；目前仅确认 CPU/内核条件，没有执行探针。厂商原生 helper 的浮点 ABI 必须以匹配 SDK 确认。
2. 获取当前固件对应 SDK/内核资料，确定安全的控制与事件接口；保留现有厂商进程。需要 C SDK 时仅增加窄的原生适配，业务仍在一个 Go Agent。
3. 确定音频驱动、路由、校准和双向 PCM 方案，再做真实通话验收。当前结论是固件音频通路未就绪，不能推断 EG25 硬件不支持语音。
4. 测量整机内存峰值与用户分区中发布/回滚/staging 的实际占用；使用持久目录和固件集成的启动入口，最后验证重启/断电恢复。

本次读取了 /proc 配置、挂载、进程名与设备 fd、init 脚本、模块清单及厂商 ELF 头；ELF 和压缩内核配置经 adb exec-out 在主机内存解析，未写入仓库或安装到设备。没有执行 AT、SDK、音频或联网功能测试。复核后的统一设计见 [多平台 Agent 架构](ARCHITECTURE.md)。
