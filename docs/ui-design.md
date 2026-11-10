# 微信 AI 助手（WeChat AI）— UI 设计说明

> 面向 macOS 26（Xcode 27.1 / Swift 6.4）的原生 SwiftUI 界面。本文是 UI 的现行契约：信息架构、
> 页面结构与交互、设计 token、组件边界与可访问性约定。实现位于
> `app/Sources/WeChatBot/DesignSystem/` 与 `Views/`，App 场景在 `WeChatBotApp.swift`。
>
> **发布状态（2026-11-10）**：本文描述 **4.0.1**（含 4.2.0.17 与朋友圈 / Moments）；用户安装见
> [`install.md`](install.md)，发布说明见 [`releases/4.0.1.md`](releases/4.0.1.md)。

## 1. 设计目标

1. **原生 Apple 质感**：`NavigationSplitView` + 隐藏标题栏 + Liquid Glass 卡片 + 系统材质；
   不使用 WebView、不模拟网页控件。
2. **信息密度适中**：桌面级三栏/双栏布局，列表可扫描，表单分组清晰。
3. **状态实时可见**：微信 / Hook / AI / OneBot 四个运行状态在侧边栏、总览、菜单栏保持一致。
4. **服务未接入也可用**：Core 未连接时用禁用态、加载态或「服务未连接」提示兜底，不伪造成功。
5. **可访问性优先**：语义字体、VoiceOver 标签、减少动态效果降级、深浅色完整适配。

## 2. 信息架构

主窗口左侧为自定义侧边栏，分三段共 9 个页面（首次向导为独立全屏流程，不计入侧边栏）：

| 分组 | 页面 | 职责 |
| --- | --- | --- |
| 常用 | 总览 `dashboard` | 健康状态、今日统计、快捷操作、最近活动/会话 |
| 常用 | 会话 `conversations` | 会话列表 + 聊天详情 + 手动发送 |
| 常用 | 朋友圈 `moments` | 时间线、评论/点赞、图片查看、发布；入口仅在朋友圈功能开启时显示 |
| 自动化 | 机器人 `bot` | 8 个子栏目：常规、触发、互动、名单、节奏、定时、朋友圈、语音 |
| 自动化 | AI 模型 `ai` | 多通道增删改、Keychain 密钥、连接测试、默认通道与请求策略 |
| 自动化 | 人格设定 `personas` | 人格卡片网格 + 编辑 sheet |
| 系统 | 记忆库 `memory` | 记忆卡：角色列表（含全局共享）、记忆卡、全量记录/导出、记忆设置、旧记忆导入；聊天记录清理在具体会话内 |
| 系统 | 运行日志 `logs` | 实时流、级别/来源过滤、暂停、清空、导出 |
| 系统 | 设置 `settings` | 通用/外观/通知/更新/Hook/OneBot/数据与备份（当前微信账号、已保存账号、重新检测）/关于 |

> 侧边栏顺序固定为「总览、会话、朋友圈、机器人、AI 模型、人格设定、记忆库、运行日志、设置」；
> 朋友圈入口在功能关闭时隐藏（已停留在该页时显示未开启空态）。

附加入口：

- 菜单栏图标（始终存在，无开关）：**左键开合状态面板**（含打开主窗口、快捷启停、会话 / 机器人 /
  设置直达与退出）；右键 / Control-左键不执行操作。
- 首次启动向导（4 步 sheet，可从设置 → 通用或总览「首次向导」快捷操作重新打开）；App 设置场景（⌘,）复用 `SettingsView`。

## 3. 窗口与导航

```
Window("WeChat AI", id: "main")
├─ NavigationSplitView (balanced, hiddenTitleBar)
│  ├─ SidebarView (236pt, 216–286 可调, ultraThinMaterial)
│  │  ├─ 品牌区（避开交通灯，38pt 顶部内边距）
│  │  ├─ 三段导航（常用 / 自动化 / 系统）
│  │  └─ 底部状态胶囊（机器人 + 微信/Hook/AI）+ 版本/设置
│  └─ PageRouter → 9 个页面（首次向导另计）
├─ Settings scene → SettingsView (880×640)
└─ MenuBarController：NSStatusItem + 左键 NSPopover (272pt)
```

- 侧边栏选中高亮使用系统语义色 `Color.accentColor`，行高 30pt、圆角 7pt；悬停为 4.5% 主色。
- 窗口隐藏标题栏，内容延伸到交通灯区域，侧边栏顶部预留 `Theme.titlebarInset (38pt)`；页面切换不加整页动画
  （只有侧边栏选中高亮 `.smooth(0.14)`），「减少动态效果」时高亮动画关闭。
- 会话页在主窗口内形成第三栏：侧边栏 + 会话列表（304pt）+ 聊天详情；列表始终可见、不折叠，
  再次点击当前选中的会话行或侧边栏「会话」入口会收起当前对话（见 §7「会话收起」）。

## 4. 设计 token

定义位置：`DesignSystem/Theme.swift`。

### 4.1 颜色

| Token | 值 / 语义 |
| --- | --- |
| `Theme.accent` | 微信品牌绿 `rgb(51,199,115)`，用于主按钮、选中态、气泡 |
| `Theme.accentStrong` | 深绿，用于渐变端点 |
| `Theme.info` / `success` / `warning` / `danger` / `violet` | 语义状态色 |
| `Theme.hairline` | `Color.primary.opacity(0.07)`，卡片/分隔线 |
| `PageBackground` | 系统窗口底色 + 极淡品牌绿/蓝渐变（深色模式渐变透明度略高） |
| `Color.accentColor` | 侧边栏选中与系统控件，尊重用户系统强调色 |

所有颜色使用语义 `Color`/材质，浅色/深色自动适配；不写死黑白。

### 4.2 字体

统一使用系统字体（SF Pro / 苹方），以语义字号为主，保证 Dynamic Type：

| Token / 用法 | 字体 |
| --- | --- |
| 页面标题 / 卡片标题 | `.title2.weight(.semibold)` / `.headline` · `.subheadline.weight(.semibold)` |
| 正文 / 列表主标题 / 辅助信息 | `.body` / `.callout` / `.caption`·`.caption2` |
| 数字指标 | `.title2/.largeTitle` + `.rounded` + `.monospacedDigit` |
| 日志/ID/路径 | `.caption` + `.monospaced` |

### 4.3 间距、圆角、材质

| Token | 值 |
| --- | --- |
| 侧边栏 / 会话列表宽度 | 236pt（216–286）/ 304pt |
| 页面内边距 | 24pt |
| 卡片内边距 | 18pt（紧凑卡片 12–15pt） |
| 卡片圆角 | 18pt（小卡片 12–16pt，控件 7–10pt） |
| 区块间距 | 20pt |
| 侧边栏 / 工具栏材质 | `.ultraThinMaterial` + 1pt 分隔线 |
| 卡片 | `.glassEffect(.regular.tint(accent 4.5%), in: .rect(cornerRadius: 18))` |
| 日志/设置分组 | `.regularMaterial` + `hairline` 描边 |

### 4.4 动效

- 页面切换不做整页动画（只有侧边栏选中高亮 `.smooth(0.14)`）；Toast `.snappy(0.22)` 进出、2.6s 自动消失；
  加载用系统 `ProgressView`。
- **不使用 `repeatForever` 动画**：Liquid Glass 背景采样下会持续重绘（空闲 CPU 升高）；
  「运行中」用静态光晕 + 彩色状态点表达。
- 所有动画经 `@Environment(\.accessibilityReduceMotion)` 开关。

## 5. 页面结构

### 5.1 总览

- `GlassToolbar`：问候语 + 日期；刷新、启动/停止机器人（本页唯一的启停入口）。
- 三张 `StatusCard`：微信（版本/进程）、Hook（状态/版本匹配/桥接）、AI（默认通道/模型/密钥状态）。
- `DashboardSystemVitalsCard`「设备与账户」：左栏本机电池（电量百分比/电量条/充电状态/剩余或充满时间，
  30 秒刷新）；右栏 DeepSeek 余额（总额、赠送/充值、可用状态与更新时间；启动后每 5 分钟刷新，可手动刷新）。
  未配置通道/Key 时给出去「AI 模型」入口，失败显示原因与「重试」、不伪造金额；无电池显示「未检测到电池」。
- 四张 `MetricTile`：今日收到、今日回复、失败、AI 平均延迟（`contentTransition(.numericText())`）。
- `SectionCard` 快捷操作（3 列）：安装 Hook、测试 AI、设置、首次向导、日志、记忆库；
  启停与刷新只保留在工具栏，避免同页重复入口；位于最近活动/最近会话双栏之上。
- 双栏 `SectionCard`：最近活动（日志）与最近会话（点击跳转会话页）；运行中安装 Hook 显示 `ProgressPanel`
  （onProgress 回调），未连接 OneBot 时底部显示 warning `InlineNotice`。
- **微信账号已切换提示**：`store.accountSwitchNotice` 非空时页面顶部显示
  `InlineNotice(kind: .info, title: "微信账号已切换")`，正文说明当前账号或旧数据归属；右侧「知道了」调用
  `store.dismissAccountSwitchNotice()`。运行中切号会同时停止机器人、需重新启动；提示不阻塞其它操作。

### 5.2 会话

- 左栏：标题/未读汇总、搜索、筛选 chips（全部/未读/AI 开启）、`SessionRow` 列表、连接状态 footer；
  列表始终可见、不折叠，收起对话见 §7「会话收起」。
- `SessionRow`：头像占位（首字/群组图标 + 稳定色）、标题、时间、预览、未读徽标、置顶标记；选中或进入
  页面即自动标记已读；AI 自动回复关闭时显示 `bolt.slash`（不可点击）；生成/等待发送/发送中时右上角
  相对时间改为 `ReplyMiniStatus` 阶段计时（「生成 6s」「3s 后发送」「发送中」「失败」）。
- **会话命名**：`Conversation.displayTitle` 优先级为**用户重命名 / 微信真实昵称 → 系统账号中文名 →
  可读兜底**（`群聊 · 尾号` / `微信好友 · 尾号` / `公众号 · 尾号`）。入站事件只带 wxid（消息对象不含
  昵称，通讯录是加密 SQLite），列表与详情**不显示裸 wxid / `xxx@chatroom`**，详情头部用等宽小字展示
  原始 ID。
- **会话重命名**：详情头部菜单「重命名会话…」打开 `ConversationRenameSheet`，保存写入 `conversations.title`
  （留空恢复自动名称），并同步到 AI 提示词与日志；已重命名的会话不会被后续消息里的 wxid 覆盖。旧版本
  写入的 ID 标题由 `MemoryStore.repairPlaceholderConversationTitles` 在启动时一次性清理。
- 详情头部：会话标题/类型/ID、**唯一的 AI 自动回复开关**、人格/置顶/标记已读/删除聊天菜单、实时回复
  状态徽标 `ReplyStatusBadge`（AI 生成中 · 已等待时长 / N 秒后发送 / 发送中 / 已发送 / 失败）。
- **删除聊天**：详情头部菜单「会话 → 删除聊天…」删除本机聊天（列表不提供右键删除），二次确认说明会
  删除会话、聊天记录与相关记忆（不影响微信端），确认后回到空状态。
