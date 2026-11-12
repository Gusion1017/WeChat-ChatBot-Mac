# 应用内更新（设置 → 更新）

> 本文是应用内更新的**现行契约**（docs-first）：GitHub Releases 检测、版本比较、自动检查、下载与 SHA256
> 校验、原地安装、更新助手与失败回滚、安装门禁、错误提示和验收清单。服务定位见
> [`core-services.md`](core-services.md) §5.12，页面交互见 [`ui-design.md`](ui-design.md) §5.10；
> 手动下载/覆盖安装的关系见 [`install.md`](install.md) §2.1。
>
> 发布状态：应用内更新自 **3.1.0** 起提供，当前 **4.1.0** 已包含；更早版本仍按
> [`install.md`](install.md) §2 手动下载覆盖安装。

## 1. 用户可感知行为

| 场景 | 行为 |
| --- | --- |
| 设置分类 | 「应用」组为 通用 / 外观 / **更新**；更新页含版本卡、新版本说明、下载进度、自动检查开关、安装位置与错误提示、跳过版本、GitHub/发布说明链接、更新日志入口 |
| 检查 | 自动检查默认开启，App 启动完成后延迟 **8 秒**发起一次，距上次成功检查不足 **6 小时**时不重复；手动「立即检查」随时可点、不受节流限制，失败会展示可读错误 |
| 发现新版本 | 设置分类侧边栏「更新」行显示「新」小徽标（无障碍「有可用更新」），主窗口侧边栏 footer 与菜单栏面板 footer 显示「有新版本 X」，点徽标/footer 直达「设置 → 更新」；自动检查另弹一次**应用内 toast**（不是系统通知） |
| 版本说明 | 更新页始终展示与状态对应的更新内容：已最新时「本版本更新内容」、有更新时「新版本更新内容」，从 Release 正文「本版重点」提取并过滤下载/安装/隐私等模板段落；「下载并安装」确认弹窗同样先展示 |
| 跳过版本 | 「跳过此版本」后该 tag 不再显示徽标、不再提示；更新页保留「已跳过 vX」与「取消跳过」 |
| 执行更新 | 用户确认后下载完整 zip → SHA256 校验 → 解压/校验 → 停止机器人 → 启动更新助手 → App 退出 → 助手替换并重新打开新版本 |
| 失败与手动兜底 | App 内失败保持旧版本运行、错误可重试；助手阶段失败恢复旧版并重新打开，详情写 `update.log`；应用内更新替代「下载 zip → 解压 → 拖入 Applications」，也可继续手动下载覆盖（见 [`install.md`](install.md) §2） |

要点：更新是**显式操作**，不会静默下载/安装或在后台强制替换，更新期间停止机器人并退出 App；只从 GitHub
正式 Release 更新，无 beta/预发布通道、自定义更新源或镜像；toast 只做一次性提醒、不依赖系统通知权限。

## 2. 更新源与 API 契约

| 项目 | 约定 |
| --- | --- |
| 发布渠道 | GitHub Releases（正式版） |
| 仓库 | `Gusion1017/WeChat-ChatBot-Mac` |
| 检查接口 | `GET https://api.github.com/repos/Gusion1017/WeChat-ChatBot-Mac/releases/latest` |
| 鉴权 | 无鉴权、只读公开接口；不发送 API Key / Cookie |
| 请求头 | `Accept: application/vnd.github+json`、`User-Agent: WeChatAI/<version> (macOS; +https://github.com/Gusion1017/WeChat-ChatBot-Mac)`、`X-GitHub-Api-Version: 2022-11-28` |
| 限流 | 未认证请求按来源 IP **60 次/小时**；`403` 且 `X-RateLimit-Remaining: 0`（或任意 `429`）视为限流 |
| 无发布版本 | `404` → 「GitHub 上没有已发布的正式版本」 |
| 响应使用字段 | `tag_name`、`name`、`body`、`html_url`、`published_at`、`assets[].name` / `browser_download_url` / `size` |
| 资产命名 | `WeChat-AI-<version>.zip` 与同名 `WeChat-AI-<version>.zip.sha256` |
| 校验文件格式 | `shasum -a 256` 输出：`<64 位十六进制小写摘要>  <文件名>`；解析首个 token，大小写不敏感 |
| 下载地址门禁 | 只接受 `https`，域名必须是 `github.com` 或 `*.githubusercontent.com` |
| 缓存/重试 | 检查与下载直接发起请求，不依赖本地缓存；失败不自动重试，由用户手动重试 |

