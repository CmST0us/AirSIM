# EG25 短号短信编码修复

2026-11-02 14:35（北京时间），通过 Workbench 发布 `sms-pdu-20261102` 到 `airsim.eric3u.cc`，仅更新网页 EG25 Agent 和清单。云端 control、媒体、edge、数据库及 RM500 包不变。用户自行更新模块，本轮没有替用户发送短信或操作实体模块。

用户反馈 6 位收件人显示“未发送，草稿已保留”。脱敏查询发现 14:25、14:28 的 `sms.send` 收据为 `failed/backend_rejected`，说明请求已进入 Agent 发送后端，而非被云端号码长度校验拒绝。未读取号码或短信正文；该结果码本身不能区分本地编码失败与具体基带错误。

## 已修复问题

1. `sms.To` 使用的 `tpdu.FromNumber` 无论输入有无 `+`，都会设置国际号码类型。EG25 现在仅对显式 `+` 使用 `0x91`；不带 `+` 的短号和本地号码使用 `0x81`，保留前导零和全部号码数字。参见 [依赖库源码](https://github.com/warthog618/sms/blob/v0.3.0/encoding/tpdu/address.go)。
2. `sms.AsUCS2` 要求传入 UTF-16BE 字节，原代码却直接传入 UTF-8。现先调用 `ucs2.Encode` 正确编码，再生成 SMS-SUBMIT。原代码会导致部分正文（包括单个 ASCII 数字）编码失败，或成功发送错误文本。参见 [编码接口要求](https://github.com/warthog618/sms/blob/v0.3.0/encode.go)。

修复位于 `module/airsim-agent/internal/platform/eg25/sms.go`，回归测试位于同目录 `sms_test.go`。仍限定单条短信、最多 70 个 UTF-16 码元；发送错误和结果未知继续区分，不自动重发。

## 验证与使用

使用旧源码 overlay 运行新增测试可复现故障；修复后 Agent 全量 `go test -race ./...` 和 `go vet ./...` 通过。30 组发送数据测试核对真实传给 AT 层的 PDU，覆盖短号、前导零、奇数位号码、本地及国际长号码、单个数字、中英文、emoji、70 个中文字符和 35 个 emoji；同时核对 SMSC 前缀、CMGS 长度、收件地址类型、UCS-2 字节及文本还原。超长拒绝和失败不重发测试也通过。

源站 HTTPS 验证 26 个文件，公网再次下载 EG25 Agent 核对哈希。四个服务容器未重启、健康检查正常。新版 Agent SHA-256：`a52867a0c963a59805c99ade4ea32b449fe6974e605c4c002b1693af8081f6e2`。部署记录见 [JSON](EG25_SMS_DEPLOYMENT_20261102.json)。

刷新 [网页安装器](https://airsim.eric3u.cc/)，对 EG25 再执行一次“更新并启用”。App 使用已发布的 SkySIM `0.9.6 (81)`，无需为本次模块编码修复重新发版。Engine 文字版本仍为 `2.0.0-dev.webrtc`，安装器按哈希识别此次更新。用户随后在本会话反馈“可以了”，确认此次短号短信问题已恢复。助手未读取收件内容或执行真实发送，用户确认与上述单元测试、部署验证分别记录。

回滚静态包的备份为 `/opt/airsim-v2/backups/sms-pdu-20261102/web`，发布副本为 `/opt/airsim-v2/releases/sms-pdu-20261102/web`。本次没有更改模块启动器、设备身份、配对或服务端数据库。
