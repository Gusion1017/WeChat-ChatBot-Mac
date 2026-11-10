# 语音能力（入站转写 / 出站合成）

> **发布状态（2026-11-10）**：本文描述 **4.0.1**，已包含 4.2.0.17 适配（见 [`install.md`](install.md)）。
>
> 状态：**入站转写与出站语音发送均已在微信 4.2.0.5 真机打通**；目标微信 4.2.0.17（Hook/文本链路已于
> 2026-11-07 真机验证；语音发送沿用同一链路但未在 4.2.0.17 复测），历史 4.2.0.12 / 4.2.0.9 已验证文本链路。
> 首次使用或微信重启后仍需在本机微信手动发一条文字 + 一条语音捕获发送句柄；App 通过统一的
> 「捕获发送句柄」弹窗提示（见 §4.1）。
> macOS 26+ · 本地处理、数据不出设备 · 相关：[`architecture.md`](architecture.md)、[`bridge.md`](bridge.md)、
> [`core-services.md`](core-services.md)、[`ui-design.md`](ui-design.md)

## 1. 能力与现状

| 能力 | 实现 | 真机状态 |
| --- | --- | --- |
| 入站语音事件 | Hook 上报语音消息，bridge 解析 `<voicemsg>`、登记下载元数据，把文本占位替换为 `{"type":"voice","data":{"duration_ms":N}}` | ✅ 真机收到事件、时长正确 |
| 入站音频获取 | `POST /fetch_voice`：按需触发语音下载 → AES-ECB 解密 → SILK 校验 → 落盘 `.silk` + 16k WAV | ✅ 真机验证（默认 `fileType=15`） |
| 语音转写 | `VoiceTranscriptionService`（SpeechAnalyzer / SpeechTranscriber，zh_CN，本地、离线） | ✅ 真机端到端；系统语音资源可由 App 内按钮下载 |
| 语音气泡/记忆/引用 | 转写落库、气泡展示、可关闭、进上下文/长期记忆、引用语音带转写 | ✅ 单测覆盖；真机待音频链路 |
| 出站 TTS | **唯一模型 Qwen3-TTS-1.7B**（Apple MLX，`Qwen3-TTS-12Hz-1.7B-Base-bf16`，24 kHz，ICL 零样本克隆）；默认 GPU，可切 CPU（实验性）；App 通过回环 HTTP 调用 | ✅ 单测 + 本机样本 + 真实服务 E2E；需用户显式安装（约 4.7GB），GPU 非实时（见 §6） |
| 出站发送 | App 传 TTS 原生 24k WAV（兼容旧 16k WAV/裸 PCM）→ bridge 按 WAV 头识别采样率（16k 才重采样）→ 官方 SILK SDK 编码 → 微信语音发送 | ✅ 真机：TTS 5s 语音正常播放 |
| 语音长度设置 | 全局设置，默认上限 30s（5–60），超限改文字或按句截断 | ✅ 设置与单测 |
| 语音回复策略 | 全局开关、概率、对等、仅短回复（全局设置） | ✅ 决策纯函数 + 单测 |

> 一句话：入站转写与出站语音发送都已真机打通；出站 TTS 走本机 Qwen3-TTS-1.7B（GPU/CPU 可选），
> 模型未安装、服务未启动、旧版服务仍在或合成失败/超时时本条改发文字（不做跨模型自动回退）；中文语音
> 资源缺失时「机器人 → 语音」提供下载按钮，下载后无需重启系统即可转写。

## 2. 数据流

### 入站（读）

```
微信语音 → Hook 事件（text="[语音]" + raw_message=<voicemsg>）
 → bridge 解析语音 XML、登记下载元数据，message[] 替换为 {"type":"voice","data":{"duration_ms":N}}
 → App VoiceFetcher → POST /fetch_voice {"message_id"}
 → bridge 下载分片 → AES-ECB 解密 → SILK 魔数/帧校验 → .silk + 16k WAV
 → App VoiceTranscriptionService（SpeechAnalyzer）→ ChatMessage.voiceTranscript
 → 气泡展示 / 上下文 `[语音 Ns] 转写` / 记忆与搜索
```