约定：

- `/releases/latest` 不返回 draft / prerelease，正常路径只会检测到最新正式版；缺少 `.zip` 资产 → 拒绝应用内
  安装，缺少同名 `.sha256` → **拒绝自动安装**（仍可手动下载核对）。
- Release JSON 的下载/校验地址不满足 https + GitHub 域名时按解析失败处理，不发起下载。

## 3. 版本比较与自动检查

### 3.1 版本比较规则

当前版本来自运行中 App 的 `CFBundleShortVersionString`，Release 版本来自 tag；采用简化的 SemVer 比较：

| 规则 | 示例 |
| --- | --- |
| 忽略 `v` / `V` 前缀与首尾空白 | `v3.1.0` → `3.1.0` |
| 缺失 minor/patch 补 0 | `3.1` → `3.1.0` |
| 忽略 `+build` 元数据 | `3.1.0+abc` → `3.1.0` |
| `-` 后为预发布标识；同号正式版 > 预发布版 | `3.1.0-beta.1` < `3.1.0` |
| 预发布标识按数字/字母逐段比较，数字段按数值比较 | `3.1.0-beta.2` < `3.1.0-beta.10` |
| 只有 Release 版本 **严格大于** 当前版本才提示更新 | 当前 `3.0.0` vs Release `3.0.0`、当前 `3.0.1` vs Release `3.0.0` 均为已是最新 |
| 无法解析的 tag | 检查失败（`invalidVersion`），不尝试猜测版本 |

> 预发布比较用于 tag 解析和契约完整性；GitHub `latest` 接口本身不返回预发布版本，应用内更新没有 beta 通道。

### 3.2 自动检查与提示策略

| 项目 | 行为 |
| --- | --- |
| 开关 | `updates.autoCheck`，默认 `true`；关闭后不自动检查，手动检查仍可用 |
| 启动与节流 | App 启动完成后延迟 8 秒发起，仅当自动检查开启且未被节流时执行；`UpdateCheckPolicy.autoCheckInterval` = 6 小时，以 `updates.lastCheckedAt` 为基准 |
| 手动检查/静默刷新 | 手动检查不受节流限制，成功检查也会刷新 `lastCheckedAt`，顺带推迟下一次自动检查；打开更新页时若自动检查开启、未在忙，且（距上次检查超过 6 小时 **或** `latestRelease` 为空）则静默刷新一次 |
| 检查失败 | 自动检查失败只写日志，**不**进入 `failed`、不弹错误，已有徽标保持不变；手动检查失败进入 `failed(message)` 并可重试 |
| 提示条件、去重与跳过 | Release 版本 > 当前版本且 tag ≠ `updates.skippedTag`；自动检查发现新版本时，若 tag ≠ `updates.lastNotifiedTag`，发一次应用内 toast 并写入该 tag；点「跳过此版本」写入 `skippedTag`，清空即取消跳过，若仍存在更新则恢复 `available` 与徽标 |
| 并发 | 检查/下载/校验/安装进行中不重复触发（`isBusy`）；手动与自动检查共用同一状态机 |

### 3.3 持久化字段（全局 `config.json`）

`AppSettings.updates: UpdateSettings` 字段保存在全局 `config.json`，不随微信账号切换；账号 `profile.json`
不包含 `updates`。

| 字段 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `autoCheck` | `Bool` | `true` | 启动后/打开更新页时是否允许自动检查 |
| `lastCheckedAt` | `Date?` | `nil` | 上次**成功**检查时间；用于 6 小时节流 |
| `skippedTag` | `String` | `""` | 用户跳过的 Release tag；空字符串表示不跳过 |
| `lastNotifiedTag` | `String` | `""` | 已弹过 toast 的 tag；仅用于提示去重，不控制徽标 |