- **清理聊天记录（会话内）**：详情头部「More（会话设置）」→「清理聊天记录…」→ `ChatCleanupSheet`；
  只清当前会话、无「全部会话」选项，只删该会话本地 `messages`（及旧 `memory_state` 游标），**不删**
  记忆卡与 `interactions` 全量记录，不影响微信端消息；确认框条数来自账号库 `messageCount` 真实总数。
- **会话工作时间**：菜单「跟随全局 / 自定义时段 / 此会话不限制」；自定义弹窗编辑星期与起止时间并随会话
  写库。详情头部常驻 `WorkingHoursBadge`（工作时段/非工作时段/不限时段），按会话覆盖优先判定、每分钟
  刷新，悬停显示来源与摘要（如「工作日 09:00–18:00」）。口径与 `RuleEngine` 一致：非工作时段不自动
  回复，手动发送不受限。
- 消息区：`DateSeparator`（超过 5 分钟插入）+ `MessageBubble`；底部锚定、新消息自动滚动。
- 气泡类型：文本、图片（`NSImage` / `AsyncImage` / 占位）、语音（时长 + 转写）、表情、文件、视频、链接、
  系统通知；发送状态：生成中（三点）、待发送、已发送、失败。
- 入站图片：先显示「图片」占位；该会话「获取图片」开启时（详情 → 菜单 →「媒体」）App 后台串行请求
  bridge（`POST /fetch_image`），成功后把本地路径写入 `mediaPath`，气泡切换为真实图片；关闭或失败时
  保留占位（不弹错，仅运行日志 debug 记录原因）。开关按会话保存，关闭后不再发起新请求；新会话/未设置
  跟随旧全局默认（开启）。
- 识图：启用「AI 模型 → 识图模型」后，识别描述以 caption 显示在图片下方（眼睛图标 + 最多 3 行，可右键
  「复制识图描述」）；未识别/未开启不显示。
- appmsg 卡片：引用回复、链接、文件、表情、聊天记录、转账、视频号统一以文本气泡展示；引用为「回复正文
  换行 `【引用 发送者：原文摘要】`」，不再出现笼统 `[链接/文件]`（历史数据启动时按同一解析器重算），
  拍一拍仍显示「… 拍了拍 …」。引用图片：气泡仍显示 `[图片]` 摘要；生成回复时按 `refermsg.svrid` 找回
  原图，在提示词末尾附加「（引用图片内容：…）」（不写库、不改气泡）。
- 输入区：多行 `TextField`、⌘↩ 发送、服务未连接时禁用并提示；AI 开关只在详情头部出现一次。
- **回复处理倒计时**（`ReplyProgressBar`，输入区上方）实时展示流水线阶段：
  - `generating`：AI 请求已发出，「已等待 N 秒」（正向计时）与通道 · 模型；
  - `waitingToSend`：拟人化随机延迟，真实「N 秒后发送」倒计时 + 收缩进度条；
  - `sending`：等待 bridge 发送回执；R3 未拿到发送句柄时显示「R3 发送句柄未就绪（微信重启后需在本机
    微信手动发一条消息）」或队列条数（App/bridge 重启会从缓存自动恢复句柄）；
  - `completed`：总用时与「已发送 N 段」，3 秒后收起；`failed`：错误原因保留，可点 × 收起（60 秒后
    自动清理）。
- 空状态：无会话 / 未选中会话（含再次点击当前会话行后收起）/ 会话无消息。

### 5.3 朋友圈

- 入口：侧边栏「常用」第三项 `moments`（位于「会话」下方），**仅当「机器人 → 朋友圈 → 启用朋友圈」打开时显示**；
  关闭时隐藏入口，若正停留在该页则显示「朋友圈功能未开启」空态并指回机器人页。快捷键 ⌘3。
- 页面重新出现：数据超过 5 分钟自动刷新一次（无数据时不重复拉取；失败保留旧列表）。
- 工具栏：`GlassToolbar` 标题「朋友圈」+ 摘要（`N 条动态 · 原生刷新 / 原生待捕获 / 被动缓存 ·
  缓存于 N 前 / 更新于 N 前`；未开启/未就绪/错误分别显示对应短句）；操作**只有一个「刷新」**
  （2026-11-10 合并：刷新本身会在时间线之后补一次 `/sns/sync`，不再单独提供「同步更新」按钮）。
  刷新按钮带 loading spinner 与无障碍文案，手动刷新时列表上方另有一行「正在读取最新动态…」轻提示；
  后台 60s 同步静默运行，不占工具栏、不闪提示；
  写操作（自动发布、评论/回复）不在工具栏，发布由自动发布排程执行、评论在动态卡片/评论区进入。本页**不提供设置按钮**。
- **同步事件无页面入口（2026-11-09）**：移除工具栏「N 条更新」按钮、状态行计数、`MomentsSyncEventsSheet`
  与「清空更新」；`syncEvents` 与 Core 合并逻辑保留，仅供内部缓存/计数合并，不提供用户可见入口。
- **Type=11 hint 无可见 UI（2026-11-09）**：Core 收到 `sns_comment_hint` 仅静默触发一次 timeline 刷新，
  不显示 banner、不做未读计数、不持久化；hint 本身不展示正文、不能直接自动回复、不写评论缓存。
  回复正文由 sns.db 只读补全，32 位 comment_id 已确认可作 reply_comment_id；P7 自动回复已真机闭环。关闭朋友圈/切号由
  Core 清除内部状态，用户无提示。
- 未就绪：分步引导卡（① 在微信「发现 → 朋友圈」停留几秒；② 回来点「重新检测」；③ 仍失败时检查微信登录/机器人运行）
  +「重新检测」+「查看捕获步骤（统一捕获弹窗）」；不再展示长段落；程序不控制/不打开微信窗口。
  微信或 bridge 重启后需要重新打开一次朋友圈。**v2.1 起**：页面可见且未就绪时每 5 秒轻量检测一次
  `/sns/status`（最多约 1 分钟），用户按提示打开朋友圈后页面自动恢复。
- 列表：`ScrollView` + `LazyVStack`；`MomentCard` 展示作者（昵称/首字头像、自己动态加「我」徽标）、相对时间
  （悬停显示绝对时间）、正文（固定行距/截断提示）、1–9 图网格（缩略图）。点赞/评论/写评论/展开评论收进带分隔的
  胶囊操作条；评论预览显示「N 条评论 + 前两条 + 查看全部」。展开卡片时调 `/sns/detail` 补齐评论；支持
  「加载更多（已显示 N 条）/ 没有更多」。图片块 hover 有描边/轻微放大，加载/失败态可点按重试。
- 媒体缓存：缩略图/原图内存缓存上限 240 条（按加载顺序淘汰最旧，图片与本地路径一起清）；失败记录上限 400 条。
- 展开评论（v2.1）：主动补齐不可用（Mac UI 不触发 0xd2，objectdetail 路线放弃）；timeline 已用 sns.db 只读补评论（真机端到端验证，P7 自动回复闭环）；被动模式/失败时保留时间线缓存里的评论与点赞，展示「评论可能不完整」
  的 info 提示（不再显示 danger 错误 + 重试按钮）；`source=cache` 与本地 diff 事件仅用于内部合并，
  不提供独立的页面入口。
- 评论 / 回复（v3.6，P4；2026-11-09 UI 打磨）：动态卡片底部与「更多」菜单提供「写评论」；展开后的每条评论
  右侧有回复图标。输入面板 `MomentCommentSheet`（560pt）展示目标动态（自己徽标/图片/视频/仅自己可见）、
  被回复评论引用条、正文进度条与计数（≤1000 字，900 字 warning）+ 二次确认；`comment_ready != true` 时显示
  「评论通道未就绪」卡片（3 步手动评论/点赞说明 +「重新检测」+「去捕获 / 查看步骤」，后者先收起评论面板再打开
  统一捕获弹窗），写开关关闭时显示设置路径；被动缓存/详情失败时评论区提供「重新加载评论」；发送成功后关闭面板并
  toast「评论已发送/回复已发送」，失败保留面板与错误文案。
  评论行仍展示「回复 X」（`reply_to_name`），bridge 未返回新评论时 App 用本地回显，不伪造 `comment_id`。
- 图片（2026-11-09 修复/优化）：
  - 单图：按真实比例整图展示（不再用 0.66–3.0 裁切），宽度上限 340 pt、高度上限 460 pt；超高的「长图」
    限制为 340×460 并裁切，右下角显示「长图」chip，点按可查看完整图片。展示宽度同时受原图像素宽度约束：
    小图（表情/截图）不放大到 340 pt（按像素宽度的一半展示、最小 100 pt），大图统一 340 pt；窗口很窄时
    随可用宽度收缩。原图到达后以真图比例为准（元数据缺失/不一致时不再留黑边），位图未到时用元数据预留
    尺寸避免卡片高度跳动；先加载缩略图立即显示、原图后台升级，失败可点开查看器重试。
  - 多图（2–9）：自定义 `MomentMediaSquareGridLayout`（`Layout`）直接算正方形格子——按可用宽度均分、
    340 pt 上限、左对齐、间距 6 pt，2/4 张两列、其余三列；格子底板为固定尺寸圆角矩形 + overlay 绘制图片
    （`scaledToFill` 只影响绘制）。**不要改回 `LazyVGrid` + `aspectRatio`**：图片比例会撑宽格子、网格向左
    溢出卡片（2026-11-09 真机复现并修复）。
  - 视频：不加载封面/播放 UI，固定显示「视频」占位（单视频 16:9、网格内方形），不伪造媒体。
  - 查看器 `MomentImageViewer`：居中自适应舞台（最大 960×720，随窗口收缩不溢出）；缩略图即时占位（原图
    加载中轻模糊 + 小进度角标，失败后清晰显示缩略图并在角上给「原图 · 加载失败 · 重试」），无任何可用图时
    显示整页重试；缩略图/原图分段切换、左右箭头/按钮与键盘 ←/→ 翻页；翻到视频显示「视频（暂不支持播放）」
    占位而不是误报加载失败。列表缩略图是否自动加载由「机器人 → 朋友圈 → 自动加载缩略图」控制
    （关闭后点击图片才下载）；原图始终在查看器按需加载。
- 发布（v3.0 起完全自动）：朋友圈页**不提供手动发布入口**（`MomentComposeSheet` 已移除），也**没有
  发布前确认**；自动发布到点直接发送。演练模式（`bot.dryRun`）下只生成只读「演练草稿」用于预览，
  不发送、不写 ledger。失败会在面板/日志明确提示，不伪造成功、不自动重发。
- AI 自动互动不在本页操作：名单/动作/频率/识图统一在「机器人 → 朋友圈 → 互动」配置；互动成功且本页
  可见时由 `MomentsStore.ingestAutoComment` 即时合并新评论，不占用/不改变「写评论」面板的发送状态。
- 朋友圈记忆（2026-11-09）：页面刷新/自动互动 native 刷新读到的好友动态由 Runtime 写入对应好友 v2 记忆卡
  （来源「朋友圈」，见 `sns.md` §1.6）；页面本身不展示记忆状态，只在「记忆」页按角色查看；不写微信数据、不上传。
- 设置：读取与显示、AI 自动互动、发布与自动发布统一在「机器人 → 朋友圈」（`MomentsSettingsPanel`，v3.7
  三区分段），见 §5.4；本页不提供设置入口。
