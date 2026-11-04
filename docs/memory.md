# 记忆系统 v2：会话记忆卡 · 人格设定

> 2026-10-28 起记忆系统按「SurfCore 记忆方案」重做：旧的「10 条短期窗口 + 每 8 条滚动总结」长期记忆页进入只读兼容期（表结构、数据、单测保留），
> 运行时召回/提取/记忆页全部切到 v2；旧记忆不自动迁移，可在「记忆卡」页「导入旧记忆」。
>
> **一句话**：一个微信会话 = 一个记忆卡目录（`characters/<key>/memory.sqlite`）；人格统一来自「人格设定」（全局 `Persona`），不再复制人设卡。
> 记忆分事实/决策/待办/经验四类、普通/重要两级，按时间、重要度、使用频率加权，支持 0.92 折叠、冲突 supersede 留档、72 小时最近记忆优先召回、
> 全量互动永久保存，并可导出 Markdown/JSON。
>
> **关键行为**：人格单一来源（删除每会话 `persona.md`）；新卡默认空；首条消息落库后自动建卡，首次维护补总结建卡前最近 500 条历史互动；
> 提取游标为 `(timestamp, id)` 复合键，忙群同秒消息不漏提取，群里安静 5 分钟后仍可兜底总结（详见 §3、§4.3、§7.1、§7.2）。

## 1. 变更摘要

| 维度 | 旧机制（v1，只读兼容） | 新机制（v2） |
| --- | --- | --- |
| 存储 | 账号库 `chatbot.sqlite` 的 `memories` 表 | 每会话目录 `characters/<key>/memory.sqlite`（只有记忆卡，没有 `persona.md`） |
| 人格 | 全局人格模板（profile.json） | **人格设定（全局 `Persona`）唯一来源**；会话只记录 `personaID` 绑定，不复制人设卡 |
| 记忆形态 | 每会话一条滚动摘要（600 字） | 多条原子记忆，带类别/重要度/关键词/来源消息 |
| 全局记忆 | 无 | 固定伪角色 `__global__`（「全局共享」），只手动维护，注入所有会话 |
| 初始状态 | 首条摘要由窗口外消息生成 | 新卡默认空；收到消息即自动建卡，首次维护补总结最近 500 条历史互动 |
| 记忆分类 | 无 | `fact` / `decision` / `todo` / `lesson` |
| 记忆等级 | 无 | `normal` / `important`；置顶不衰减 |
| 老化 | 30 天半衰期 + 使用强化 | 普通 30 天、重要 180 天半衰期；置顶不衰减；长期未访问压缩归档 |
| 去重 | 滚动合并成一条 | 相似度 ≥ 0.92 自动折叠；冲突 supersede，双方留档 |
| 召回 | 核心/手写/自动总结，最多 6 条 | 最近 72h → 重要 → 关键词相关，按 token 预算裁剪 |
| 提取 | 每 8 条窗口外消息 AI 总结 | 每 N 条（默认 8）互动 AI 批量提取；空闲兜底；首次建卡补总结历史 |
| 全量记录 | 仅账号消息表 | 记忆卡内 `interactions` 永久保存文本互动，不随聊天记录清理删除 |
| 指令 | 无 | 不开放微信 `/记忆`；只在 App 记忆面板查看/编辑/置顶/压缩/导出 |
| 账号隔离 | 账号库隔离 | 账号目录 `accounts/<id>/characters/` 隔离，随账号切换 |

## 2. 目录与文件

```
accounts/<微信账号 id>/
├── chatbot.sqlite                 # 会话/消息/日志/设置（仍由 MemoryStore 管理）
├── profile.json                   # 人格设定、机器人设置、定时任务
└── characters/
    ├── c-__global__/
    │   └── memory.sqlite          # 全局共享记忆卡（手动维护，注入所有会话）
    ├── c-wxid_friend01/
    │   └── memory.sqlite          # 记忆卡（SQLite，WAL）
    └── c-123456789@chatroom/
        └── memory.sqlite
```

- **一个微信会话一个目录**：私聊、群聊按会话 ID 建目录；首条消息落库后由后台**自动创建**（不阻塞回复，不要求机器人先回复），
  `filehelper` 等系统会话与公众号不自动建卡，手动「为现有会话创建记忆卡」仍可补建；首次维护补总结建卡前历史（最多 500 条，§7.2）。
- **新卡默认空**：创建时只建 `memory.sqlite` 与 meta（`conversation_id` / `conversation_title` / `conversation_kind` /
  `persona_id` / `persona_name`、`last_extracted_at`、`history_cutoff_at`），不写「角色名/初始设定」行；之后按 §7 批量提取、首次维护补总结（§7.2），
  也可手动新增/导入旧记忆。
