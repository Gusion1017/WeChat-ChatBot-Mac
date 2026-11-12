# Qwen3-TTS-1.7B 本地 TTS（唯一语音模型）

> 状态：**2026-11-04 起 CosyVoice3 已移除，Qwen3-TTS-1.7B 是 App 唯一语音模型**：Apple MLX 本机离线
> 推理，GPU（默认）/ CPU（极慢，实验性）；未安装/服务未启动/合成失败或超时时本条回复自动改发文字。
> 相关：[`voice.md`](voice.md)、[`core-services.md`](core-services.md)、[`architecture.md`](architecture.md)、
> 服务契约 [`devtools/cosyvoice/CONTRACT.md`](../devtools/cosyvoice/CONTRACT.md)

## 1. 定位

- **唯一语音模型**：`Qwen3-TTS-12Hz-1.7B-Base-bf16`（Apache-2.0，24 kHz，零样本/ICL 克隆），经
  `mlx-audio` 在 Apple Silicon 本机推理；无引擎选择器、无跨引擎回退。
- **运行设备**：`gpu`（默认，MLX Metal，热态 RTF≈0.54–0.78，推荐）/ `cpu`（MLX CPU，实测 1 秒音频
  约 644 秒、RTF≈619，仅排障/无 GPU，通常因合成超时改发文字）。
- **不支持**：语速倍率（speed）与 instruct 风格指令；`/tts` 仍接受但服务端忽略（兼容旧 App）。
- **降级**：模型未安装/服务未启动/运行中的服务不是 Qwen3/合成失败或超时 → 本条改发文字，不做
  跨模型回退；原因写入运行日志。

## 2. 架构

```
SwiftUI App
  VoiceSynthesisService → CosyVoiceClient (HTTP, 127.0.0.1:5051)
    → Python sidecar devtools/cosyvoice/server.py (FastAPI/uvicorn)
      → Qwen3Engine → Qwen3-TTS-12Hz-1.7B-Base（MLX，默认 GPU；可选 CPU）→ 24 kHz mono 16-bit WAV
  → bridge POST /send_voice (24k WAV) → 官方 SILK SDK 24 kHz → 微信
```

- sidecar 与 App 都只走回环：endpoint 只接受 `127.0.0.1` / `localhost` / `::1`。
- 音色清单以 `voices/voices.json` 为准，启动时读取；新增/修改后调 `POST /voices/reload`。
  sidecar 只读合并后的 `prompt.wav` + `prompt.txt`；串行合成，App 不做并发 `/tts`。
- 启动参数：`--device gpu|cpu|auto`（env `COSYVOICE_DEVICE`），加载模型前确定，`auto` 有 Metal 则
  选 GPU，否则 CPU。

## 3. 安装

### 3.1 App 内（推荐）

1. 机器人 → 语音 → 语音引擎与音色 →「运行环境与模型」→「下载并安装…」；确认体积：模型约 4.2GB +
   依赖约 0.5GB ≈ **4.7GB**，运行时内存约 10GB。
2. 安装脚本：创建 `venv-qwen3tts`（Python 3.10）→ 装 `mlx-audio==0.6.4` + `huggingface_hub` +
   `fastapi/uvicorn/pydantic`（不装 torch、不 clone）→ `snapshot_download` 模型 → 保留 `voices/` →
   写 `.installed-qwen3tts`。
3. 安装后在「管理音色…」导入参考音（§4），选「运行设备」点「启动」等 `/health` 就绪。
4. 旧版 CosyVoice3 文件（模型/`repo/`/旧 `venv/`/`.installed`）不再使用；设置页可清理，只删旧文件，
   保留共享音色与 Qwen3 安装。

> **分发包边界**：安装脚本不生成音色，App 包与仓库不含参考音频、`prompt.txt`、`voices.json`；音色需
> 自行添加，已有 `voices/` 不会因重装删除，请勿提交/分享。

安装目录（`<home>`；开发态默认 `<repo>/_local/cosyvoice`，首次安装时创建，仓库默认不包含该目录（`.gitignore` 已忽略 `_local/`）；打包 App 为 `~/Library/Application Support/WeChatAI/cosyvoice/`）：

