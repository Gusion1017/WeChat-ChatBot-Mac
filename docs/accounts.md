# 多微信账号数据隔离（账号档案）

> 自 2026-10-27 起，App 以**当前登录的微信账号**为边界保存聊天与机器人数据：换一个微信账号登录，聊天记录、记忆卡（角色目录）、
> 会话设置、机器人配置、人格与定时任务自动切到该账号自己的档案；AI 模型、Hook、OneBot、Keychain、本地 TTS 安装与音色等「本机能力」仍全局共享。
>
> 实现：`Services/WeChatAccountResolver.swift`（识别）、`Services/AccountProfile.swift`（档案/迁移）、`Models/AppSettings.swift` +
> `Services/SettingsPersistence.swift`（全局/账号双文件）、`Core/AppStore+Runtime.swift`（启动、切号、换库）。总体架构见
> [architecture.md](architecture.md)，记忆库见 [memory.md](memory.md)，UI 见 [ui-design.md](ui-design.md)。
>
> 本文是账号档案的行为契约：改存储布局、识别规则、切号顺序或迁移策略时，先改这里，再改代码。

## 1. 行为定义

### 1.1 按微信账号隔离（随账号切换）

- **SQLite 数据库**：会话、消息、旧版长期记忆/`memory_state`（只读兼容）、日志、通讯录缓存、统计与 KV（包括 `onebot.self_id` /
  `onebot.self_id_source`）。
- **角色目录（记忆 v2）**：`accounts/<id>/characters/<会话 key>/memory.sqlite`，每微信会话一个目录，随账号目录整体复制/认领；另
  有固定 `characters/c-__global__/memory.sqlite` 全局共享记忆（手动维护、注入所有会话，每账号一份）。人格不放在角色目录，统一来自
  `profile.json` 的人格设定（见 [memory.md](memory.md) §3、§4.4）。
- **`profile.json`**：`bot`（触发方式、白/黑名单、节奏、互动、语音偏好、默认人格与默认通道、`memory` 记忆设置）、`personas`、
  `schedules`。
- **新产生的媒体文件**：入站图片/语音、TTS 输出等，写入 `accounts/<id>/media/`。

### 1.2 全局共享（不随账号切换）

- `config.json` 中的 `general`（外观/菜单栏/开机启动/语言/防睡眠等）、`hook`、`onebot`、`ai`、`providers`。
- Keychain API Key（service = `com.gusionw.wechatai`，account = `AIProvider.apiKeyReference`）。
- 本地 TTS 安装、运行环境、模型与音色（`cosyvoice/`；Qwen3-TTS-1.7B 单模型）。
- 崩溃日志与面包屑（`~/Library/Logs/WeChatAI/`）、bridge 运行日志（`~/Library/Logs/WeChatAI/bridge/`）、微信 App
  官方备份（`backups/`）。

### 1.3 升级遗留的旧媒体

旧版单库写在 `~/Library/Application Support/WeChatAI/media/` 的媒体文件**原样保留**：旧消息里的绝对路径仍可读，App 不移动/复制/删除；
升级后的新媒体只写 `accounts/<id>/media/`，旧目录不再写入，也不参与媒体清理。

## 2. 隔离矩阵

| 数据 / 能力 | 实际位置 | 随微信账号切换 | 说明 |
| --- | --- | --- | --- |
| 会话、消息、日志、统计、通讯录缓存、KV | `accounts/<id>/chatbot.sqlite` | ✅ | 当前账号库；WAL 模式 |
| 角色目录（只有 `memory.sqlite`） | `accounts/<id>/characters/` | ✅ | 每会话一个目录 + 固定 `c-__global__` 全局共享卡；人格不复制，来自账号 `profile.json`；随账号目录整体复制/认领，见 [memory.md](memory.md) §4.4 |
| 旧版长期记忆、`memory_state` | `accounts/<id>/chatbot.sqlite` | ✅ | v1 表只读兼容，运行时不写入、不召回 |
| 机器人 `bot` 设置 | `accounts/<id>/profile.json` | ✅ | 触发/名单/节奏/互动/语音偏好/默认人格与通道 |
| 人格 `personas` | 同上 | ✅ | 每个账号可维护自己的人格设定；是会话人格的唯一来源，不按会话复制 |
| 定时任务 `schedules` | 同上 | ✅ | 只有当前账号的任务参与调度 |
| 会话级设置（AI 开关、工作时段、备注、置顶、图片获取等） | 当前账号库 | ✅ | 存在 `conversations` / `messages` 等表 |
| 新媒体（图片/语音/TTS 输出） | `accounts/<id>/media/` | ✅ | bridge `-media_dir` 指向当前账号目录 |
| 旧版媒体 | `~/Library/Application Support/WeChatAI/media/` | ❌（只读保留） | 旧消息绝对路径继续有效，不迁移、不删除 |
| 通用设置 `general` | `config.json` | ❌ | 外观/菜单栏/语言/防睡眠等本机偏好 |
| Hook / OneBot / AI 通道设置 | `config.json` | ❌ | `hook`、`onebot`、`ai`、`providers` |
| API Key | macOS Keychain | ❌ | 删账号档案不会删除 Keychain 条目 |
| 本地 TTS 安装、运行环境、模型与音色 | `cosyvoice/` | ❌ | Qwen3-TTS-1.7B 约 4.7GB；按本机全局共享 |
| 崩溃日志 / bridge 日志 | `~/Library/Logs/WeChatAI/` | ❌ | 文件日志不区分账号 |
| 微信官方备份 | `backups/` | ❌ | 安装 Hook 前的完整备份 |
| 账号指针 | `account-state.json` | 全局 | 只记录当前/最近账号，不存业务数据 |
| 运行期 Hook 配置 | `runtime/` | ❌ | 由全局 Hook 设置生成 |

