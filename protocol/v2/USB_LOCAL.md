# v2 USB 本地接入

状态：实现契约。App 固定 v2；USB 是同一模块的另一条传输。首次授权及续期经过 ECS，已有有效授权可在 ECS 不可达时使用。无 v1 回退。

## 授权

App 以现有 ECS 会话调用 `POST /v2/modules/{module_id}/usb-authorization`，空 JSON 对象。ECS 复用模块归属、客户端有效性和 module scope 校验；模块须在线且广告 `usb_local`。ECS 在当前设备 mTLS 控制连接发送 `usb_authorize`：

```json
{"request_id":"UUID","client_installation_id":"UUID","expires_at":"UTC RFC3339，当前时间加24小时"}
```

Agent 验证字段、UUID、UTC 期限（未来且不超过24小时加5秒），返回 `usb_authorization`：

```json
{"request_id":"UUID","status_code":200,"authorization":{"server_id":"UUID","module_id":"UUID","client_installation_id":"UUID","api_origin":"https://192.168.225.1:8577","certificate_der_base64":"BASE64","token":"64 lowercase hex","expires_at":"UTC RFC3339"}}
```

不可用返回 `status_code:503, authorization:null`；无效请求终止控制连接。ECS 请求等待最多4秒，仅接受同一 peer/connection_epoch、request_id 与 client 的响应；校验身份、期限、私网 HTTPS origin、非空证书及 token 后原样返回 App，超时503。帧上限16KiB。响应及日志不得记录 token。请求断开清理等待项；模块断线取消等待，不转发到新连接。ECS 不存储本地 token。已有客户端撤销或换绑时（数据库撤销扫描最多5秒），向当前peer发送 `usb_revoke {client_installation_id}`，Agent持久清除该客户端授权并停止其媒体；离线撤销以授权到期为界。

Agent hello 增加可选布尔 `usb_local`；仅本地 TLS 服务配置有效时为 true。旧设备字段缺失视为 false；不改变 discovery profile，不让不支持 USB 的设备阻塞云端。

本地 TLS 使用模块生成并持久保存的独立证书/密钥，0600，证书使用P-256 ECDSA，有效期十年；不是 ECS mTLS 客户端证书。首次信任通过已经验证的 ECS + mTLS 传递完整 DER 证书。App 精确比较叶证书，证书不匹配拒绝连接。App 将证书、地址、授权保存 Keychain，按 server/module/client 隔离，不把 ECS bearer 发给模块。授权有24小时期限，剩余不足一小时时在联网状态自动续期；更新失败不删除尚有效授权。

Agent 持久保存每个已授权客户端的随机 token 与期限，续期沿用 token、更新期限；每个模块只保留当前一个客户端授权，换绑时替换原授权。模块重启保留未过期授权。撤销无法立即到达完全离线模块，最迟授权到期失效；重配/换主人必须清除原授权。

## 网络和路由

Agent 新增 `--usb-listen`，显式指定 USB 私网 IPv4:端口，EG25 部署值 `192.168.225.1:8577`。监听该地址，不监听0.0.0.0/蜂窝公网，不暴露 Unix 管理 API。IP 就绪后启动；接口地址消失时关闭监听及所有本地媒体；地址变化重新连接前重新取得授权，不以 IP 充当模块身份。App 对本地控制和媒体绑定对应 USB 网卡；找不到接口则视为 USB 不可达，不向 Wi-Fi/VPN 发本地凭据。

EG25 启动器在桥地址就绪后提供 USB DHCP（`192.168.225.10–30/24`），不下发 IPv4 默认路由或 DNS，不改动厂商 IPv6 配置。已有 DHCP 服务保持运行；USB 网络等待及服务恢复不阻塞 Agent 云端连接。

App 在空闲时优先使用已授权且身份验证通过的 USB。首次控制提交前固定路由，command pending、现有通话、媒体使用同一路由及 connection_epoch。USB 故障仅显示断开并查询原路由结果，禁止向 ECS 重发相同副作用。无活动业务才可重新选路。

## 本地业务接口

所有接口除媒体握手外使用 `Authorization: Bearer <本地token>`；服务端检查期限与客户端。请求必须携带 `X-AirSIM-Timestamp`（Unix秒）、`X-AirSIM-Nonce`（32随机字节lowercase hex）、`X-AirSIM-Signature`（HMAC-SHA256 lowercase hex）。HMAC key为本地token解码后的32字节，签名输入为 `timestamp + "\n" + nonce + "\n" + method + "\n" + path_and_query + "\n" + body原始字节`。时间窗±30秒，nonce至少保留61秒且拒绝重用。控制 body 上限8192字节，响应有界，拒绝重定向。仅支持下列白名单，响应沿用现有 v2 App 模型：

- `GET /v2/modules`：仅当前模块，online 表示本地控制就绪，connection_epoch 为Agent本次本地运行实例 UUID。
- `GET /v2/modules/{id}/snapshot`：模块实际状态，freshness/boot/backend 与云端一致，不取 ECS 在线状态。
- `GET /v2/modules/{id}/messages`：模块短信视图及缺口标识。
- `POST /v2/modules/{id}/commands`：原 `connection_epoch,command` envelope，原类型化动作和去重记录。返回 `command_id,state,generation,receipt`。
- `GET /v2/modules/{id}/commands/{id}`：仅同一本地授权客户端创建的命令结果。
- `POST /v2/modules/{id}/calls/{call_id}/media-sessions` 与 DELETE 对应会话：沿用现有 v2 媒体请求/响应字段。
- `WSS /v2/media`：`airsim.media.v2`，首帧 `session_id,role=client,ticket`，30秒单次票据，不在 URL 放 token。

本地不提供账户、安装、配对授权、云端配置、升级、任意AT或shell接口。

## 所有权和媒体

Agent 是本地和云端通话仲裁者。每次 dial/answer 取得客户端、transport、generation 的保留权；控制完成后绑定实际 call_id。其他入口的 answer/hangup/DTMF/media 不能抢占已有 owner。命令结果未知时保留原归属；只在实际通话结束、明确拒绝或 boot/backend 失效时解除。命令ID绑定客户端与传输，重复请求不得重新分配 generation。

本地媒体继续使用现有 ASMP：8kHz mono S16LE、160 samples/20ms，方向1为 App 到模块，方向2为模块到 App。媒体票据绑定 module/call/client/generation/本地epoch，只有对应通话 owner 可申请。Agent 复用 media.Manager 的唯一会话、资格和 lease，经 Unix 媒体通道连接 helper；与云端使用同一有界节拍桥。paired 后才流式发送；拔线、超时、helper退出、通话结束立即回收。PCM不落盘。

## 验证边界

契约测试覆盖错误身份、过期授权、非白名单、跨客户端命令结果、云端/本地竞争、迟到代次、重复命令及媒体票据重用；媒体测试覆盖双向ASMP和关闭释放。App 编译和单测覆盖固定证书、路由固定、离线有效授权、短信和媒体连接。真机分别验证 USB 枚举、呼入/呼出/接听/挂断、短信双向、音频双向、拔线与重插。后台/冷启动来电仍使用 APNs/PushKit；完全离线不承诺唤醒被系统挂起或终止的 App。
