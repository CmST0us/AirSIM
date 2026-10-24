# RM500 本机 Go CLI

`rm500` 是运行在 **RM500 Linux 系统内部**的命令行程序。原生控制直接走本机 AT 通道，网络/USB/系统/音频设备数据来自 Linux 和已有系统工具。原生命令不依赖 module-agent、Relay、APNs 或其他公网服务。

设计参考 [CLI-Anything](https://github.com/HKUDS/CLI-Anything)：可发现的命令树、机器可读输出、真实后端、可组合的数据流、REPL 和明确错误。实现为独立 Go module，只有标准库，`CGO_ENABLED=0` 静态构建。

## 实机基线

2026-10-23 检查并部署，2026-10-24 复核。CLI v0.1.1 已安装到模块持久目录 `/mnt/data/airsim/bin/rm500`：

| 项目 | 实际值 |
| --- | --- |
| 型号 / 固件 | RM500U-CN / RM500UCNAAR01A18M2G |
| SoC / CPU | UNISOC UDX710 / ARM64 |
| 内核 / 系统 | Linux 4.14.98 / unisoc-initgc-distro |
| 可用 AT 入口 | `/dev/smd1`，已通过 `ATI` 验证 |
| 系统 AT 路由 | `/etc/atrouter/system.ini` 将 `/dev/smd0` 接到 CP；不要抢占 `/dev/stty_lte0..7` 等 RIL/atrouter 通道 |
| USB 网卡 | `usb0`、`sipa_usb0`，桥接至 `tether` |
| USB 网络模式 | `AT+QCFG="usbnet"` 返回 `3`，即 RNDIS |
| 蜂窝接口 | `sipa_eth0..7`；接口存在不代表会话已激活 |
| 音频 | ALSA 声卡、VOICE/VOIP PCM 节点、`tinymix` / `tinyplay` / `tinycap` / `tinypcminfo` |

**实测结果：已测本机控制项、蜂窝 DNS/ping/TCP 收发通过；更换联通 SIM 后已正常响铃、接通和挂断。** 用户确认手机清楚听到模块注入的测试音，模块也在用户说话时采到明显音频；静音段仍有残余，下行语音清晰度和持续双向 PCM 桥尚未验收。此前电信 SIM 的呼出在约 0.4 秒后以 `DisconnectReason: network` 断开；换卡对照与详细证据见 [TESTING.md](TESTING.md)。

**RM500U 与旧 QDC507/RM500Q 不能混用驱动、USB 参数或语音路径。** 本 CLI 不加载 QDC507 内核模块、不启动其音频 helper、不修改系统服务。所有写操作都必须通过对应命令显式执行。

## 构建与运行

开发机安装 Go 1.24 或更新版本：

```sh
cd module/rm500/cli
./build.sh                  # dist/rm500-linux-arm64，本次实机目标
./build.sh --all            # 额外构建 armv7，未做 armv7 实机验证
go test -race ./...
go vet ./...
```

在开发机显式选择 ADB 设备，部署到模块可写的持久分区：

```sh
adb devices -l
./deploy-adb.sh "$SERIAL"
adb -s "$SERIAL" shell
```

部署脚本核对 ARM64 架构和 SHA-256，通过同一文件系统的重命名更新二进制，保留一份 `rm500.previous`。脚本检查设备端退出码，兼容本固件不向主机传播退出码的旧 ADB 协议。不修改只读根分区或开机服务。

以下命令在 **模块 shell 内**运行：

```sh
export RM500_AT_DEVICE=/dev/smd1
export PATH=/mnt/data/airsim/bin:$PATH
rm500 device info
rm500 system capabilities --json
rm500 network signal --json
rm500 network interfaces --json
rm500 modem config-list --json
rm500 schema --json
rm500 repl
```

AT 设备必须显式指定；不自动遍历并打开所有 AT 端口。CLI 会串行执行同一命令内的 AT 事务，并用 `/run/lock` 文件锁避免多个 CLI 同时消费同一设备。锁按设备号归一化，对不同路径别名同样有效；其他未遵循该锁的厂商程序不受约束，应使用专用通道。TTY 临时设置为 raw 模式，退出时恢复 termios；SMD 字符设备不强求 TTY ioctl。

## Agent skill

配套的 [rm500-cli skill](../skills/rm500-cli/SKILL.md) 位于 `module/rm500/skills/rm500-cli`，指导 Agent 从运行中的 schema 发现命令、检查执行结果，并处理控制、蜂窝数据、部署与语音验证。将该目录放入或链接到 Codex 的 skills 目录后，可使用 `$rm500-cli 检查模块的网络、IMS 和通话状态` 调用。

skill 内的 `scripts/rm500_adb.py` 用于开发机执行有限 JSON 命令，核对旧 ADB 协议丢失的设备退出码；二进制流、持续监控和 REPL 在模块侧执行。详细用法见 skill，语音能力的实际验收状态仍以 [TESTING.md](TESTING.md) 为准。

## 命令树

`rm500 --help` 查看全部命令，`rm500 data --help` 查看分组，`rm500 data set-apn --help` 查看必需参数。`schema --json` 是与实现共用注册表的完整机器可读目录，包括参数类型、AT 命令模板、后端和是否改变状态。

| 分组 | 覆盖的控制和数据能力 |
| --- | --- |
| `device` | 型号/固件、IMEI、RF 功能、时钟、重启、关机 |
| `sim` | PIN 状态/解锁、ICCID、IMSI、号码、卡槽、原始 APDU |
| `network` | 信号、注册、运营商扫描、小区、RAT/频段、Linux 接口/路由/地址、DNS、ping |
| `data` | APN/PDP 定义、附着、激活/停用、PDP 地址和协商参数 |
| `usb` | 网络模式、USB 功能配置读取、Linux gadget 状态 |
| `router` | 模块 NAT 模式、LAN 配置读取；修改可用 `modem config-set` |
| `modem` | QCFG 能力枚举、任意具名 QCFG 读取/设置，覆盖固件扩展配置 |
| `calls` | 通话列表、拨号、接听、拒接、挂断、DTMF、静音、音量、失败原因、IMS 注册 |
| `sms` | 存储、列表/单条读取、UTF-16 文本发送、完整 PDU 发送、单条删除、URC 配置 |
| `gps` | GNSS 状态、启动/停止、位置、NMEA 查询；固件支持情况见下文 |
| `audio` | ALSA 设备/PCM 约束、mixer 读取/设置、音频模式、USB 语音状态、WAV 播放、内存采集统计与测试音 |
| `system` | 系统信息、能力清单、电源/温度传感器 |
| `watch` | 接口和流量计数持续 NDJSON 输出 |
| `stream` | TCP 双向字节流、兼容 AirSIM PCM 桥的双向流、URC/NMEA 行流 |
| `at` | 原始 AT 扩展入口、固件命令列表查询 |
| `agent` | 可选的旧 Agent HTTP API 兼容入口，原生命令不经过它 |

这份目录代表 CLI 暴露的协议入口，**不是所有型号/固件都支持这些功能的承诺**。原始 `at exec` 与 `modem config-get/config-set` 可以访问尚未命名封装的厂商控制能力；不执行 shell 拼接。`AT+QCFG=?` 在当前设备上实际返回 25 类配置，包括 USB、NAT、IMS、PCIe、以太网、LAN、APN、内存/文件系统用量、热管理等。

## 控制示例

```sh
# 先预览；不打开串口、不连接网络
rm500 data set-apn --cid 1 --type IPV4V6 --apn example.apn --dry-run --json

# 显式执行配置；APN 激活与 Linux 路由是不同步骤
rm500 data set-apn --cid 1 --type IPV4V6 --apn example.apn
rm500 data activate --cid 1
rm500 data address --cid 1
rm500 network routes --family 4
rm500 network routes --family 6

rm500 calls status --json
rm500 calls ims --json
rm500 calls dial --number '<替换为目标号码>' --dry-run
rm500 sms send --number '<替换为目标号码>' --text '测试内容' --dry-run

rm500 modem config-get --key ims
rm500 modem config-set --key nat --value 1 --dry-run
rm500 at exec --command 'AT+QCFG="usage/apmem"'
```

短信列表和读取输出 PDU 原文，保留完整数据；这些操作可能标记短信已读。发送支持单条 UTF-16 SMS（最多 70 个 UTF-16 code unit，超长明确拒绝），不把长短信悄悄拆成多条计费短信。`sms send-pdu` 接受包含 SMSC 长度字节的完整 PDU，可用于上层自己编码的长短信。SMS 操作临时切换 PDU 模式，结束后恢复原 `CMGF`；发送成功但恢复失败也返回错误，避免把部分成功伪装为完全成功。

## 本机音频检测

`calls dial` / `calls answer` 返回 `OK` 表示固件接受命令，输出中的 `note` 明确说明尚未确认接通。必须继续观察通话状态；首张 SIM 的实测就是命令被接受但呼叫很快失败；换卡后另行观察到了 active。`calls last-error` 在该固件上返回 `unknown`，需要结合系统 oFono 事件定位。

固件配置将 `hw:0,9` 命名为 `voice_c`；厂商 `quec-voice` 二进制包含 `hw:0,9`、`hw:0,55` 与语音采集/播放路径。实机 mixer 显示采集方向为 `VOICE_CAPTURE_DOWNLINK`，播放为 `VOICE_PCM_PLAY_UPLINK_MIX`。这些是路由线索，不能替代接通后的双向验收。

```sh
rm500 audio mode --json
rm500 audio usb-voice --json
rm500 audio pcm-info --card 0 --device 9 --json

# 只输出采样量、峰值、RMS、去除直流后的 AC RMS 等统计量
rm500 audio probe --card 0 --device 9 --rate 8000 --seconds 3 --timeout 8s --json

# 在已接通且路由已确认时，向指定播放节点送入间歇测试音
rm500 audio tone --card 0 --device 55 --rate 8000 --seconds 2 --frequency 660 --timeout 8s --json
```

`probe` 和 `tone` 使用固件的 `tinycap` / `tinyplay`，通过匿名管道处理音频，所有 PCM 和 WAV 头只在内存中生成/解析。不会保存录音、自动拨号或修改 mixer。采集限定 1–10 秒、单声道 S16LE、8/16 kHz；同时报告请求时长、采样时长和实际耗时。测试音峰值约 −24 dBFS，带渐入渐出和间歇。工具报错、格式不符、超时或超出内存上限均失败；不能凭子进程退出码 0 宣布成功，因为本固件的 tinyplay 会在 `Error playing sample.ret:-32` 后仍退出 0。

无活动通话时 `probe` 曾读出重复统计值，`tone` 曾在设备 55 上返回上述错误。更换 SIM 并接通后，`tone` 写入成功，用户确认手机清楚听到测试音。最后一次对照采集时没有同时注入测试音，用户确认按提示先说话再静音；说话段 RMS 约 4,627，但静音段仍约 2,463，残留来源尚未定位。统计量不能代替下行语音内容和清晰度验收。CLI 尚未实现经过实测的 RM500U 持续双向 PCM 桥。

## 数据流

```sh
rm500 watch interfaces --interval 1s --count 10 --json
rm500 stream urc --count 5 --json
rm500 stream nmea --device /dev/实际NMEA设备 --json

# 双向网络字节流：stdin -> 对端；对端 -> stdout
producer | rm500 stream tcp --address 127.0.0.1:9000 | consumer

# 已存在兼容 AIRSIMPCM1/AIRSIMREADY 的本机桥时：
pcm_producer | rm500 stream pcm --address 127.0.0.1:7580 | pcm_consumer
```

TCP/PCM 的 stdout 只包含二进制，不接受 `--json`；错误写 stderr。输入 EOF 对 TCP 执行半关闭，并继续接收至对端 EOF/空闲超时。`--timeout` 控制连接、握手及网络空闲超时。PCM 数据必须由调用者按桥约定格式和节奏提供；此命令不会启动录音、建立通话、选择 mixer 路由或提供麦克风/扬声器。当前 RM500U 上未验证 AirSIM PCM 桥，不能直接复用旧 QDC507 的 7580 服务。

URC/NMEA 与流量监控输出一行一个 JSON；默认持续至 Ctrl-C，`--count` 可限定条数。URC 监听独占选定的 AT 通道，不能同时在该通道发另一个 CLI 命令。REPL 不保存命令历史；二进制流命令须在 REPL 外运行。

## 可选旧 Agent API

```sh
rm500 agent request --endpoint http://127.0.0.1:8575 \
  --method GET --path /api/health --json
rm500 agent request --endpoint http://127.0.0.1:8575 \
  --token-file /run/airsim/control.token \
  --method POST --path /api/push/register --data @registration.json
```

支持 GET/POST/PUT/PATCH/DELETE、JSON 字符串、`@文件` 或 `@-` 标准输入。URL 不写死，禁止跨主机重定向、不继承 HTTP 代理环境变量；令牌仅通过文件读取。现有 Agent 的通话/短信、eSIM、路由、诊断、事件与云端注册等 `/api/*` 均可从这个入口访问；真实后端返回 410/501 时 CLI 失败，不模拟成功。本机 RM500 基线未安装该服务，原生命令没有这个依赖。

## 输出和错误契约

- 成功：stdout 为 `{"ok":true,"data":...}`。默认缩进便于阅读，`--json` 紧凑输出，监控固定 NDJSON。
- 失败：stderr 为错误，启用 `--json` 时为 `{"ok":false,"error":{"code":...,"message":...}}`，stdout 不输出成功对象。
- 退出码：`0` 成功，`1` 其他 I/O 错误，`2` 参数错误，`3` 设备/网络/协议错误，`4` 操作超时，`5` 设备拒绝/未支持能力/后端失败，`130` 中断。
- AT 多行响应保留 `lines`，并按 `+XXX:` 聚合为 `fields` 数组。未识别字段不丢弃。无数据的只读查询不会仅凭一个 `OK` 就宣布能力可用。
- 不自动重试写操作。超时不等于动作未执行；先查询设备状态再决定是否重试。
- 不自动保存 PCM、短信、令牌、命令历史或设备快照；数据命令的显式输出由调用者管理。`--dry-run` 隐藏号码、PIN、短信、APDU、原始命令和值。

## 已知边界

当前固件的 `AT+QGPS?` 和 `AT+CLAC` 在实测中返回 `+CME ERROR: 4`，因此对应能力标记为未支持。换卡后的拨号接通和挂断已实测；接听、持续双向语音及音质、发送短信、软件控制 SIM 切换、USB 模式切换和网络写配置仍未验收。SIM APDU 是底层接口，不等于具备完整 eSIM LPA 下载/安装流程。透明 AT 数据模式不由 `at exec` 承载；Linux TCP 字节流使用 `stream tcp`。

RM500U 命令以[移远 RGx00U/RM500U AT 手册](https://quectel.com/content/uploads/2024/02/Quectel_RGx00URM500U_Series_AT_Commands_Manual_V1.0.pdf)与实机响应为依据；早于手册的固件会有差异。测试细节见 [TESTING.md](TESTING.md)。遵循仓库根目录 LICENSE、NOTICE 和第三方声明。
