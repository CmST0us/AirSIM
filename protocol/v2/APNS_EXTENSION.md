# v2 APNs 推送扩展（未启用）

服务端预备实现为 `411bf38`，未部署到生产。此扩展不属于 [R7 原视图与 CallKit](R7.md) 的交付或验收条件。启用前需要单独安排客户端实现、部署与真机验证。

## 协议

ECS discovery profile 为 `airsim-v2-r7`，保留现有字段；`apns` 仅在 provider 完整配置时为 true。新 App 接受 `airsim-v2-r4.1`（无推送）和 `airsim-v2-r7`，继续拒绝未知协议。旧 R5/R6 App 不用于新的推送验收。

认证仍用现有客户端 Bearer；客户端 ID 只能从认证结果取得。`PUT /v2/push/registration` 接收严格 JSON：`registration_id`（UUID）、`module_id`（UUID）、`bundle_id`、`environment`（sandbox/production）、`voip_token`、`alert_token`（可为空字符串）。token 为 32–256 字节的十六进制表示，不限定为 32 字节。服务器校验模块归属、配置允许的主 Bundle ID 和环境。每个安装实例只有一条注册，订阅用户显式选择的单个模块。成功返回 200：`server_id`、`client_installation_id`、`registration_id`、`module_id`、`bundle_id`、`environment`；不回显 token。

`DELETE /v2/push/registration` 携带严格 JSON `registration_id`，仅删除当前安装实例匹配的注册，幂等返回 204。换模块/版本/服务前先注销旧注册，遇到网络失败保留待注销状态并阻止切换，401/已过期视为服务端不再有有效订阅。token 更新复用当前 registration ID；订阅域变化生成新 ID。请求串行化，迟到回调不能修改新注册。

VoIP payload 字段：`aps: {"content-available": 1}`、`protocol_version: 2`、`event: "incoming_call"`、`server_id`、`client_installation_id`、`registration_id`、`module_id`、`connection_epoch`、`agent_boot_id`、`backend_epoch`、`call_id`、`call_uuid`、`expires_at`（UTC RFC3339）及 `number`。来自已认证设备的在线且新鲜快照，呼叫必须为 incoming/ringing、方向 incoming。有效期为生成后 30 秒，APNs expiration=0、priority=10、push-type=voip、topic=`<bundle_id>.voip`。CallKit UUID 按模块/boot/backend/call 持久化，设备重连不生成第二个来电身份。发送前再次确认呼叫仍有效，网络发送不持有控制锁。

推送注册、通话 UUID 和投递去重落 PostgreSQL。成功投递按 registration/模块/boot/backend/call 去重；服务重启和重复快照不重复响铃。暂时错误最多短时重试两次，每次重新核对当前呼叫和客户端有效期；已结束、离线、过期或撤销立即停止。APNs 失效 token 响应只清除对应旧 token，不能清除刚更新的注册。数量按现有客户端限额约束；过期投递元数据定期清理。

普通短信通知使用相同注册的 alert token，push-type=alert、topic=主 Bundle ID，显示固定“收到一条新短信，打开 AirSIM 查看”，payload 带上述身份域及 `event: "incoming_sms"`、`message_id`，不携带短信正文。仅对注册后新收到的 incoming 消息推送，按域/message ID 去重。点击通知获取当前短信后进入原会话；迟到的其他域通知不自动切换服务或模块。

APNs provider 在 control 内实现，使用 ES256 JWT、HTTP/2、受限文件密钥和有限超时；增加仅出站的 Compose 网络，不暴露 control 端口。配置名为 `APNS_KEY_ID`、`APNS_TEAM_ID`、`APNS_BUNDLE_ID`、`APNS_KEY_FILE`；全部为空时关闭推送，部分配置或非法密钥启动报错。APNs 私钥不进入镜像或仓库。增量数据库迁移保留现有身份、命令、模块和媒体数据。

管理员 `issue-client` 增加 `--client-ttl`，默认一小时，可显式设置 1 小时至 30 天；仍可随时撤销。App 导入上限调整为 30 天加五分钟时钟容差，并在原设置显示有效期。没有自动续期或交互登录；到期明确要求重新导入。后台接听需要 Keychain `AfterFirstUnlockThisDeviceOnly`；v2 控制状态文件使用首次解锁后可读保护，重启未首次解锁时及时结束不可处理的系统来电，不生成未经核对的控制操作。

后台来电处理仅允许匹配的持久化注册。及时上报 CallKit 后，给来电核对一个有界后台任务，使用原 HTTPS 身份验证、目录和快照；拿到当前绑定后才能接听/拒接/挂断。正常系统通话期间仅保留 snapshot 轮询与所属媒体，短信/目录轮询暂停。无系统通话时停止后台轮询。CallKit `didActivate` 后才启动真实音频，`didDeactivate` 暂停音频；不擅自争用系统 AudioSession。远端结束后关闭媒体和系统通话；provider reset 对已拥有通话提交一次定向挂断，未知结果按原收据恢复。

R7 不实现 Watch v2；相关旧入口在 v2 下明确不可用。短信通知和 PushKit 注册的真机权限/签名验收与模拟器测试分别记录。


Apple 依据：[VoIP 通知处理](https://developer.apple.com/documentation/pushkit/responding-to-voip-notifications-from-pushkit)、[APNs 请求](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)。