```
<home>/
  venv-qwen3tts/                        # Python 3.10
  models/Qwen3-TTS-12Hz-1.7B-Base-bf16/ # MLX 模型（约 4.2GB）
  voices/<voice-id>/{prompt.wav,prompt.txt,meta.json}
  voices/<voice-id>/refs/{ref-N.wav,ref-N.txt}   # 原始参考片段（1–5 条）
  voices/voices.json
  .installed-qwen3tts                   # 安装标记
  venv/ repo/ models/Fun-CosyVoice3-0.5B-2512/ .installed   # 旧版遗留，可清理
```

`WECHATAI_COSYVOICE_HOME` 可覆盖安装根目录，`WECHATAI_COSYVOICE_INSTALL_SCRIPT` /
`WECHATAI_COSYVOICE_SCRIPT` 覆盖脚本位置；`cosyvoice` 为历史命名（契约仍用），实际只安装/运行 Qwen3-TTS。

### 3.2 命令行（开发/排障）

```bash
# 安装（幂等；默认不生成音色）
scripts/install_cosyvoice.sh --home ~/Library/Application\ Support/WeChatAI/cosyvoice
# 启动服务（前台；App 也用同一脚本）
scripts/run_cosyvoice.sh --home <home> --device gpu   # 默认 gpu；cpu/auto 亦可
scripts/run_cosyvoice.sh --home <home> --device cpu   # MLX CPU（极慢，自动跳过 warmup）
# 健康检查 / 音色 / 合成
curl -s http://127.0.0.1:5051/health | jq '{engine,device,model,ready}'
curl -s http://127.0.0.1:5051/voices | jq
curl -s -X POST http://127.0.0.1:5051/tts \
  -H 'Content-Type: application/json' \
  -d '{"text":"今天天气不错，我们出去走走吧。","voice_id":"YOUR_VOICE_ID","speed":1.0}' \
  -o /tmp/voice.wav
```

前置条件：macOS 26 + Apple Silicon（13/14 不保证可用）、`uv` / `python3.10` / conda 之一；约 5GB 磁盘。
脚本不依赖 GUI 进程 PATH（显式搜 `/opt/homebrew/bin`、`/usr/local/bin`、`/opt/anaconda3/bin`）。

## 4. 音色与参考音（只存本机）

导入规则：

- **格式**：AVFoundation 可解码即可（wav/mp3/m4a/aac/aiff/aif/caf/flac 等），拖入或多选。
- **条数与时长**：一个音色 1–5 段；每段 ≥1 秒（单段无上限）；合并 prompt **≤30 秒**（含片段间
  0.25 秒静音），超出导入时自动截取、保存时兜底（沿用旧引擎限制，Qwen3 本身无此硬限制）。
- **参考文本**：导入/更换后默认自动转写（可关、可改），文本越准确克隆越像，留空也能合成但走
  x-vector fallback、相似度下降。全空 → `cross_lingual`（只克隆音色）；部分空 → 保存前自动补齐，
  仍失败按 `cross_lingual` 落盘并提示；ICL 时 `prompt.txt` 为各条非空文本按顺序换行连接，须与合并
  `prompt.wav` 逐字对应。
- **存储布局**（v2）：

  ```
  voices/
    voices.json
    <id>/prompt.wav        # 合并 prompt（24k mono 16-bit），服务端合成用
    <id>/prompt.txt        # 合并参考文本（`\n` 连接；cross-lingual 时可为空）
    <id>/refs/ref-N.wav    # 第 N 条参考音频（24k mono 16-bit，1–5 条）
    <id>/refs/ref-N.txt    # 第 N 条参考文本（可为空）
    <id>/meta.json
  ```

- 旧音色兼容：只有 `prompt.wav` + `prompt.txt`、没有 `refs/` 的按 **1 条**读取并继续可用；用户首次
  编辑参考片段时才迁移到 `refs/` 布局。

### 4.1 新增与管理音色（App 内）

入口：机器人 → 语音 → 语音引擎与音色 → 音色 →「管理音色…」。

- 列表显示名称/简介/时长/参考条数/有无文本，支持试听、设为当前、编辑、删除（仅自定义）。
- 新增：名称（必填 ≤40 字）、简介（可选）→ 1–5 段参考音（拖入或多选，单人、干净无伴奏；超长按
  预算自动截取并提示）→ 默认自动转写（可关、可逐条或全部、可改）→ 保存时按顺序拼成 `prompt.wav`
  （片段间 0.25s 静音）+ `prompt.txt`，原始片段写入 `refs/` 并更新 `voices.json`；服务运行中调
  `POST /voices/reload` 立即生效。