> **注意**：记忆 v2 按会话隔离，不共享记忆卡；旧版「全局记忆」只在只读旧表里，可在记忆面板手动导入到某个会话。人格设定在同一账号内是
> 全局模板（修改对所有使用该人格的会话生效），但不跨微信账号共享；换账号后看到的是新账号自己的角色目录与人格设定。

## 3. 存储布局

### 3.1 目录树

```
~/Library/Application Support/WeChatAI/
├── config.json                     # 全局设置（完整 AppSettings 镜像，兼容旧版回滚）
├── account-state.json              # 全局账号指针
├── accounts/
│   ├── _unassigned/                # 尚未识别微信账号时的临时档案（保留名）
│   │   ├── chatbot.sqlite
│   │   ├── profile.json
│   │   ├── characters/             # 每会话 + 全局共享卡
│   │   └── media/
│   └── <wxid>/
│       ├── chatbot.sqlite (+ -wal / -shm)
│       ├── profile.json            # 当前账号的 bot / personas / schedules
│       ├── characters/             # 每会话 c-<key>/memory.sqlite + c-__global__/ 全局共享
│       ├── media/                  # 该账号的新媒体
│       ├── logs/                   # 预留（当前为空；App 内日志仍在账号库）
│       ├── legacy-migration.json   # 仅旧版迁移目标有：标记旧数据已归入本账号
│       └── unassigned-claim.json   # 仅从 _unassigned 认领过的账号有
├── media/                          # 旧版遗留媒体（只读保留，不迁移、不删除）
├── backups/                        # 微信 App 官方备份（全局）
├── runtime/                        # 运行期 Hook 配置（全局）
├── cosyvoice/                      # 本地 TTS 安装：Qwen3-TTS 运行环境、模型与音色（全局）
└── chatbot.sqlite                  # 旧版单库（迁移后保留，不删除）
```

### 3.2 关键文件

| 文件 | 所有者 | 说明 |
| --- | --- | --- |
| `config.json` | `SettingsStore` / `SettingsPersistence` | 全局设置，保持旧路径与旧格式；同时保留 `bot`/`personas`/`schedules` 字段作为旧版回滚镜像，运行时由 `profile.json` 覆盖 |
| `account-state.json` | `AccountProfile` | `{"schemaVersion":1,"lastAccountID":"wxid_xxx","updatedAt":<Unix 秒>,"legacyMigrationDone":true}`；启动早期只读，`activate`/迁移后原子写。`legacyMigrationDone` 只有旧库迁移真正完成后才为 `true`，切号/回滚不会替它置位 |
| `accounts/<id>/chatbot.sqlite` | `MemoryStore` | 当前账号的会话/消息/日志/KV（旧 `memories` / `memory_state` 只读兼容）；切换账号即关闭旧库、打开新库 |
| `accounts/<id>/characters/` | `CharacterStore` | 记忆 v2 的每会话角色目录（只有 `memory.sqlite`）+ 固定 `c-__global__` 全局共享卡；人格来自账号 `profile.json`，不写 `persona.md`；随账号目录复制/认领 |
| `accounts/<id>/profile.json` | `SettingsStore` | `ProfileSettings`：`schemaVersion`、`bot`（含 `memory` 设置）、`personas`、`schedules`；缺失时用默认值 |
| `accounts/<id>/media/` | `OneBotClient` / 语音流水线 | 该账号新媒体的落盘目录，按日期分子目录（`<yyyy-MM-dd>/`） |
| `accounts/<id>/logs/` | 预留 | 预留给未来按账号切分文件日志；当前账号库内 `logs` 表才是 App 内日志 |
| `accounts/<id>/legacy-migration.json` | `AccountProfile` | 旧版迁移标记；存在表示该账号接收了旧单库数据；内容以供排查为主，不是业务配置 |
| `chatbot.sqlite`（根） | 旧版 | 迁移后保留；应用不再写入，供回滚或人工核对 |
| `media/`（根） | 旧版 | 旧媒体只读保留 |

### 3.3 JSON 形态

`account-state.json`（示例，wxid 为占位符）：

```json
{
  "schemaVersion": 1,
  "lastAccountID": "wxid_xxx",
  "updatedAt": 1761000000,
  "legacyMigrationDone": true
}
```

`profile.json`（示例，省略具体人格/任务内容）：

```json
{
  "schemaVersion": 1,
  "bot": { "enabled": false, "replyToDirect": true, "keywords": ["AI"] },
  "personas": [ { "id": "persona-default", "name": "默认助手", "isDefault": true } ],
  "schedules": []
}
```

`ProfileSettings.schemaVersion` 当前为 `1`；`BotSettings`/`Persona`/`ScheduledTask` 仍按各自 Codable
兼容旧键。旧 `config.json` 缺少新字段时不会导致 profile 解码失败。

### 3.4 写入与原子性

- `AccountProfile` 的静态状态（activeID、pendingNotice 等）由 `NSLock` 保护；`preparePaths()` 可重复调用。
- 所有 JSON/状态写入使用 `Data.write(options: .atomic)`（或临时文件 + replace）；目录创建幂等。
- 除迁移「复制」外，不 `removeItem` 用户数据目录；旧单库、旧媒体、旧 `config.json` 一律保留。
- 账号 ID 同时用作目录名，不做额外编码：校验规则见 §4.2，已排除路径穿越。