### 出站（说）

```
AI 回复文本 → decideVoiceReply（开关/概率/对等/短回复/本地 TTS 就绪）
 → 已确定语音：跳过拟人化随机延迟（「语音回复免拟人化延迟」，默认开）
 → VoiceSynthesisService（Qwen3-TTS-1.7B，GPU/CPU，HTTP 127.0.0.1:5051）→ 24k WAV
 → POST /send_voice {"user_id"/"group_id","pcm16k","duration_ms"}
 → bridge 官方 SILK SDK（`bridge/silkenc`）编码 24k SILK → 上传 → 发送
 → 任一环节失败（引擎未安装/服务未启动/运行引擎与设置不一致/合成失败/voice_send_unsupported）
   → 本条改发文字，不重试语音
```

### 提示词里的语音标注与出站清洗

- `[语音 Ns] 转写` 只是**入站**语音在提示词里的系统标注，让模型知道「对方发的是语音、时长
  多少、说了什么」；AI 自己发出的 TTS 语音回复进入历史时**只保留正文**、不加标注，否则模型会
  把标注当成自己的回复格式照抄，下一轮文字回复就以 `[语音 8s]` 开头发到微信。
- 回复出站前统一清洗：模型误抄的 `[语音 Ns]` / `[语音]` / `[语音，转写失败]`（含全角括号）会被删除，
  再收敛多余空白；清洗后只剩标注时按「空回复」处理（重试/报错），不会发给任何人。记忆提取同理：
  关闭「转写写入记忆」时只有入站语音退化为 `[语音 Ns]` 标签，出站语音仍保留正文，避免记忆里出现
  只有标注的「我：」行。

## 3. 接口契约

### 3.1 入站事件

```json
{"type":"voice","data":{"duration_ms":5200}}
```

- 事件不含 aeskey/CDN key；`raw_message` 保持原 XML（与既有图片行为一致）。
- 时长未知时 `data` 为 `{}`。

### 3.2 `POST /fetch_voice`（Bearer）

请求：`{"message_id":"<事件 message_id>"}`；可选 `file_types`（1–32）覆盖下载 fileType 列表，
默认 `[15]`（调试用）。

成功（HTTP 200）：

```json
{"ok":true,"path":"file:///…/voice_x_16k.wav","silk_path":"file:///…/voice_x.silk","duration_ms":5200}
```

- 失败：HTTP 200 `{"ok":false,"error":"…"}`（不返回 500）；超时/下载失败会恢复登记，App 可重试。
- 参数校验：非 POST → 405，未授权 → 401，`message_id` 缺失 → 400（鉴权语义与 `/send_*` 一致）。

### 3.3 `POST /send_voice`（Bearer）

请求：

```json
{"user_id":"wxid_x","pcm16k":"<base64 16k 单声道 s16le、或 16k/24k 单声道 16-bit WAV>","duration_ms":1000}
```

- `user_id`（私聊）与 `group_id`（群聊）至少给一个；鉴权与请求校验语义同 `/send_*`。
- 裸 PCM 仍按 16k 处理（旧契约）；带 RIFF 头的 WAV 以 `fmt ` 块采样率为准，只接受 16k/24k。
- 24k 输入直接进 SILK；16k 输入仍走 16k→24k 线性插值。

成功：`{"ok":true,"duration_ms":N}`（实际时长按 SILK 帧计算）。
未支持/失败：`{"ok":false,"error":"voice_send_unsupported"}`、`voice_warming_up`
（带 `retry_after_ms`）或可读中文原因。

### 3.4 `GET|POST /voice_status`（Bearer）

只读诊断：返回登录稳定门禁剩余毫秒数、文本/语音发送句柄与语音发送配置状态
（「捕获发送句柄」弹窗与语音面板状态行使用），不含地址与密钥。

## 4. 设置