- **全局共享记忆卡**：固定伪会话 ID `__global__`、标题「全局共享」，目录 `characters/c-__global__/memory.sqlite`；每个微信账号各自一份（§4.4）。
- **目录名编码**（`CharacterDirectory.key(for:)`）：只保留 `A-Z a-z 0-9 . _ - @`，其余 UTF-8 字节按 `%XX` 转义；统一加 `c-` 前缀；
  超过 160 字符时用 `c-<前 60 字符>-<sha256 前 16 位>`；权威会话 ID 存在 `meta.conversation_id`，目录名可随时重建。
- **角色目录只有 `memory.sqlite`**（2026-10-28 人格单一来源）：不创建/不读取 `persona.md`，人格来自 `profile.json`（§3）。旧 `persona.md` 在创建/加载时
  best-effort 移到废纸篓、不阻塞回复；只含 `persona.md` 的旧目录不算有效角色卡，等该会话下一条消息（或首次回复）时按当前人格设定重建。
- **账号归属**：`characters/` 在 `accounts/<id>/` 内，旧版迁移/`_unassigned` 认领会递归复制整个账号目录，无需单独迁移；记忆卡只属于当前账号，
  换号后使用新账号的角色目录与人格设定。
- **写入约定**：`memory.sqlite` WAL + `synchronous=NORMAL`；所有 DB 操作在 `CharacterStore` actor 内串行，不占主线程。

## 3. 人格来源（人格设定）

### 3.1 唯一来源

- 人格设定（`PersonasView` / `profile.json` 的 `personas`）是人格名称、摘要、系统提示词与模型的**唯一来源**，不再为每个会话复制人设卡。
- 会话→人格绑定为 `conversation.personaID ?? bot.defaultPersonaID`；解析不到时提示词回退 `Persona.defaultSystemPrompt`、展示名回退会话标题。
- 没有每会话人设卡编辑器或模型/提示词覆盖；修改后所有使用该人格的会话**下一轮回复立即生效**。`Persona.model` 非空时应用到该会话的回复请求。
- 记忆卡只缓存展示用 `persona_id` / `persona_name` meta，**不保存 systemPrompt 副本**。

### 3.2 记忆卡的创建

- 首条消息（或首次生成回复）时，按 `conversation.personaID ?? bot.defaultPersonaID` 解析人格并调用
  `CharacterStore.ensureCharacter(conversation:persona:activationTimestamp:)`：① 建角色目录与空 `memory.sqlite`（只写 meta）；② 初始化
  `last_extracted_at = 触发消息时间戳 - 0.001`，让本轮消息与回复进入首批提取；③ 初始化 `history_cutoff_at = 触发消息时间戳`，建卡前历史由
  首次维护补总结（§7.2）。
- 已存在时只同步 `conversation_title` / `conversation_kind` / `persona_id` / `persona_name` 等元信息，**不写初始记忆、不覆盖记忆正文**。
- 人格变化只影响下一轮提示词与新建卡展示 meta；`listCharacters(settings:personas:now:)` 接收「会话 → 当前人格」映射，仅用于左栏展示。

### 3.3 旧 `persona.md` 清理

旧版本在每个角色目录复制 `persona.md`，统一人格后它只是冗余副本：创建/列出记忆卡时用 `FileManager.trashItem` best-effort 移到废纸篓。
其中的自定义正文**不会被读取或迁移**，需要保留的提示词请在人格设定中维护；`memory.sqlite` 的历史记忆不受影响。

## 4. 记忆卡 `memory.sqlite`

### 4.1 Schema

```sql
PRAGMA user_version = 1;

CREATE TABLE meta (
    key   TEXT PRIMARY KEY NOT NULL,
    value TEXT NOT NULL
);
-- 常用键：conversation_id, conversation_title, conversation_kind, schema_version,
--         persona_id, persona_name, last_extracted_at, last_extracted_interaction_id,
--         last_archive_at, interactions_backfilled, interactions_backfilled_at,
--         interactions_synced_at, history_cutoff_at, history_backfilled_at,
--         history_backfill_version, history_backfill_cursor_at,
--         history_backfill_cursor_id, history_backfill_cutoff_at,
--         history_memory_repair_v1

CREATE TABLE memories (
    id                 TEXT PRIMARY KEY NOT NULL,
    category           TEXT NOT NULL,              -- fact | decision | todo | lesson
    kind               TEXT NOT NULL,              -- normal | important
    content            TEXT NOT NULL,
    compressed_content TEXT,                       -- 压缩后的提示词版本；原文仍保留
    keywords           TEXT NOT NULL DEFAULT '',   -- 空格分隔，用于关键词召回
    importance         REAL NOT NULL DEFAULT 3.0,  -- 1.0...10.0
    pinned             INTEGER NOT NULL DEFAULT 0, -- 用户置顶：不衰减、优先召回
    archived           INTEGER NOT NULL DEFAULT 0, -- 归档：默认不召回，仍可查看/导出
    superseded_by      TEXT,                       -- 被哪条新记忆取代
    supersedes         TEXT,                       -- 取代了哪条旧记忆
    superseded_at      REAL,
    source             TEXT NOT NULL DEFAULT 'extraction', -- extraction|manual|legacy-import
    source_message_ids TEXT NOT NULL DEFAULT '',   -- JSON 数组字符串
    merge_count        INTEGER NOT NULL DEFAULT 0, -- 自动折叠次数
    access_count       INTEGER NOT NULL DEFAULT 0, -- 被提示词召回次数
    created_at         REAL NOT NULL,
    updated_at         REAL NOT NULL,
    last_accessed_at   REAL
);
CREATE INDEX idx_memories_recall
    ON memories (archived, superseded_by, kind, category, updated_at DESC);

CREATE TABLE interactions (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    message_id  TEXT NOT NULL UNIQUE,   -- 对应账号 messages.id
    direction   TEXT NOT NULL,          -- incoming | outgoing
    sender_id   TEXT NOT NULL DEFAULT '',
    sender_name TEXT NOT NULL DEFAULT '',
    content     TEXT NOT NULL,
    timestamp   REAL NOT NULL,          -- 消息时间；提取游标用它，不随清空消息重置
    created_at  REAL NOT NULL
);
CREATE INDEX idx_interactions_time ON interactions (timestamp DESC);
```