## 4. 账号识别算法

### 4.1 识别优先级

`WeChatAccountResolver.resolve()` 只读文件系统元数据（`stat`/JSON），不打开 SQLite。微信 Documents 根默认为
`~/Library/Containers/com.tencent.xinWeChat/Data/Documents/`，按以下优先级识别：

1. **登录标记 mtime（source = `loginMarker`）**：取 `app_data/login/<wxid>/key_info.dat` 与
   `xwechat_files/all_users/login/<wxid>/key_info.db`（含 `-wal`）最近修改时间的**最大值**；只接受在
   `xwechat_files/<wxid>_<suffix>/` 下确有数据目录的账号，避免把已卸载/残留登录标记当作当前账号。
2. **账号目录活动（source = `accountActivity`）**：取 `xwechat_files/<wxid>_<suffix>/` 本身、`temp/`、`db_storage/`、
   `db_storage/session/session.db`、`db_storage/message/message_0.db` 的 mtime 最大值；等价旧 `AppResources.imageDirectory()`
   启发式，用于登录标记不可读/不新鲜时。
3. **都没有** → 返回 `nil`。

多个账号 mtime 相同时按账号字典序稳定排序，结果可重复；识别成功时通过 `WeChatAccountResolution.imageDirectory` 带回该账号的
`xwechat_files/<dir>/temp`（存在时），用于 bridge `-image_path`。

### 4.2 账号 ID 与 mask 显示

- 合法账号 ID：`^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`；`_unassigned` 是保留名（只表示「尚未识别」），不能作为真实账号目录。
- `AppAccount.maskedID`：`_unassigned` → `未识别`；长度 ≤ 10 → 原样；否则 → 前 9 个字符 + `…` + 后 4 个字符。
- UI、日志、文档示例只展示 mask 后的值或 `wxid_xxx` 占位符，不写真实 wxid。

### 4.3 权威确认：bridge `get_login_info`

resolver 是启动/启动机器人时的账号判定来源，但不是绝对事实（微信未登录、历史账号目录、登录标记滞后都会影响），因此 bridge 启动后 App 还会请求 `get_login_info` 确认：

- 已识别账号时把 `AccountProfile.activeID` 传给 bridge（`-self_id`），正常情况下回包与档案一致；一致 → 记录 `onebot.self_id` 与
  `onebot.self_id_source=login`，历史修复可信任它并跳过历史事件反推。
- 不一致（`-self_id` 未被采用、显式 `onebot.imagePath` 指向别的账号目录、或当前仍是 `_unassigned`）→ 以回包为准走切号流程（§5.3），
  绝不在旧账号库上按新账号 selfID 做「修复」，否则会污染两个账号的数据。
- 返回值不满足账号 ID 校验（无法安全用作目录名）→ 记 warning 并忽略，不落盘。

> 「换号」的常规判定在启动/启动机器人前（resolver + 登录标记），bridge 回包是运行期确认与兜底；冲突以回包为准，但不会拿它去改写其它账号的库。

### 4.4 `preparePaths()` 的行为

`AccountProfile.preparePaths()` 在 App 启动早期、`SettingsStore.load()` **之前**同步调用，只做 `stat`/JSON 读取，不打开 SQLite：

1. 用 resolver 检测微信账号，并读 `account-state.json`（缺失/损坏按无状态处理）。
2. provisional activeID：若 `state.lastAccountID == _unassigned`、`_unassigned/` 已有数据库/`profile.json`、且检测到真实账号 →
   **保持 active = `_unassigned`**，不写 state，由 bootstrap 在开库前认领（§5.1、§7.2）；否则用检测到的账号；否则
   `state.lastAccountID`（若合法）；否则 `_unassigned`。旧库 owner 不在这里读取，只有 `state` 缺失/不可用时才由迁移读取（§6）。
3. 除「等待认领」外，若检测到的账号与 `state.lastAccountID` 都存在且不同：设 `pendingNotice = "检测到微信账号已切换"` 并把
   detected 原子写回 `account-state.json`（只写 JSON、`legacyMigrationDone` 沿用旧值），避免下次启动回退到旧账号或重复提示。
4. 设置 active，调用 `ensureDirectories(for:)`。

`runLegacyMigrationIfNeeded()` 之后可能把 active 改成旧库 owner，调用方需重新加载设置（§5.1）。

## 5. 切号流程

切号只有一个入口：`RuntimeCoordinator.switchAccount(to:reason:)`。所有路径（启动检测、启动机器人前检测、运行中
`get_login_info` 不一致、设置页「重新检测」）最终都收敛到它，避免出现多套「部分切库」逻辑。

### 5.1 启动时（App 启动）

```
AppStore.init
  └─ AccountProfile.preparePaths()          # 只读 stat/JSON，决定 provisional active
  └─ SettingsStore.load()                   # config + 当前 active 的 profile
RuntimeCoordinator.bootstrapIfNeeded / performBootstrap
  └─ AppPaths.ensureDirectories()
  └─ Task.detached { runLegacyMigrationIfNeeded() }      # 后台 IO；可能把 active 改为旧库 owner
  └─ active 变化或写了 profile 种子：applyLoadedSettings(load())、refreshAccountObservables、清空 selfID
  └─ Task.detached { claimUnassignedForStartup(...) }    # _unassigned 有数据时在开库前归入目标账号
  └─ memory.open() → characterStore.activate() → LogPipeline.attach(...)
  └─ 启动期修复（自消息/伪群/appmsg/引用）仅在本账号库内；loadPersistedState / stats / refreshStatus
startRuntime（用户点「启动机器人」）
  └─ resolver 再检测；账号变化先 switchAccount；bridge 的 -self_id / -image_path / -media_dir 用当前账号
```