- 编辑：可整组增删/替换片段并用上下箭头调整顺序；换音频会清空该条旧文本并重新转写；仅改名称/简介
  不动音频；旧单参考音色首次编辑片段时迁移到 `refs/`。
- 文本与校验：参考文本用原生文本视图，支持中文输入法组词；`cross-lingual` 不锁输入框，输入/转写
  出文本时自动关闭，保存前提交组词内容。片段 1–5 条、可解码、每段 ≥1 秒、合计 ≤30 秒；保存时统一转
  24k mono 16-bit 并峰值归一。
- **导出自定义音色（本人备份）**：导出 `.zip`（`<id>/prompt.wav`、`prompt.txt`、`meta.json`、
  `voice.json`、`README.txt`，多条参考音色另含 `refs/`；zip 根目录含 `export.json`），仅本机、无上传；预置音色不可导出。

`voices.json` 条目示例：

```json
{"id":"custom-xxx","name":"我的音色","description":"","mode":"zero_shot",
 "prompt_wav":"custom-xxx/prompt.wav","prompt_text":"第一条文本\n第二条文本",
 "references":[
   {"audio":"custom-xxx/refs/ref-1.wav","text":"第一条文本","duration":6.0},
   {"audio":"custom-xxx/refs/ref-2.wav","text":"第二条文本","duration":7.0}],
 "duration":13.25,"personal_use_only":true,"builtin":false,"source":"app-import"}
```

## 5. 设置项

`BotSettings.voice` 相关字段：

- `voiceComputeDevice`：`gpu`（默认，MLX Metal）/ `cpu`（极慢，实验性）；缺键/非法值回退
  `gpu`；切换设备会停旧服务再按自动启动策略拉起；旧键 `voiceEngine` 已删除，解码忽略、不再写入。
- `cosyVoiceVoiceID`：本机 `voices.json` 中的音色 id；未选择/音色库为空时显示「未选择音色」。
- `cosyVoiceEndpoint`：默认 `http://127.0.0.1:5051`（只允许回环）。
- `cosyVoiceAutoStart`：默认 `true`；**仅当「允许语音回复」开启、本开关开启、已安装且有音色时**，
  启动 App/打开语音面板会拉起本地服务。
- `cosyVoiceSpeed`：已无 UI 且 Qwen3 不支持（服务端忽略）；保留字段仅兼容旧配置，缺省 1.0、旧值 0.5–2.0 原样回写。

## 6. HTTP 契约（v2.0.0）

完整字段、错误码与 curl 示例见 [`devtools/cosyvoice/CONTRACT.md`](../devtools/cosyvoice/CONTRACT.md)。
摘要：

- `GET /health`：200 就绪；503 加载中；500 加载失败。字段：`engine="qwen3tts"`、
  `device="gpu"|"cpu"`、`model`、`model_dir`、`sample_rate`、`voices`/`voices_detail`、
  `state`/`progress`/`load_seconds`/`memory_rss_mb`/`stats`。
- `GET /voices`：`{"ok":true,"voices":[{"id","name","description","mode","duration_s",
  "personal_use_only","builtin","reference_count","has_prompt_text"}]}`。
- `POST /voices/reload`：重读 `voices.json` 并重建音色表（不重载模型）。
- `POST /tts`：`{"text","voice_id","speed","instruct"}` → `audio/wav` 24k mono 16-bit；响应头含
  `X-CosyVoice-Engine: qwen3tts` / `X-CosyVoice-Device: gpu|cpu` / `X-CosyVoice-RTF` 等；
  `speed`/`instruct` 仍校验但忽略；错误 JSON：`invalid_request` / `empty_text` / `text_too_long` /
  `unknown_voice` / `not_ready` / `synthesis_failed` 等。

## 7. 性能与限制

- **GPU（默认）**：冷加载约 17–30s（文件缓存热时 1–4s）；首次合成约 9s Metal 预热；热态 23 字 →
  4.7s 音频约 2.6–2.9s（RTF≈0.54–0.78）。MLX peak 约 9–10GB，macOS footprint 约 16GB。
- **CPU（实验性）**：ready 约 1.7s（自动跳过 warmup）；实测「你好」1.04s 音频 synth **644s**
  （RTF≈619.3），23 字更慢；App 合成超时 180s，通常超时改发文字，仅建议排障或降 GPU 占用。