- `kind` 与 `importance/pinned`：`pinned` 永久且最高优先；`importance >= 7` 视为「重要」（慢衰减），其余为「普通」。
- 「最近记忆」不是存储类型：创建/最近访问在 `recentWindowHours`（默认 72h）内的记忆进入「最近」组并享受权重加成。
- 记忆正文：普通记忆 ≤ 300 字（提取时裁剪）、手动新增可到 2000 字；`compressed_content` 用于提示词与摘要，原文不丢。

### 4.2 全量互动 `interactions`

- 角色卡创建后，运行时把该会话历史消息（最多最近 **5000 条**）一次性**回填**进 `interactions`；之后按游标增量同步，`message_id` 唯一，
  语音转写/识图描述更新时覆盖同一条。
- 内容只存文本：沿用 `ChatEngine.promptText`（语音转写、图片描述、引用文本）；单条上限 4000 字，系统消息跳过。
- `interactions` 不参与衰减、不压缩，是「全量记忆卡」的载体；**清理聊天记录**（具体会话头部菜单 `ChatCleanupSheet`，仅该会话）不会删除它，只有
  删除整个记忆卡/会话时才会移除（移到废纸篓，见 §10）。

### 4.3 移除起点记忆（2026-10-28 迁移）

旧版本创建记忆卡时会生成一条 `kind = origin` 的「角色名/初始设定」起点记忆；现在新卡不再生成。打开旧 `memory.sqlite` 时，
`CharacterDatabase.migrate()` 执行一次性迁移（幂等，没有 origin 行的库不受影响）：

- `meta.origin_edited != '1'`（生成型起点）→ `DELETE FROM memories WHERE kind = 'origin'`；
- `meta.origin_edited = '1'`（用户编辑过）→ 转为普通置顶手写记忆：`kind = 'normal'`、`pinned = 1`、
  `importance = MAX(importance, 10)`、`source = 'manual'`；
- 最后删除 `meta.origin_edited`。

迁移后的记忆按普通/置顶记忆参与权重、归档、supersede 与导出；该迁移目前无独立单测。

### 4.4 全局共享记忆

- **固定伪角色**：`CharacterStore.globalConversationID = "__global__"`、标题「全局共享」，目录
  `characters/c-__global__/memory.sqlite`；每个微信账号各自一份。
- **惰性创建**：`CharacterStore.ensureGlobalCharacter()` 在记忆页加载与 `MemoryEngine.recall` 时调用；创建的是**空卡**，没有
  `interactions`，不参与批量提取，也不随任何会话删除。
- **只手动维护**：从记忆页新增/编辑/置顶/压缩/删除；不会自动提取，清理某个会话的聊天记录也不会删除它。
- **召回注入**：`MemoryEngine.recall` 合并会话记忆与全局记忆，按正文去重、统一排序与 token 预算；全局卡自己的预览不重复叠加；提示词在类别前加「全局」，
  访问计数按各自 `characterID` 回写；群聊「本轮发言人身份」同样合并全局记忆。
- **UI**：左栏固定「全局共享 / 所有会话共享」行（globe 图标，位于会话角色之上）；选中后显示「全局共享」「注入所有会话」，可新增/编辑/删除/置顶/压缩；
  `全量记录` 与 `删除记忆卡` 禁用（无 interactions、运行时也拒绝）。聚合「全部角色」同时显示全局与会话记忆，header 为「聚合 N 个会话角色 · 全局记忆同时并入」。
- **导出**：全局卡可导出 Markdown/JSON，使用当前人格设定（无会话时用默认人格）；全量记录不导出。
- **账号隔离**：`c-__global__` 在账号目录内，换微信账号后看到的是新账号自己的全局记忆，不会跨账号共享。

## 5. 权重、衰减与归档

### 5.1 综合权重