> 语音设置面板只位于「机器人 → 语音」，复用共用组件 `VoiceSettingsPanel`；设置页不再提供
> 「语音」分类，**会话详情菜单也不提供语音设置**：转写、语音回复、概率、对等、仅短回复、
> 音色与运行设备均为全局设置。语音发送复用「R3 原生发送」开关；首次启用或微信重启后需捕获
> 文本/语音句柄，开启语音回复或机器人启动检测会打开统一的「捕获发送句柄」弹窗（见 §4.1）；
> 未就绪或发送失败时自动降级文字。手动发一条语音时 hook 会克隆 uploadvoice 任务闭包并持久化
> 语音句柄（与文本句柄同存于 `r3-seed.json`，按微信进程恢复）；朋友圈开启时统一弹窗会多一条
> 「打开/发布一次朋友圈」，朋友圈读取/发布样本缺失也会参与启动检测（见 §4.1、[sns.md](sns.md) §2）。

### 4.1 界面（单模型）

- **语音转写**：三个开关 + 「转写资源」行；资源未安装时在行内直接「下载」。
- **语音回复**：默认只显示总开关；开启后才展开概率、对等、短回复阈值、最长时长、超限处理
  与「语音回复免拟人化延迟」。
- **语音引擎与音色**（Qwen3-TTS-1.7B 单模型）：
  - 运行设备与服务：`GPU（MLX，推荐）` / `CPU（极慢，实验性）`，切换时停旧服务→保存→按自动启动
    策略拉起；本地服务显示状态（运行中/启动中/未运行/异常/未检测）+「启动」/「停止」/「重新检测」
    与 subtitle（`Qwen3-TTS-1.7B · GPU/CPU · endpoint · model`），服务地址默认
    `http://127.0.0.1:5051`（只接受回环）。
  - 运行环境与模型：安装/重新安装/删除（约 4.7GB），首次安装弹确认框、可取消/重试；
    删除只清模型/venv/标记，保留共享音色。
  - 音色：本机音色菜单 +「管理音色…」；**App 不内置音色**，安装后为空，导入 1–5 段参考音
    （每段 ≥1s，合计 ≤30s，超长自动截取）新增自定义音色，可编辑/删除（内置不可删）、自动转写与
    试听、导出 `.zip` 备份（含 `refs/`，内置不可导出）；参考文本越准确越像，留空仍可合成但相似度
    下降。导入规则详见 [`cosyvoice.md`](cosyvoice.md) §4。
  - 自动启动：**仅当「允许语音回复」开启、本开关开启、已安装且有音色时**，启动 App /
    打开语音面板会拉起本地服务；面板内仍可手动「启动」。
  - 旧版清理：检测到 CosyVoice3 残留时显示「清理旧版语音文件（约 xGB）」，只删旧模型/repo/venv/标记。
- **试听**：直接调用本地 Qwen3-TTS HTTP 服务（同音色/原生 24k WAV），本地 `AVAudioPlayer`
  播放，不发往微信、不联网；切换音色/运行设备、离开页面或再次点按即停止。全局只保留一个播放器。
- **语音发送状态**：只在开启「允许语音回复」时出现。
- **句柄引导**：统一使用全局「捕获发送句柄」弹窗 `CaptureSetupSheet`（`CaptureSetupPlan` 判定条目/状态）：
  - 条目按功能显示：「发一条文字」始终显示，`ready = voiceRuntimeStatus.textSeed`；「发一条语音」仅在
    「允许语音回复」开启时显示，`ready = voiceSeed`；朋友圈条目只在朋友圈开启时显示。当前微信版本不支持
    语音发送或 R3 未启用时，「发一条语音」显示「不可用」，且不会出现在状态行的「还差：…」里。
  - 删除原「等待登录稳定」步骤；登录预热只作为状态行（仅语音开启且剩余 > 0 时显示倒计时），
    状态还可能为「机器人未运行 / bridge 尚未就绪 / R3 原生发送未开启 / 当前版本不支持语音发送 /
    还差：发一条语音（直接列出缺失条目）」。
  - 开启「允许语音回复」时先刷新 `/voice_status`，不能发送语音即打开该弹窗。
  - **机器人启动检测**：每次启动机器人都重新检测（bridge/hook 未就绪时每 3s 重试、最多约 60s），
    只要发送通道可用且句柄/样本仍缺失就自动弹一次；同一次机器人运行内最多一次，不影响下次启动。
    检测范围：R3 原生发送开启且文字句柄缺失（即使语音、朋友圈都关闭）、语音回复开启且语音句柄缺失、
    朋友圈开启且读取样本（或开启发布后的 post 样本）缺失。用户手动打开弹窗只算本次运行已提示，
    不会吞掉下一次启动的自动提示。
  - 弹窗打开期间约 1s 轮询 `/voice_status`；「重新检测」立即刷新。语音面板只保留单行发送状态与
    「重新检测 / 查看步骤…」入口，不再重复整段说明。