- 状态来源：`store.moments`（`MomentsStore`）；视图只读状态并调用 `loadInitialIfNeeded / refresh / loadMore /
  pollSync / loadDetail / retryAfterPriming / refreshPrimingStatus / submitComment` 等方法，不直接访问网络；
  `publish` 只由自动发布调度（Runtime）调用，页面没有手动发布入口。

### 5.4 机器人

- 8 个子栏目（`PageTabBar` sticky）：常规 / 触发 / 互动 / 名单 / 节奏 / 定时 / **朋友圈** / 语音；分栏条不随内容滚动，
  切换子栏目内容回到顶部，选择按窗口记忆（`@SceneStorage("bot.subTab")`）。启动/停止与「保存设置」
  始终在页面顶部工具栏（本页唯一启停入口）。
- 「常规」：状态卡（渐变图标、运行状态、真实/演练模式、配置停用提示、OneBot/Hook 状态）+ 基础开关（演练模式全页唯一入口、私聊自动回复、忽略自己、忽略公众号）
  + 默认人格 Picker；系统提示词只在「人格设定」维护，默认 AI 通道只在「AI 模型 → 默认通道」设置一处。
- 「触发」：群聊触发方式多选 chips（@ / 关键词 / 拍一拍 / 引用机器人 可组合，「所有消息」与其它方式
  互斥）、群聊关键词 chips 编辑器（勾选「关键词」后生效）；命令前缀仅保留给历史配置。
  - 「引用机器人」（默认关闭）：别人引用机器人发过的消息时唤醒，正文无需 @/关键词；判定用 refermsg
    的结构化发送者 wxid（`<chatusr>`，私聊形态回退 `<fromusr>`），不看昵称；chip 悬停提示
    「引用机器人：别人引用机器人发的消息时唤醒机器人（正文无需 @ 或关键词）」；被引用原文仅作 AI
    上下文，不参与 @/关键词触发。
  - 群聊 @ 优先认结构化 `at` 段且目标为机器人本人；结构化 at 缺失时用从历史 @ 事件学到的群昵称做文本 @
    兜底；@ 其他人和普通文本里的 `@` 不会触发（避免群收款/卡片等 appmsg 误回复）。
- 「互动」：唤醒后免唤醒词 + 拍一拍回复。
  - 「唤醒后免唤醒词」（默认关闭）：开关 + 1–60 分钟 Slider 与 1/3/5/10/30/60 分钟快捷 chips（默认 5）。
    群聊被任一方式唤醒后，**同一发送者**在窗口内继续发言无需再次 @/关键词/引用/拍一拍，每条放行的消息
    都会续期（滑动窗口）；仅群聊生效。与会话开关、白黑名单、工作时段、冷却与每分钟上限同时生效时，
    窗口只放宽触发判定，不绕过其它门槛。
  - 「拍一拍回复」（默认关闭）：「发送自定义文字」（AI 前/后文字，留空不发送，支持 `{name}` 占位符）、
    「附带 AI 回复」（使用普通回复的 persona/provider/model）、「群聊被拍后 @ 拍的人」（仅群聊；真实 @
    以 OneBot `at` 段交给 bridge，`<atuserlist>` 与群昵称由 bridge 解析，附在第一条回复前）。发送顺序：
    自定义文字（前）→ AI 回复 → 自定义文字（后），AI 失败时仍发送文字；全部未发出而回退普通 AI 时 @
    只附在回退第一条。判定优先 `pat_target_wxid == 机器人 wxid`；旧版没有结构化字段时从 `raw_message`
    的 patinfo/sysmsg 模板与正文兜底（私聊认「拍了拍我」，群聊要求能对上 selfID 或群昵称）；群里拍别人
    不触发；回拍已移除；bridge 解析不到群昵称时退化为不带 @ 的普通文本，不阻断回复。
- 「名单」：「白名单 / 黑名单」为两个 `IDListEditor`，条目可为会话 ID 或用户 wxid；chips 可删、
  可从会话选择；白名单为空表示全部允许，重叠时显示 warning（黑名单优先）。
- 「节奏」：频率与上下文（冷却 Slider、每分钟回复数、短期上下文条数 Stepper；窗口外旧消息进入记忆卡
  全量记录，由后台按批次提取记忆）+ 工作时间（开关、星期 chips、起止时间 `DatePicker` 分钟整数绑定；
  全局默认，可在会话页覆盖）+ 拟人化（开关、随机延迟双 Slider 自动保持 min ≤ max、分段开关/段数、
  输入中状态）。
- 「朋友圈」：`MomentsSettingsPanel`（2026-11-09 分区重构 v3.7 + 状态总览打磨），只编辑 `bot.snsSettings`；
  读取/发布/互动由 `MomentsStore` / Runtime 执行。顶部是一张「朋友圈状态总览」GlassCard：品牌图标 + 标题/说明 +
  整体状态胶囊（未开启 / 未运行 / 待检测 / 待配置 / 已就绪）和三张可点击的分区状态卡（读取/互动/发布，各含图标、
  状态色点、状态标签、一句话摘要与 tooltip）；状态卡同时承担分区切换（替代 segmented picker，保留
  `@SceneStorage("moments.settingsSection")`，一次只渲染一个分区）。功能/写开关/R3 改动未重启机器人时，
  在总览下方显示「配置待生效」warning（`store.snsBridgeConfigStale`）。整体状态在 R3 未开启时直接显示
  「待配置」。全局演练模式开启时，总览右侧追加「演练中」pill，并在总览下方显示一条演练影响面 info
  （不发送、不写互动/发布计数与朋友圈记忆，指回「机器人 → 常规」关闭）；这是全局开关的唯一入口，
  朋友圈页不重复提供同名开关。
  - 分区「读取」：卡片「读取与显示」（symbol `photo.on.rectangle.angled`，violet）。状态行（`PillLabel` +
    说明 + 「重新检测」；状态含「未开启 / 依赖 R3 / 检测中 / 未检测 / 读取失败 / 原生通道 / 原生待捕获 /
    被动缓存 / 未就绪」；与总览卡共用同一份 `readSectionState` 判定，避免「原生待捕获」在总览显示成被动缓存）
    →「启用朋友圈」开关（默认关；关闭时同时停用自动发布与自动互动；开启后在侧边栏
    「会话」下显示入口，并检测 readiness，未就绪打开统一「捕获发送句柄」弹窗）→「自动加载缩略图」开关
    （需功能开启；关闭后点击图片才下载，原图始终在打开大图时按需加载）→「记忆」区域（2026-11-09 新增）：
    「把好友朋友圈写入对方记忆」总开关（默认开）+「图片识别结果一并写入」子开关（记忆关闭时禁用）；说明只写
    本机记忆卡、不上传、关闭后保留既有记忆；全局 `bot.memory.enabled=false` 时整组禁用并显示 warning；
    演练模式下底部说明改为「演练模式下不写入记忆」，开关值保留供关闭演练后生效 →
    底部刷新方式说明（程序不控制微信窗口；被动缓存约 10 分钟有效，微信或 bridge 重启后需重新打开一次）。
  - 分区「互动」（v3.7 新增，symbol `bubble.left.and.bubble.right`，info；trailing `PillLabel`「运行中 /
    待配置 / 已关闭 / 未运行」）：「启用自动互动」开关（`.disabled(!sns.enabled)`；关闭朋友圈或写操作时
    同时把互动置为关闭，重新打开不会自动恢复互动；开启时检测评论句柄，缺句柄直接进入统一捕获弹窗；
    需要「允许发布 + R3 + 机器人运行」才能真正执行）。前置条件拆成两层：配置缺失（朋友圈未开启 /
    「允许发布」未开启 / 未开启 R3 / 尚未捕获读取样本 / 评论句柄未就绪 / 聊天白名单里还没有私聊对象 /
    没有启用互动动作 / 配置待生效）用 warning，存在可手动补齐的捕获项时附「查看捕获步骤…」按钮；
    配置完整但机器人未运行只用 info「机器人未运行」，不再把未启动误报成配置问题。
    演练模式 info（不发送、不占计数、不写记忆；关闭演练后这些动态仍会正常互动）→「互动对象」只读行
    （「共 N 人」；说明「直接使用聊天白名单中的私聊对象；聊天黑名单永不互动」+「去名单…」按钮跳转
    「机器人 → 名单」编辑白名单；help 说明白名单为空时不自动互动、**不会**退化为全部好友；不再有独立的
    互动名单选择 sheet）→ 三种动作开关（评论新动态 / 回复我的动态 / 回复我收到的回复；
    `SnsInteractionKind.label/detail/symbol`）→ 频率行（每天最多互动次数 0–20、**0 显示「无上限」**；两次互动最小间隔 0–180 分钟、步进 5）→
    「图片识别」开关（把动态内全部图片一次交给识图模型分析；识图模型未开启时显示 warning 说明会降级纯文本）→
    可展开「高级选项」（只处理最近 1–72 小时；单条动态每天最多回复 0–5 条、**0 显示「无上限」**；
    检查间隔 60–600 秒、步进 30）→「立即检查」（需机器人运行；`checkSNSInteractionsNow`
    不等待轮询，完成后 toast 结果；演练模式下按钮改为「演练一轮」，toast 为「演练完成：生成 N 条（未发送）」）
    →「上次检查」（时间 + 评论/回复/演练/跳过/失败计数 + 下次检查；首条错误
    以 warning 展示）→「最近互动」（N 条 +「查看…」打开 `MomentsInteractionActivitySheet`）→ 底部说明
    （只评论/回复不点赞；失败 10 分钟内不重试、最多 3 次；正文只在本地内存展示、不上传）。
  - 分区「发布」：卡片「发布」（v3.4 起与自动发布合并；symbol `square.and.pencil`，warning；trailing 只读
    `PillLabel("部分可见")`），内容与 v3.4/v3.6 一致：「允许发布（写操作）」开关（默认关、需功能开启；
    关闭时同时停用自动发布与自动互动；改动需重启机器人）→ 演练草稿行（常驻；`MomentsOutboxSheet`
    620×560，只读预览/清空，写操作/自动发布关闭时也可查看）→ 写通道状态行（`write_ready` → 已就绪/未就绪/
    未检测；未就绪时说明「首次需在微信成功发布一次以捕获发布样本」并附「查看捕获步骤…」；支持文字，
    图片/视频未实现）→ 评论通道
    状态行（`comment_ready` → 已就绪/未就绪/未检测；首次评论/回复前需在微信里手动点一次评论以捕获 0xD5
    任务与真实请求模板；与发布样本是两套独立句柄；未就绪时提供「去捕获…/查看步骤…」）→ 自动发布全部内容：
    配置缺失 warning（机器人未运行只用 info）、开关、发布对象（`MomentsTargetsSheet`，候选仅「开启 AI 自动
    回复的私聊会话」；该行同时承载可见性语义——固定「部分可见、只发给已选好友、未选择时不发布」，
    不再单列只读的「谁可以看」行）→ 发布时机（2026-11-10 起由 segmented picker 改为两张并列模式卡：
    `windows`「时段内随机」/ `times`「固定时间点」；每卡显示模式名、说明、`SnsPublishSettings.timingSummary(for:)`
    生成的一句话配置摘要（未选中的模式也显示自己的摘要，未配置时为「未设置可发时段 / 未设置时间点」）、
    单选圆点与选中底色，选中卡 help 为「当前使用的发布时机」；切换只改 `publish.mode`，`publish.windows` /
    `publish.times` 分别保存、互不清空，卡片下方固定说明）→ 对应编辑器（不再提供快捷预设 chips；
    `times` 为「指定时间点」：行内 `DatePicker` 步进编辑，「+」新增（上限 10，达到上限时禁用并说明）；
    同一分钟重复的时间点由设置写回自动去重（`sanitized` 按分钟去重，不会出现重复行；编辑撞车时 toast
    说明并移除重复项）、乱序提示「按时间排序」，空配置显示「恢复默认时间点」；`windows` 为「可发时段」：
    每行起止 `DatePicker` + 时长文本（如「1 小时 30 分」）或跨午夜「次日」violet pill，「+」新增（上限 6，
    达到上限时禁用并说明），重叠行显示 warning 图标并在下方给出「合并重叠时段」（按覆盖范围合并，首尾相接的
    相邻时段也一并并入；覆盖整天时收成 00:00–23:59），空配置显示「恢复默认时段」；开始与结束相同时自动
    顺延结束时间并在编辑器内 warning 说明）→ 频率（`windows`：每个好友每天上限 0–10、**0 显示「无上限」**，
    并显示同一好友最小间隔 0–1440 分钟，后者仅在每天多条或无上限时出现；`times`：每天次数由去重后的时间点
    数量决定、不可直接编辑；时段与最小间隔排不下设定次数时显示 warning「时段放不下设置次数」，用本地日历日
    容量（`calendarDayCapacity`：当天批次当天部分 + 前一天批次跨午夜部分，与当天随机结果无关）说明每天最多
    能排几次并给出调整建议）→「排程预览」（2026-11-10 晚简化为一行：`TimelineView(.everyMinute)` 每分钟
    刷新；副标题为「今天剩余 HH:mm · HH:mm」（最多 6 个，超出「等 N 个」）+ 今日配额「今天已发 N 次
    （上限 M 次）/（无上限）」；右侧 pill 为「下一次 今天/明天 HH:mm」，今日配额用尽时替换为 warning
    「今天已发满」并出现「重置今日计数」按钮；不再列时刻 chips /「下一次+之后」长列表）→「上次结果」
    （时间 + 成功 / 演练 / 跳过 / 失败计数，非今天的结果带日期；有首条错误时 subtitle 为「上次失败：…」，
    仅有跳过时 subtitle 为「上次未发送：…」）→ 底部说明。
    面板打开期间启停机器人或重新开启朋友圈会自动刷新读取状态，不再停留在旧状态。
  - 面板不出现「自动同步 / 同步间隔」「图片下载三档」等未接线或伪设置；被门控的控件必须在卡片或行内
    给出原因（见 §7）。