```
activityAt  = max(updated_at, last_accessed_at ?? created_at)
ageDays     = max(0, now - activityAt) / 86400
recency     = 1 + 0.5 × max(0, 1 - 距上次活动小时数 / recentWindowHours)   // 72h 内最高 1.5
usage       = 1 + 0.02 × min(access_count, 20)                              // 最多 +40%
base        = importance                                                   // 1...10
decay       = 1                                                             // pinned
            = 0.5 ^ (ageDays / importantHalfLifeDays)                       // kind=important
            = 0.5 ^ (ageDays / normalHalfLifeDays)                          // 其余
score       = max(0.0001, base × recency × usage × decay)
```

- `kind` 在写入时计算：`pinned` 或 `importance >= 7` → `important`，否则 `normal`。
- 每次召回 `access_count + 1`、刷新 `last_accessed_at`（best-effort，不改正文/`updated_at`）。
- 置顶/取消置顶、修改重要度会重算 `kind` 并刷新 `updated_at`，时间衰减从头计算。

### 5.2 自动归档

- 每次成功提取后 best-effort 执行 `archiveStale`：条件为 `kind = normal`、未置顶、未归档、未被取代、最近活动（`created_at`/
  `updated_at`/`last_accessed_at` 取最晚）距今超过 `archiveAfterDays`（默认 90 天）、`access_count < 3`；动
  作是 `archived = 1`，正文超过 300 字时用确定性压缩器写 `compressed_content`（保留原文，提示词只用压缩版）。
- 归档记忆不自动召回，但「已归档」筛选可见、可恢复、可导出；不做自动删除。

## 6. 合并（折叠）与冲突（supersede）

### 6.1 相似度

`MemorySimilarity.score(a, b)`（纯函数，可单测）：

1. 归一化：去掉标点/空白、全角转半角、ASCII 小写；
2. 字符 bigram 词频向量余弦（中文无需分词）；
3. 若较短文本（≥4 字）完整出现在较长文本中，得分取 `max(余弦, 0.95)`；
4. 输出 `0...1`。相似度 ≥ `mergeSimilarity`（默认 **0.92**）视为重复。

### 6.2 自动折叠

提取到新记忆时，在同类别、未归档、未被取代的记忆里找最高相似度：

- `≥ 0.92` → **合并**到已有记忆：保留已有 `id`；正文取较长的一条（更完整），等长时保留已有正文；`keywords` 并集；`importance = max`；
  `merge_count += 1`；`updated_at = now`；`source_message_ids` 并集；`kind` 按 §5.1 重算。
- `< 0.92` → 新增一条。

### 6.3 冲突 supersede

- 提取提示词会把候选旧记忆的 `id/content` 交给模型；模型判定新记忆与某旧记忆矛盾时，在新记忆里返回 `supersedes: ["<旧 id>"]`。
- 落库规则：新记忆正常插入并写 `supersedes = 旧 id`；旧记忆写 `superseded_by = 新 id`、`superseded_at = now`，
  **不删除、不覆盖正文**；已置顶记忆不被自动取代（日志警告，保留双方，由用户手动编辑/删除或取消取代）；旧记忆在卡中显示「已被取代」徽标。
- 召回只注入 `superseded_by IS NULL` 的记忆；导出保留全部历史。UI 提供「取消取代」：清空双方的 supersede 字段，恢复旧记忆召回。

## 7. 批量提取

### 7.1 触发与游标

- `MemorySettings.enabled = true` 时，每次消息落库后调用 `scheduleMemoryMaintenance`（后台任务，按会话去重，不阻塞回复）。
  会话还没有记忆卡且属于可采集范围（`MemoryCapturePolicy`：非系统会话、非公众号、该会话未关闭 AI）→ 先自动建卡再维护。
- 维护任务：① `syncInteractions`：首次回填该会话最多 5000 条历史进 `interactions`，之后按 `interactions_synced_at` 游标增量同步（单批 500 条）；
  ② 历史补总结（§7.2）；③ `pendingInteractions` 取 `(timestamp, id) > meta.last_extracted_at` 的互动，升序单批最多 40 条（复合游标避免同秒被
  LIMIT 截断的忙群消息漏提取）；④ 未处理条数 `< extractionBatchSize`（默认 8）→ 不提取；⑤ AI 提取 → 合并/取代 → 推进游标；⑥ 归档维护并记日志。
- AI 成功或本地兜底成功后推进游标；失败保留游标，下次有新消息时重试。
- **空闲兜底**：最后一条消息后 5 分钟无新消息、且待提取条数 ≥ `extractionBatchSize / 2` 时补跑一次部分批次，避免长期攒不够一批而
  不总结；不足半批不做，避免给噪声留下记忆。
- 启动时对**已有记忆卡**的会话补跑一次维护（待提取 + 旧卡首次历史补总结，§7.2），不给所有历史会话批量建卡。
- 提取/历史补总结的 AI 请求有全局并发闸门（最多 3 个请求同时在途），避免升级首启或停机重启时几十个会话同时调用模型。
- 无 API Key / AI 失败 / 返回不可解析时用**本地兜底**：把本批互动压缩成 1 条 `fact` 记忆（重要度 2，关键词取前 2 个；正文 ≤ 400 字），保
  证离线也有可用记忆；日志标注「本地兜底」。