`BotSettings.voice`（可选结构，缺键默认；旧配置完全兼容）：

- 入站：`transcriptionEnabled`（默认开）、`showTranscriptInBubble`（开）、`saveTranscriptToMemory`（开）
- 回复：`replyEnabled`（默认关）、`replyProbability`（0.3）、`mirrorIncomingVoice`、`shortReplyOnly`（开）、
  `shortReplyMaxChars`（80）、`maxVoiceSeconds`（30，5–60）、`overLimit`（text/truncate）、
  `skipHumanizeDelayForVoiceReply`（默认开）
- 本地 TTS：`voiceComputeDevice`（`gpu` 默认 / `cpu`；缺键/非法值回退 gpu）、
  `cosyVoiceVoiceID`（本机 `voices.json` 中的音色 id；未导入时为空）、
  `cosyVoiceEndpoint`（默认 `http://127.0.0.1:5051`，仅回环）、
  `cosyVoiceAutoStart`（默认 true）；旧 `voiceEngine` 键解码时忽略、保存时不再写入；
  `cosyVoiceSpeed` 无 UI、Qwen3 不支持（保留字段仅兼容旧配置）
- 旧键 `engine` / `kokoroSpeakerID` / `kokoroSpeed` / `cloneID` / `modelDownloadConsent`
  在解码时被忽略，保存时不再写入（旧 `config.json` 仍可正常加载）。

语音开关全部为全局设置：关闭转写后不再发起新的语音下载与转写，已有转写仍可显示并参与上下文；
关闭语音回复后只发文字；概率、对等、短回复、音色与运行设备同样由全局设置控制。
`skipHumanizeDelayForVoiceReply` 默认开启：命中语音后直接进入 TTS 合成，不再叠加
`[minDelayMs, maxDelayMs]` 的随机等待（关闭后恢复与文字回复一致的拟人化节奏，文字回复不受影响）。

## 5. 语音模型

- **唯一语音模型是 Qwen3-TTS-1.7B**（`Qwen3-TTS-12Hz-1.7B-Base-bf16`，Apple MLX，依赖
  `mlx-audio`）。安装根目录 `~/Library/Application Support/WeChatAI/cosyvoice/`（开发态默认
  `<repo>/_local/cosyvoice`，首次安装时创建；仓库默认不包含该目录，已被 `.gitignore` 忽略），含 `venv-qwen3tts`、模型、`.installed-qwen3tts` 标记，`voices/` 保留；
  细节见 [`cosyvoice.md`](cosyvoice.md)。
- **安装需用户显式确认**：在「机器人 → 语音 → 语音引擎与音色 → 运行环境与模型」点
  「下载并安装…」，确认框写明体积（约 4.7GB：模型 4.2GB + 依赖 0.5GB，运行时内存约 10GB）；
  安装中可取消，失败可重试，已安装可删除。旧版 CosyVoice3 文件不再使用，设置页提供清理入口。
  资源体积：

  | 资源 | 体积 | 用途 |
  | --- | --- | --- |
  | `Qwen3-TTS-12Hz-1.7B-Base-bf16` | 约 4.2 GB | 唯一语音模型（MLX，ICL 克隆） |
  | 运行环境（`venv-qwen3tts`：mlx-audio + fastapi/uvicorn 等） | 约 0.5 GB | 推理与本地服务运行时 |