兼容性：

- 旧 `config.json` 缺 `updates` 键时整段回退默认值，**不重置** `general/hook/onebot/ai/bot` 等其它设置；
  `UpdateSettings` 逐字段解码，段内缺键或类型损坏只回退该字段（`SettingsStore.decodeSectionsLossily` 同理）。
- `lastCheckedAt` 只在成功拿到 latest Release 响应后写入；自动检查失败不会推进节流时间。

## 4. 状态机

`UpdateCenter` 是更新流程的唯一 UI 状态源（独立 `@MainActor @Observable` 单例，不并入 `AppStore`）；
状态定义在 `AppUpdateState`：

| 状态 | 触发 | 更新页/UI |
| --- | --- | --- |
| `idle` | 初始化完成、无检查结果 | 显示当前版本与安装位置，可「立即检查」；打开更新页时会补拉一次 latest 以展示本版本更新内容 |
| `checking` | 手动或自动检查 | 按钮显示进度/禁用；不重复发起检查 |
| `upToDate(checkedAt:)` | 无更新、版本不高于当前，或当前 tag 已被跳过 | 「已是最新」+ 上次检查时间；展示「本版本更新内容」（latest Release 的「本版重点」）；跳过的版本提供「取消跳过」 |
| `available(release)` | 发现更高版本且未跳过 | 版本卡、Release 说明、「下载并安装」、跳过、GitHub 链接；三处提示出现（设置分类「新」+ 两处 footer「有新版本 X」），footer 徽标可点击进入「设置 → 更新」 |
| `downloading(received:total:)` | 点击「下载并安装」并开始下载 | 进度条 + 百分比；总大小未知时显示不确定进度 |
| `verifying` | 下载完成，校验 SHA256 | 「正在校验更新包」；失败进入 `failed` |
| `installing` | 校验通过，解压/校验/停止机器人/启动助手 | 「正在准备安装，App 即将退出」；助手启动后 App 自行退出 |
| `failed(message:)` | 检查、下载、校验、解压、门禁或助手启动任一步失败 | 可读错误 + 重试/关闭；关闭后回到 `available`、`upToDate` 或 `idle` |

状态迁移：`idle` →（检查）`checking` → 无更新/已跳过 `upToDate`，或有更高版本 `available` →
`downloading` → `verifying` → `installing` → App 退出；任意 App 内步骤失败 → `failed(message)`。

- `checking`、`downloading`、`verifying`、`installing` 属于 busy 状态，任何入口都不应重复触发；自动检查
  失败不进入 `failed`（若已有可用更新则恢复 `available`，否则回到 `upToDate`/`idle`），避免卡在「检查中」。
- `installing` 之后 App 进程退出，替换与回滚由更新助手完成，不再回到 App 内状态；助手失败时重新打开的是
  **旧版本**，App 从 `idle` 启动，具体原因见 `update.log`。

## 5. 安装流程与更新助手

### 5.1 App 内前半程（进程未退出）

| # | 步骤 | 说明 | 失败处理 |
| --- | --- | --- | --- |
| 1 | 用户确认 | 「下载并安装」前弹出确认：先展示新版本更新内容，再明确会**停止机器人并退出 App**；点击「下载并安装」后弹窗立即关闭并开始下载 | 取消则无副作用 |
| 2 | 安装门禁复核 | 重新解析 `Bundle.main.bundleURL`，检查 `.app`、bundle id、Translocation、目录可写 | 进入 `failed`，不下载 |
| 3 | 下载 zip 并校验 SHA256 | 下载到 `~/Library/Application Support/WeChatAI/updates/update-<UUID>/`，按字节回调进度（约 200ms 节流）；从 Release 同名资产取 `.sha256`（内容为空/格式非法按缺失处理），流式计算 SHA256 比对 | 下载失败删除工作目录；缺失拒绝安装；不匹配 → `failed`，不继续解压 |
| 4 | 解压与校验 | 解压到工作目录，确认是唯一 `.app`，校验 Info.plist、bundle id、版本号、主可执行文件与 codesign 签名 | `unzipFailed` / `invalidBundle` / `signatureInvalid` |
| 5 | 停止机器人并启动助手 | 运行中先 `stopBot()` 并记录「准备安装」；随后写入助手脚本、启动独立进程，日志记录后 `NSApp.terminate` | 机器人可能保持停止、后续失败需手动重启；助手启动失败 → `helperLaunchFailed`，App 保持运行 |