### 7.2 历史补总结（2026-10-29）

建卡游标从建卡时刻开始，建卡前的历史互动只会回填进 `interactions`，永远不进普通提取。首次维护用一组**独立于普通提取游标的断点**补总结：

- 历史范围：早于 `history_cutoff_at`（新卡）或 `interactions_backfilled_at`（旧版卡）的互动；旧卡两者都没有时回退
  `last_extracted_at`。单卡只补**最近最多 500 条**（`MemoryEngine.historyBackfillMessageLimit`，按
  `(timestamp, id)` 窗口选取，每批 `min(40, 剩余额度)`），更早的只保留在全量记录，避免建卡触发上百次 AI 调用。
- **必须由 AI 完成**：无可用模型/凭据、AI 失败或返回不可解析时，本批不落库、断点不前进、不写 `history_backfilled_at`，下次重试（本地兜底只用于普通提取）；
  模型恢复后可继续补，不会永久缺失。
- 断点：`history_backfill_cursor_at` / `history_backfill_cursor_id`（`(timestamp, id)` 复合键，同秒边界不
  重不漏）；普通 `last_extracted_at` **不动**，不会把已提取的新消息重新拉回队列；断点/完成标记在一个事务内写入。
- 按批（每批 ≤40 条）提取，全部补完写 `history_backfilled_at` 与 `history_backfill_version=2` 并清理断点 meta；中途退
  出/取消时保留断点，下次继续；落库失败时单次运行内停止重试，下次维护重试同一批（可能再次调用 AI），历史不会丢。补总结同样走相似度折叠/supersede，不会每批堆一条。
- **时间语义（2026-10-29 修复）**：提示词按每条消息的发送时间（行首 `[yyyy-MM-dd HH:mm]`）解析「今天/明天/今晚/这周末」等相对时间；历史批的记忆
  `created_at/updated_at` 写来源消息时间，不写补总结时刻，因此不会出现在「最近 72h」或被近期权重加成；历史批里带近期时间词的 `todo` 统一降级为
  `fact`（信息保留、不再冒充当前待办），普通实时提取不受影响。
- **旧数据修复**：升级后首次打开记忆卡时，旧逻辑补出的历史记忆（来源早于建卡时刻）：未编辑过的归档并清除完成标记、按新逻辑重补；编辑过的只修正时间，
  来源超过 24 小时且带近期时间词的 todo 降级为 fact。一次性迁移，幂等。

### 7.3 模型输出

系统提示要求只输出 JSON：

```json
{
  "memories": [
    {
      "category": "fact|decision|todo|lesson",
      "content": "一句可独立理解的中文记忆，≤300 字",
      "importance": 1,
      "keywords": ["关键词1", "关键词2"],
      "supersedes": ["旧记忆 id"]
    }
  ]
}
```

- 每批最多 8 条新记忆；`importance` 1–10；`keywords` 最多 8 个；只记录可核实的信息（偏好/身份/约定/决定/未完成事项/互动规律），不记录玩笑、外号、
  自称或「某人其实是某人」的玩梗。
- **相对时间按消息发送时间解析**：提示词每行以 `[yyyy-MM-dd HH:mm]` 开头，历史补总结还会给出消息时间范围；「今晚/这周末」不能按当前时间或对话顺序揣测。
- 已经过去的事件、过期/完成的计划与待办不输出为 `todo/decision`；确有长期价值的用 `fact` 以过去时记录（「当时约定…」），不编造日期；与已有记忆矛盾时用
  `supersedes`，不要改写旧记忆；没有值得长期记住的内容时返回 `{"memories":[]}`（也要推进游标）。
- 解析器容错：去掉 Markdown 围栏，截取第一个 `{` 到最后一个 `}`；字段缺失/类型错误逐条丢弃；超长裁剪；非法 JSON 走本地兜底。

### 7.4 提取上下文

提示词包含：

- 角色名/摘要（来自**人格设定**，只传摘要，省 token）；
- 本批互动（`[发送时间] 我：` / `[发送时间] 昵称：` 格式）；提示词按 6000 字预算截断，只把实际写入提示词的前缀记为已提取（游标/来源消息 ID 不越过截断点）；
- 最多 12 条参考记忆（置顶 → 重要 → 本批关键词命中 → 按更新时间补齐）及其 `id`，供合并/取代引用；
- 当前时间与会话标题/类型；已有待办提醒（`todo` 类别）优先保留，已完成的可由模型省略。

## 8. 召回与注入

### 8.1 召回分组

每次回复前，`MemoryEngine.recall(conversationID:query:settings:now:recordAccess:)` 先合并**当前会话记忆 + 全局共享记忆**
  （全局卡自己的预览不重复叠加），再按同一规则分组：