- 迁移与 `_unassigned` 认领必须在 `memory.open()` 之前完成，否则会打开旧单库/临时库，或让「已存在的目标库」被迁移误判为已完成。
- `MemoryStore.shared` 在 bootstrap 前禁止隐式 `ensureOpen`；`LogPipeline` 延后到最终库打开后 attach；迁移/认领是阻塞 IO，必须放在 `Task.detached`。
- 角色目录跟随账号目录，`characterStore.activate()` 在 `memory.open()` 之后执行；切号 `suspend()` 后禁止打开记忆卡（best-effort）。启动阶段 bridge 回报账号若与档案不一致，先记 `pendingAccountSwitch`，由 `startRuntime` 收尾后 `consumePendingAccountSwitchIfNeeded()` 切换。

### 5.2 启动机器人前

`startRuntime()` 在启动 bridge 前调用 `AccountProfile.detectedAccountID()` 再检测一次：

- 检测到的账号与当前档案不同 → 先 `switchAccount(to:reason:.detectedBeforeStart)`，再读新账号 `profile`、拼接 bridge 参数；
- 已识别账号时 `-self_id` 用 `AccountProfile.activeID`（不信任旧库可能被污染的 selfID）；未识别时沿用运行时 `selfID`，等
  `get_login_info` 确认后再认领/切换；
- `-image_path` / `-media_dir` 强制用当前账号目录：已识别时忽略全局 `onebot.imagePath`（可能来自上一个账号），图片目录取
  `xwechat_files/<dir>/temp`、媒体目录取 `accounts/<当前账号>/media`；
- 当前账号的图片临时目录不存在时**显式阻止启动**并提示先登录微信/打开图片，不回退到按 mtime 猜账号的 `AppResources.imageDirectory()`；
- 未识别账号（`_unassigned`）时才沿用旧的显式 `onebot.imagePath`/自动探测行为。

### 5.3 运行中登录不一致

bridge 返回 `get_login_info` 后，`RuntimeCoordinator.adoptSelfID(_:)`：

- `id == activeID` 且 active 不是 `_unassigned` → 记录权威 selfID 与来源，在**当前账号库**内补跑历史修复；
- `id != activeID` 或 active 为 `_unassigned` → 调
  `switchAccount(to: id, reason: .loginMismatch)`，而不是直接在当前库改 selfID；
- 若此时 `startRuntime` 正在逐段启动（bridge → WS → scheduler），先挂起 `pendingAccountSwitch`，等启动收尾后再切，避免拆
  到一半的运行时。

`switchAccount` 的顺序：

1. 若机器人/运行时在跑，先停止（bridge、OneBot、调度、媒体队列；停止过程中 flush 日志、设置与统计）。
2. drain 旧账号后台写入任务（记忆维护、长记忆总结、群昵称回填、统计落盘、消息预取：cancel + await），关键 await 后比对 `accountEpoch`，防止 A
   的提取结果写进 B。
3. `characterStore.suspend()`（关闭全部角色记忆卡连接）。
4. `memory.suspend()`（close + 禁止 `ensureOpen` 隐式重开，保证认领前库保持关闭）。
5. `claimUnassigned(by:)`（若 active 仍为 `_unassigned`）或 `AccountProfile.activate(id)`。
6. `memory.switchToActiveAccountDatabase()` 打开新账号库。
7. `characterStore.activate()` 指向新账号的 `characters/`。
8. `SettingsStore.load()` / `store.applyLoadedSettings()` 应用新账号 `profile`。
9. 清空内存中的会话、消息、角色与记忆状态、日志、统计、选中会话、回复进度。
10. 从新库载入会话/消息/状态。
11. `store.persist()`（profile 写回新账号）。
12. 更新 `activeAccountID` / `activeAccountIsUnassigned` / `savedWeChatAccounts` /
    `accountSwitchNotice`，`store.settings.bot.enabled = false`、`isBotRunning = false`。

切号期间 `isSwitchingAccount = true`：设置页「重新检测」与启动按钮禁用，`startBot` / `startRuntime` / `reconcileWeChatAccount`
拒绝并发启动，避免 bridge 用旧档案身份启动。失败时尽力 `activate(previousID)` 并重开原库，把 `isBotRunning` / `bot.enabled` 复位为 false、
记录原因并提示重试，不会把两个账号数据写进同一库。
**切号不会自动重启机器人**：运行中切号会停止机器人，需用户手动重新启动，避免没注意到切号就自动用新账号回复。

### 5.4 三条路径对比

| 触发时机 | 检测方式 | 对 active 的处理 | 用户可见结果 |
| --- | --- | --- | --- |
| App 启动 | `preparePaths` + 旧版迁移 + `_unassigned` 认领 | provisional →（迁移可能改为旧库 owner）→ 认领临时档案 → 打开最终库 | 启动后直接是正确账号；若检测到变化/认领显示提示 |
| 点「启动机器人」前 | resolver 再检测 | 启动 bridge 前切到检测到的账号 | 新账号的聊天/配置；bridge 用新账号 selfID 与媒体目录 |
| 运行中换微信账号 | bridge `get_login_info` 权威值 | 停止运行时 → 切库/配置 → 提示 | 机器人停止、数据切换、总览提示；需手动重新启动机器人 |