### 5.2 更新助手（App 退出后执行）

助手脚本由 App 写入更新工作目录，用绝对路径调用系统工具、不经过 shell 拼接用户输入；工作对象是当前
App bundle，而不是 `/Applications` 猜测路径。

| # | 步骤 | 具体行为 |
| --- | --- | --- |
| 1 | 等待旧进程退出 | 最多等待约 **60 秒**；超时发信号前用 `/bin/ps -p <pid> -o comm=` 确认 PID 仍是本 App（防 PID 复用误杀），再 SIGTERM → SIGKILL |
| 2 | 备份旧版 | 旧 App `mv` 到同目录 `WeChat AI.app.update-backup-<epoch>` |
| 3 | 展开新版本 | 用 `ditto` 把暂存 App 展开到安装目标 |
| 4 | 去 quarantine、重签并校验 | `xattr -dr com.apple.quarantine <目标 App>`；`/usr/bin/codesign -f -s - --timestamp=none <目标 App>`；`/usr/bin/codesign --verify --strict <目标 App>` |
| 5 | 重新打开与收尾 | `open <目标 App>`（打不开按失败回滚）；保留旧版备份、删除本次 `update-<UUID>` 工作目录，新版本启动时由 `UpdateInstaller.cleanupAfterUpdate` 清理旧备份与残留目录 |

- 等待旧 PID 超时后先发 `SIGTERM`、仍未退出再发 `SIGKILL`，仍无法结束则按失败回滚；`xattr -dr
  com.apple.quarantine` 返回非 0（通常是没有 quarantine 属性）只记录日志，继续下一步。

失败回滚（任一步失败）：

1. 若旧 App 已被移走（备份存在）：删除未完成的半成品，把 `.update-backup-<epoch>` 恢复为原路径；若尚未替换，则保持旧版原样、不删任何 App。
2. 重新 `open` 旧版本；助手以退出码 `1` 结束，完整命令与失败原因写入 `update.log`；本次工作目录保留便于排查，超过 24 小时的下次启动会清理。

- 更新助手成功时立即删除本次工作目录（zip、解压产物与助手脚本），只保留旧版备份与日志。新版本启动完成约
  8 秒后（`UpdateCenter.scheduleLaunchCheck`）执行 `UpdateInstaller.cleanupAfterUpdate`：删除同目录下
  `<App>.app.update-backup-*` 旧备份，并清理 `updates/` 中修改时间超过 **24 小时**的失败/中断残留目录。
  等新版本真正运行起来再删旧包，避免早期崩溃时无可回滚备份；`update.log` 不随替换或清理删除。

### 5.3 路径与日志

| 项目 | 路径/命名 |
| --- | --- |
| 更新工作目录 | `~/Library/Application Support/WeChatAI/updates/`（每次更新 `update-<UUID>/`；成功即时删除，失败保留并由 24h 清理兜底） |
| 旧版备份 | 安装目录下 `WeChat AI.app.update-backup-<epoch>` |
| 更新助手日志/入口 | `~/Library/Logs/WeChatAI/update.log`；更新页「更新日志」打开该文件（不存在时打开所在目录） |
| 机器人停止 | 助手启动前由 App 调用 `stopBot()`；更新完成后需用户重新启动机器人 |

## 6. 安装门禁与错误映射

### 6.1 安装门禁

安装目标固定为当前运行 App 的 `Bundle.main.bundleURL`；以下任一条件不满足都不执行替换：

