# 控制、数据与部署

以下示例在模块 shell 内运行，已设置 `RM500_AT_DEVICE` 和 `PATH`。主机可将有限 JSON 命令传给 `scripts/rm500_adb.py`。这里是常用工作流；完整参数从目标 CLI 的 `schema --json` 或子命令帮助获取。

## 控制与数据基线

根据待解决的问题选择查询，无需每次扫描全设备：

```sh
rm500 sim status --json
rm500 network registration --json
rm500 network operator --json
rm500 calls ims --json
rm500 data attached --json
rm500 data contexts --json
rm500 data sessions --json
rm500 network interfaces --json
rm500 network routes --family 4 --json
```

在已确认 `sipa_eth0` 是当前蜂窝出口的设备上：

```sh
rm500 network dns --host example.com --json
rm500 network ping --host 1.1.1.1 --interface sipa_eth0 --count 3 --timeout 15s --json
```

DNS 查询使用系统解析器；不能单凭解析成功断定它经过了蜂窝。结合实际路由与绑定接口的 ping/TCP 结果判断。PDP 激活和 Linux 地址/路由是不同层；`data activate` 返回成功不保证可访问公网。HTTP 301 也可证明 TCP 请求/响应成功，不能当作应用内容或 TLS 验收。

APN 修改示例仅作预览，CID、APN 与 IP 类型必须来自目标网络要求：

```sh
rm500 data set-apn --cid 1 --type IPV4V6 --apn example.apn --dry-run --json
```

执行已授权修改后，读回 `data contexts`、`data sessions`、`data address --cid ...`，再按需验证数据。不要为让测试通过而盲目切换 RAT、频段或 USB。当前 RM500U 查询到 `usbnet=3`（RNDIS）；USB 网卡存在不等于主机经 USB 上网通过。USB 参数改变可能让 ADB 中断。

## 短信与 SIM

- `sms list/read` 返回 PDU，可能标记短信已读；临时切换短信格式后会恢复。发送成功但格式恢复失败仍报告失败，此时先查询实际结果，不自动重发。
- `sms send` 支持单条 UTF-16 短信，最多 70 个 UTF-16 code unit；长消息不自动拆条。`sms send-pdu` 要求含 SMSC 长度字节的完整 PDU。
- 不猜 PIN，不对失败的 PIN/APDU 自动重试。原始 APDU 接口不等于完整 eSIM LPA。
- 删除短信是指定索引删除。先明确目标索引，不为排障清空存储。

## 字节流与监控

`stream tcp/pcm` 的 stdin/stdout 是二进制，不能使用 `--json` 或 JSON ADB 调用脚本。当前设备的 `adb exec-out` 曾返回 closed；不要依赖未经验证的旧 ADB shell 传输保真 PCM。将生产者、CLI、消费者放在模块侧，通过匿名管道或兼容的网络连接处理数据：

```sh
producer | rm500 stream tcp --address 127.0.0.1:9000 --timeout 15s | consumer
# 仅当该地址已有兼容 AIRSIMPCM1 / AIRSIMREADY 的桥时：
pcm_producer | rm500 stream pcm --address 127.0.0.1:7580 | pcm_consumer
```

这些生产者、消费者和地址是占位，先确认实际组件。`stream pcm` 只实现握手和字节转发，不建立通话、不采集/播放 ALSA、不创建桥。RM500U 上尚无经验证的本机双向桥；不要将 QDC507 的 7580 服务当成现成依赖。

`watch interfaces --count 5 --interval 1s --json` 输出 NDJSON；`stream urc/nmea` 按行输出 JSON。URC 监听独占选定 AT 端口，不要同时发查询；`--count` 等不到事件时仍会持续等待。为长任务安排明确的停止方式并检查退出，不只依靠 `--timeout`。不要终止其他任务的采集或厂商服务。

## 部署与版本

如果项目就在身边，事实来源为仓库的 `module/rm500/cli/README.md`、`TESTING.md` 和源码。此 skill 位于原仓库布局时，可从 skill 目录通过 `../../cli` 找到 CLI；作为独立复制品使用时，定位用户当前 AirSIM checkout，不依赖作者机器的绝对路径。

用户要求部署/升级时，在开发机执行：

```sh
cd /实际仓库路径/module/rm500/cli
./build.sh
./deploy-adb.sh "$SERIAL"
```

构建需要 Go 1.24+，默认 ARM64；ARMv7 只有编译验证。遵守目标仓库的部署前检查。部署脚本验证架构和 SHA-256，在可写分区原子替换二进制，保留 `rm500.previous`，不安装服务。部署后查询 version、device info；检查二进制一致不等于业务验收。未要求部署时，复用设备现有 CLI。

## 结果与常见错误

| 退出码 | 含义 |
| --- | --- |
| 0 | 命令执行成功，仍需对应的业务验证 |
| 1 | 其他 I/O 错误 |
| 2 | 参数错误 |
| 3 | 设备、连接或协议错误 |
| 4 | 超时 |
| 5 | 设备拒绝、未支持或后端失败 |
| 130 | 中断 |

ADB helper 自身失败在错误 JSON 中附 `source: "adb-wrapper"`，不包含未经校验的部分输出。`--host-timeout` 默认 90 秒；长扫描或多事务命令需按 CLI 超时与总任务时长设置，避免将主机等待超时误判为设备拒绝。

可选 `agent` 分组是旧 HTTP Agent 客户端，需用户明确指定的真实 endpoint 和设备上的 token 文件。RM500 原生命令无需它；没有服务时不要启动或配置 Relay 来解决原生 AT/音频问题。`@文件`、`--token-file` 引用的是模块文件；JSON ADB helper 不转发 stdin，不能用于 `--data @-`。
