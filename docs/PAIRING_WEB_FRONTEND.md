# 首次设备连接网页

## 页面层

实现目录：[service/airsim/web](../service/airsim/web/README.md)。视觉基准：[reference.png](../service/airsim/web/tests/visual/reference.png)。沿用系统字体、`#f5f5f7` 背景、蓝色主按钮、居中内容区与圆角设备条目。用户文案不包含账户、配置文件、服务器地址或协议版本。

页面只显示真实适配器返回的设备，流程为选择设备、核对名称与短标识、点击连接、等待结果。生产入口不包含预览工具、示例设备或自动成功计时器。

## 适配器接入点

[adapter.ts](../service/airsim/web/src/adapter.ts) 是生产装配入口，当前装配 [WebUSB/ADB 适配器](../service/airsim/web/src/transport/webusb.ts)。适配器通过系统设备选择器连接用户明确选择的模块，在设备本机 0600 Unix socket 上完成新鲜 Ed25519 证明，再通过同源 `/v2/pairing` 接口取得八位连接码。页面状态与 DOM 视图不依赖 USB 类或服务器响应格式。

[pairing.ts](../service/airsim/web/src/pairing.ts) 是页面适配器接口；线上行为由 [配对契约](../protocol/v2/PAIRING.md) 定义：

| 方法 | 页面用途与约束 |
| --- | --- |
| `listGrantedDevices(signal)` | 读取已授权设备；不得弹出选择器或进行网络发现 |
| `requestDevice(signal)` | 用户点击触发；必须在第一个异步等待前调用系统选择器 |
| `inspect(device, signal)` | 返回经设备核实的名称、短标识与适配器设备标识 |
| `connect(operation, signal)` | 显式确认后执行；相同操作标识不得产生第二次写入 |
| `status(operation, signal)` | 只查指定操作；用于等待、未知结果、未联网状态 |
| `disconnect(device)` | 释放本地句柄，不解除配对、不清空设备 |

`Device` 含不透明 `id`、显示名称 `name`、`shortId`。`Operation` 含一次生成的 `id` 和设备显示信息。`ConnectionResult` 包含 `pending`、`awaiting_phone`、`expired`、`cancelled`、`connected`（含 `online`）或明确的 `failed`。适配器不能确定操作结果时应拒绝 Promise，不能返回 `failed` 允许新操作。

预连接错误使用 `TransportFailure`：`cancelled`、`busy`、`disconnected`、`unsupported`、`failed`、`unknown`。连接写入开始后的任何异常都保留原操作，进入结果未知；不使用异常文本作为用户文案，不回显凭据。

## 恢复与生命周期

- 状态先切换为处理中，再调用异步操作；重复点击不创建第二次选择、连接或查询。
- 查询中、等待中、结果未知不提供新连接按钮。
- 写入开始前将操作标识与设备显示信息保存到当前标签页的 sessionStorage；一次性轮询秘密由传输层单独保存在 sessionStorage，视图不读取。保存失败则停止写入。
- 刷新恢复为结果未知，只查询原操作。明确结束后清除恢复记录。
- 页面关闭中止等待，释放设备句柄。旧异步响应不能更新已销毁视图。
- 页面从浏览器往返缓存恢复时重新加载，通过恢复记录查询原操作。
- 手机显示电脑连接说明。桌面需要安全上下文和 WebUSB 能力。缺少适配器时停止在不可用页面，不回退到测试实现。

## 验证记录

2026-10-27：25 项 Vitest 测试通过；TypeScript 检查和 Vite 生产构建通过。覆盖同步选择器调用、重复点击、取消选择、设备占用/拔线/不支持、八位连接码、未知结果查询、刷新恢复、持久化失败、迟到响应、设备句柄释放、纯文本渲染、焦点迁移与本机 HTTP 分块响应读取。

内置浏览器使用测试注入，检查 1440、960、390、320 CSS 像素宽度；各宽度的 `scrollWidth` 等于 `clientWidth`。检查确认、等待、连接失败、结果未知、完成、完成但未联网、手机说明状态。Enter 选择与确认、Tab 到主按钮、Escape 关闭帮助并返回触发控件均通过；控制台无错误或警告。

视觉比对点：背景色、系统字体、标题字号、540px 内容宽度、设备条目圆角、蓝色按钮。相对设计稿的限定差异：删除预览页脚，初始设备来自适配器，核对文案不承诺未经验证的通话/短信能力，增加真实错误与恢复状态。

## 生产边界

页面通过现有 443 API 域名同源提供。WebUSB 只支持安全上下文中的桌面 Chromium；移动端只显示转到电脑的说明。真实系统 USB 选择器、RM500 物理配对、刷新恢复及生产 ECS 交互仍需实机验收。
