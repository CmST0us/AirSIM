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

## 网页安装

`https://airsim.eric3u.cc/` 的配对页会在模块未安装、版本不一致或缺少开机启动项时
提供“安装并启用”或“更新并启用”。`service/airsim/web` 的构建会从
`module/airsim-agent` 和 `module/rm500/audio` 生成 arm64 Agent、启动器、原生音频
Helper 和带 SHA-256 的 manifest。网页通过 Chrome WebUSB 直接传送一个安装包，
校验设备上的副本后写入 `/mnt/data/airsim-v2`，保留 `config/`、`state/`、
`audio-current` 和现有配对，再更新 `current` 与唯一的 `asm:` 条目并重启 Agent。

模块重启后，如果 Engine 已安装但控制 socket 尚未出现，网页显示
“Engine 正在启动”，不把随机源初始化窗口误报为未安装或设备断开。用户可以保持供电并
点击“重新检查”。

手工安装仍可作为仓库内救援路径。在 `module/airsim-agent` 目录执行：

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
- 通过生产配对页完成一次从旧版到 `2.0.0-dev.pairing` 的更新；网页返回
  “确认设备”，`current`、启动器与 `airsim-audiod` 哈希均匹配发布 manifest。
  重启后 `config/identity.json` 与 `config/cloud.json` 内容哈希不变，
  `current`、`audio-current` 和 `asm:` 条目保持不变；等待内核随机源完成后，
  `control.sock`、`media.sock` 和 Agent 进程自动恢复。网页再次识别为“确认设备”，
  并显示 Engine 已启用开机自启。