| 门禁 | 规则 | 不满足时 |
| --- | --- | --- |
| 运行形态 | 必须以 `.app` bundle 运行（`swift run` / 裸二进制不可更新） | `notAnApplicationBundle` |
| bundle id | 必须是 `com.gusionw.wechatai`，避免替换其它 App | `invalidBundle`（Bundle ID 不匹配） |
| App Translocation | 拒绝 `/AppTranslocation/` 随机只读路径 | `translocated` |
| 安装目录可写 | bundle 所在父目录必须可写（不请求管理员/不执行 sudo） | `readOnlyLocation` |
| 资产完整 | 必须有 zip 与同名 `.sha256`，且 SHA256 匹配 | `missingAsset` / `checksumMissing` / `checksumMismatch` |
| 包内容 | 解压后必须是唯一 `.app`，且 bundle id、版本号、主可执行文件与签名校验通过 | `invalidBundle` / `signatureInvalid` |
| 开发构建提示 | 从 `dist/` 或 `.build` 运行允许更新，但更新页提示「当前为开发构建」 | 不阻断，仅提示 |

补充：Translocation 常见于从 ZIP/下载目录直接双击运行，先拖到 `~/Applications` 或 `/Applications` 再启动
才能原地更新；`/Applications` 是否可写取决于安装方式与属主，无写权限时更新页直接提示、不弹管理员授权。
更新页始终展示安装位置，门禁失败时展示对应原因与处理建议。

### 6.2 错误映射

| 错误 | 触发场景 | 用户可见提示 |
| --- | --- | --- |
| `invalidVersion` | tag 无法解析 | 无法解析版本号：`<tag>` |
| `releaseNotFound` | GitHub 没有已发布正式版（404） | GitHub 上没有已发布的正式版本 |
| `rateLimited` | 403 且剩余配额为 0，或任意 429 | GitHub 接口调用过于频繁，请稍后重试 |
| `httpStatus` | 其它非 2xx 状态 | 更新检查失败（HTTP `<status>`） |
| `malformedResponse` | JSON 结构异常、下载地址非 GitHub/https | 更新信息解析失败：`<detail>` |
| `network` | DNS/连接/TLS 等传输错误 | 网络错误：`<message>` |
| `missingAsset` | Release 无可用 zip | 发布包中缺少可安装的 zip 文件 |
| `checksumMissing` | 无同名 `.sha256` 或内容为空 | 发布包缺少 SHA256 校验文件，已拒绝自动安装 |
| `checksumMismatch` | SHA256 不一致 | 更新包校验失败（SHA256 不匹配） |
| `downloadFailed` | 下载中断/写盘失败/取消 | 下载更新失败：`<message>` |
| `unzipFailed` | 解压失败 | 解压更新包失败：`<message>` |
| `invalidBundle` | bundle id/版本/Info.plist 不符 | 更新包不是有效的 WeChat AI 应用：`<detail>` |
| `signatureInvalid` | codesign 校验失败 | 更新包签名校验失败：`<detail>` |
| `notAnApplicationBundle` | 非 `.app` 运行 | 当前不是以 `.app` 方式运行，无法应用内更新 |
| `translocated` | App Translocation 路径 | App 运行在系统隔离路径，无法原地更新：`<path>` |
| `readOnlyLocation` | 安装目录不可写 | 没有写入权限：`<path>` |
| `helperLaunchFailed` | 助手进程无法启动 | 无法启动更新助手：`<message>` |

- 自动检查中的网络/限流错误只写日志；页面错误只在手动检查或安装操作时展示。助手阶段错误不回传 App 状态
  （App 已退出），以 `update.log` 和「旧版重新打开」为准。

## 7. 安全边界

**不发送**：不向 GitHub 发送 API Key、Cookie、OneBot token、聊天内容、账号/wxid 或本地路径；只发送更新
检查/下载所需的标准请求头（含 `User-Agent: WeChatAI/<version>`）。

**不安装**：不安装非 https、非 `github.com` / `*.githubusercontent.com` 域名的包；不跳过 SHA256、bundle id、
版本号或 codesign 校验，任一失败即拒绝；不安装非 `com.gusionw.wechatai` 的 bundle，也不更新 App
Translocation 中的副本；不提供「忽略错误继续安装」的隐藏开关。