- 文本上限 500 字；长文本上游分句合成，耗时线性增加。运行时内存约 10GB 量级。
- 打包 `.app` 把 `scripts/{install,run}_cosyvoice.sh`、`server.py`、契约/说明复制到
  `Contents/Resources/cosyvoice/`；Python 环境与模型首次使用时下载，不随包分发。App 强杀可能残留
  子进程，正常退出在 `willTerminate` 终止（见 `CosyVoiceProcessRegistry`）。
- 实测：GPU 热态 23 字 → 4.78s 音频 synth 2.57s（RTF 0.538）；App 真机 E2E 3.92s 音频整请求
  12.86s（含冷加载）；模型下载约 4.2GB / 14 文件；MLX peak 9.25–10.02GB，footprint ≈16GB。

RTF 口径：`duration = samples / sample_rate`，`rtf = processing_time_seconds / duration`。
**不要用** `GenerationResult.real_time_factor`（它是 audio_time/processing_time，语义相反）。

## 8. 隐私

- 安装后推理全在本机；`/tts` 只监听 127.0.0.1，文本不出设备。
- 日志只记录 `text_len`、音色、设备、耗时、RTF，不打印正文。
- 模型下载是用户显式同意的网络请求；参考音、合成音频只存本机。

## 9. 故障排查

| 现象 | 排查 |
| --- | --- |
| 显示“未安装” | 看安装日志尾部；确认 `uv`/`python3.10`/conda、磁盘 ≥5GB、网络可达 Hugging Face |
| 旧服务/残留进程 | `/health.engine` 为空或 `cosyvoice3`：旧版服务仍在跑，退出旧版/重启 App 或 `pkill -f devtools/cosyvoice/server.py` 后「重新检测」 |
| `/health` 一直 503 | GPU 模型仍在加载；查 sidecar stderr |
| 端口 5051 被占 | 换端口或停旧进程：`lsof -nP -iTCP:5051 -sTCP:LISTEN` |
| 合成超时/CPU 很慢 | CPU 为实验功能（RTF≈619），建议切回 GPU；超时按既有策略改发文字 |
| 新增音色失败 | 参考片段 1–5 段、可解码、每段 ≥1 秒、合计 ≤30 秒（超长自动截取） |
| 旧版文件占空间 | 设置页「清理旧版语音文件（约 xGB）」；只删旧模型/repo/venv/标记，保留音色 |
| 切换设备后语音没生效 | 切换会停服务再按自动启动；确认 `/health.device` 与设置一致 |

## 10. 代码位置

| 层 | 文件 |
| --- | --- |
| App 合成入口 / HTTP 客户端 | `app/Sources/WeChatBot/Services/VoiceSynthesisService.swift`、`CosyVoiceClient.swift` |
| 生命周期/安装清理 | `app/Sources/WeChatBot/Services/CosyVoiceRuntime.swift`、`CosyVoiceInstaller.swift` |
| 模型/设备/参考规则 | `app/Sources/WeChatBot/Models/CosyVoiceVoice.swift`、`Models/Models.swift`（`VoiceComputeDevice`）、`Models/CosyVoiceReference.swift` |
| 音色管理（增删改/多片段导入/导出） | `app/Sources/WeChatBot/Services/CosyVoiceVoiceStore.swift`、`Views/Components/CosyVoiceVoiceManagerSheet.swift` |
| 设置 UI / 试听 | `app/Sources/WeChatBot/Views/VoiceSettingsPanel.swift`、`Services/VoicePreviewController.swift` |
| Sidecar/脚本/打包 | `devtools/cosyvoice/server.py`、`CONTRACT.md`、`scripts/install_cosyvoice.sh`、`scripts/run_cosyvoice.sh`（历史文件名）、`scripts/build_app.sh`（复制到 `Contents/Resources/cosyvoice/`） |

## 11. 测试与验证状态

- `swift test` **933 项（931 通过 / 2 跳过）0 失败**，`--filter CosyVoice`、`--filter ReferenceImport`
  与真实 GPU E2E 通过；`test_server.py` **72 项通过**（设备解析/auto、health、合成、x-vector
  fallback、headers 等）；完整真实下载/安装在早期版本已跑通。
- 真实 GPU `/tts` 24k WAV、RTF≈0.54–0.78；`--device auto/gpu`、`--wait-health`、`bash -n`、
  `py_compile`、`check.sh --docs`、`check_docs.py` 与安装脚本 `--dry-run` 均通过。
- 未验证：CPU 模式在 App 内的端到端超时/改文字未点验；真机 24k SILK 发送未复测。
