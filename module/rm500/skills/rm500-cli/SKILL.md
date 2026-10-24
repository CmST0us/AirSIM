---
name: rm500-cli
description: "通过运行在模块内部的 rm500 Go CLI 查询和控制 Quectel RM500/RM500U，处理 AT、SIM、蜂窝网络、USB、通话、短信及 PCM 诊断；适用于本机 shell 或 ADB 对接、部署和实机验证。"
---

# RM500 CLI

把用户的操作目标映射到 `rm500` 命令，执行并检查设备结果。CLI 在 RM500 的 Linux 系统内运行；主机通过 ADB 调用。原生命令直接使用 AT、Linux 和厂商工具，不需要 Agent、Relay 或云端账户。

## 连接与发现

1. 沿用当前任务已经确认的设备、操作范围和授权。多设备且无法从上下文确定目标时才询问；不要从历史测试记录复制序列号、号码或配置。
2. 已在模块 shell 中，直接执行下列命令；在开发机上先 `adb devices -l`，选定序列号，再使用本 skill 的 [ADB 调用脚本](scripts/rm500_adb.py)。
3. 首次连接或 CLI 版本变化时读取 `version --json`、`schema --json`；按需读取 `system capabilities --json` 和目标命令的 `--help --json`。以运行中的 schema 为参数和后端依据；`mutates` 表示有副作用，schema 中存在命令不代表固件支持。

模块内的已测默认路径：

```sh
export RM500_AT_DEVICE=/dev/smd1
export PATH=/mnt/data/airsim/bin:$PATH
rm500 version --json
rm500 device info --json
rm500 network signal --json
rm500 calls status --json
```

主机调用示例（`SKILL_DIR` 为本 SKILL.md 所在目录，`SERIAL` 为当前确认的目标）：

```sh
python3 "$SKILL_DIR/scripts/rm500_adb.py" --serial "$SERIAL" -- version
python3 "$SKILL_DIR/scripts/rm500_adb.py" --serial "$SERIAL" -- schema
python3 "$SKILL_DIR/scripts/rm500_adb.py" --serial "$SERIAL" -- network signal
```

脚本仅用于一次性 JSON 命令，自动补充 `--json` 和缺省 AT 路径，不会自动拨号、重试或部署。支持 `--adb`、`--binary`、`--at-device` 和独立的 `--host-timeout`；CLI 参数放在分隔符 `--` 后，以命令名开头。CLI 的每个 flag 只出现一次；重复的 `--timeout` 会被拒绝。

已测硬件为 **RM500U-CN / UDX710 / aarch64**，不是旧 QDC507 或 RM500Q。不同型号先核对 `device info`、系统架构和实际端口。`/dev/smd1` 是当前设备专用 AP AT 通道；不要枚举试开所有端口或抢占 RIL/at-router 使用的 `/dev/stty_lte*`、`/dev/smd0`。同一 AT 通道的查询、写入、URC 监听串行安排。

## 根据目标选命令

| 用户目标 | 入口与读后验证 |
| --- | --- |
| 设备、SIM、信号、注册与 IMS | `device info`、`sim status`、`network signal/registration/operator`、`calls ims` |
| APN、PDP 和蜂窝数据 | `data contexts/attached/sessions/address/details`；写配置后读回，再检查 Linux 接口、路由与实际收发 |
| USB、LAN、NAT 和厂商配置 | `usb mode/configuration/status`、`router nat/lan`、`modem config-list/config-get`；写操作使用 schema 中的具名命令或 `modem config-set` |
| 呼叫与语音 | `calls`、`audio`；先读 [语音验证](references/voice.md) |
| 短信、SIM PIN/APDU、GNSS | 查询目标子命令帮助；短信与高影响配置注意 [操作说明](references/operations.md) |
| 网络流、PCM 字节流、URC、持续监控 | `stream`、`watch`；读 [操作说明](references/operations.md)，在模块侧处理二进制或长运行任务 |
| CLI 不存在或需要升级 | 使用仓库 `module/rm500/cli/build.sh`、`deploy-adb.sh`；见 [操作说明](references/operations.md) |

优先使用具名命令。确实缺少封装时，可用 `at exec` 或 `modem config-get/config-set`，但先依据当前固件资料和实际响应确认语法。不要把其他 Quectel 型号的参数值套到 RM500U。

## 执行与结果判断

- 执行用户已经要求的操作，无需重复索要同一授权。缺少真实呼叫/短信的目标或授权、或拟进行任务范围以外的破坏性操作时，先完成查询、命令预览和影响说明，再询问缺失信息。历史测试号码不是今后所有任务的拨号授权。
- 新配置可用 `--dry-run --json` 检查参数与目标；dry-run 不连接硬件，不能证明配置有效。修改 APN、RAT、频段、USB、SIM 卡槽、RF、路由或电源前读取旧值，明确恢复方法；只做用户目标所需的变更。
- 有限命令使用 `--json`。成功为 `{"ok":true,"data":...}`；失败为 `{"ok":false,"error":...}`。检查退出码与 payload；AT `OK` 只表示命令接受，拨号、PDP 激活和配置写入还要查询结果或验证业务。
- AT 结果位于 `data.responses[]`；每项包含 `lines`、`fields`、`terminal`，例如 `fields["+CLCC"]` 是同类响应的数组。检查所有事务响应，不要把不存在的顶层 `data.lines` 当成空通话列表。本地命令的 `data` 结构按命令区分。
- 本固件旧 `adb shell` 的主机退出码不代表设备退出码。调用脚本会校验随机尾标记中的设备退出码并移除标记；标记缺失、JSON 损坏或连接中断都不能记为成功。超时可能已经产生副作用，先查状态再决定下一步，不自动重发写命令。
- 命令超时与任务完成时限不同。`--timeout` 对 AT 命令逐事务生效；stream/watch 也不一定受总时限约束。主机超时仅表示 ADB 等待被终止，不能保证远端进程结束。
- `CME ERROR: 4` 在当前固件的 `gps status` 和 `at commands` 查询中出现过；将它报告为该固件/命令未支持，不把失败转换成模拟结果。
- 保留原始 AT 字段用于内存中的判读。真实号码、短信/PDU、SIM 标识、令牌和音频不写入仓库、报告或诊断日志；工具返回可能含敏感信息，展示前只提取必要的状态。PCM 只走内存、匿名管道和网络，不生成录音文件。

最终说明执行了什么、哪些结果有设备证据、尚未验证什么。分清 CLI 命令可调用、模块业务成功与 Relay/手机端到端成功；只报告本次检查支持的结论。