设置页「重新检测微信账号」调用 `store.refreshWeChatAccount()`：仅当检测到的账号与当前档案不同才切库并返回是否切换；检测不到、无变化或
`managesAccountProfiles == false` 时返回 `false`，不触碰本机账号目录。

### 5.5 失败处理

- 任一步失败都不得把两个账号的数据写进同一库：切换在停运行时之后才 `activate` / 换库，失败时保持运行时停止，写错误日志并提示用户重试。
- 重新检测、重新启动 App 或再次启动机器人都可以重试；不要手动把 `account-state.json` 改成别的账号来「救数据」——这会让 App 打开错误档案。

## 6. 旧版迁移

### 6.1 触发条件

升级后首次启动时：`account-state.json` 不存在/不可用，或存在但 `legacyMigrationDone=false`；且根目录存在旧版单库
`chatbot.sqlite`（或只剩旧 `config.json` 的账号级设置）。没有旧单库时也会写 state（`legacyMigrationDone=true`）并把「只
剩配置」的 profile 种下。

迁移在 `performBootstrap` 中通过 `Task.detached` 调用 `AccountProfile.runLegacyMigrationIfNeeded()`，
同步返回 `LegacyMigrationOutcome`：

```swift
struct LegacyMigrationOutcome {
    var activeAccountID: String
    var didMigrate: Bool
    var legacyOwnerAccountID: String?
    var notice: String?      // 可展示给用户的中文说明；nil = 无需提示
}
```

### 6.2 确定旧数据的 owner

- 用 SQLite 打开旧库（仅执行 SELECT / Backup API，不写业务数据）查询：
  `select value from settings where key='onebot.self_id'`。注意：旧库通常是 WAL 模式，旧 App 干净退出后可能只剩主库、
  没有 `-wal`/`-shm`；此时 READONLY 连接会 CANTOPEN，必须用 READWRITE 连接让 SQLite 恢复 WAL 辅助文件。
- owner = 该值通过 `AppAccount.isValidID` 校验的账号；否则视为无 owner。
- target = `owner`（有效）或当前 provisional active（resolver 结果，或 `_unassigned`）。

> 旧库的 `onebot.self_id` 是旧版运行时从 bridge/历史事件学到的账号，最接近旧数据的真实归属。不读旧 `config.json` 猜 owner；旧配置只用于
> seed profile。

### 6.3 迁移动作（只 copy，不删除）

- **数据库**：用 **SQLite Backup API** 打开旧库（READWRITE，仅备份），复制成目标目录里的一致快照，再移动到
  `accounts/<target>/chatbot.sqlite`；**仅当目标主库不存在时复制**（已存在说明迁移过，不再覆盖）。不裸 copy `-wal`/`-shm`——
  Backup API 已含 WAL 中已提交内容，避免并发写下复制到不一致的库。
- **profile 种子**：仅当 `accounts/<target>/profile.json` 不存在、且旧 `config.json` 顶层确有 `bot` / `personas` / `schedules` 时写入
  `ProfileSettings` 种子；缺失这些键时保留 `.default`。旧库不存在但只剩旧配置时，当前 active 是真实账号也只做 profile 种子。
- **角色目录**：`characters/` 不单独迁移；新卡在登录后收到消息（或首次回复）时按人格设定创建（只有 `memory.sqlite`，不写
  `persona.md`、不生成初始记忆；首次维护补总结最近 500 条建卡前历史，见 [`memory.md`](memory.md) §7.2）。旧 `persona.md` 在创建/加载时
  best-effort 移到废纸篓；打开旧 `memory.sqlite` 时执行起点迁移（生成型 `kind='origin'` 删除、用户编辑过的转普通置顶手写记忆，见
  [`memory.md`](memory.md) §4.3）。旧库 `memories` 表随快照只读保留，需要时用记忆面板「导入旧记忆」（见 [`memory.md`](memory.md) §3.3、§13）。
- **目标已有空库**：若目标库存在、迁移 marker 不存在且 `conversations/messages/memories/settings` 全为空，用旧库快照原子替换
  （兼容旧实现「迁移前提前开库」的空壳）；有任何业务数据则绝不覆盖。
- **迁移标记**：写 `accounts/<target>/legacy-migration.json`，记录 `schemaVersion` / `migratedAt` / `targetAccountID` /
  `legacyOwnerAccountID`（有 owner 时）/ `legacyDatabasePath` / `copiedDatabase` / `seededProfile`，便于排查与幂等判断。
- 旧 `chatbot.sqlite`、旧 `config.json`、旧 `media/` 与旧库 `-wal`/`-shm` **全部保留**；迁移完成后写 `account-state.json`，
  记录最终 active、`updatedAt` 与 `legacyMigrationDone=true`。

### 6.4 最终 active 与提示

`finalActive` 规则：

1. 当前 active 不是 `_unassigned` → 保持当前 active（例如用户已经登录了新账号，旧数据仍归 owner，不把新账号的当前会话切走）；
2. 否则 owner 有效 → owner；
3. 否则 target（即当前 active）。

`notice` 优先说明「旧版本数据已归入账号 <maskedID>」；没有迁移/无需提示时为 `nil`。UI 在总览用 `InlineNotice` 展示，见
[ui-design.md](ui-design.md)。

### 6.5 幂等与重试

