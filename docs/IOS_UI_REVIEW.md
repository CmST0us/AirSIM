# AirSIM iOS 界面审查

## 结论

当前界面评级：Good。保留五个主入口和熟人联系优先的布局，以号卡名称明确每次通信使用的线路。浅色留白、深色纯净表面、中文标题和克制的蓝绿操作色形成统一识别。

范围覆盖当前 v2 App 的通话首页、搜索与记录详情、联系人列表与详情、联系人编辑、短信列表与会话、新信息与收件人选择、拨号与号卡选择、号卡列表与详情、命名与配对、呼入／呼出／通话中、DTMF、空状态、不可用状态及错误提示。

## 色彩、字体与布局

对比度由资源中的 sRGB 值计算。数字表示文字或图标对所在表面的亮度比。

| 角色 | 浅色 | 深色 | 对比度 |
| --- | --- | --- | --- |
| 主表面 | `#FFFFFF` | `#000000` | — |
| 分组表面 | `#F2F2F7` | `#2C2C2E` | — |
| 正文 | `#000000` | `#F2F2F7` | 主表面 21.00 / 18.82 |
| 次要文字 | `#626268` | `#A5A5AD` | 分组表面 5.43 / 5.70 |
| 文字操作 | `#0066CC` | `#69ACFF` | 分组表面 4.99 / 5.94 |
| 蓝色实心操作／发出短信 | `#0066CC` | `#0066CC` | 白字 5.57 |

绿色实心呼叫操作 `#197B3B` 配白字为 5.33；状态文字使用独立的浅色 `#137B36`／深色 `#78D995`。错误文字为 `#B92320`／`#FF938A`，在分组表面为 5.66／6.50。前景颜色提供 Increase Contrast 变体。连接、失败和选中状态同时使用文字、符号或轮廓表达。

中文内容沿用 Noto Sans SC，标题 30–32 pt、正文与短信 17 pt、辅助信息 12–15 pt；全部按语义文本样式缩放。系统导航、表单和菜单使用系统字体。装饰头像字母限制缩放，完整姓名仍由正文呈现。

窄窗口按列表进入详情；宽窗口以原生双栏并列列表和详情。辅助功能字号下减少横排信息，内容可增高、换行和滚动。主要点击区域至少 44 pt。五标签位置随系统适配，详情保留标签栏。

```text
窄窗口                     宽窗口
[标题／搜索／操作]          [列表／搜索] | [所选详情]
[列表或所选详情]            [列表项目]   | [通信操作]
[五个主标签]                [系统标签栏随窗口排列]
```

动效只承担状态变化：通话呈现与错误提示使用短过渡，减少动态效果时改为淡入淡出；短信滚动与 DTMF 按压遵守减少动态效果。减少透明度时，错误提示使用不透明系统表面。

## 已修复的问题

| 等级 | 问题与调整 | 实现 |
| --- | --- | --- |
| Critical | 小字号链接原有浅色对比度 3.52，短信气泡白字 4.02；调整为合格前景与独立实心背景。固定黑色图标改为语义模板渲染。 | `A1DesignSystem.swift`、颜色资源、`RootView.swift` |
| Critical | 固定行高和横排信息在辅助字号下挤压；标题、联系人、时间戳、号卡设置与操作区允许增高、换行或纵排。 | `A1CallsView.swift`、`A1ContactsViews.swift`、`A1CardsView.swift`、`A1MessagesViews.swift` |
| Critical | 拨号号卡浮层固定高度，新增联系人触控高度仅 22 pt；改用原生列表弹层并扩大点击区域。 | `A1DialPadView.swift` |
| Critical | 短窗口通话和 DTMF 内容缺乏滚动空间；允许滚动，并在辅助字号下重排通话控制。短信短窗口输入保留一行，说明进入滚动内容。 | `PhoneViews.swift`、`A1MessagesViews.swift` |
| High | 联系人和短信详情隐藏主标签，自定义返回缺少原生导航行为；联系人、短信、号卡详情改用系统返回，保留五个主标签。 | 三类详情视图 |
| High | 宽屏号卡使用手工并排布局；改为 `NavigationSplitView`，保持所选项目轮廓和辅助功能选中状态。 | `A1CardsView.swift` |
| High | 短信内容与导航容器的宽窄规则不一致，iPad 竖屏切换标签可能出现空白；统一窗口规则，窄窗口使用单栏返回，宽窗口并列显示，折叠前后保留会话与草稿。 | `A1MessagesViews.swift` |
| Medium | 错误提示限三行、五秒自动消失、关闭区域 28 pt；改为完整文字、手动关闭和 44 pt 控件，并支持减少透明度。 | `RootView.swift` |
| Medium | 配对查询和添加共用进度描述，请求时仍可修改输入；区分进度并冻结当次输入，名称表单保留字段标签。 | `CloudV2View.swift` |
| Medium | 新信息重复出现两个发送入口；保留输入框旁的发送按钮。搜索增加清除操作。 | 短信与联系人视图 |
| Medium | iPad 竖屏系统标签栏占用标题区域；短信内容区显示联系人名称，保持会话身份可见。 | `A1MessagesViews.swift` |

## 设计依据

审查读取了 apple-design 的本地 HIG 文档及代码审查指南。对应原文：

- `accessibility.md › Mobility`：“Offer sufficiently sized controls.” iOS／iPadOS 默认 44×44 pt。[Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- `typography.md › Supporting Dynamic Type`：“Consider adjusting your layout at large font sizes.” [Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
- `color.md › Inclusive color`：“Avoid relying solely on color”。[Color](https://developer.apple.com/design/human-interface-guidelines/color)
- `dark-mode.md › Dark Mode colors`：“Embrace colors that adapt to the current appearance.” [Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode)
- `tab-bars.md › Best practices`：“Make sure the tab bar is visible when people navigate to different sections of your app.” [Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars)
- `toolbars.md › Navigation`：“Use the standard Back and Close buttons.” [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)
- `designing-for-iphone-duo.md › Dynamic layouts`：“Prefer a layout container that adapts automatically”。[Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)
- `split-views.md › Best practices`：“persistently highlight the current selection”。[Split views](https://developer.apple.com/design/human-interface-guidelines/split-views)
- `motion.md › Best practices`：“Make motion optional.” [Motion](https://developer.apple.com/design/human-interface-guidelines/motion)

外观偏好保留用户已有设置；默认跟随系统。该取舍保留既有个性化能力，明暗模式仍共享相同导航和操作。

## 验证与边界

采用虚构联系人、号码和短信进行界面自动化与截图核对。覆盖五标签、普通和辅助字号、明暗配色、联系人编辑与短信跳转、拨号临时号卡选择、三种通话状态、DTMF、iPad 横竖屏双栏，以及 Duo 内外屏。

| 环境 | 验证内容 | 结果 |
| --- | --- | --- |
| iPhone 18 Pro 模拟器 | 最大辅助字号与深色页面、表单、拨号长按与选号、跨标签草稿 | 通过 |
| iPad mini 模拟器 | 横竖屏、五标签、详情与命名、返回原会话后的草稿 | 通过 |
| iPhone Duo 模拟器 | 展开与合屏、会话选择、系统返回与草稿保留 | 通过 |
| iPad mini 真机 | `com.eric3u.airsim2` 签名构建、更新安装与启动 | 通过 |

Watch v2 与 v2 Live Activity 当前未启用；旧版不可达界面不计入本次 App 审查。界面验证不代表真实运营商通话、短信收发或 USB 链路验收。VoiceOver 朗读顺序、Switch Control 和全部系统辅助功能组合尚未逐项真机验收。
