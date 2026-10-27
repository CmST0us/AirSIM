# RM500U Agent 开机启动

RM500U 使用 BusyBox `init`，不是 systemd。持久启动配置由
`/etc/inittab` 中的以下条目进入；`respawn` 让进程退出后再次启动：

```text
asm:12345:respawn:/mnt/data/airsim-v2/run-agent.sh
```

启动器位于 `/mnt/data/airsim-v2/run-agent.sh`，执行
`/mnt/data/airsim-v2/current/airsim-agent`。它先等待 `/dev/smd1` 出现，再等待
Agent 的阻塞式随机源探测完成。该固件会提前暴露 AT 设备节点，但 Go 的
`crypto/rand` 在内核随机源初始化前会阻塞；缺少第二个条件时，Agent 进程虽然存在，
却不会创建控制 socket。不能轮询 `entropy_avail`：该值可能到达阈值后在两次采样之间
立刻回落，导致启动器永久等待。

首次安装可在仓库的 `module/airsim-agent` 目录执行：

```sh
GO=/path/to/go ./scripts/build.sh
python3 scripts/install_rm500u_autostart.py \
  --serial <adb-serial> \
  --binary dist/airsim-agent
adb -s <adb-serial> reboot
```

安装脚本把启动器写入 `/mnt/data/airsim-v2/run-agent.sh`，把 `current` 指向
`releases/<hash前16位>`，并只向 `/etc/inittab` 写一条 `asm:` 条目。原始
`/etc/inittab` 保存在 `/mnt/data/airsim-v2/config/inittab.orig`。修改系统分区时会暂时
remount 为可写，写完 `sync` 后恢复只读。它不修改
`/etc/quec_app_monitor.json`，厂商监控配置保持原样。

开机后按以下顺序确认链路：

```sh
adb -s <adb-serial> shell 'pidof quec_app_monitor; pidof airsim-agent'
adb -s <adb-serial> shell 'ls -l /run/airsim-v2/control.sock /run/airsim-v2/media.sock'
adb -s <adb-serial> forward tcp:18765 localfilesystem:/run/airsim-v2/control.sock
curl --noproxy '*' -fsS http://127.0.0.1:18765/healthz
curl --noproxy '*' -fsS http://127.0.0.1:18765/readyz
curl --noproxy '*' -fsS http://127.0.0.1:18765/v2/local/pairing
curl --noproxy '*' -fsS http://127.0.0.1:18765/v2/local/cloud
```

稳定启动后，网页配对使用 Chrome WebUSB 自带的 ADB 实现，不依赖电脑上的
`adb server`。在同一台电脑上执行 `adb kill-server` 可释放 USB 接口，让浏览器取得设备；
该操作不会停止 RM500U 内的 Agent，也不影响下一次整机启动。

需要回滚时，在设备上暂时 remount 根分区为可写，删除 `/etc/inittab` 中以
`asm:` 开头的唯一一行，执行 `sync` 后恢复只读并重启。Agent 部署目录、身份、
日志和 cloud 配置均不在这一行内，不会被删除。

## 实机验证

2026-10-27 在 RM500U-CN、Linux 4.14.98 上完成以下闭环：

- 重启后 `/etc/inittab` 中只有一条 `asm:` 条目，系统分区保持只读；
  `/etc/quec_app_monitor.json` 未被修改。
- 内核随机源尚未初始化时，`airsim-agent --wait-random` 阻塞等待；即使
  `entropy_avail` 从 127 瞬间回落到个位数，也没有漏过启动条件。约 128 秒后，
  `/run/airsim-v2/control.sock` 和 `media.sock` 同时出现。
- `/healthz`、`/readyz`、`/v2/local/pairing` 和 `/v2/local/cloud` 均返回 200；
  pairing 显示 `configured=true`、`connected=true`，cloud 同时恢复连接。
- 对已核对 PID 执行 `SIGKILL` 后，BusyBox init 立即拉起新 PID；数秒内控制 socket
  和 ready 接口恢复。
- 停止主机 `adb server` 后，Chrome WebUSB 仍能在系统选择器中显示
  `RM500U-CN - 已配对`，读取 Agent 后进入“确认设备”页面。