- `account-state.json` 存在、`lastAccountID` 可用且 `legacyMigrationDone=true` → 直接返回当前 active，不再读旧库、不再复制。
- state 存在但 flag=false（迁移失败后切号/回滚过）→ 重试迁移；`activate`/`preparePaths` 写 state 时沿用旧 flag，绝不替迁移「盖章」。
- 没有旧单库时也写 state；若旧 `config.json` 仍有账号级设置且当前是真实账号，先补 profile 种子（`didMigrate = true`）。
- 目标库已存在 → 跳过数据库复制；目标 profile 已存在 → 跳过 seed。
- 中途失败（磁盘满、权限、旧库损坏）→ 不置 `legacyMigrationDone`，下次启动重试；已复制文件不覆盖目标、不删旧数据。

### 6.6 旧媒体与回滚

- 旧 `media/` 不迁移：旧消息 `mediaPath` 是绝对路径，继续指向旧目录即可显示；新媒体写入 `accounts/<id>/media/`。
- `config.json` 保留完整 `AppSettings` 镜像（含 `bot`/`personas`/`schedules`），旧版 App 回滚也能读到可用配置；当前版本以 `profile.json` 为准。
- 旧媒体目录不会被自动清理；删除账号目录或旧 `media/` 会破坏对应旧消息的媒体显示。

### 6.7 迁移边界情况

| 情况 | 行为 |
| --- | --- |
| 没有旧单库 | 写 `account-state.json`（active = 当前 active）；若旧 config 仍有账号级设置且 active 是真实账号，只补 profile 种子，`didMigrate` 反映是否恢复 |
| 旧库没有 `settings` 表 / 没有 `onebot.self_id` | owner 无效 → 归当前 active |
| owner 有效但当前已登录另一个账号 | 旧库归 owner；active 保持当前账号（不混库） |
| owner 等于当前 active | 直接复制到该账号档案 |
| 复制中断 | 下次启动重试；只补缺失文件，不覆盖已有目标库 |
| 用户手动删过旧库 | 视为没有旧单库，不再复制数据库；旧媒体仍在 |
| `_unassigned` 有数据、首次登录 | 通过 `claimUnassigned` 认领（§7），不走旧库迁移 |

### 6.8 迁移验收清单

升级后应满足：旧库/旧配置/旧媒体仍在；旧数据出现在 `accounts/<owner>/chatbot.sqlite`，`account-state.json.lastAccountID = <owner>`
且 `legacy-migration.json` 存在；profile 种子只写一次；再次启动幂等、不重复复制。手工步骤见 §11.2。

## 7. `_unassigned` 与认领

### 7.1 何时使用 `_unassigned`

首次安装、或启动时 resolver 无法识别账号（微信未登录、容器不可读、登录标记未生成）时，active = `_unassigned`。此时聊天、记忆、配置都写入
`accounts/_unassigned/`，不会丢弃，也不会猜一个账号归属。

### 7.2 认领（claim）

bridge `get_login_info` 确认真实账号 `<id>` 后：

- 启动阶段（`performBootstrap`，开库前）：`claimUnassignedForStartup(detectedAccountID:)` 会在 state 已停在
  `_unassigned` 或 active 暂未识别时自动认领；成功后 `activate(id)`。
- 运行中（`switchAccount`）：`AccountProfile.claimUnassigned(by:)`。
- 条件：目标 `accounts/<id>/chatbot.sqlite` 不存在，或只是「空壳库」（`conversations/messages/memories/settings`
  全空）；目标已有业务数据时不复制、返回 `false`。
- 动作：调用方先 `CharacterStore.suspend()` / `MemoryStore.suspend()`（close + 禁止隐式 open），再把
  `_unassigned/` 内容先复制到 `accounts/` 下的 staging 目录，随后逐项 move 到目标账号目录（数据库文件单独 staged + 原子替换；
  `characters/` 角色目录随目录整体复制）；写 `unassigned-claim.json` 标记。
- `_unassigned/` 原样保留，不删除、不改名；中断/磁盘满时下次启动重试。

### 7.3 为什么要保留 `_unassigned`

微信未登录时产生的消息/记忆可能是真实数据，不能因为「还没识别」就丢弃；保留原目录便于排查「第一次登录前写的消息去了哪」。`_unassigned` 是保留名，不会与真实 wxid
冲突，也不出现在「已保存的账号」列表中。

## 8. 边界与限制

1. **同一时间只有一个 active 账号库**：App 一次只服务一个微信登录；换账号 = 关旧库、开新库。
2. **不能手动切库**：UI 不提供选择入口，切号只由 resolver 与 bridge `get_login_info` 驱动；手动改 `account-state.json`/目录名不受支持。
3. **未登录账号的数据保留**：换号、退出、删除某账号聊天都不删除其它档案；App 不提供「删除账号档案」按钮。
4. **删除聊天只删当前账号**：`clearMessages`/`deleteConversation` 作用于当前 `MemoryStore`；删除会话还会删旧长期记忆与总结游标，
   并把角色目录移到废纸篓（见 [memory.md](memory.md) §10）。
