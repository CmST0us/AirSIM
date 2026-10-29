# 网页设备配对与持续连接

2026-10-26。主控冻结的实现契约。网页沿用 `design/pairing-web/index.html` 的最终设计；不引入账户注册、登录、JSON 导入或服务地址填写。旧 Figma 中的账户步骤不适用本阶段。

## 范围

电脑网页通过 WebUSB/ADB 访问用户主动选择的 RM500U 或 EG25 QDC507 上现有 `airsim-agent`。只有已安装 Agent、已加入当前服务且未撤销的模块可授权手机。网页不公开模块目录，不公开管理员签发接口，不读取或导出模块私钥。未准备的模块给出明确状态；网页可安装对应平台 Engine 与 init 启动入口；管理员登记和加入服务仍使用本机 prepare/activate 流程，网页不会自动签发设备证书。

主路径：选择设备 → 核对设备 → 连接设备 → 在 AirSIM 输入连接码并核对 → 设备已连接。网页的设备名称、短标识和连接状态来自真实模块。连接码是完成手机授权所需的一步，不是账户或服务配置。网页可以使用现有公网同源 HTTPS 部署，也可本地开发；部署目标由主控确认。

服务仍保留 R4 管理员客户端；新增配对客户端只可访问一个被授权模块，不能继承相同内部 `user_id` 的全部模块。`user_id` 是现有内部归属字段，不构成用户账户产品。跨版本、不同服务、模块的现有隔离保持。

## 设备证明

本机新增 `GET /v2/local/pairing`，返回 `{module_id,public_key_base64,profile,configured,server_id,api_origin,media_origin,connected,certificate_expires_at}`。profile 为 `rm500u-embedded` 或 `eg25-qdc507`。配置损坏、过期或未配置时不得填充成功的服务信息。此接口仅通过原 0600 Unix socket 提供。

本机新增 `POST /v2/local/pairing/authorize`，严格字段 `{request_id,server_id,module_id,nonce,expires_at,poll_token_hash}`。要求模块已配置、证书仍有效、server/module 精确匹配；UUID 为小写 v4；nonce 与 poll_token_hash 为 64 位小写 hex；expiry 为 UTC RFC3339，剩余时间在 `(0,305s]`。返回 `{request_id,module_id,public_key_base64,proof_base64}`。

Ed25519 签名字节为 UTF-8：

```text
airsim-v2-pairing\n
request_id\n
server_id\n
module_id\n
nonce\n
expires_at\n
poll_token_hash\n
```

每行变量使用原始值并带尾 LF。使用现有 Identity.Signer，不能签任意输入字节。服务验证签名与数据库登记公钥相同，不把 USB 选择动作本身当作服务授权；本机权限与用户持有设备构成本阶段信任边界。

## 网页 API

所有接口只接受 HTTPS JSON，禁止凭据放入 URL 或日志。普通响应 `Cache-Control: no-store`，body 最大 16 KiB。配对有效期五分钟，过期不能续为已授权；已完成结果仍可查询。浏览器先生成 request_id 和随机 32-byte hex poll_token，存入本标签 sessionStorage 后开始请求，以便断线/刷新查询原操作；完成或取消后清理秘密。界面不显示这些字段。

1. `POST /v2/pairing/challenges`：`{request_id,module_id,poll_token,replace_existing?}`。已登记、未撤销、有效证书且没有在用手机授权的模块返回 `{request_id,module_id,server_id,nonce,expires_at,replace_existing:false}`。服务持久化 nonce、期限、替换意图及 poll_token 的 hash。相同 ID/模块/token/替换意图精确重试返回同一挑战；不同内容 409。已经有在用手机授权且未请求替换时返回 409 `module_already_paired`。持有模块的用户在网页确认重置后可带 `replace_existing:true` 创建挑战；此时服务仍不撤销旧手机。不能覆盖已有 pending。每模块最多八个未过期挑战，全局最多128个；新建请求每来源地址每分钟最多八次，来源取受控入口而非任意用户头。过期记录不占 pending 数量。

2. `POST /v2/pairing/{request_id}/approve`：Bearer poll_token，body `{public_key_base64,proof_base64}`。验证以上证明、模块公钥/未撤销/证书期限，设置状态 `awaiting_phone`，生成随机八位十进制连接码（保留前导零）。连接码与本事务同期限；不签发 App 凭据。重复同一证明返回同一结果，不生成第二个连接码。code lookup 使用 hash；如为返回同一结果而保留明文响应，使用 AES-GCM 加密，密钥由现有 HMAC 根通过 HMAC-SHA256、固定域 `airsim-v2-pairing-code` 派生，与命令摘要用途区分。已确认事务不再返回连接码。

3. `GET /v2/pairing/{request_id}`：Bearer poll_token，返回 `{request_id,module_id,state,expires_at,code,online}`。state 为 `awaiting_device/awaiting_phone/connected/expired/cancelled`，code 仅在 awaiting_phone 返回，其余为空字符串。online 由真实服务连接状态提供。结果未知时只读本接口，不重新签名、绑定、安装或制造新身份。设备失联不自动撤销已完成手机配对。

4. `DELETE /v2/pairing/{request_id}`：Bearer poll_token。未兑换的事务设 cancelled；已完成返回当前 connected，不撤销已经添加的手机、不解除模块绑定。重试幂等。

响应中不包含管理员凭据、短信、号码、模块私钥。服务在每次 approve/status/claim 复核模块撤销与服务身份。未知 request/token 统一无访问权。限流失败 429，过期 410，内容冲突/已被另一安装实例使用 409。

