# R1 验收记录：本机与 RM500 只读闭环通过

日期：2026-10-24（Asia/Shanghai）。实施范围为独立 `module/airsim-agent/`。R1 已完成，主控独立复核代码、测试、构建 hash、运行 PID、四个接口及权限后验收通过；未进入 R2/R3 或云端部署。

## 最终构建与运行状态

| 项目 | 实测结果 |
| --- | --- |
| 版本 | `2.0.0-dev.r1` |
| 工具链 | Go 1.24.13；go.mod 1.24.0；仅标准库 |
| 平台 | Linux 4.14.98 / aarch64 / udx710-module |
| 设备/固件 | RM500U-CN / RM500UCNAAR01A18M2G_01.001.01.001，严格白名单 |
| SHA-256 | `b9659d09758375ba8597654339d7b76f63603c7588134b478e7a9b3481569707`（主机与设备相同） |
| 二进制 | `/mnt/data/airsim-v2/releases/b9659d09758375ba/airsim-agent` |
| 二进制大小 | 5,898,424 字节；ELF ARM64、静态链接、CGO=0 |
| 当前 PID | 6367，保持健康只读运行 |
| module_id | `3138c264-cd46-4370-86d7-0e15c0c89bc5` |
| agent_boot_id | `52aea688-0f77-443c-8b0b-310f2f0045c6` |
| 持久目录 / 运行目录 | `/mnt/data/airsim-v2/` / `/run/airsim-v2/`，0700 |
| 身份 / socket | `config/identity.json` / `control.sock`，0600 |
| 持久分区剩余 | 清理后 21,376 KiB（同一 userdata 文件系统；不是 OTA 容量保证） |

设备每次部署前重新枚举并核对目标，未硬编码 transport ID。设备操作检查显式退出码标记；上传后核对设备 SHA-256。当前部署描述保留于主机 `/tmp/airsim-r1-run.json`。

## 本机验证

- `go test -race ./...`、`go vet ./...`：最终源码通过。
- `CGO_ENABLED=0 GOOS=linux GOARCH=arm64` 构建通过；依赖清单只有标准库与本工程内部包。
- 身份测试覆盖重读不变、UUID、字段精确大小写、重复/未知/错误类型/尾随数据/超长/损坏/部分初始化/符号链接拒绝、公钥与 seed 派生不一致拒绝。
- AT 测试覆盖分片与终止、URC 分流/溢出、16 项请求队列满拒绝、4096 字节行边界、16384 字节响应限制、超时/取消后迟到响应拒绝、锁冲突、无数据/零字节读取与可关闭等待、正常 drain、异常进程 kill 保留栅栏。
- 配置/快照/接口测试覆盖未知 profile、错误端口、同固件前缀不同后缀拒绝、CSQ=99、IMS 字段解析、失败与过期快照、失步后能力失效、路径/方法白名单、活 socket/普通文件保护及正常关闭。
- `gofmt`、Python 脚本语法、shell 脚本语法与 `git diff --check` 通过。

## 最终构建的连续观察

[逐项样本](R1_EVIDENCE.json) 明确记录最终 binary、SHA-256 和 PID；共 19 次，每 10 秒采样一次，覆盖 180.221 秒。

| 指标 | 实测 |
| --- | --- |
| revision | 1 → 19，连续递增 |
| 就绪 / 时效 | 全部 ready=true、fresh；voice_ready 始终 false |
| RSS | 6768–11568 KiB；最后 11396 KiB |
| 进程 HWM | 最大 11644 KiB |
| FD / 线程 | FD [10]；线程 [7, 8] |
| 整机 MemAvailable | 91344–96340 KiB，属于该观察窗口 |
| SIM | READY |
| 信号（最后样本） | RSSI=21，BER=99，dBm=-71 |
| 注册（最后样本） | CS=0，packet=0，EPS=1 |
| IMS / 通话 | IMS 注册=1；通话数=0 |

这仅证明本轮三分钟只读观察，不证明长期内存上界或业务通话可用。HTTP 读取缓存快照，不触发额外 AT 查询。

## 生命周期、接口与清理

[最终构建生命周期证据](R1_LIFECYCLE.json)：

- 相同运行目录的第二实例被拒；相同持久目录、不同运行目录的实例也被拒，原实例继续就绪。
- PID 6124 正常 SIGTERM 后约 0.095 秒退出，进程/设备 FD 消失，socket 移除，未残留在途栅栏；重启 PID 6177，module_id 不变、boot_id 更新。
- 等待完整采样 revision=2 提交后，在确认无在途标记的空闲窗口，对本轮已核对的 PID 执行 SIGKILL；随后 PID 6367 成功恢复身份、锁和陈旧 socket，module_id 不变、boot_id 再次更新。
- 在途 SIGTERM drain 与在途异常 kill 留栅栏的不同语义由 fake/独立测试子进程验证；未对厂商进程注入故障。
- 正常探针退出曾回读核对原 termios 恢复。**SIGKILL 无法执行恢复代码，不宣称它恢复了原终端设置。** 后续启动重新读取并按已批准参数配置端口。
- 四个 GET 接口均成功；healthz/readyz 为 200。POST/HEAD healthz 为 405，未授权路径 `/api/at` 为 404。未知 profile 进程启动被拒。
- 当前进程仅监听 Unix socket；持有 `/dev/smd1`、rdev=130049 锁和两份实例锁。设备无辅助测试进程，旧诊断二进制和探针均已清理；只保留当前 release 与身份/锁/诊断运行文件。

## 已解决的实机阻塞与历史证据

早期构建在原端口设置下 ATI 错误终止。按主控裁决加入 O_NOCTTY；实测 TCGETS 支持，保存原 termios 后设置 raw 8N1 115200，使 CR 结尾 ATI 查询成功且型号精确匹配。随后发现 CGMR 返回包含子版本的完整产品版本；主控冻结完整白名单后通过，不采用前缀包含或任意后缀匹配，也未改用 CRLF。

身份字段大小写加固前的构建 `78b3a202b4256679c5b4b4c28a241b364e3ca69756b8e6b3a7e58be84636d336` 曾完成独立的三分钟观察及生命周期测试，完整记录保留在 [加固前证据](R1_PRE_HARDENING.json)，其已停止的 PID 为 5600。该旧记录未归因到最终构建；最终构建已重新完成上述全部实机步骤。

## 边界与后续

本轮未修改 v1 Agent/CLI/service/iOS，不调用或包装 RM500 CLI；保留原有工作区改动。未拨号、发短信、采集音频，未操作厂商服务、RF、USB、APN、路由、根分区、固件或自启动。

身份为 unenrolled；没有账户归属或 Relay 激活。Messaging/Audio 仍为 unknown/unavailable/not_implemented。无永久安装、TLS/Relay/APNs、真实通话/短信/双向音频、OTA/断电回滚或 EG25/AVF 验收。后续仅在主控下达相应阶段后推进。