5. **Keychain、本地 TTS 安装与音色、崩溃/bridge 日志全局**：换账号不更换 API Key、不重装 TTS 运行环境/模型、不切换日志目录。
6. **旧媒体路径保留**：旧版 `media/` 不迁移；手动移动/删除旧目录会使旧消息媒体失效。
7. **首次升级可能需要额外磁盘**：旧单库是「复制」而非移动，请预留同量级空间，确认无误前不要删旧库。
8. **机器人不会自动重启**：运行中切号后 `isBotRunning = false`，需用户手动启动。
9. **历史修复只作用于当前账号库**：启动期修复在 active 库内执行，不会拿新 selfID 去修旧账号库。
10. **profile 保存按账号隔离**：`persist()` 捕获 `profileURL`，切号后延迟到达的旧快照仍写回旧账号 profile。
11. **账号目录名必须可安全用于路径**：非法/异常登录 ID 被忽略并记 warning；不要手建不符合 §4.2 的目录。
12. **多开微信不支持**：App/bridge 按单微信实例设计，同时登录多个账号的数据归属不可预测。

## 9. UI 入口与文案

### 9.1 设置 → 数据与备份

「当前微信账号」区块展示：账号（`AccountProfile.maskedActiveID`，未识别时显示「未识别（等待微信登录）」与「临时档案」徽标）、
账号数据目录（`accounts/<id>/`）、账号配置（`accounts/<id>/profile.json`）、会话数据库（`chatbot.sqlite`，旧记忆表只读）、
角色目录（`characters/`）、媒体目录（`media/`）、全局配置（`config.json`）、备份目录（`backups/`）与运行日志目录
（`~/Library/Logs/WeChatAI/`），并说明哪些随账号切换、哪些全局共享（与 §1/§2 一致）。

「已保存的账号」列表来自 `AccountProfile.savedAccounts(limit:)`，按最近使用倒序显示 `maskedID`、最近使用时间与当前账号标记，
提供「在 Finder 中显示」；不显示 `_unassigned`，也不提供点击切号，仅用于查看与定位目录。

「重新检测微信账号」按钮调用 `await store.refreshWeChatAccount()`，期间按 `store.isSwitchingAccount` 禁用；机器人启动中检测到变化时
先排队（`store.accountSwitchPending`）并提示。结果分四种：切换成功、无变化（info）、未识别（error）、切换未生效（error，展示
`store.lastAccountSwitchError` 并回退原账号），不伪造成功。

### 9.2 总览

`store.accountSwitchNotice` 非空时，总览顶部显示 `InlineNotice(kind: .info, title: "微信账号已切换")`，正文为 notice，右侧「知道了」
调用 `store.dismissAccountSwitchNotice()`。运行中切号会同时停止机器人（`isBotRunning = false`），需手动重新启动。

### 9.3 文案与本地化

- 中文是源语言；新增 `L("…")` 需同步 `app/Packaging/en.lproj/Localizable.strings` 与 zh-Hans 身份表（由 UI 任务维护）。
- 不在 UI 中展示完整 wxid；账号列表、日志与路径展示用 mask 或完整路径。

## 10. 契约与不变式

关键接口（详见 `Services/AccountProfile.swift` 与 [architecture.md](architecture.md) §5）：

```swift
struct AccountLayout {
    let root: URL                         // AppPaths.supportDirectory
    var accountsDirectory: URL
    var stateFile: URL                    // root/account-state.json
    var legacyDatabaseFile: URL           // root/chatbot.sqlite
    var legacyMediaDirectory: URL         // root/media
    var legacyConfigFile: URL             // root/config.json
    func directory(for id: String) -> URL
    func databaseFile(for id: String) -> URL
    func profileFile(for id: String) -> URL
    func charactersDirectory(for id: String) -> URL   // 记忆 v2 角色目录
    func mediaDirectory(for id: String) -> URL
    func logsDirectory(for id: String) -> URL
    func ensureDirectories(for id: String)            // 含 characters/
}

enum AccountProfile {
    static var layout: AccountLayout { get }
    static var activeID: String { get }
    static var activeDirectory: URL { get }
    static var databaseFile: URL { get }
    static var profileFile: URL { get }
    static var charactersDirectory: URL { get }   // accounts/<id>/characters/
    static var mediaDirectory: URL { get }
    static var logsDirectory: URL { get }
    static var isUnassigned: Bool { get }
    static var maskedActiveID: String { get }
    static func preparePaths()
    static func activate(_ id: String) throws
    @discardableResult
    static func claimUnassigned(by id: String) throws -> Bool
    static func claimUnassignedForStartup(detectedAccountID: String?) -> UnassignedClaimOutcome
    static func runLegacyMigrationIfNeeded() -> LegacyMigrationOutcome
    static func savedAccounts(limit: Int = 10) -> [SavedWeChatAccount]
    static func detectedAccountID() -> String?
    static func activeImageDirectory() -> URL?
}
```

必须保持的不变式：

1. `preparePaths()` 早于 `SettingsStore.load()`，且不读 SQLite。
2. `runLegacyMigrationIfNeeded()` 早于 `MemoryStore.open()`，只在后台线程执行。
3. 迁移只 copy、不删除旧文件；`legacyMigrationDone=true` 是幂等门禁，`activate` 不得隐式置位。
4. `claimUnassigned*`/迁移必须在 `MemoryStore.suspend()` 或未开库时执行；目标有业务数据不覆盖，`_unassigned` 源保留。
5. 切号收敛到 `RuntimeCoordinator.switchAccount(to:reason:)`：先停运行时、drain 后台任务、suspend 库，再认领/激活/换库；期间禁止启动机器人。
6. `SettingsStore.load()` = 读 `config.json` 后 `applyProfile(profile.json)`；profile 缺失 → `.default`，损坏 → 备份
   `profile.corrupt-<ts>.json` 后默认。