- 「语音」：复用 `VoiceSettingsPanel`，App 内唯一语音设置入口。
  - 转写：三个开关 + 「转写资源」行内状态/下载/刷新。回复：总开关默认收起策略项（概率、对等、
    短回复阈值、最长时长、超限处理、语音回复免拟人化延迟）。
  - 引擎与音色：Qwen3-TTS-1.7B 单模型；运行设备 GPU（MLX，推荐）/ CPU（极慢，实验性），切换时停服务
    → 保存 → 按自动启动拉起；本地服务状态（运行中/启动中/未运行/异常/未检测）+ 启动/停止/重新检测，
    subtitle 显示 `Qwen3-TTS-1.7B · GPU/CPU · endpoint · 模型`；运行环境与模型下载/取消/重装/删除
    （下载约 4.7 GB、运行时内存约 10 GB，删除只清模型/venv/标记；可见条件为体积、首次预热约 10 秒、
    CPU 极慢，原理收进标题 help）；音色本机菜单 + 「管理音色…」，App 不内置音色，列表行显示
    参考音段数，管理 sheet 为 1–5 段片段卡片（批量导入、排序、替换、删除、逐条/自动转写、N/5 与
    时长/字符计数；常见格式、每段 ≥1s、合计 ≤30s 超长截取、缺失文本保存前自动补齐、cross-lingual
    保留且不锁文本，内置音色只读），导出 zip 含 `refs/`；自动启动仅在「允许语音回复」+ 开关开启 +
    已安装且有音色时，于启动 App/打开语音面板拉起；服务地址默认 `http://127.0.0.1:5051`（仅回环）。
    安装/启动与音色细节见 [`voice.md`](voice.md) §4.1。
  - 试听：共享 `VoicePreviewController`，走当前引擎的本地 HTTP 服务播放真实合成，不发往微信；服务
    未启动或未选音色时提示先安装/启动。发送状态：仅开启「允许语音回复」时显示，单行摘要 + 重新检测 +
    「查看步骤…」（打开统一的「捕获发送句柄」弹窗，见 §5.14）；首次开启「允许语音回复」时先检测一次，
    不能发送语音即打开该弹窗。该 section 的重复说明 footer 已删除，只保留状态行。
- 所有修改即时写回 `store.settings`，保存按钮 + 离开页面时 `persist()`。

### 5.5 AI 模型

- 顶部：通道数量/默认通道摘要、添加通道。
- `ProviderRow`：类型图标、名称、类型/默认/停用徽标、baseURL host、模型、Keychain 状态、输出上限/超时/
  有效流式状态、测试按钮（idle/testing/success/failure，成功耗时与失败原因直接展开）、启用开关、编辑、
  删除（确认；至少保留一个）。Key 文案：「密钥已登记」/「缺少 API Key」/「无需密钥」（Ollama）/
  「密钥可选」（自定义）；全局流式关闭显示「流式已暂停」；行内不重复提供「编辑/测试」菜单项。
- `ProviderEditorSheet`（600×660）：名称、类型（切换时自动填入该类型默认地址与模型，不覆盖用户手改值）、
  Base URL（按类型给示例）、模型；API Key（SecureField + 显示切换，按类型「需密钥 / 可选」，已有密钥提示
  「留空保持不变」，可清除并二次确认）；「生成参数」折叠为「高级参数」摘要，含回复最大长度、请求超时与
  通道级流式开关（全局流式关闭时提示不生效）。字段级校验显示在输入框下，错误提示固定 footer 上方。
  **启用/停用只在通道列表行操作**，编辑 sheet 不重复提供开关；默认通道只在「默认通道」卡设置。
- 「默认通道」：Picker 始终选中一个具体通道（不再提供会静默回退到第一个通道的「无」选项）；默认通道停用或缺少 API Key 时显示 warning 和可行动说明。
- 「请求策略」：流式总开关（关闭后所有通道非流式；开启时跟随各通道的流式设置）、
  失败重试（额外重试次数，0 = 不重试）。全局请求超时已移除，真实超时按通道配置。
- 「模型温度」：按模型名列出实际使用的模型及已保存自定义温度的历史模型，每个模型可单独设置 0–2 或恢复
  默认；未配置时请求不发送 `temperature`；有自定义温度时提供「全部恢复默认」。
- 「识图模型」：启用开关、识图通道 Picker（「跟随默认通道」+ 全部通道）、识图模型覆盖（留空跟随通道
  模型，需支持 OpenAI 兼容 `image_url` 输入）。说明识图结果仅存本机并作为后续回复上下文；关闭时
  通道/模型行禁用；无通道时提示先添加通道并填写模型名称。
- 「密钥与安全」：Keychain 策略说明、测试行为说明、Ollama 说明、删除通道同时删除其 Keychain 条目、
  配置文件路径（可复制）。删除通道需确认，默认通道自动回退到第一个通道。

### 5.6 人格设定

- 自适应网格（`LazyVGrid`，280–420pt）；`PersonaCard`：渐变头像、名称/默认徽标、简介、
  提示词预览、模型覆盖、编辑按钮、更多菜单（设为默认/删除）。
- `PersonaEditorSheet`：名称、简介、系统提示词 `TextEditor`、可选模型覆盖；不设回复风格或温度
  （温度按模型在 AI 模型页配置）；校验名称/提示词。
- 默认人格联动 `settings.bot.defaultPersonaID`，删除默认人格自动回退。**人格设定是唯一来源**：会话按
  `personaID ?? 默认人格` 绑定，不复制人设卡；页面提示「人格是模板」，修改后立即对所有使用该人格的会话生效。

### 5.7 记忆库

- 只有**记忆卡**模式；聊天记录清理在具体会话头部菜单（见 §5.2），记忆页无数据库浏览或清理入口。
- **入口不自动打开聚合**：进入（含再次点击侧边栏「记忆库」）只显示左栏角色列表，右栏为「选择一个角色」
  空状态 + 「查看全部角色」按钮，**不自动加载/展示任何角色或聚合页**；点击「全部角色」或该按钮才打开
  聚合，点击全局/会话行切换选择；刷新、创建卡、删除卡后保持无选择。
- 只展示**当前微信账号**的角色目录；换账号后角色列表与记忆卡都切到该账号，不同会话之间不共享记忆。
  账号切换见 [`accounts.md`](accounts.md)，记忆卡契约见 [`memory.md`](memory.md) §10。
- 记忆卡模式（记忆 v2）：左栏角色列表 + 右栏记忆卡。
  - 左栏：`全部角色`（聚合）+ **固定「全局共享 / 所有会话共享」行**（globe 图标，位于会话角色之上）+
    各会话角色行（标题/类型/人格名/记忆数/重要数/待办数），支持按标题/人格名搜索；无记忆卡时整页
    空状态提供「为现有会话创建记忆卡」，建卡后后台补总结最近一批旧聊天（最多 500 条），更早历史可手动导入。
  - 右栏顶部：会话标题/类型、人格名（来自**人格设定**）、更新时间；全局行显示「全局共享」+
    「注入所有会话」；聚合 header 为「聚合 N 个会话角色 · 全局记忆同时并入」。**无「人设卡」按钮/sheet、
    无每会话自定义提示词、无重复统计行**；总数只在工具栏副标题（`N 个记忆卡 · N 条生效记忆`，含全局卡），
    各筛选数量只在筛选 chip。按钮：`全量记录`、`导出`、`更多`（预览注入 / 导入旧记忆 / 为缺失会话创建
    记忆卡 / 删除记忆卡）；记忆设置入口是工具栏齿轮；聚合视图隐藏/禁用角色专属按钮；**全局卡禁用
    「全量记录」（无 interactions）与「删除记忆卡」**，可导出与手动维护记忆；人格只读展示（统一在
    「人格设定」维护，记忆页不编辑）。
  - 筛选：全部 / 最近 72h / 重要 / 待办 / 事实 / 决策 / 经验 / 已归档 / 已被取代；排序：综合权重（默认）/
    最近更新 / 重要度；搜索正文与关键词。
  - 卡片：正文、类别徽标（事实/决策/待办/经验）、置顶/重要徽标、重要度、权重、合并次数、召回次数、
    来源（自动提取/手写/旧记忆导入）与「已被取代」徽标；菜单：编辑、置顶/取消、归档/恢复、压缩、
    取消取代、删除（二次确认）。
  - 新增记忆：预填当前会话，类别默认 `fact`、来源 `manual`；提取记忆正文 ≤300 字，手动新增可到 2000 字。
  - 注入预览/召回测试（[`memory.md`](memory.md) §8.3）：输入模拟消息，显示按当前会话生成的记忆上下文
    与字符估算。
