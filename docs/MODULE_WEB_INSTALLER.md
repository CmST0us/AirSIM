# 模块网页安装器：EG25 / macOS

2026-11-04 15:19：用户重试后仍空间不足，并授权删除旧版。网页已加入 EG25 低空间重装：完整下载校验后暂停 Agent/helper、删除旧程序再写入，保留身份/配对/状态，中断后重新选择继续安装，完成后恢复自启动。Workbench 已发布 `installer-reclaim-20261104`（源码 `492daa6`），85 项测试通过；96 kbps Engine 包不变，未做本轮真机验收。详见 [低空间重装](ENGINE_RECLAIM_UPDATE_20261104.md)。

2026-11-04：网页 Engine 安装器已修复中断暂存清理顺序、UBIFS 识别和低空间分块写入，通过 Workbench 发布 `installer-storage-20261104`；保留 512 KiB 余量及活动版本，96 kbps Engine 包不变。71 项测试通过，本轮无真机复验。详见 [空间检查修复](ENGINE_STORAGE_UPDATE_20261104.md)。

2026-11-02 22:28：完整修复链已提交到 main（`f49b425`），并从独立工作区构建 `main-f49b425-20261102`。Workbench 已更新云端 control 和两平台网页 Engine，当前 EG25 已安装；最终包通过断电自启、新短信到达模块/云端及再次满仓自动清理验收。SkySIM 82 与 main 的 App 源码一致。详见 [main 部署](MAIN_DEPLOYMENT_20261102.md)。

2026-11-02 收件修复新增 EG25 的“短信收件诊断”，可在选择并更新模块后直接读取容量、接收配置和轮询计数，无需重置配对。新版 Engine 满箱时按时间回收旧的完整短信；发布状态和真机证据见 [收件调查](EG25_SMS_RECEIVE_INVESTIGATION.md)。

2026-11-01：修复位于 `service/airsim/web`，已通过 Workbench 发布到深圳 ECS `i-wz93dhbsy21quebidepg` 的 `airsim.eric3u.cc`。网页与两个平台安装包共 26 个文件已从源站通过 HTTPS 核对哈希。采用静态文件原子替换，保留备份，四个业务容器未重启且健康。本轮已完成同一块 EG25 的 ADB 关闭后网页开启、完整安装、更新及两条路径的真实断电自启；[实机记录](../module/eg25/TESTING.md)保留详细证据。部署证据见 [部署记录](MODULE_WEB_INSTALLER_DEPLOYMENT.json)。

## 两条安装路径

- **已开启 ADB**：选择模块 → 核对精确固件和架构 → 安装或更新 Engine → 核对运行版本和开机启动 → 配对。没有 Agent socket 不代表 USB 断开；未安装显示安装入口，已安装但尚未运行显示启动等待，版本不符或启动项缺失显示更新入口。
- **出厂 EG25 QDC507**：选择 Baiwang / Quectel → 通过 USB AT 核对 `QDC507 / QDC507GLEFM21` → 点击“开启 ADB 并重启” → 等待重启并重新选择原模块 → 核对 Linux `armv7l`、内核 `3.18.44`、项目 `EG25G_QDC507`、子版本 `QDC507GLEFM21_02.004.03` → 安装完整 Engine。

桌面 Chrome/Edge 必须在 HTTPS 或 localhost 安全上下文使用。macOS 不必先安装串口驱动、platform-tools 或运行主机 ADB server。若其他程序占用接口，关闭相关工具；运行过主机 ADB 时用 `adb kill-server` 释放接口。Windows/Linux 的驱动绑定与权限需单独验证。

选择器同时接受 ADB `ff/42/01` 接口和 EG25 的 `2ca3:4006`、`2c7c:0125` 两组 USB ID。后两组 ID 只用于发现，不能单独证明固件兼容。AT 仅探测这些设备的 interface 2/3、`ff/00/00` bulk IN/OUT，不探测 DIAG、NMEA 或 QMI。该路径使用 WebUSB，不依赖 macOS 是否创建 `/dev/cu.*`。

初始化只接受上述 QDC507 固件的旧式八位数字 QADBKEY 挑战。响应在浏览器内存中派生，不记录、不保存、不上传。未知固件或新版授权格式停止，不自动套用其他型号的命令。读取原 USBCFG 后只开启 ADB 位，保留实际 VID/PID、AT、网络及 UAC 等其他位；回读检查后重启。初始化会持久开启 USB 调试授权，关闭 ADB 接口不能视为撤销该授权。存在语音通话时拒绝初始化；QDC507 的 CLCC mode=1 数据连接不作为语音通话；写入或重启响应不明确时不自动重放。重枚举后由用户重新选择原模块，不盲选第一个设备。

两个无序列号模块使用不同的页面内句柄。真实断开后，无序列号设备必须重新选择，不能用 VID/PID 或库生成的替代序列号认定是原模块。

## 安装和启动验收