7. `SettingsPersistence.save(_:profileURL:)` 在 `profileURL != nil` 时双写 config + profile，`nil` 时只写 config；两边按编码字节去重
   （profile 路径变化时强制写）、原子 replace。
8. `AppPaths` 的 databaseFile/profileFile/charactersDirectory/mediaDirectory 委托 `AccountProfile`；`ensureDirectories()` 创建 root、
   bridgeLog、backups、runtime 与当前账号目录（含 `characters/`），新媒体不再写根 `media/`。
9. `MemoryStore.databaseURL` 在 `open()` 时解析；`shared` 在 bootstrap 前禁止隐式 `ensureOpen`；切号用 `suspend()` →
   `switchDatabase(to:)`/`switchToActiveAccountDatabase()`。
10. `account-state.json`、`profile.json` 与迁移文件原子写；目录创建幂等。

## 11. 测试与验收

### 11.1 自动化测试范围

新增/更新测试至少覆盖：识别（登录标记优先/目录活动回退/稳定排序/非法目录返回 `nil`、mask 规则、`AccountLayout` 路径与
`ensureDirectories` 幂等、ID 校验）；`preparePaths`/迁移/认领（优先级、pendingNotice、owner 有效/无效、幂等、profile seed、
WAL 旧库缺 `-wal`/`-shm` 时 Backup API 仍可读、`_unassigned` 不覆盖目标且不删源）；配置与隔离（config+profile 合并与回退、
双写去重、A/B 库与 `characters/` 互不可见、`c-__global__` 按账号隔离）；回归（空壳目标库可替换、`legacyMigrationDone=false`
重试、`suspend()` 后禁止隐式 open）。运行时切号依赖真实 bridge/微信，见 §11.2。

测试使用临时目录/独立 `MemoryStore`，不触碰真实数据目录；注入 `AppSettings` 的 AppStore 测试不得调用 `preparePaths`/迁移。

### 11.2 手工验收

- [ ] 全新安装未登录写 `_unassigned`；登录 A 后认领且源保留；A/B 切换后聊天、记忆卡、人格、全局卡互不可见，切回 A 完整
  （旧 `memories` 表只读、旧 `persona.md` 移废纸篓）。
- [ ] 运行中换号：机器人停止、数据切换、提示可见；手动启动后以新账号回复。
- [ ] 设置 → 数据与备份的账号/目录/列表正确；「重新检测」在无变化/切换/失败三种情况下提示符合预期。
- [ ] 升级：旧库与旧媒体保留、数据归入旧 `self_id` 账号、profile 种子正确；删除当前账号聊天不影响其他账号。

### 11.3 命令

```bash
cd app && SWIFT_DISABLE_SANDBOX=1 swift test --disable-sandbox
python3 scripts/check_docs.py
bash scripts/check.sh --docs
```

当前基线：`swift test` 619 项执行（617 通过 / 2 项按环境跳过：真实本地 TTS 服务 E2E）。

## 12. 排障

| 现象 | 可能原因 | 处理 |
| --- | --- | --- |
| 账号显示「未识别」 | 微信未登录、容器无权限、登录标记未生成 | 登录微信后重启 App，或在设置 → 数据与备份点「重新检测」；检查 系统设置 → 隐私与安全性 → App 数据 |
| 数据出现在错误账号 | 旧库 `onebot.self_id` 与预期不同、或运行中切号提示未注意 | 查看 `account-state.json`、`accounts/*/legacy-migration.json` 与 bridge 日志；不要手动改名/合并目录，先备份再排查 |
| 升级后旧聊天「消失」 | 旧数据已归入旧 `self_id` 所属账号，而当前登录的是另一个账号 | 切回原微信账号；确认 `accounts/<旧账号>/chatbot.sqlite` 与 `legacy-migration.json` |
| 升级后旧聊天/记忆为空，但旧 `chatbot.sqlite` 仍在 | 2026-10-28 前的构建在旧库为 WAL 模式、且 `-wal/-shm` 已删除时，READONLY 迁移失败后打开了空库 | 升级到修复版；停止 App，备份并移走空 `accounts/<id>/` 与 `account-state.json`（或把 `legacyMigrationDone` 置 false），重新启动让迁移重跑；旧库/旧媒体不要删 |
| 换号后机器人不回复 | 切号会停止机器人，且不自动重启 | 确认总览提示；手动启动机器人 |
| 新消息图片仍指向旧目录 | 旧消息的 `mediaPath` 是历史绝对路径 | 属预期；旧媒体保留在根 `media/`，不自动迁移 |
| `profile` 反复回默认 | `accounts/<id>/profile.json` 解码失败，已备份为 `profile.corrupt-<ts>.json` | 查看备份与日志；修复 JSON 后重启，勿删除账号库 |
| 切换后仍写旧库 | 运行时未真正停止或切换失败 | 停止机器人/重启 App 重试；检查日志中 `switchAccount` 与 `memory.open` 的报错 |

## 13. 相关文档

- [architecture.md](architecture.md)：总体数据流、bridge `-self_id` / 媒体目录契约、配置与密钥。
- [core-services.md](core-services.md)：启动顺序、`SettingsStore`/`SettingsPersistence` 双文件、
  `MemoryStore` 换库与切号 API。
- [memory.md](memory.md)：记忆系统 v2（每会话记忆卡、全局共享记忆、人格设定单一来源）与旧记忆只读兼容。
- [ui-design.md](ui-design.md)：设置 → 数据与备份的账号区块、总览切号提示。
- [install.md](install.md)：换微信账号相关 FAQ。