1. **最近**：`activityAt >= now - recentWindowHours`，按 score 降序，最多 4 条；
2. **重要**：`pinned = 1` 或 `kind = important`，按 score 降序，最多 4 条；
3. **相关**：对当前消息做关键词切分（复用 `ChatEngine.memoryTokens`），命中 `content/keywords` 的事实/经验记忆，按 score 降序，
   最多 4 条；
4. **补位**：仍未达到 `maxRecallCount` 时按 score 降序补齐（最多 12 条）。

- 过滤：`archived = 0`、`superseded_by IS NULL`；去重：同一 `id` 只出现一次，正文完全相同只保留最高分一条（全局与会话重复时只注入一条）。
- token 控制：注入正文 ≤ `maxRecallCharacters`（默认 1200）；超限按最近 → 重要 → 相关 保留，低优先级丢弃并在段尾注明省略条数；单条超 240 字
  优先用 `compressed_content`，否则截断并加「…」。
- 空记忆卡（含只有全局卡为空）直接返回空召回，不注入任何占位行；全局记忆不会覆盖同正文的会话记忆。

### 8.2 提示词格式

注入到 system prompt 的「相关历史记忆」段：

```
记忆上下文（最近/重要/相关；已被取代的记忆不注入）：
- [事实·最近·重要度 6] 用户喜欢猫
- [全局·事实·重要度 8] 用户是 GPL-3.0 项目的维护者
- [待办·重要·置顶] 下次提醒用户更新微信版本
- [经验·相关] 用户发梗图时适合用玩梗风格回复
```

- 全局记忆在类别前加「全局」；其它标签规则不变。
- 人格正文来自**人格设定**（`Persona.systemPrompt`），不再有每会话人设卡正文；人格缺失时回退 `Persona.defaultSystemPrompt`。
- 保留群聊身份硬约束：从**本会话 + 全局**记忆卡的置顶/重要/fact 记忆里解析 `wxid：称呼`，在 system prompt 末尾追加「本轮发言人身份」；群聊玩笑/
  临时外号不能覆盖。
- 召回成功的记忆 best-effort `access_count + 1`，并按 `characterID` 回写到各自的记忆库。

### 8.3 手动注入/查看

- 不开放微信 `/记忆` 指令（2026-10-28 确认）。
- App 记忆面板：置顶记忆 = 永久优先召回；「预览注入 / 召回测试」输入一句模拟消息，显示按当前会话生成的记忆上下文与字符估算；支持把记忆标记为 `archived`、
  `pinned`，调整重要度（≥ 阈值即「重要」），或编辑正文/类别/关键词。

## 9. 对话上下文与短期窗口

- 对话历史仍取最近 `min(maxContextMessages, 10)` 条，保持现有行为；
- v2 不再把短期窗口外的消息批量改写成一条摘要；它们进入 `interactions`，由 §7 的批量提取生成原子记忆；
- 旧 `ChatEngine.summarizeOverflow` / `MemoryStore` 旧记忆方法保留给旧单测与只读兼容，运行时不调用；
- 群聊发言人标注、语音转写、图片描述、引用文本规则不变。

## 10. App 记忆面板（记忆库页）

### 10.1 结构

- 记忆库页只有**记忆卡**模式；聊天记录清理在**具体会话**头部菜单。
- **入口不自动打开聚合**：进入记忆库只显示左侧角色列表，右栏空状态「选择一个角色」；只有点击「全部角色」或「查看全部角色」才加载聚合，
  刷新/创建/删除记忆卡后保持「无选择」，不自动跳回聚合。
- 记忆卡模式 = 左侧角色列表 + 右侧记忆卡：
  - 左栏：`全部角色`（聚合）+ 固定「全局共享 / 所有会话共享」行（globe 图标，位于会话角色之上）+ 各会话（标题/类型/人格名/记忆数/重要数/待办数），
    支持按标题/人格名搜索；无记忆卡时整页空状态，提供「为现有会话创建记忆卡」（建卡后回填全量互动并补总结最多 500 条旧聊天）。
  - 右栏顶部：会话标题/类型、人格名（来自人格设定）、更新时间；全局行显示「全局共享」「注入所有会话」。没有「人设卡」按钮/sheet，无重复统计行；
    总数只在工具栏副标题（`N 个记忆卡 · N 条生效记忆`，包含全局卡），筛选数量在 chip 上。聚合 header 为「聚合 N 个会话角色 · 全局记忆同时并入」。
  - 按钮：`全量记录`、`导出`、`更多`（预览注入 / 导入旧记忆 / 为缺失会话创建记忆卡 / 删除记忆卡）；设置入口在工具栏齿轮；聚合视图隐藏或禁用角色专属按钮。
    全局卡禁用「全量记录」「删除记忆卡」，可导出/新增/编辑/置顶/压缩/删除单条记忆。
  - 筛选：全部 / 最近 72h / 重要 / 待办 / 事实 / 决策 / 经验 / 已归档 / 已被取代；排序：综合权重（默认）/ 最近更新 / 重要度；搜索正文/关键词。
  - 卡片：正文、类别、置顶/重要、重要度、权重、合并次数、召回次数、来源（自动提取/手写/旧记忆导入）、`已被取代`；菜单：编辑、置顶/取消、归档/恢复、
    压缩、取消取代、删除。所有记忆都可编辑/删除；新增记忆预填当前会话，类别默认 fact、来源 manual。