- **音色**：App 不内置任何音色，安装后音色列表为空；导入 1–5 段单人参考音频（每段 ≥1s，
  合计 ≤30s）新增自定义音色，参考文本越准确克隆越像（留空也能合成，相似度下降）；保存时
  App 拼成一条 `prompt.wav`（片段间 0.25s 静音）+ `prompt.txt`，原始片段存 `refs/`；
  旧单参考音色继续可用，音色只存本机。
- **数字/日期/电话**：旧引擎的 `rule_fsts`（`date-zh` / `phone-zh` / `number-zh`）已移除，Qwen3
  侧读法以实测为准；语音文本清洗仍在（Markdown/emoji/URL、`[语音 Ns]` 标注、`%` → 百分之、
  货币口语化，见 §2）。
- **系统中文语音资源**：转写依赖系统语音资源，部分机器需先在 系统设置 → 通用 → 语言与地区 →
  语音识别资源 下载中文语音；「机器人 → 语音」也提供「下载中文语音资源」按钮（`AssetInventory`），它与上表
  TTS 资源是两套独立资源。
- 失败降级：模型未安装、运行环境/模型缺失、服务未启动、旧版 CosyVoice3 服务仍占用端口、合成失败或
  超时、发送句柄未就绪或微信侧拒绝时自动改发文字、不重试语音；可在「机器人 → 语音」重试安装/启动
  服务，或退出旧版后重启 App。
- 模型、参考音频、转写与合成音频都只存本机，不上传、无遥测（见 §8）；模型为 Apache-2.0
  （模型卡），通过 `mlx-audio`（MIT）加载。

## 6. 性能与限制

- STT：9.2s → 0.23s；46.6s → 0.51s（RTF 0.011–0.043）；峰值内存约 22 MB；完全离线。
- TTS（Qwen3-TTS，GPU 默认，**非实时**）：冷加载约 17–30s、首次合成含 Metal 预热（约 +9s），
  热态 23 字（约 4.7s 音频）≈2.6–2.9s（RTF≈0.54–0.78），MLX peak 约 9–10GB；CPU 极慢
  （1.04s 音频 ≈644s，RTF≈619），通常超时改发文字；极端长文本（>300 字）仍建议用
  `maxVoiceSeconds`/短回复策略限制。详见 [`cosyvoice.md`](cosyvoice.md) §7。
- 输出：Qwen3-TTS 原生 24k 单声道 16-bit WAV 直通（16k 输入才由 bridge 线性重采样），
  首尾 5 ms 淡入淡出避免 WAV 边界爆音。
- SILK：5.2s/16k PCM → 9,921 B；编码约 0.04s、解码约 0.005s（pilk 实测）；bridge 静态链接
  官方 SILK SDK（`bridge/silkenc`），无 ffmpeg/pilk 运行时依赖。
- 微信语音消息限制 60s；超限按设置改文字/截断。
- 语音回复不保留系统「@ 提及」；群聊带 @ 时直接走文字（避免丢失提及）。AI 自己写进正文的
  开头 `@昵称` 会在朗读稿清洗时去掉，不再念出昵称。
- 语音发送依赖「R3 原生发送」开关，未开启或失败时自动降级文字；4.2 语音发送为实验路径，
  filehelper 目标未验证。
- 转写失败/低置信度不会编造内容；静音幻觉由置信度门限过滤。

## 7. 限制与现状

- **入站**：默认用 `triggerDownload(fileType=15)`（0x0F）拉取语音，fileType 5/6 会被拒绝，请求体
  可覆盖 `file_types`（见 §3.2）；真实入站语音已验证，`/fetch_voice` 返回 16k WAV、时长与 XML 一致。
- **出站**：官方 SILK SDK（`-tencent`，24 kHz）以 cgo 包 `bridge/silkenc` 静态编入 bridge，与真实
  微信语音走同一上传/发送链路；TTS 24k PCM 直通（旧 16k 输入先线性重采样到 24k），补静音对齐
  20ms 帧再编码。真机验证 TTS 5s 语音有声音、内容正确、可正常停止。使用限制：

  1. 首次启用语音发送或微信重启后，需要在本机微信**手动发一条文字 + 一条语音**捕获句柄；
     bridge 重启会自动恢复。App 会用统一的「捕获发送句柄」弹窗提示（见 §4.1）。
  2. bridge 刚启动的 **60 秒内**登录尚未稳定，语音上传可能失败并降级文字；弹窗/面板只以状态行展示
     倒计时（不再作为独立步骤），等待或恢复后重新检测即可。
  3. 语音发送失败必须保持自动降级文字，不能重试语音（避免重复发送）。
  4. 发送后桌面微信可能不回显（与文本发送一致），以手机/对方客户端为准。