**不越权**：不请求管理员权限、不执行 `sudo`、不写系统级目录（LaunchAgents/LaunchDaemons/系统扩展）；只替换
当前 App bundle 并在同目录创建 `.update-backup-*` 备份，不改微信、Hook、bridge 数据；不静默安装、不在后台
强制更新、不自动重启机器人（更新前明确告知会停止机器人并退出 App）；只使用固定仓库的 GitHub 正式 Release。

**信任边界**：zip 与 `.sha256` 同源于 GitHub Release，SHA256 用于完整性校验，不是独立发布者签名，发布链路
信任仍以 GitHub 仓库/TLS 为准；App 为 ad-hoc 签名、未公证，更新助手会 ad-hoc 重签新版本，首次打开可能仍需
Gatekeeper 放行，见 §8。

## 8. 已知限制

| 限制 | 影响 | 处理 |
| --- | --- | --- |
| ad-hoc 签名、未公证 | 替换后的新版本首次打开可能被 Gatekeeper 拦截 | 按 [`install.md`](install.md) §2 Gatekeeper 流程「仍要打开」；助手会移除新包 quarantine（失败只记日志），但不改变未公证事实 |
| 需可写安装目录 | `/Applications` 属主异常或只读卷上不能原地更新 | 安装到 `~/Applications`，或修正目录权限后重试；不提供提权 |
| 仅正式版、无增量更新 | 每次更新下载完整 `WeChat-AI-<version>.zip`（约 70 MB / 66 MiB） | 进度条展示大小；网络慢时等待完成 |
| 助手等待旧 PID 最多约 60 秒 | 旧 App 若未及时退出，助手按失败回滚 | 确保更新时 App 能正常退出；失败后查看 `update.log` |
| 成功启动后无自动降级 | 新版本自身有问题时不会自动回滚 | 旧备份会在新版本**首次启动**时清理；需要保留旧版请更新前自行备份或重新下载旧版安装 |

> 更新失败不会丢失当前版本：App 内失败不退出；助手阶段失败会恢复备份并重新打开旧版；两条路径都异常时，可重新从 Releases 手动下载覆盖安装（见 [`install.md`](install.md)）。

## 9. 验证清单

### 9.1 手动验收

| # | 步骤 | 期望 |
| --- | --- | --- |
| 1 | 打开 设置 → 更新并手动检查 | 左侧「应用」组出现「更新」；版本卡显示当前 `CFBundleShortVersionString`/build、安装位置与门禁状态；`checking` 后进入 `available`/`upToDate`，按钮不重复触发、页面不卡在检查中，已最新时出现「本版本更新内容」 |
| 2 | 自动检查 | 启动后约 8 秒发起一次；`lastCheckedAt` 写入；6 小时内重启不重复请求；关闭开关后启动不再自动检查 |
| 3 | 检查失败 | 断网/限流/404 显示对应可读提示并可重试；自动检查失败只写日志、不弹错误 |
| 4 | 新版本提示与跳过 | 设置分类侧栏「更新」行显示「新」，主窗口侧栏与菜单栏 footer 显示「有新版本 X」；自动检查只弹一次 toast；重启/再次检查同一 tag 不重复弹；跳过/取消跳过后徽标与 toast 相应消失/恢复 |
| 5 | 更新内容与确认 | 已最新显示本版本「本版重点」、有更新显示新版本更新内容（无下载/安装/隐私模板段落，标题/列表/代码块有层级）；点「下载并安装」的弹窗先显示更新内容，再显示退出/替换/重签提示与取消按钮 |
| 6 | 安装门禁与校验 | 非 `.app` 运行、伪造 bundle id、Translocation、只读目录分别给出对应提示且不下载/不替换；损坏 `.sha256` → SHA256 不匹配提示，缺失 `.sha256` → 拒绝安装，伪造非 GitHub 下载地址 → 解析失败提示 |
| 7 | 正常更新与清理 | 机器人运行中点击更新 → 确认 → 下载/校验/安装 → App 退出 → 助手替换并重新打开 → 版本号更新、`update.log` 记录各步骤；本次 `update-<UUID>` 目录立即删除，新版本首次启动清理旧 `.update-backup-*`，人为制造超过 24h 的失败残留后重启会被清理 |
| 8 | 回滚与安全 | 人为制造替换/重签失败 → 已替换时半成品删除、旧版恢复并重新打开、退出码 1、`update.log` 有失败原因；抓包确认只访问 GitHub API/资产域名、请求不含 Cookie/API Key/本地路径、http 地址被拒；新版本 ad-hoc 签名有效（`codesign --verify --strict` 通过）、首次打开按系统提示可放行；更新页 GitHub/Release 链接与更新日志入口可用、相对链接无失效 |