- 全量记录 sheet：`interactions` 列表（时间/方向/发言人/正文），搜索、上限 1000 条；首次查看角色自动
  补齐最多 5000 条历史互动，之后增量同步；工具栏「导出」包含全部互动记录；sheet 内不提供删除（随
  记忆卡删除）。
- 导出：Markdown / JSON，使用 `NSSavePanel`；全局卡也可导出（用当前人格设定/默认人格），不含全量记录。
  Markdown 含角色信息、人格设定（摘要/系统提示词/模型）、分类记忆（重要项带标记）、已归档/已被取代与
  全量互动；JSON 含 `format`、`exportedAt`、`character`、`memories`、`interactions`；`character` 含
  `conversationID`/`title`/`kind`/`personaID`/`name`/`summary`/`model`/`systemPrompt`/
  `personaSource = "persona-settings"`，不含每会话人设卡字段/时间戳。
- 记忆设置 sheet：记忆开关、提取批量、最近窗口、普通/重要半衰期、重要阈值、合并阈值、归档天数、
  召回条数/字数等；保存到当前账号 `profile.json` 的 `bot.memory`（字段/默认值见 [`memory.md`](memory.md) §11）。
- 「导入旧记忆」：只读旧 `memories` 表，把本会话 + 全局旧记忆拆分/启发式分类后导入当前记忆卡
  （来源 `legacy-import`、核心记忆置顶）；需用户点击。
- 删除记忆卡：二次确认，整个角色目录移到废纸篓；**人格设定不受影响**，该会话下一条消息（或下次回复）
  按当前人格设定重建记忆卡并重新补总结最近历史（见 [`memory.md`](memory.md) §7.2）。全局共享卡不可删除
  （按钮禁用，运行时拒绝）；删除会话同时把角色目录移到废纸篓。
- 工具栏副标题显示「本地 SQLite」与记忆卡/生效记忆数；账号库与角色目录完整路径在「设置 → 数据与备份」。
  微信侧不提供 `/记忆` 指令；查看/编辑/置顶/压缩/导出只在 App 记忆面板进行。
- 空状态区分「还没有记忆卡」「记忆卡还是空的」「这个角色还没有记忆」「全局记忆还是空的」（后两者提供
  「新增记忆」；全局卡说明只支持手动维护、注入所有会话）、「当前筛选为空」「搜索无结果」；有卡但 0 条
  不是读取错误。错误（DB/目录读写失败）用 Toast + 日志提示，不静默吞掉，面板保持可用。

### 5.8 定时任务（机器人 → 定时）

- 从侧边栏移入机器人页的「定时」子栏目（`SchedulesPanel`），侧边栏不再单列；卡片头部为任务数/启用数、
  新建任务。
- 全部/启用/停用筛选；`ScheduleRow` 左侧突出下次执行时间（时:分 + 今天/明天/星期），停用任务
  时间列显示「—」而不是「已结束」；任务名、重复方式、每周星期、内容、目标会话、下次/上次、启停、编辑、删除
  （溢出菜单不再重复「编辑」入口）。
- `ScheduleEditorSheet`：名称、目标会话（列表选择或手动 ID）、内容、重复方式、星期 chips、
  统一「执行时间」DatePicker、下次执行预览、启用开关；按频次显示提示（仅一次 / 每天 / 每周所选星期 /
  周一至周五），并说明需机器人与 OneBot 在线才会发送；校验名称/目标/内容/星期/一次性任务时间。下次时间
  优先 Core 的 `nextFireAt`，否则 UI 用 `ScheduleMath` 估算。

### 5.9 运行日志

- 工具栏：暂停/继续、导出、清空（确认）。
- 过滤：级别 chips（含计数）、来源菜单、搜索、自动滚动、实时/暂停状态、条数统计。
- 日志列表：`LogRow` 等宽时间/级别/来源/消息；错误警告行带浅色底；文本可选。暂停时展示暂停瞬间快照；
  导出为 `.log`（`NSSavePanel`，UTType plainText）。

### 5.10 设置

左侧分类（应用 / 集成 / 数据）+ 右侧分组卡片：

