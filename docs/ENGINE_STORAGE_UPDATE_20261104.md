# 网页 Engine 更新空间检查修复（2026-11-04）

用户反馈 EG25 更新 96 kbps Engine 时出现“模块空间不足；当前运行版本已保留”。模块无法接回 Mac，按用户要求直接修改网页安装器。本轮没有该模块的实时 df、文件清单或完整失败阶段，因此不能把其中某一个代码缺陷认定为本次真机报错的唯一原因。

源码提交 `20e760dac887457ee537e7fec9f75978b8327d86`，发布 `installer-storage-20261104`。11:36:30（北京时间）通过 alibabacloud-workbench-cli 的 `default` profile 发布到 `i-wz93dhbsy21quebidepg` / `airsim.eric3u.cc`。

## 修复范围

- 将安装器拥有的中断暂存文件清理提前到空间检查之前，包括当前发布目录中的 `.airsim-agent.new` 及根目录内明确列举的暂存文件；不扫描删除配置、状态、短信记录或未知文件。
- 删除非活动 Agent/helper 发布目录后执行 sync，再读取剩余空间。保留 current、audio-current 及 `/proc/<pid>/exe` 指向的仍在运行的版本。
- 根据包含安装目录的最长挂载点识别 UBIFS，不再依赖 df 的设备名称与 `/proc/mounts` 完全相同；非压缩文件系统仍检查待写入的完整大小，包含安装脚本。
- UBIFS 取消固定 1 MiB 入场门槛；每次传输按实际空闲量将最大 64 KiB 缩小到最小 4 KiB（文件尾可以更小），始终保留 512 KiB 安全余量。测试覆盖剩余 552 KiB 时能够分块完成可压缩的 64 KiB 尾部，而固定 64 KiB 旧判断会拒绝。
- 整理脚本必须返回明确成功标记。读取空间失败、中断整理或真实容量不足均停止，不将空响应或非数值当作正常空间。失败信息增加具体文件、空闲量及本次写入需求。

这不是扩容，也没有通过删除当前版本或降低安全余量强行安装。如果最终确实无法同时容纳当前 Engine 与新包，仍会清理本次暂存并保留当前版本。本轮未改变激活、启动器、init 或配对协议。

## 验证及发布

71 项网页测试、TypeScript 检查和 Vite 生产构建通过。新增测试在隔离目录运行真实清理 shell，覆盖中断残留、sync 顺序、设备别名、嵌套挂载、仍在运行的旧版本保护、身份/状态保留、未知空间和分块边界；原有双平台安装脚本与界面流程测试继续通过。此类测试不替代 UBIFS 真机写入、中途断电或冷启动验收。

生产发布先备份旧入口和 assets，再上传新的带哈希 JS，最后原子替换 index.html；旧 JS 保留供已打开的页面和回滚使用。部署脚本在源站检查失败时自动恢复旧入口。

- 网页挂载目录：`/opt/airsim-v2/releases/usb-local-20261030/web/dist`。
- 发布目录：`/opt/airsim-v2/releases/installer-storage-20261104`。
- 备份目录：`/opt/airsim-v2/backups/installer-storage-20261104`。
- 上传归档 SHA-256：`fe9b29f34762fb33c825bac72259c24682cd954bd53430539eb80368a649a1a3`。
- 新 JS：`assets/index-C9raoufR.js`；CSS 内容不变。
- 3 个当前网页资源和 23 个 Engine 文件均经过源站与公网 HTTPS 长度/SHA-256 校验；Engine 与原 `opus96-7f5e8d9-20261104` 发布完全相同。
- control、media、edge、PostgreSQL 与 cloudflared 的容器、镜像和启动时间不变；healthz、readyz 正常，源站匿名 modules 返回 401。

用户刷新网页后重新选择 EG25，再执行更新即可使用新安装逻辑。本轮未安装 EG25/RM500，未执行断电、短信或真实通话验收。App 无需更新。机器可读证据见 [发布校验](ENGINE_STORAGE_UPDATE_20261104.json)。