### 9.2 单测覆盖点（`UpdateTests.swift` / `ReleaseNotesTests.swift`）

以 `app/Tests/WeChatAITests/UpdateTests.swift` 与 `ReleaseNotesTests.swift` 的实际用例为准（新增用例数以下方
命令输出为准）；下表是应覆盖的契约点，「现状」列标出仍需补测的部分，不把计划当作已验证：

| 模块 | 覆盖点 | 现状 |
| --- | --- | --- |
| `AppVersion` | `v` 前缀、缺 minor/patch 补 0、`+build` 忽略、预发布 < 同号正式、数字段比较、非法 tag 返回 nil | 已覆盖 |
| `UpdateCheckPolicy` | 6 小时边界；`shouldPrompt` 的更高版本/跳过 tag/同 tag 去重 | 已覆盖 |
| `AppUpdateAssetSelector` | 优先 `WeChat-AI-*.zip`、同名 `.sha256` 配对（大小写不敏感）、缺校验文件返回 nil | 已覆盖 |
| `GitHubUpdateClient.decodeRelease` | tag/name/body/日期/资产解析、非法版本、无资产、缺字段 JSON | 已覆盖 |
| URL/HTTP 门禁 | https + `github.com` / `*.githubusercontent.com` 通过，http、其它域名、无 host 拒绝；200/404/403 剩余 0/429/传输错误映射 | 已覆盖 |
| `UpdateChecksum` | `shasum` 文本解析（空格/制表符/大小写）、空内容、SHA256 已知向量、不匹配抛错 | 已覆盖 |
| `UpdateInstaller` 门禁与包校验 | 非 `.app`、bundle id 不符、Translocation、只读父目录、夹具 bundle 可更新；解压产物缺失/多个 App、Info.plist/bundle id/版本/可执行文件不符、unsigned codesign 拒绝 | 已覆盖（开发构建标记为纯计算，无专门用例） |
| 状态机 | 忙状态不重入；自动检查失败不进入 `failed`；跳过/取消跳过；可用更新徽标判定 | `shouldPrompt` 已覆盖，`UpdateCenter` 状态迁移仍待补 |
| 设置解码 | 旧 `config.json` 缺 `updates` 回退默认；段内缺字段逐项回退；不影响其它设置段 | 旧配置/往返已覆盖，逐字段损坏待补 |
| 清理 | 旧 `.update-backup-*` 与超过 24h 工作目录的清理；未到期目录保留 | 已覆盖 |
| 助手脚本 | 包含等待 PID（含 `ps -p` 身份校验）、备份、`ditto`、quarantine、ad-hoc 重签、verify、open、失败恢复与退出码 1；真实替换/回滚/工作目录自清理集成 | 已覆盖 |
| `ReleaseNotesDocument` | 「本版重点/更新内容」小节提取、模板段落过滤、嵌套标题、列表/代码/引用/表格、CRLF+BOM、软换行合并、空正文 | 已覆盖（`ReleaseNotesTests`） |

运行方式：

```bash
cd app && swift test --filter Update
cd app && swift test                 # 全量；新增用例数以本命令实际输出为准
python3 scripts/check_docs.py        # 文档相对链接
bash scripts/check.sh --docs         # 文档 + hook 副本 + 版本 JSON
```

> 手动验收中的「发布新版本」可在测试 Release/tag 上完成；不要把测试产物、截图或真实账号信息入库；更新助手会真实替换当前 App，验收建议使用独立安装副本并保留可回滚备份。