| 分类 | 内容 |
| --- | --- |
| 通用 | 登录启动（尚未接入）、退出确认（尚未接入）、**防睡眠（永不/接入电源时/始终 + 当前状态）**、语言、重新打开向导；窗口/Dock 行为只做说明（Dock 图标随主窗口显隐，无开关）；未接线项在行副标题后直接标注「尚未接入」，不伪装成已生效 |
| 外观 | 系统/浅色/深色分段选择 + 三个外观缩略预览；减少动态效果与动态字体状态；设计说明 |
| 通知 | 通知开关、声音开关（只保存偏好）；系统通知尚未接入，行内说明新消息/异常请到会话页与运行日志查看，不显示系统授权状态 |
| 更新 | 当前版本/Build、安装位置与门禁提示、立即检查、自动检查开关、新版本说明、下载进度、跳过/取消跳过、GitHub/发布说明链接、更新日志（`update.log`）入口、错误与重试 |
| Hook | 微信版本/进程/Gadget/Bridge/网关/版本匹配、**CLT 状态/安装/重新检测**、**R3 发送句柄状态**、安装/还原/刷新、进度、风险提示、路径/端口/自动启动/**R3 原生发送开关（4.2.0.17 / 4.2.0.12 / 4.2.0.9 / 4.2.0.5 / 4.1.15.55，默认开；首次需本机手动发一条消息）** |
| OneBot | Host/Port/连接类型/Token（安全显示+复制）、Bridge 路径、图片目录、WS 地址 |
| 数据与备份 | **当前微信账号（mask/账号数据目录/账号配置/记忆数据库/记忆卡目录/媒体目录）**、**已保存的账号**、**重新检测微信账号**；全局配置 `config.json`、备份目录、运行日志目录（`~/Library/Logs/WeChatAI/`）；导出配置、打开目录、重新加载、日志清空 |
| 关于 | 图标、版本/Build、Bundle ID、系统版本、架构、资源路径、**运行信息**、**技术栈与许可**（每项写明本项目中的用途）、**自研能力概述**（版本适配、收发送、通讯录读取、语音与媒体、安全边界与分析工具链；不展示地址、结构偏移或密钥细节）、上游开源项目 GitHub 链接与许可（重新打开向导在「通用」页与总览「首次向导」快捷操作提供） |

**「数据与备份」多微信账号区域**：

- **当前微信账号**（只读，值来自 `AccountProfile` / `AppStore`）：账号为 `store.activeAccountID` 的 mask
  （`AccountProfile.maskedActiveID`；未识别显示「未识别（等待微信登录）」+ warning「临时档案」徽标，
  已识别显示「当前」）；账号数据目录 `accounts/<id>/`、账号配置 `accounts/<id>/profile.json`、
  记忆数据库 `accounts/<id>/chatbot.sqlite`（旧记忆表只读）、记忆卡目录 `accounts/<id>/characters/`、
  媒体目录 `accounts/<id>/media/`；全局配置 `config.json`、备份目录 `backups/`、运行日志目录
  `~/Library/Logs/WeChatAI/`（崩溃与 bridge 日志同级）。每个路径提供复制与「在 Finder 中显示」
  （`.monospaced`），卡片下方用 `InlineNotice(kind: .info, title: "数据隔离")` 说明账号级与全局数据边界。
- **已保存的账号**：数据来自 `store.savedWeChatAccounts`（`AccountProfile.savedAccounts(limit:)`，
  按最近使用倒序，不含 `_unassigned`）；行显示 mask、最近使用时间、当前账号徽标与「在 Finder 中显示」；
  不提供点击切号（切号只跟随微信登录）；无档案时为空状态，只有当前账号时追加「登录其他微信后点
  『重新检测微信账号』即可建立独立档案」。
- **「重新检测微信账号」按钮**：调用 `await store.refreshWeChatAccount()`；`store.isSwitchingAccount`
  为 true 时显示 ProgressView 并禁用（总览/菜单栏启动按钮同样禁用）；完成切换 → toast
  「已切换到当前微信账号的数据」；仍未识别 → error toast「仍未识别到微信账号，请先登录微信后重试」；
  检测到但切换未生效 → error toast（展示 `store.lastAccountSwitchError` 并回退原账号）；启动中检测到
  变化 → info toast「机器人正在启动，完成后会自动切换账号数据」；没有变化 → info toast
  「未检测到账号变化」。不提供手动选择数据库/账号档案入口，UI 不直接调用 `AccountProfile` 切换接口。
- 说明文案（与 [`accounts.md`](accounts.md) §1–§2 一致）：聊天、记忆卡（角色目录）、会话设置、机器人配置、
  人格、定时任务与新媒体随微信账号切换；AI 通道/Keychain、Hook、OneBot、本地 TTS 安装与音色、日志文件
  全局共享；旧版媒体保留在原目录。删除当前账号的聊天不影响其它账号，也不能在 App 内删除账号档案。

**「Hook 安装前置」交互（设置页与首启向导共用同一张环境检查卡）**：

- 顶部显示 Xcode Command Line Tools 状态（已安装 / 未安装 / 检测中 / 检测失败 + 版本或路径摘要），
  完整 Xcode 同样视为就绪；未就绪时提供「安装 Command Line Tools」（执行 `xcode-select --install`，
  由系统弹面板）与「重新检测」，安装完成后自动轮询刷新，无需重启 App。
- CLT 未就绪时禁用「安装 Hook」并 `InlineNotice` 说明原因；微信版本不匹配、路径不存在或
  `/Applications/WeChat.app` 不可写时同样禁用并给原因，避免安装到一半失败。

**「节能与睡眠」交互**：

- 三档 segmented Picker（永不 / 接入电源时 / 始终）+ 当前档说明；「当前状态」PillLabel（已关闭 /
  已生效（阻止空闲睡眠）/ 未生效（使用电池）/ 未生效（机器人未运行））附原因。IOKit 失败时区块下方
  warning `InlineNotice`，不阻塞其它设置。
- 修改后立即 `SleepPreventionCenter.apply(mode:)` 并持久化；footer 说明仅阻止系统空闲睡眠，
  不阻止合盖/手动睡眠，也不保持显示器常亮。
- 只在机器人运行期间生效：未运行时切换只保存偏好并 toast「已保存，启动机器人后生效」；机器人启动/停止
  分别 `setRuntimeActive(true/false)` 持有/释放断言。同页同一设置只保留一个入口。

**「获取图片」交互（会话级）**：

- 会话详情头部 `Menu` 的「媒体」Section 一项可勾选「获取图片（已开启 / 已关闭）」，点击切换并写库
  （`Conversation.imageFetchEnabled`）+ toast；生效值 = 会话覆盖 → 旧全局 `bot.imageFetchEnabled`
  （默认开启）；关闭后该会话不再发起新请求，已获取图片仍显示；全局设置页不再暴露该开关。
- 识图在「AI 模型 → 识图模型」单独配置；会话级开关只控制是否获取图片，未获取或失败时气泡继续显示占位。

**「语音」交互（统一在「机器人 → 语音」，设置页不提供「语音」分类）**：

- 转写与语音回复只在「机器人 → 语音」提供全局开关，会话详情菜单无会话级覆盖；关闭转写后不再入队新的
  语音下载/转写，已有转写仍显示；关闭语音回复后只发文字。
- 首次开启「允许语音回复」先刷新 `/voice_status`，不能发送语音即打开统一「捕获发送句柄」弹窗；机器人每次
  启动后都会在 bridge 就绪时重新检测，文字/语音句柄或朋友圈样本仍缺失就自动弹一次（同一次运行内最多一次）。
  弹窗条目/状态见 §5.14；面板本身只保留单行发送状态与「重新检测」「查看步骤…」入口，不再重复整段说明。
- 概率、对等、仅短回复、音色与运行设备均由全局语音设置控制；已确定改发语音时默认跳过拟人化随机延迟
  （可在语音设置关闭），进度条不再出现「N 秒后发送」倒计时。

**「应用内更新」交互（应用组：通用 / 外观 / 通知 / 更新；契约见 [`updates.md`](updates.md)）**：

- **徽标与提醒**：存在可用更新（版本高于当前且未跳过）时，设置分类侧边栏「更新」行显示「新」小徽标
  （无障碍「有可用更新」），主窗口侧边栏 footer 与菜单栏面板 footer 显示「有新版本 X」；两个 footer
  徽标可点击并经 `requestUpdatePageFocus()` 深链到「设置 → 更新」。徽标只读 `UpdateCenter` 的
  `hasAvailableUpdate` / `availableRelease`，不依赖系统通知权限。自动检查首次发现新版本时主窗口弹一次
  应用内 toast（「发现新版本 vX，可在设置 → 更新中安装」），同一 tag 由 `updates.lastNotifiedTag` 去重；
  手动检查不重复弹 toast，更新页直接进入 `available`。
- **更新页结构**（从上到下）：版本卡（`CFBundleShortVersionString` / Build、安装位置
  `Bundle.main.bundleURL` 与门禁状态；开发构建 `dist/`、`.build` 显示提示但不阻断）→ 新版本卡
  （Release 标题/发布时间、「本版重点」、「下载并安装」「跳过此版本」、GitHub Release 链接）→
  本版本卡（已是最新时显示当前版本更新内容与完整发布说明链接；重启后 6 小时节流内补拉一次 latest）→
  进度区（下载进度、总大小未知用不确定进度、SHA256 校验、准备安装）→ 设置区（自动检查开关即时持久化、
  已跳过版本与「取消跳过」）→ 页脚（GitHub Releases 与 `update.log` 入口）。
- **状态与错误**：`idle` / `checking` / `upToDate` / `available` / `downloading` / `verifying` /
  `installing` / `failed(message)`；进行中禁用重复触发，自动检查失败不进入错误态、不卡在「检查中」。
  `failed` 用 `InlineNotice` + 「重试」「打开发布页」展示，下载/校验/解压/门禁/助手启动失败映射为
  可读中文提示（见 [`updates.md`](updates.md) §6）。
- **确认与进度**：点「下载并安装」先二次确认，顶部展示新版本更新内容（与页面同源「本版重点」），
  再明确会**停止机器人并退出 App**，随后由更新助手替换并重新打开；取消无下载或文件改动。
  点「下载并安装」后**弹窗立即关闭**（用 sheet 的 `isPresented` 绑定关闭，不依赖 presenter 的
  `dismiss`），页面随即切到下载进度。
  `downloading` 显示已接收/总大小与百分比，`verifying` 显示校验中，`installing` 提示 App 会自动重新
  打开；助手启动成功后 App 自行退出，不再提供「取消安装」。
- **跳过版本**：写入 `updates.skippedTag` 后徽标与 toast 消失，页面显示「已跳过 vX」；「取消跳过」
  清空 tag，若该版本仍高于当前则恢复 `available` 与徽标。
- **安装位置门禁**：非 `.app` 运行、bundle id 非 `com.gusionw.wechatai`、App Translocation、安装目录
  不可写或发布包缺 zip/`.sha256` 时禁用「下载并安装」并显示原因与处理建议；安装位置卡片展示版本、
  Build、路径与校验状态，门禁失败时提供「打开发布页手动下载」；不请求管理员权限。
- **更新内容渲染与收尾**：`ReleaseNotesDocument` 从 Release 正文提取「本版重点/更新内容」，过滤下载表格、
  安装步骤、隐私说明等模板段落；`ReleaseNotesView` 按标题/列表/代码/引用分块排版，行内加粗、代码与链接
  交给 `AttributedString`。新版本首次启动清理旧 `.update-backup-*` 与超过 24 小时的更新工作目录；
  ad-hoc 签名未公证，首次打开可能需 Gatekeeper「仍要打开」放行，页面与安装文档给出提醒。

### 5.11 首次启动向导

4 步 sheet（720×620），顶部步骤指示器 + 跳过；右上角「语言 / Language」（跟随系统 / 简体中文 / English）
切换即时生效，与设置 → 通用 → 界面语言同步。

1. **欢迎**：品牌图标、隐私/本地优先/多模型说明、微信版本与风险提示。
2. **微信 Hook**：顶部环境检查卡（CLT 状态；未安装时「安装 Command Line Tools」/「重新检测」，
   CLT 未就绪禁用 Hook 安装）；其下微信路径/版本/进程/Gadget 状态、检测微信、备份并安装
   （`ConfirmSheet` 二次确认 + 备份/重签/风险说明）、`installHook(onProgress:)` 进度、失败错误、跳过说明。
3. **AI 模型**：默认通道 Picker、Base URL/模型摘要、API Key（Keychain）、保存并测试连接、
   无通道时可创建默认 DeepSeek、测试结果内联展示。
4. **启动**：微信/Hook/AI 检查清单、启动后立即运行开关、完成并启动。

底部：上一步（禁用态）、步骤 n/4、下一步/完成并开始；安装中禁止交互与关闭 sheet。

### 5.12 菜单栏

自绘 `NSStatusItem` + SwiftUI `NSPopover`（272pt，`Core/MenuBarController.swift`）：

- **左键单击图标（按下即响应）开合状态面板**（不打开主窗口，也无右键菜单）；右键 / Control-左键
  不执行操作。左键由常驻 local 鼠标监视器在分发前拦截吞掉，避免与 `.transient` 自动收起重复处理；
  右键事件同样被吞掉且不触发动作。面板内导航或「打开主窗口」后自动收起。
- 收起分工：面板 `.transient`，点击面板外（其它 App、桌面、其它状态栏图标）由系统收起，不依赖需要
  辅助功能权限的全局事件监视器；本 App 其它窗口上的点击由 local 点击监视器立即收起；Esc、应用失活、
  应用隐藏与系统菜单跟踪也会收起。**不使用 `clickCount`、双击时间窗或同次点击抑制启发式**；点击意图
  由纯映射 `MenuBarClickIntent` 决定：左键 → 开合，右键 / Control-左键 → 忽略，其它修饰键不改变左键
  语义，未知/合成事件按左键兜底（VoiceOver 场景）。主窗口其它打开路径（Finder/LaunchServices 重开、
  ⌘1…⌘0、面板内入口）走 `MainWindowRegistry.show()`，会先调用 `MenuBarController.shared.dismissPanel()`
  收起面板。
- 面板内容：头部品牌与运行状态胶囊；带描边状态卡（微信、Hook、AI、电量、DeepSeek 余额、今日收到/
  回复/延迟）；快捷操作按「启动/停止 → 打开主窗口 → 会话 / 机器人 / 设置」分层；底部版本与退出
  （⌥⌘Q）；有可用更新时版本区域显示「有新版本 X」（只读 `UpdateCenter.shared`）。启停不收起面板，
  导航/打开主窗口后收起。
- 图标：模板 SF Symbol 随运行状态切换填充/轮廓（`bubble.left.and.bubble.right.fill` /
  `bubble.left.and.bubble.right`），不叠加颜色或状态点、不跑动画；不显示悬停 tooltip，仅保留无障碍值
  （`机器人运行中` / `机器人已停止`）与 VoiceOver 帮助，在启停与界面语言切换时刷新。
- 性能：`NSPopover` + `NSHostingController` 首次构建后缓存复用；图标出现后约 1s 预热，用
  `sizeThatFits(in:)` 量高并固定 `contentSize`（`sizingOptions = []`；离屏 `fittingSize` 恒为 0，
  不用它），余额/统计/电量刷新不再触发自动重排，语言切换释放缓存；内容层不叠加 `regularMaterial`
  （popover 自带材质），悬停只对 `opacity` 做 ≤0.15s 过渡，减少动态效果时不做动画。
- 菜单栏图标是 App 唯一常驻入口，**始终存在**（`showInMenuBar` 已移除）：不使用 `MenuBarExtra`，
  因此没有 `isInserted` 写回循环。
- 主窗口关闭按钮与 ⌘W 改为隐藏窗口（`orderOut`），随后 `ActivationPolicyController` 把进程退回
  `.accessory`：Dock 图标消失、仅保留菜单栏图标，App 隐藏并交还焦点。可从菜单栏左键（面板内
  「打开主窗口」）、Finder/LaunchServices 重开或 `applicationShouldHandleReopen` 重新显示；显示前先
  切到 `.regular` 才能被台前调度识别。退出不绑定 ⌘Q，仅保留 ⌥⌘Q 与菜单/面板的退出入口。
- 辅助功能：状态栏条目保留 `WeChat AI` 无障碍标签/值与 VoiceOver 帮助；面板内状态行合并 label/value，
  按钮带 accessibility 标签与 help。

### 5.13 设置场景

`Settings { SettingsView() }`，系统自动绑定 ⌘,；复用同一套设置页面与分类侧边栏。

### 5.14 捕获发送句柄弹窗（全局 sheet）

- **单一通道**：`AppStore.isCaptureSetupPromptPresented` 是唯一弹出状态，`RootView` 只挂一个
  `.sheet` → `CaptureSetupSheet`。语音开关、朋友圈开关、自动互动开关、评论输入面板「去捕获」与机器人启动检测
  都走它，保证同一时刻只有一个弹窗。
- **条目按已开启功能显示**（`CaptureSetupPlan`）：
  1. 「发一条文字」始终显示（`voiceRuntimeStatus.textSeed`）；
  2. 「发一条语音」仅在「允许语音回复」开启时显示（`voiceSeed`）；
  3. 「打开/发布一次朋友圈」仅在「启用朋友圈」开启时显示（`moments.status?.isPrimed`；开启「允许发布」时
     还要求 `writeReady`，即已捕获 post 样本）；
  4. 「评论或点赞一次」（2026-11-09 新增）仅在自动互动已配置（已开启 + 有名单/动作 + 非演练）时显示
     （`comment_ready`）；0xD5 评论句柄与读取/发布样本是三条独立通道。
  原「等待登录稳定」步骤已删除；登录预热只作为状态行倒计时（仅语音开启且剩余 > 0）。
  条目状态为「已就绪 / 待完成 / 不可用」：`blockedItems` 表示当前微信版本不支持语音发送或 R3 未启用，
  这类语音条目不会出现在「还差：…」里。
- **文案**：标题固定「捕获发送句柄」，标题旁问号提示解释依赖关系与保存位置（语音/朋友圈/自动评论复用原生通道；
  句柄仅保存在本机、不含聊天内容、微信重启后需重新捕获）；副标题统一为一句「微信原生发送需要先捕获发送句柄。
  请按下列步骤各操作一次，完成后自动检测。」，不再按功能组合维护多套；状态行只保留一条，取值为：全部就绪，
  可以关闭了 / 机器人未运行，请先启动 / bridge 尚未就绪，请稍后重新检测 / 未开启 R3 原生发送，语音将改用文字 /
  当前微信版本不支持语音发送 / 语音预热中，约 N 秒后可发送；可以关闭此窗口（或无倒计时时的「登录稳定中，
  可以关闭此窗口」）/ 还差：…（直接列出缺失条目，如「还差：发一条语音、评论或点赞一次」）/
  等待朋友圈样本：在微信打开一次朋友圈 / 等待评论句柄：在微信里评论或点赞一次 /
  暂时读不到朋友圈状态，请稍后重新检测。
- **交互**：「重新检测」立即刷新 `/voice_status` 与朋友圈 readiness；**句柄齐全、只剩登录稳定/语音预热时按钮即为
  「完成」**（预热在后台继续，不需要用户停留），否则为「稍后再说」；预热状态使用信息色而不是警示色；弹窗打开期间
  约 1s 轮询语音状态与朋友圈就绪状态（只查状态，不拉时间线、不阻塞页面加载；
  `MomentsStore.refreshPrimingStatus` 在 loading 时跳过、失败保留上次状态）。
- **启动自动提示**：机器人启动后统一为一个 `startCaptureSetupWatchIfNeeded` 检测（立即检测一次；bridge 未就绪时
  每 3s 重试、最多约 60 秒），判定结果只有「弹出 / 继续等 / 结束」三种。检测范围：
  ① R3 原生发送开启且文字句柄缺失（语音、朋友圈都关闭也要提示）；② 语音回复开启且语音句柄缺失；
  ③ 朋友圈开启且读取样本（或开启发布后的 post 样本）缺失；④ 自动互动已配置且非演练、`comment_ready=false`。
  **每次启动机器人都重新检测并最多自动弹一次**；
  同一次机器人运行内不重复，用户手动打开弹窗不会消耗下一次启动的提示。朋友圈样本 v3.3 起持久化，
  恢复成功时不会重复弹；bridge 尚未就绪/状态未知时继续等而不是误报缺失。
- **不阻塞**：关闭后机器人照常运行；文本句柄未就绪时回复排队，语音句柄未就绪时该条降级文字，朋友圈页显示一行
  未就绪状态 + 「重新检测」。首次启动向导保持原有「未完成才自动弹」，与本弹窗互不影响。

## 6. 组件清单

### DesignSystem

| 文件 | 组件 |
| --- | --- |
| `Theme.swift` | 颜色/字体/尺寸 token、`PageBackground`、`UIFormat`、`Theme.hookColor` 等 |
| `Surfaces.swift` | `GlassCard`、`SectionCard`、`GlassToolbar`、`ScrollingPage`、`IconTile`、`AvatarView`、`StatusDot`、`PillLabel`、`MetricTile` |
| `Controls.swift` | `FlowLayout`、`FilterChip`、`TagChip`、`IconActionButton`、`CopyButton`、`HelpTip`（问号悬停说明）、`FormField`、`PathRow`、`InlineNotice`/`NoticeKind`、`SearchField`、`SettingsSection`/`SettingsRow`/`SettingsDivider`、`PageTabBar`/`PageTabItem` |
| `Feedback.swift` | `EmptyState`、`LoadingState`、`ProgressPanel`、`ConfirmSheet`、`ToastCenter`/`ToastView`/`ToastOverlay` |

### Views/Components

| 组件 | 用途 |
| --- | --- |
| `StatusCard` / `QuickActionButton` | 总览健康状态、快捷动作 |
| `DashboardSystemVitalsCard` | 总览「设备与账户」：本机电量 + DeepSeek 余额（独立刷新，避免电量轮询重绘整页） |
| `SessionRow` | 会话列表行（AI 关闭状态标记、回复阶段计时） |
| `WorkingHoursBadge` | 会话详情头部工作时间状态（工作/非工作/不限，悬停看来源与摘要） |
| `ReplyProgressBar` / `ReplyStatusBadge` / `ReplyMiniStatus` | 回复流水线状态条、详情头部徽标、会话行计时 |
| `MessageBubble` / `SystemNoticeRow` / `TypingIndicator` / `DateSeparator` | 聊天消息 |
| `ChatCleanupSheet` | 会话内聊天记录清理：只删该会话本地 `messages`，不动记忆卡与全量记录 |
| `ProviderRow` / `ProviderTestState` / `ProviderEditorSheet` / `PersonaCard` | AI 通道行与测试状态、通道编辑 sheet、人格卡片 |
| `ScheduleRow` / `ScheduleMath` | 定时任务行与下次时间估算 |
| `CaptureSetupSheet` | 全局「捕获发送句柄」弹窗：文字/语音/朋友圈/评论条目按开关显示，状态行 + 重新检测 |
| `MomentsView` / `MomentsSettingsPanel` | 朋友圈页（时间线/详情/图片/视频占位/评论回复/空态引导）与「机器人 → 朋友圈」设置面板（v3.7+：状态总览 GlassCard + 三张可点击分区卡；读取卡保留读取与显示并新增记忆开关，互动卡含互动对象只读行（来源为聊天白名单私聊对象）/动作/无上限频率/识图/立即检查/最近互动，发布卡保留写通道与自动发布全部设置） |
| `MomentCommentSheet` | 朋友圈评论/回复输入面板（`Views/Components/MomentCommentSheet.swift`）：目标动态 + 被回复评论、1000 字进度与分级计数、写开关/`comment_ready` 提示 +「重新检测」+「去捕获/查看步骤」、二次确认与失败提示 |
| `MomentsInteractionActivitySheet` | 「最近互动」只读 sheet（560×520）：动作/对象/动态作者/被回复评论/生成正文/识图条数/结果与错误；演练草稿也会记录；「重置互动记录」二次确认后清空账本与列表 |
| `MomentsTargetsSheet` | 自动发布「发布对象」多选 sheet：只列开启 AI 自动回复的私聊会话，支持逐人开关与清空（`MomentsSettingsPanel.swift` 内部） |
| `MomentsOutboxSheet` | 「演练草稿」只读列表（`Views/Components/MomentsOutboxSheet.swift`）：演练模式生成，可删除/清空，不发送；数据来自 `SnsOutboxStore`（账号目录 `sns-outbox.json`，上限 20 条） |
| 记忆 v2：角色列表 / 记忆卡行 / 全量记录 sheet / 记忆设置 sheet | 记忆卡模式（左栏角色、右栏记忆卡；人格来自人格设定，无每会话人设卡；导入旧记忆与 Markdown/JSON 导出） |
| `LogRow` / `ReleaseNotesView` | 日志行；更新内容渲染（标题/列表/代码/引用分块，行内 Markdown 交给 `AttributedString`） |

## 7. 交互约定

### 文案与问号提示

- 文案契约（术语表、句式、分场景规则、本地化）见 [`copy-style.md`](copy-style.md)，修改任何用户可见文案前先读它。
- 解释性长文案（原理/背景/边界/数据位置）改用 `HelpTip`：小问号图标，悬停约 0.6 秒弹出解释，移开收起；
  同时通过 `accessibilityHint` 提供给 VoiceOver。行内只保留一句可见说明。
- `SectionCard` / `SettingsRow` / `FormField` / `SettingsSection` 都提供 `help:` 参数，在标题旁自动加问号。
- **风险、前置条件、不可逆后果与用户必须执行的步骤不得只放进问号提示**；禁用控件仍须就地说明原因。
- 每条解释 ≤ 120 个汉字；同一行/分组最多一个问号；同屏不重复同一句说明。

### 键盘快捷键

| 快捷键 | 行为 |
| --- | --- |
| ⌘1 … ⌘8 | 总览、会话、朋友圈、机器人、AI 模型、人格设定、记忆库、运行日志 |
| ⌘0 | 设置页 |
| ⌘, | 打开系统设置场景 |
| ⌘↩ | 会话页发送消息（服务连接时） |
| ⌘W | 隐藏主窗口（不退出、不销毁） |
| ⌥⌘Q | 退出 WeChat AI（⌘Q 已不再绑定退出） |
| Esc | 关闭 sheet / 确认框 |

### 状态与错误

- Core 未连接：发送按钮、清理、测试等操作禁用并显示「服务未连接」；不制造成功结果。
- 异步操作：`ProgressView`/`ProgressPanel`；Hook 安装显示 `onProgress` 百分比。失败用 `InlineNotice(.danger)`
  + Toast，不吞错；编辑 sheet 保存前校验并展示错误。
- 破坏性操作（删除通道/人格/任务/记忆卡、清理聊天记录、清空日志、安装/还原 Hook）均二次确认；
  配置修改即时持久化。
- 回复进度：状态条以 `TimelineView` 每 0.25s 刷新计时（仅活动阶段），完成态 3s、失败态 60s 后自动清理；
  失败可立即点 × 收起。计时数字使用 `monospacedDigit`，避免跳动。

### 禁用态与依赖原因

- **禁用必须给原因**：任何被父开关或前置条件门控的控件，都要在所在卡片/行内解释「为什么灰」，
  不允许出现「灰着但不知道为什么」。实现方式（与「机器人 → 朋友圈」v2 面板一致）：
  - 父开关行的 subtitle 写清依赖链（如「开启后才能手动或自动发布」）；
  - 整组被门控时在卡片内用一条 `InlineNotice(.warning)` 汇总当前真正阻塞的项（朋友圈自动发布卡的
    「还不能自动发布」即此模式），不要逐行重复同一句；
  - 运行期配置尚未同步（需重启机器人 / bridge）时用 warning 说明「配置待生效」，而不是只把控件置灰；
  - 只读信息用 `PillLabel` 或说明文本呈现，不要做成看起来可编辑的假控件（伪设置一律不进面板）。
- 同一原因只出现一次：行 subtitle 已说明的，不再额外叠一条同义通知。

### 会话收起

- 两个等价触发：再次点击会话列表中当前选中的行，或再次点击侧边栏「会话」入口。两者都把
  `selectedConversationID` 置为 `nil`，详情区回到「选择一个会话」空状态，会话列表保持展开；点击其它行
  正常切换，`onChange` 不再在 nil 时自动选回第一条。
- 收起只影响当前打开的对话，不改变未读、置顶或会话数据；进入会话页时不自动打开第一条，只清理已失效的
  选中项。

## 8. 可访问性

- 所有图标按钮有 `accessibilityLabel` / `.help`；行级组件使用 `.accessibilityElement(children: .combine/.contain)`，
  会话行提供未读/选中状态；机器人页分栏条按 `isSelected` 暴露选中状态并带 `accessibilityLabel` 与 `.help`。
- 聊天气泡朗读「发送者 + 类型 + 内容 + 时间」；语义字体 + 系统缩放，关键数字使用 `monospacedDigit`，
  深浅色全部使用语义色/材质；`accessibilityReduceMotion` 关闭侧边栏选中高亮、Toast 与骨架/脉冲动画，
  静态状态点代替重复动画以保证低能耗。

## 9. 文件结构

```
app/Sources/WeChatBot/
├─ DesignSystem/
│  ├─ Theme.swift
│  ├─ Surfaces.swift
│  ├─ Controls.swift
│  └─ Feedback.swift
├─ Views/
│  ├─ RootView.swift            # 主窗口 + PageRouter + 全局捕获句柄/首次向导 sheet
│  ├─ SidebarView.swift         # 侧边栏 + 状态胶囊
│  ├─ DashboardView.swift
│  ├─ ConversationsView.swift
│  ├─ ChatCleanupSheet.swift    # 会话内清理聊天记录（sheet）
│  ├─ MomentsView.swift         # 朋友圈时间线/详情/图片/发布/评论回复
│  ├─ MomentsSettingsPanel.swift # 机器人 → 朋友圈
│  ├─ BotView.swift
│  ├─ VoiceSettingsPanel.swift  # 机器人 → 语音（复用组件）
│  ├─ AIModelsView.swift
│  ├─ PersonasView.swift
│  ├─ MemoryView.swift
│  ├─ MemoryEditorSheet.swift / MemorySettingsSheet.swift # 记忆卡编辑 / 记忆设置
│  ├─ CharacterFullArchive.swift # 记忆卡全量记录 sheet
│  ├─ SchedulesPanel.swift      # 机器人 → 定时
│  ├─ LogsView.swift
│  ├─ SettingsView.swift
│  ├─ SettingsUpdateSection.swift # 设置 → 更新（GitHub Releases）
│  ├─ CaptureSetupSheet.swift   # 全局「捕获发送句柄」弹窗
│  ├─ OnboardingView.swift
│  ├─ MenuBarView.swift
│  └─ Components/               # 21 个复用组件/编辑 sheet（含 ReplyProgressBar、DashboardSystemVitalsCard）
├─ Core/
│  ├─ AppStore.swift / AppStore+Runtime.swift / AppStore+Moments.swift
│  ├─ AppLifecycle.swift        # 主窗口注册表、关闭即隐藏、AppDelegate
│  └─ MenuBarController.swift   # NSStatusItem：左键开合状态面板（右键不执行操作）
└─ WeChatBotApp.swift           # Window / Settings / Commands / MenuBarController 装配
```

## 10. 与 Core 的边界

UI 只读 `AppStore` 状态并调用既有方法，不直接访问数据库/网络/进程：

- 状态：`settings/providers/personas/schedules/conversations/messages/logs/hookStatus/stats/batteryStatus/deepSeekBalance/isBalanceRefreshing/activeAccountID/activeAccountIsUnassigned/accountSwitchNotice/savedWeChatAccounts/isSwitchingAccount/moments/isCaptureSetupPromptPresented/voiceRuntimeStatus`
- 运行时：`startBot/stopBot/refreshStatus/refreshSystemVitals/installHook(onProgress:)/restoreWeChatBackup/testProvider/
  sendManualMessage/clearMessages/deleteMessage/saveAPIKey/apiKey/deleteAPIKey/persist/reload/appendLog/clearLogs/
  refreshWeChatAccount/dismissAccountSwitchNotice/refreshVoiceStatus/presentCaptureSetupPrompt/prepareMoments`
- 朋友圈：UI 只读 `store.moments`（`MomentsStore`）并调用其 `loadInitialIfNeeded/refresh/loadMore/pollSync/
  loadDetail/retryAfterPriming/refreshPrimingStatus/submitComment`，不直接调用 `SnsClient` 或拼 HTTP；
  `publish` 只由自动发布（Runtime）调用；设置只改 `settings.bot.snsSettings` 后 `persist()`。契约见
  [`sns.md`](sns.md)。
- 账号：设置页只调用 `store.refreshWeChatAccount()` 与 `store.dismissAccountSwitchNotice()`，不直接调用
  `AccountProfile.activate` / `MemoryStore.switchDatabase`，也不提供手动切库入口；账号路径只读展示。
  契约见 [`accounts.md`](accounts.md)。
- 记忆卡页：只通过 AppStore 暴露的记忆 v2 方法读取/编辑/置顶/压缩/导出（内部走 `CharacterStore` /
  `MemoryEngine`），不直接打开 `memory.sqlite`；记忆设置保存到当前账号 `profile.json` 的 `bot.memory`。
  人格只通过「人格设定」页维护，记忆页不读写人设副本。契约见 [`memory.md`](memory.md) §3、§10–§11。
- 配置集合（providers/personas/schedules）由 UI 修改数组后调用 `persist()`，Core 不提供冲突的 CRUD。
- 应用内更新：UI 不直接发网络请求或操作 bundle，只读 `UpdateCenter.shared` 的
  `state/latestRelease/currentVersion/currentBuild/installTarget/installTargetError/
  autoCheckEnabled/skippedTag` 状态，并调用其 `checkForUpdates()`/`downloadAndInstall()`/
  `setAutoCheck(_:)`/`skipAvailableRelease()`/`clearSkippedRelease()`/`reloadSettings()`/
  `refreshIfNeeded()`/`openReleasePage()`/`openAllReleasesPage()`/`revealUpdateLog()` 与
  `requestUpdatePageFocus()`/`consumeUpdatePageFocus()`（徽标深链）。`UpdateCenter` 是独立
  `@MainActor @Observable` 单例，不并入 `AppStore`；设置写入 `store.settings.updates` 并持久化。
  契约见 [`updates.md`](updates.md) 与 [`core-services.md`](core-services.md) §5.12。

## 11. 验证与已知限制

验证状态（最近一次真机与单测走查；历史细节见 CHANGELOG）：

- `swift test` 886 项执行（884 通过 / 2 项按环境跳过，0 失败；41 个测试文件），覆盖批量记忆、压缩器、权重强化、
  旧库迁移、防睡眠三档决策、回复进度倒计时、自消息路由、通讯录标题补全、拍一拍回复、免唤醒词窗口、
  appmsg 分类与历史文本修复、入站帧单次解析、R3 版本门禁/运行期配置合并、识图设置与图片描述落库、
  朋友圈模型/状态机/同步/发布可见性、互动无上限/评论句柄捕获判定（`CaptureSetupTests`）、
  朋友圈记忆映射与落库幂等（`SnsMemoryIngestorTests`）。
- 微信 4.2.0.5 真机 E2E：Gadget 注入 + ad-hoc 重签后微信正常启动；私聊/自消息入站、通讯录读取、
  R3 文本发送（含 bridge 重启后句柄恢复）通过；群聊 @ / 拍一拍沿用既有逻辑未单独复测；图片获取链路
  已实现（CDN 触发下载待复测）。除朋友圈外的 8 个侧边栏页面、首次向导、设置场景、菜单栏、浅色/深色、
  会话三栏、气泡类型、过滤/暂停/导出与表单校验均已人工走查。
- 朋友圈：页面/详情/图片查看/评论回复按 §5.3 实现，列表/状态机/JSON 解码由单测覆盖；4.2.0.17 真机已验证
  被动缓存读取、主动刷新、图片 thumb/full、文字发布（partial 与 public 联调）与评论发送，回复/点赞与实时
  通知仍未验证（详见 [`sns.md`](sns.md) §0、§8）。捕获发送句柄弹窗的条目/状态判定（含 2026-11-09 新增的
  评论句柄条目）由 `CaptureSetupTests` 覆盖；评论/朋友圈记忆的 UI 走查待补。
- 朋友圈设置面板 2026-11-09 版：状态总览 + 三张可点击分区卡、读取卡记忆开关、互动无上限/评论捕获 CTA、
  发布卡去捕获入口均**只完成编译**；界面走查（含中英文文案、窄窗口、禁用态说明）与自动发布/自动互动真机
  联调均**未验证**，验收清单见 [`sns.md`](sns.md) §9。
- 菜单栏点击语义与面板收起走查通过，`MenuBarClickTests` 覆盖映射与兜底；首开耗时未用 Instruments 量化。
  空闲 CPU（关闭脉冲动画后）约 2–3%，旧 `MenuBarExtra` 写回循环导致的 100% 已消除。
- 会话收起、窗口/Dock 图标（`LSUIElement=true`，`.regular ⇄ .accessory`）、台前调度、群聊 @ 误触发回归、
  引用消息可见性回归、白/黑名单合并、人格温度迁移、重复入口清理、防睡眠、记忆 v2（四类记忆、0.92 折叠
  与 supersede、批量提取/本地兜底、全量互动与导出）、记忆页清理/统计收敛、全局共享记忆、记忆库入口行为
  均通过单测/构建核对，按本文件对应页面设计实现；旧 `MemoryStore` 记忆方法保留只读兼容，旧长期记忆页不再
  展示（旧记忆需手动导入）。

限制 / 外部依赖：

- 系统通知与登录项尚未接入（设置开关可持久化，但不弹通知/不注册 `SMAppService`）。
- 窗口/Dock 行为通过 `NSApplication.ActivationPolicy` 实现（`.regular` ⇄ `.accessory`），窗口可见性是
  唯一决定因素；`app/Packaging/Info.plist` 声明 `LSUIElement=true`，避免 AppKit 在菜单栏激活时把隐藏
  模式重置回 regular；`applicationDidBecomeActive` / 空间切换后按窗口状态重新确认。旧 `showDockIcon` 键
  会被忽略。台前调度只在主窗口打开期间（`.regular`）可用，关闭后退回 `.accessory` 并从应用条移除，这是
  「仅菜单栏常驻」的已知取舍；已用隔离副本配合 `lsappinfo` 走查切换，安装版 Dock 图标视觉待补。
- 「拍一拍」：4.1.15.55 为 appmsg（type=49，`<appmsg><type>62</type><title>…拍了拍…</title>`），Hook 提取
  `<title>` 为文本、原始 XML 保留在 `raw_message`，规则层按文本、`<type>62</type>`、`sysmsg type="pat"`
  多路径匹配；4.1.12 及更早兼容 localType 10000 / sysmsg 形态；4.2.0.5 沿用，本轮未单独复测。防睡眠
  插拔电源后的状态刷新与真机睡眠行为尚未人工走查；Hook 安装进度依赖 Core `onProgress`，失败信息透传。
- 从源码直接启动（非 `.app`）时 `Bundle` 版本号为开发回退值，正式版本由打包脚本注入；Core `ProcessRunner`
  启停偶发异常（`-[NSConcreteTask terminationStatus]: task still running`）与 UI 无关，已同步 swift-core。
- 多账号 UI、应用内更新（设置 → 更新、三处徽标、确认弹窗、下载/校验/安装进度与错误态）为 docs-first 契约；
  真实切号、真实升级、失败回滚、Gatekeeper 放行与英文文案的窗口走查待补验，不写入本文「已验证」；契约见
  [`updates.md`](updates.md)。
- 开发期截图位于 `/tmp/wechatai-*.png`、`/tmp/shot-*.png`、`/tmp/demo-*.png`，不纳入仓库。

> 语音设置统一在「机器人 → 语音」提供，复用共用组件 `VoiceSettingsPanel`；设置页已不再提供「语音」分类。
> 会话页只保留全局语音设置，不提供会话级覆盖。
> 捕获发送句柄统一使用全局 `CaptureSetupSheet`（见 §5.14）：首次开启语音/朋友圈或机器人启动检测到缺失时
> 自动弹一次；机器人每次启动都会重新检测，同一次运行内最多一次。Qwen3-TTS 的安装/启动、音色选择与试听
> 见 [`voice.md`](voice.md) §4.1。