- 全量记录 sheet：`interactions` 列表（时间/方向/发言人/正文），搜索、上限 1000 条；首次打开角色时自动补齐最多 5000 条历史互动，之后增量同步；
  sheet 内不提供删除（随记忆卡删除）。
- 导出：Markdown / JSON，`NSSavePanel` 保存，人格内容来自当前人格设定；全局卡可导出（无会话时用默认人格），不导出全量记录。
  - Markdown：角色信息 + 人设（摘要/系统提示词/模型）+ 分类记忆（重要项带标记）+ 已归档/已被取代 + 全量互动；
  - JSON：`format`、`exportedAt`、`character`、`memories`、`interactions`；`character` 含 `conversationID` / `title` / `kind` / `personaID` /
    `name` / `summary` / `model` / `systemPrompt` / `personaSource = "persona-settings"`。
- 记忆设置 sheet：§11 的开关与数值，保存到当前账号 `profile.json` 的 `bot.memory`。
- 导入旧记忆：把旧 `memories` 表中本会话 + 全局记忆导入当前记忆卡（拆分/分类启发式、来源 `legacy-import`、核心记忆置顶），需用户点击。
- **清理聊天记录**：会话 → 头部「More（会话设置）」→「清理聊天记录…」→ `ChatCleanupSheet`；只清理当前会话，只删本地 `messages`
  （及旧 `memory_state` 游标），不删记忆卡/`interactions`，不影响微信端消息；确认条数来自账号库 `messageCount`（真实总数，不是已加载的 60 条）。
- 删除记忆卡：二次确认，整个角色目录移废纸篓；人格设定不受影响，该会话下一条消息（或下一次回复）按当前人格设定重建并补总结最近历史；
  全局卡不可删除（UI 禁用，运行时拒绝）。删除会话：删本地聊天记录并同时把角色目录移废纸篓。

### 10.2 空状态与错误

- 未选择角色：左栏可见，右栏「选择一个角色」并提示点「全部角色」才打开聚合。
- 无记忆卡：说明「机器人收到消息后自动创建（系统会话、公众号、关闭 AI 的会话除外）」，可直接「为现有会话创建记忆卡」并补总结（§7.2）。
- 有卡但 0 条记忆：聚合显示「记忆卡还是空的」、单角色「这个角色还没有记忆」并给「新增记忆」、全局卡「全局记忆还是空的」（只支持手动维护）。
- 某筛选为空：说明条件并提供「显示全部」；0 条≠读取失败，数据库/目录失败仍用 Toast + 日志。

## 11. 设置

`BotSettings.memory: MemorySettings`（可选，缺省用默认值；随账号 `profile.json`）：

| 字段 | 默认 | 范围 | 说明 |
| --- | --- | --- | --- |
| `enabled` | true | – | 关闭后不提取/不召回/不写全量记录；人格仍来自人格设定 |
| `extractionBatchSize` | 8 | 4–20 | 每多少条新互动触发一次提取 |
| `recentWindowHours` | 72 | 1–168 | 「最近记忆」窗口 |
| `normalHalfLifeDays` | 30 | 1–365 | 普通记忆半衰期 |
| `importantHalfLifeDays` | 180 | 1–730 | 重要记忆半衰期 |
| `importanceThreshold` | 7.0 | 5–10 | 判为「重要」的重要度阈值 |
| `mergeSimilarity` | 0.92 | 0.80–1.0 | 自动折叠阈值 |
| `archiveAfterDays` | 90 | 7–3650 | 自动归档的未访问天数 |
| `maxRecallCount` | 12 | 3–30 | 单轮注入条数上限 |
| `maxRecallCharacters` | 1200 | 300–6000 | 单轮注入正文长度上限 |
| `autoArchive` | true | – | 是否自动归档 |

所有数值写入前收敛到范围；NaN 回退默认。设置变更下一轮回复生效，不需要重启。

## 12. 生命周期、账号切换与并发

- `CharacterStore` 是 actor，按需打开 `memory.sqlite`，LRU 缓存最多 4 个连接；未打开/切号中显式报 `notActive`，按 best-effort 处理。
- 启动：`memory.open()` 成功后 `characterStore.activate()`，并对已有卡的会话补跑一次维护（补总结 + 待提取 + 空闲兜底排期）。
- 切号（`switchAccount`）顺序：① `drainBackgroundWorkForAccountSwitch()` 取消并 await 记忆维护任务；②
  `characterStore.suspend()` 关闭全部角色连接； ③ `memory.suspend()` → 认领/激活账号 →
  `memory.switchToActiveAccountDatabase()`；④ `characterStore.activate()` 指向新账号的 `characters/`；
  ⑤ 清空内存中的角色/记忆状态并重新加载。