## App 添加设备

原 v2 首次连接和设置增加“添加设备”入口，输入八位连接码；保留原五标签、v1/v2 选择和管理员导入能力的原有兼容性。正常配对流程没有文件、地址和协议字段。服务来源取部署配置的 HTTPS origin，不从配对码中执行任意 URL。仓库使用占位部署配置；本机签名/部署配置指定现有服务。

`POST /v2/pairing/lookup` body `{code}`：在模块有效、事务 awaiting_phone，且模块尚无在用手机授权或事务带有替换意图时，返回 `{request_id,server_id,module_id,name,short_id,online,expires_at}` 供 App 核对；不签发凭据，不消费码。名称使用当前已支持型号，short_id 为模块 ID 末八位。码查找/兑换每来源每分钟最多十次失败，限流状态有全局有界容量和超时清理。

用户确认后 `POST /v2/pairing/claim` body `{code,claim_id,client_installation_id,refresh_token}`。App 先生成两个 UUID 和随机 32-byte hex refresh_token，保存于 Keychain 的 pending 记录，再发送；不能在超时后生成新安装身份。事务创建稳定 client_installation_id，授权仅当前 module_id，保存 refresh_token 的 hash，消费连接码，返回 `{schema_version:3,api_origin,media_origin,server_id,module_id,client_installation_id,token,expires_at:null,refresh_expires_at:null,persistent_session:true}`。新配对访问凭据没有服务端期限，也不因未使用而失效；`expires_at` 和 `refresh_expires_at` 明确为 `null`。App 将原 pending refresh_token 和结果原子存入 Keychain，再激活已有 v2 runtime 并明确显示目标模块。

相同已消费码、claim_id、client_installation_id、refresh_token 可重试取回同一安装身份并重新签发无期限访问 token。任何不同 claim 返回冲突。事务对模块行加锁并再次检查在用授权；普通事务遇到已有手机返回 409 `module_already_paired`。替换事务在同一数据库事务中先撤销该模块原有手机客户端，再创建新客户端；任一步失败都会整体回滚，旧授权保留。旧手机的刷新、控制、媒体和通知授权随撤销失效。数据库以部分唯一索引保证一个模块最多一条未撤销手机客户端记录。成功后网页轮询 connected。收到响应前被取消或未知时，App 保留原 pending 供查询/重试，不显示添加成功。

## 持续会话

新配对客户端的访问 token 与 refresh token 都是可撤销、无固定期限的设备授权。服务端只检查客户端未撤销、模块未撤销、server/module 匹配；手机离线、App 长时间未启动、云端重启和设备证书续期都不会消耗授权。实际持有模块并通过本机证明重新配对的人可以替换旧手机；新手机完成 claim 后旧手机现有 token 立即失效。管理员也可单独撤销手机。

`POST /v2/client-sessions/refresh` 保留给 schema 2 旧 App。它验证同一 client_installation_id 与 refresh token、未撤销和模块授权，轮换访问 token，并返回 schema 2 的兼容响应；其中一小时和 90 天时间戳只用于让旧 App 继续按原节奏刷新，服务端仍不保存或执行该期限。新 App 识别 `persistent_session:true`，不会在正常启动或长期未使用后调用刷新。Keychain 延续首次解锁后仅本设备保护。临时 R4 管理员连接仍保持原有的一小时或显式 TTL 限制，不转换为持续设备授权。

现有 calls/reservations/media 的 client_installation_id 稳定；媒体续租查持续授权及模块范围。管理员 revoke-client 同时撤销控制、媒体、刷新和通知资格。未启用的 APNs 查询也必须服从模块范围和持续授权，不能扩大推送收件范围。

## 发布与验证

服务端当前 schema 为 6：schema 3 增加模块范围配对，schema 4 将未撤销的配对设备授权升级为持续会话，schema 5 移除持续授权期限并强制一个模块只有一台在用手机，schema 6 持久化模块持有者发起的替换意图。迁移保留每个模块最新的一条未撤销手机记录，撤销较早的重复记录，并清除持续授权期限；管理员兼容客户端不受该手机唯一索引约束。CallKit profile 暴露 `device_pairing:true,client_session_refresh:true`；`interactive_login:false,apns:false` 保持。Agent 接受原 R4.1 与 CallKit profile 的既有规则保持，配对能力不改变通话媒体协议。配对签名的固定域为 `airsim-v2-pairing`，服务端与 Agent 必须同步部署。生产升级包含已提交的 schema 2 至 6，但不启用 APNs。

网页由现有443入口同源静态提供；设备 mTLS 子域名、控制/媒体路径保持。CSP 仅允许本站脚本/样式/连接，WebUSB 权限仅本站；不引入任意脚本执行、终端或文件浏览器。通过 ADB localfilesystem socket 发送有限 HTTP 方法/路径，正文大小/响应时限有界；只对用户选择的设备操作。

按里程碑提交：网页及适配器、Agent 证明、服务配对与续期、App 添加与刷新、实机及部署记录。测试覆盖错误签名/服务、临时挑战过期/撤销、模块持有者重置确认、替换事务回滚、旧手机撤销、重复与丢响应、不同安装抢兑、一模块一手机唯一性、模块隔离、长期未使用后无需刷新、schema 2 刷新兼容、刷新前后稳定客户端/媒体授权、网页刷新恢复与拔线、窄屏/键盘。真实 RM500 验证网页选择→模块证明→App 确认→云端状态；不发起电话短信或音质测试。
