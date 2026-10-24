# 呼叫与语音验证

## 实测基线与证据层次

截至 2026-10-24，RM500U-CN / RM500UCNAAR01A18M2G / CLI v0.1.1：

- 联通 SIM 已完成 dialing → alerting → active，以及接通后的挂断。
- 模块向 `hw:0,55` 注入间歇测试音，用户确认手机清楚听到，证明模块 → 手机方向。
- 用户确认先说话后静音，`hw:0,9` 采集说话段 RMS 约 4,627，静音段仍约 2,463。已取得明显音频；静音残留来源、语音内容/清晰度和连续双向桥尚未验收。
- 先前电信 SIM 在拨号约 0.4 秒后以 oFono `network` 原因断开；未收到来电。换卡成功不能单独证明旧 SIM 未开通语音。

这些是特定设备上的历史证据，不是其他设备/当前 SIM 的成功保证。通话 `OK`、IMS 已注册、PCM 非零、远端听感、持续端到端通话分别需要相应证据。

## 受控测试

1. 沿用本次任务已获授权的测试号码与操作；缺少目标或拨号授权时询问。先检查现有通话，避免接管或挂断无关通话。读取 `calls ims`、`network registration`、`sim status`，必要时补充信号和运营商信息。
2. 用 `calls dial --number ... --json` 发起一次呼叫。轮询 `calls status --json`；`+CLCC` 的第三个字段为状态：0 active、1 held、2 dialing、3 alerting、4 incoming、5 waiting。仅 `OK` 不证明接通。
3. 为本次测试明确接听等待时间，默认可用 60 秒，用户需要时调整。等待期间保持用户可见进展。超时、失败或测试完成后清理本次通话；未确认结束前不重拨。
4. 接通后按需分别验证下面两个音频方向。让用户知道提示音、说话和静音的顺序；需要确认听感或操作时再请求反馈。采集/播放失败先检查仍为 active、PCM 节点和路由，不因一次失败修改所有 mixer。
5. 使用 `calls hangup` 后继续查通话直到为空；挂断命令接受与实际结束可能异步。确认本次采集/播放/监控子进程退出，设备 5、9、55 的 PCM status 关闭。测试前后状态不同或清理失败时如实说明。

设备系统总线存在 oFono 时，可辅助读取：

```sh
dbus-send --system --print-reply --dest=org.ofono /ril_0 org.ofono.VoiceCallManager.GetCalls
```

GetCalls 和事件可能包含号码；在内存中提取 State / DisconnectReason，避免将原始输出写入日志。`calls last-error` 在已测固件上可能仅返回 unknown，不能据此推断网络拒绝的具体原因。控制失败不要无限拨号；先查注册、错误、SIM 语音能力等新证据。

## 模块 → 手机

确认已接通并核对实际路由后，在模块内：

```sh
rm500 audio tone --card 0 --device 55 --rate 8000 --seconds 3 --frequency 660 --timeout 8s --json
```

这是已测参数；测试音约 −24 dBFS，有间歇和渐入渐出。必须取得手机端听感，写入字节数不等于远端听到。厂商程序播放配置还出现过 16 kHz；8 kHz 测试音可听不代表所有采样率与音高均已验收。

固件 tinyplay 曾在 `Error playing sample.ret:-32` 后退出 0；CLI v0.1.1 会将这种情况返回为失败。无通话时出现过该错误，接通后消失；不要绕过 CLI 仅凭 tinyplay 退出码判断成功。

## 手机 → 模块

提示用户连续说话，提示音结束后再采集，避免同时写入本地音频造成混淆：

```sh
rm500 audio probe --card 0 --device 9 --rate 8000 --seconds 10 --timeout 15s --json
```

再让用户静音，间隔后采集对照：

```sh
rm500 audio probe --card 0 --device 9 --rate 8000 --seconds 6 --timeout 10s --json
```

比较 RMS、AC RMS、峰值、非零样本、削波、采样时长和实际耗时，并关联用户确认的操作窗口。不能只看“有字节”或“非零”：空闲时曾读到重复统计值；静音时仍有强信号应记录为未解决，不猜测为缓存或网络问题。语音内容可辨识需要实时监听或受控信号等进一步证据，不能用统计量替代。

`probe` 通过匿名管道处理 PCM，只输出统计量。该固件 tinycap 在非可寻址管道中会将 WAV 头放在原始样本之后，CLI 已解析此行为；不要将全部管道数据直接按常规 WAV 文件解释，也不要为了排查而写录音文件。

## 路由与清理边界

- `/etc/audio/config/audio_pcm.xml`：设备 5 是 audiohal 管理的 modem UL/DL；设备 9 是 voice_c 采集。设备 55 是语音 PCM 播放节点。
- 已测 mixer 默认 `VOICE_CAPTURE_DOWNLINK` / `VOICE_PCM_PLAY_UPLINK_MIX`；`audio mixer` 可读取当前状态。节点与默认路由是定位线索，不自动套用到其他固件。
- 原测试未修改 QAUDMOD/mixer，也未打开 QPCMV USB 语音；不需为了复现先改这些设置。
- 无活动通话却有 PCM 长期 RUNNING 时，先检查本次子进程和厂商状态。已测固件的 `libvoice.so` 有向 `/dev/mmi.audio.ctrl` 写 `set_mode=0` 的普通模式恢复接口，但这不是通用 CLI 流程；只在确认同一固件、无无关通话/录放任务且确有残留时考虑，不能把 FIFO 写入当成每次测试的必做步骤。
- `stream pcm` 不连接这些 ALSA 节点；“两个方向分别取得音频证据”不等于完整的 RM500U 实时全双工桥，更不等于 Relay、iOS/watchOS 通话已验收。