每个平台分别提供 Agent、启动器、配套 Opus 音频 helper 和许可证；EG25 另含 DATA11、语音驱动及 CA 补充。按 manifest 校验浏览器下载和设备副本。身份、云端配置与状态目录保持不变。更新复用哈希一致文件的硬链接；UBIFS 不再使用固定压缩比判断是否能安装，先清理安装器拥有的中断暂存文件和非活动发布目录，sync 后再检查空间；按包含安装目录的最长挂载点识别 UBIFS，避免 df 的设备别名导致误判。写入块从最多 64 KiB 随可用空间缩小到 4 KiB（文件尾可以更小），始终保留 512 KiB 余量；暂存失败先清理本次文件。EG25 遇到已确认的空间不足时，会在完整新包已下载校验的前提下停止 Agent/helper，切换到持久维护启动器，删除旧程序释放空间并自动重试一次。配置和状态保留；若断线或断电，网页显示待继续安装，重新选择设备后可完成重装。最终安装校验、启动器和 init 持久化后才解除维护状态；该低空间路径不保留旧程序回滚。普通路径及 RM500U 继续保留活动版本。EG25 使用 `/usrdata/airsim-v2`，RM500U 使用 `/mnt/data/airsim-v2`。

安装器备份 `/etc/inittab`，写入唯一 `asm:12345:respawn:<平台目录>/run-agent.sh`，同步磁盘并恢复原只读根分区，再通知 PID 1 重载。运行检查要求：

1. 最新 manifest 可读取且平台匹配；不能在版本查询失败时宣称已是最新。
2. Agent、启动器、helper、驱动与许可证哈希匹配。
3. 唯一 `asm:` 启动项正确，启动器可执行。
4. 只有一个运行中的 Agent，`/proc/<pid>/exe` 的哈希及 `/healthz` 版本匹配发布包。

安装后的等待窗口为四分钟，覆盖 RM500U 的冷启动随机源等待。仅 socket 尚未就绪时保留 ADB 连接，不把 EG25 反复送回选择器。安装状态检查证明当前运行和启动配置；真实断电重启用于确认开机自启，崩溃恢复需另行验证。本轮同一块 EG25 在网页更新和完整安装后各实际断电至少 10 秒，恢复后唯一 Agent 均由 PID 1 自动启动，运行哈希匹配最新包，身份和云配置保持，云连接恢复。首次选择过早时显示启动等待，重新检查后就绪。此处使用保留身份的既有模块，不代表未授权出厂设备或首次云登记已验收。

**首次云端登记是独立步骤。** 全新模块安装 Engine 不会自动取得 ECS 模块证书。当前仍按 [R4](../protocol/v2/R4.md) 执行 prepare、管理员 `issue-module`、activate；已有登记的模块更新后保留身份、配置和配对。本次没有新增公开的管理员签发接口。

## 缺陷与本地验证

原实现仅用 ADB 接口过滤选择器，因此 ADB 关闭的设备不可见。另一个缺陷是检测出 Engine 未安装/正在启动后仍读取配对 socket；ADB 的 `Socket open failed` 被转换为 `disconnected`，安装页因此被错误页覆盖。现在将服务尚未就绪与 USB 断开分开处理，并仅在 Engine 就绪时读取配对状态。

Vitest 覆盖真实控制器与 ADB 服务拒绝、出厂 USB 发现、无序列号双设备、只读预检、授权兼容向量、仅修改 ADB 位、未知授权/固件/通话拒绝、AT 超时关闭和重复操作保护。两个平台的实际安装 shell 在隔离目录执行，检查 init、根分区恢复调用、可执行权限和身份配置保留。浏览器以测试适配器验证“选择 → 开启 → 重选 → 安装”及更新流程。此类模拟不替代真实 Chrome USB 选择器、AT 开启、文件传输或冷启动测试。

## 接口依据

- [QDC507 实机研究与 interface 2/3 记录](https://github.com/cr-zhichen/DJOneHubNative/blob/7194ae8cd71da34e0ab3727874dafb82ffd2537b/docs/MODULE_RESEARCH.md)。
- [Quectel USB 描述符说明](https://forums.quectel.com/uploads/short-url/uXpQMicPJt44aEHQ2YOqZgJhpjh.pdf)及[厂商 ADB 授权顺序](https://forums.quectel.com/t/how-to-enable-adb-interface-for-new-ec25-e-modem/21951)。
- [旧式授权兼容向量](https://github.com/carp4/qadbkey-unlock/blob/cab52a0a7429c8d8b8f31da8894c8c93155c0fc5/README.md)。哈希原语使用 MIT 许可的 noble-hashes，声明随发布包保留。

## 历史短信编码发布与回滚位置

2026-11-02 发布版本：`sms-pdu-20261102`（2026-11-02 14:35），在 `shortnumber-20261102` 基础上仅更新 EG25 Agent 和清单，修复短号收件地址及 UCS-2 正文编码。发布副本在 `/opt/airsim-v2/releases/sms-pdu-20261102/web`，Caddy 挂载目录仍为 `/opt/airsim-v2/releases/usb-local-20261030/web/dist`，静态备份为 `/opt/airsim-v2/backups/sms-pdu-20261102/web`。四个服务容器、RM500 包和模块启动器未变；EG25 由用户自行更新，没有新的真机或断电验收。详见 [短信编码修复](EG25_SMS_FIX.md)；此前云端控制服务更新见 [短号部署](SHORT_NUMBER_UPDATE.md)。

本地 58 项网页测试、Agent 的 `GOTOOLCHAIN=go1.24.13 go test ./...`、TypeScript、Vite 生产构建与安装资源哈希校验均通过。生产 `/healthz` 与 `/readyz` 返回 200，匿名 `/v2/modules` 保持 401。另外从 ECS 通过公网域名访问首页、前端 JS 和两平台 manifest，内容哈希均与本次发布一致。网页构建和源站/公网资源验证不等于 Chrome 真机 USB 安装验收。