> Hook 发送/下载改动只在 `hook/script.js` 与版本 JSON；公开文档不记录函数地址与偏移。

## 8. 隐私与安全

- 音频、转写、参考音频（含 `refs/` 原始片段与合并 prompt）只存本机；日志不打印转写原文、
  音频字节、aeskey、CDN key。转写展示/记忆可分别关闭，删除消息/会话时随本地存储清理。
- 首次启用或微信重启后需捕获发送句柄；默认 `replyEnabled=false`，句柄/倒计时未就绪时失败自动降级
  文字。App 用统一的「捕获发送句柄」弹窗提示（条目按语音/朋友圈开关显示），不控制微信界面。
  本地 TTS 引擎安装与模型下载是用户显式确认后的网络请求，不上传任何用户数据。

## 9. 代码位置

| 层 | 文件 |
| --- | --- |
| Hook | `hook/script.js`（语音下载触发与语音发送入口） |
| Bridge | `bridge/voice.go`、`bridge/voice_test.go`、`bridge/incoming.go`、`bridge/http.go`、`bridge/main.go`、`bridge/param.go` |
| STT | `app/Sources/WeChatBot/Services/VoiceTranscriptionService.swift`、`VoiceFetcher.swift` |
| 回复决策 | `app/Sources/WeChatBot/Services/VoiceReplyDecision.swift` |
| TTS | `app/Sources/WeChatBot/Services/VoiceSynthesisService.swift`、`VoiceSynthesisAudio.swift`、`VoiceSynthesisText.swift`；Qwen3-TTS-1.7B 单模型（无引擎选择）；设置见 `Views/VoiceSettingsPanel.swift` |
| 音色/试听 | `Services/VoicePreviewController.swift`（共享试听播放器，走当前引擎的本地 HTTP 服务） |
| 本地 TTS | `Services/CosyVoice{Client,Runtime,Installer}.swift`、`Models/CosyVoiceVoice.swift`、`Models/CosyVoiceReference.swift`、`Services/CosyVoiceVoiceStore.swift`、`Views/Components/CosyVoiceVoiceManagerSheet.swift`、`devtools/cosyvoice/`、`scripts/{install,run}_cosyvoice.sh`；详见 [`cosyvoice.md`](cosyvoice.md) |
| UI | `Views/VoiceSettingsPanel.swift`、`Views/CaptureSetupSheet.swift`、`Views/Components/MessageBubble.swift`、`Views/ConversationsView.swift`；条目/状态判定见 `Models/CaptureSetup.swift` |
| 数据 | `Models/Models.swift`、`Services/MemoryStore.swift`、`Core/AppStore+Runtime.swift` |

## 10. 测试

```bash
bash scripts/check.sh --with-go        # 静态 + Swift 全量 + Go
cd app && SWIFT_DISABLE_SANDBOX=1 swift test --scratch-path .build-lead
```

当前：Swift **886 项**执行（884 通过 / 2 项按环境跳过：真实本地 TTS 服务 E2E；0 失败，41 个测试文件；覆盖 Qwen3 GPU/CPU、参考音
导入、语音合成/发送回归、记忆 v2、捕获句柄判定）；Go **312 项**用例（180 顶层 + 132 子测试，0 失败；`bridge/*_test.go` 19 个文件）；4.0.0 App 约 175MB（本机 `dist/` 实测；二进制约 21MB，
不再静态链接 sherpa-onnx）。语音实现细节见 `bridge/voice.go`、`bridge/voice_test.go`；
契约与限制见本文件与 [`bridge.md`](bridge.md)。
