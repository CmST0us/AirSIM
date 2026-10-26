# airsim-agent v2 — R3 当前16kHz语音时钟本地验收通过

本目录为独立 Go 工程 `airsim.local/airsim-agent`，当前源码版本 `2.0.0-dev.pairing`，依赖 godbus/dbus v5.2.2 与其 x/sys v0.27.0，不依赖旧 Agent、RM500 CLI 或云端服务。依据主控维护的 [R2 契约](../../docs/RM500_AGENT_R2.md)。R1 已完成主控验收，其 [证据](R1_TESTING.md) 保持为历史记录；R2 功能实机链路与重启后命令去重验证通过，短信重复到达/延迟仍未解释，voice_ready=false、无开机自启；详细边界见 [R2 记录](R2_TESTING.md)。

R3 已实现原生音频 helper、本机媒体会话与通话 lease；本机验证和构建见 [R3 交接记录](R3_TESTING.md)及[构建证据](R3_BUILD_EVIDENCE.json)。R3 裁决04构建已部署，当前固件、厂商16kHz语音时钟下75.004秒双向内容验收通过；用户确认听清提示语及自己的回声。运行时 voice_ready=false、verification=unverified 仍保留为实验发布门槛。权威事实见[验收证据](R3_ACCEPTANCE_EVIDENCE.json)与[历史诊断证据](R3_DIAGNOSTIC_EVIDENCE.json)。下文 R2 证据保留为历史基线。

设备配对在现有身份上增加网页配对所需的新鲜 Ed25519 证明，不导出私钥，也不新增网络监听。实现和验证边界见 [配对记录](PAIRING_TESTING.md)。

## 范围

R1 AT 只读采样与精确 RM500 profile 校验继续保留。R2 新增长期私有 oFono D-Bus 连接、串行控制协调器、有界持久去重记录及本机呼叫/短信控制。R3 Audio 已通过上述限定范围的本地内容验收，运行时 voice_ready 固定 false。

- `internal/ofono`：有界信号队列、连接/发现、快照与指定业务方法。
- `internal/control`：串行状态、两个独立 worker、epoch/期限/状态门禁与事件关联。
- `internal/journal`：不含正文或号码的原子操作记录。
- `internal/identity`、`internal/at`、`internal/platform/rm500u`、`internal/state`：沿用 R1 身份、串口、平台和只读快照职责。
- `internal/transport/local`：0600 Unix socket API，handler 不直接访问设备。

## 本机验证与构建

在本目录执行，使用 Go 1.24.13：

```sh
go test -race ./...
go vet ./...
GO=/path/to/go ./scripts/build.sh
```

构建固定 `CGO_ENABLED=0 GOOS=linux GOARCH=arm64`，输出 `dist/airsim-agent` 与 SHA-256。产物未签名，不是 OTA 包。

## 已授权部署辅助

`scripts/adb_device.py` 的 `Device(serial)` 每次构造都重新枚举 ADB、取得当前 transport ID、核对 Linux/aarch64/udx710-module。`shell` 校验设备侧退出码标记；`deploy` 将文件写入独立的 `/mnt/data/airsim-v2/releases/<hash前16位>/airsim-agent` 并复核设备 SHA-256，不覆盖已存在的不同内容。该 helper 仅用于本阶段开发部署。

设备运行参数：

```sh
<release-directory>/airsim-agent --profile rm500u-embedded --at-device /dev/smd1
```

持久目录 `/mnt/data/airsim-v2`，运行目录 `/run/airsim-v2`，均为 0700。实例先取得持久目录与运行目录两份 flock，再初始化身份；端口另持有按 rdev 命名的资源锁。身份在 `config/identity.json`（0600），私钥不返回接口或日志，也不要复制到主机。

R1 诊断接口保留在 `control.sock`（0600），仅接受 GET：

- `/healthz`：进程存活。
- `/readyz`：必要查询新鲜且 AT 同步时返回 200，否则 503。
- `/v2/local/capabilities`：本轮六类能力状态。
- `/v2/local/snapshot`：脱敏只读快照。

R2 增加 GET `/v2/local/control`、`/v2/local/calls`、`/v2/local/messages`、`/v2/local/commands/<UUID>` 和 POST `/v2/local/commands`。请求与动作精确结构见主控契约。业务接口可返回号码/正文，仅限本机受控调用；只读 snapshot 不含这些内容。

设备配对增加 GET `/v2/local/pairing` 和 POST `/v2/local/pairing/authorize`。前者只返回模块身份、服务绑定和连接状态；后者对网页生成的五分钟请求签名。两者仍只存在于 0600 Unix socket；调用方必须已经能访问该 socket。证明不替代手机确认，也不创建 App token。

这不是冻结的云端 v2 协议。无 TCP 监听、自动启动、Relay/TLS、更新或固件修改。R3 音频仅在授权本地媒体会话及通话 lease 内运行。消息正文仅保留进程内存；命令记录最多1024条且不自动淘汰。

## 停止与故障边界

正常 SIGTERM 停止新事务，让当前事务在原 5 秒预算内收完终止行；总退出预算 15 秒；R2 停止新命令、取消未提交项并让已提交调用在原预算内收敛，不自动挂断或删除消息。端口在支持 TCGETS 时保存并设置经验证的 raw 8N1 115200，正常关闭恢复原 termios；保持 CR 结尾。未知/超时事务关闭端口，保留 `at-inflight.json` 并停止所有 AT。存在该文件时重启只提供诊断，不打开设备；不得删除它绕过失败。主控决定后续恢复。

SIGKILL 实机验证只允许针对已核对的本轮 PID，且必须处于无在途标记的轮询间隔。该项已按空闲窗口完成，详见验收记录。

## R1 历史验收构建

SHA-256：`b9659d09758375ba8597654339d7b76f63603c7588134b478e7a9b3481569707`。原设备 PID 6367 已由本轮 R2 部署正常停止，release 保留；历史部署描述在 `/tmp/airsim-r1-run.json`。

最终构建与加固前构建的证据分别保存在 [最终连续观察](R1_EVIDENCE.json)、[最终生命周期](R1_LIFECYCLE.json) 与 [加固前历史记录](R1_PRE_HARDENING.json)，不混用 hash。

当前 R2 hash、最终进程与验收边界见 [R2_TESTING.md](R2_TESTING.md)、[业务证据](R2_BUSINESS_EVIDENCE.json)和[重启证据](R2_RESTART_EVIDENCE.json)；[初次只读观察](R2_EVIDENCE.json)保留为历史基线。实机业务测试由主控统一触发，执行会话交接后不并发操作设备。


## R3 验收范围与剩余门槛

75.004秒上下行各3750帧，外部序号零缺口、xrun为零（零字段省略）；helper input_drops=14，约0.37%，不能称零丢帧。silence_samples=5760为native16k样本，约0.36秒；echo_dropped=1435主要是主机提示语/非回声窗口主动丢弃，不是网络丢包。真实helper SIGKILL后的helper_exit、PCM关闭/子进程回收、新session成功、旧token拒绝、客户端EOF的media_read及通话结束lease_revoked均通过。最终无活动通话或自有helper，5c/5p/9c/55p closed，控制ready、身份保持。

精确构建哈希、资源采样及最终状态以[主控验收证据](R3_ACCEPTANCE_EVIDENCE.json)为准。此前失败保留在[主控诊断证据](R3_DIAGNOSTIC_EVIDENCE.json)，已由最后成功内容闭环取代。8kHz vendor时钟只有单测；30分钟/100会话长稳、Mac麦克风/扬声器、ECS/Worker/iOS端到端未验证，R4–R5不启动。没有保存录音或声音内容。