- 维护任务按会话去重，切号/关闭机器人时取消；关键 await 后比对 `accountEpoch`，避免 A 的提取结果写进 B。
- 删除会话/记忆卡在 actor 内串行；目录移动用 `FileManager.trashItem`（失败则删除并记日志）。

## 13. 旧数据与兼容

- 旧 `memories` / `memory_state` 表**保留只读**，不再写入；旧方法与单测保留、运行时不调用；升级不删除/改写旧数据。
- 启动/记忆页不再加载旧长期记忆运行时数组（`longTermMemories` 及 CRUD 已移除）；唯一读取入口是「导入旧记忆」。
- 人格设定仍在 `profile.json`（`personas`）；旧 `persona.md` 不再读取，创建/加载记忆卡时 best-effort 移到废纸篓，自定义正文不采用。
- 旧卡 `kind='origin'` 行在打开数据库时迁移（§4.3）：生成型删除、用户编辑过的转普通置顶手写记忆；新卡不再生成起点。
- 导入旧记忆映射：`is_core = 1` → `kind = important`、`pinned = 1`、`importance = 8`；`source = manual` → `legacy-import`、重要度 6；
  自动总结按 `- ` 拆成多条并用关键词启发式分类（提醒/下次→todo；约定/决定→decision；喜欢/叫/是→fact；规律/经验→lesson；默认 fact）；
  正文 > 300 字截断；相同正文按 0.92 折叠；不改旧表。
- `c-__global__` 与普通角色卡同在账号 `characters/` 下，切号后使用新账号自己的全局记忆，不跨账号共享。
- 回滚：旧表/旧代码仍在，可读旧记忆；新 `characters/` 旧版不识别，不影响启动。

## 14. 验证

单测（`app/Tests/WeChatAITests/CharacterMemoryTests.swift`、`ChatEngineV2Tests.swift`，临时目录，不碰真实网络/数据），当前 `swift test` **619 项**（2 项按环境跳过），覆盖：

- 目录 key 编码/超长哈希；建卡只生成 `memory.sqlite`（无 `persona.md`）、新卡 0 条记忆、meta 与 `last_extracted_at` 初始化、再次 ensure 不清记忆。
- schema、interactions upsert 与去重、`(timestamp, id)` 复合游标、字段裁剪、首次回填/增量同步。
- 相似度合并/新增、关键词并集、`merge_count`；supersede 双方标记、旧记忆不召回、置顶不被自动取代。
- 权重（72h recency、30/180 天半衰期、置顶不衰减）、归档（90 天 + 低召回，可恢复，压缩保留原文）。
- 召回分组/关键词/token 裁剪/访问计数/群聊身份映射；提取 JSON 容错、空结果推进游标、失败不推进、本地兜底、空闲兜底、落库合并。
- 历史补总结（一次性、500 条上限、断点续补、重复折叠、无 AI 不写兜底、时间取来源消息、近期 todo 降级、旧数据修复）；自动建卡范围。
- 导出 Markdown/JSON 字段、设置 clamp、旧配置缺键默认值、旧记忆导入映射、全局卡独立列出与合并召回、ChatEngine v2 回退路径。

门禁：

```bash
cd app && SWIFT_DISABLE_SANDBOX=1 swift build --build-tests
cd app && SWIFT_DISABLE_SANDBOX=1 swift test          # 619 项（2 项按环境跳过）
bash scripts/check.sh                                 # 文档/脚本/符号检查
```

## 15. 限制与已知取舍

- 每会话一个 SQLite：会话多时首次列表要逐个打开读计数；`CharacterStore` 缓存 + 限制并发打开数；聚合最多加载 2000 条记忆。
- 提取质量依赖模型，本地兜底只保证「有记忆」；相似度是字符 bigram + 包含关系、非语义向量，同义不同说法可能漏合并，可手动编辑/删除或「取消取代」。
- 全量互动额外占磁盘（每条消息一份文本，不复制媒体）；单会话回填上限 5000 条，更早历史只在账号消息表（清理聊天后不再有副本）。
- 自动建卡覆盖所有「收到过消息」的真实会话：首次维护回填最多 5000 条并补总结最近 500 条，会话多时磁盘与首次升级的 AI 费用会增加。
- 记忆卡按会话隔离，但**全局共享记忆**注入所有会话；全局记忆只手动维护、不自动提取、不进入全量记录、不可删除。
- 新卡默认空：消息到达即建卡，首次维护补总结最近 500 条建卡前历史（旧卡用 `interactions_backfilled_at`，再退 `last_extracted_at`），
  自动建卡只覆盖「收到过消息且未关闭 AI 的真实会话」。
- 历史补总结依赖 AI：无模型时不兜底凑历史、保留断点等恢复；升级首启可能对多张旧卡补总结（每卡最多 500 条），AI 请求 3 并发上限。
- 人格不按会话隔离，修改影响所有使用该人格的会话；没有每会话人设卡/提示词覆盖；公众号/系统会话默认不建卡。
- 微信 `/记忆` 指令不开放，避免把私密记忆发到聊天窗口。
