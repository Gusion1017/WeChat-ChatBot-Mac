# Qwen3-TTS-1.7B 本地 TTS（唯一语音模型）

> 状态：**2026-11-04 起 CosyVoice3 已移除，Qwen3-TTS-1.7B 是 App 唯一的语音模型。**
> 本机离线推理（Apple MLX），支持 **GPU（默认）/ CPU（极慢，实验性）** 两种运行设备；
> 未安装/服务未启动/合成失败/合成超时时本条回复自动改发文字。
> 相关：[`voice.md`](voice.md)、[`core-services.md`](core-services.md)、[`architecture.md`](architecture.md)、
> 服务契约 [`devtools/cosyvoice/CONTRACT.md`](../devtools/cosyvoice/CONTRACT.md)

## 1. 定位

- **唯一语音模型**：`Qwen3-TTS-12Hz-1.7B-Base-bf16`（Apache-2.0，24 kHz，零样本/ICL 克隆），
  通过 `mlx-audio` 在 Apple Silicon 上本机推理；不再有引擎选择器、CosyVoice3 安装或跨引擎回退。
- **运行设备可选**：
  - `gpu`（默认）：MLX Metal，热态 RTF≈0.54–0.78，推荐；
  - `cpu`：MLX CPU 后端，实测 1 秒音频约 644 秒（RTF≈619），**仅用于排障/无 GPU 环境**；
    因 App 合成超时 180 秒，CPU 模式通常会超时并改发文字。CPU 模式自动跳过预热，服务可快速 ready。
- **参考文本**：Qwen3 ICL 克隆需要 `ref_audio` + 逐字对应 `ref_text`；缺失时静默走
  speaker-encoder（x-vector）fallback，仍能出声但相似度下降。App 导入参考音时默认自动转写。
- **不支持**：语速倍率（speed）与 instruct 风格指令；`/tts` 仍接受这两个字段但服务端忽略（兼容旧 App）。
- **App 包不内置任何音色**：不打包参考音频、`prompt.txt`、`voices.json`；音色需用户自行导入。
- **降级**：模型未安装/服务未启动/旧版 CosyVoice3 服务仍占用端口/合成失败或超时 → 本条改发文字。

## 2. 架构

```
SwiftUI App
  VoiceSynthesisService
    → CosyVoiceClient (HTTP, 127.0.0.1:5051)
      → Python sidecar: devtools/cosyvoice/server.py (FastAPI/uvicorn)
        → Qwen3Engine → Qwen3-TTS-12Hz-1.7B-Base（MLX，默认 GPU；可选 CPU）
        → 24 kHz mono 16-bit WAV
    → 统一时长/截断/淡入淡出/写 WAV
  → bridge POST /send_voice (24k WAV)
    → 官方 SILK SDK 24 kHz → 微信
```

- sidecar 只监听回环地址；App 的 endpoint 只接受 `127.0.0.1` / `localhost` / `::1`。
- 音色清单以本机 `voices/voices.json` 为准；服务启动时读取清单，新增/修改后
  `POST /voices/reload` 增量更新，不重载模型。
- 每请求由 MLX 现算参考音特征，不做 prompt 特征缓存。
- 多条参考音频在**保存时**由 App 按顺序拼接为一条合并 prompt（片段间 0.25s 静音），
  sidecar 仍只读 `prompt.wav` + `prompt.txt` 合成。
- 串行合成；App 不做并发 `/tts`。
- 启动参数：`--device gpu|cpu|auto`（env `COSYVOICE_DEVICE`）。GPU/CPU 在**加载模型前**
  通过 `mlx.core.set_default_device()` 设定；`auto` 在 Metal 可用时选 GPU，否则 CPU。

## 3. 安装

### 3.1 App 内（推荐）

1. 机器人 → 语音 → 语音引擎与音色 →「运行环境与模型」；
2. 点「下载并安装…」，确认体积：MLX 模型约 4.2 GB + 依赖约 0.5 GB，合计约 **4.7 GB**；
   运行时内存约 10 GB；
3. 安装脚本依次：创建 `venv-qwen3tts`（Python 3.10）→ 安装 `mlx-audio==0.6.4` + `huggingface_hub`
   + `fastapi/uvicorn/pydantic`（不装 torch、不 clone 仓库）→ `snapshot_download` 模型 →
   创建/保留 `voices/` → 写 `.installed-qwen3tts` 标记；
4. 安装完成后先在「管理音色…」导入参考音（规则见 §4），再选「运行设备」并点「启动」，等待
   `/health` 就绪：GPU 冷加载约 17–30s，首次合成有约 9s Metal 预热；
5. 历史版本留下的 CosyVoice3 文件（模型/`repo/`/旧 `venv/`/`.installed`）不再使用；设置页检测到残留时
   显示「清理旧版语音文件（约 xGB）」，清理只删这些旧文件，保留共享音色与 Qwen3 安装。

> **分发包边界**：安装脚本**不生成任何音色**，App 包不包含参考音频/`prompt.txt`。
> 普通用户安装后音色列表为空，需自行添加；本机已有的 `voices/` 不会被安装/重装删除。

安装目录（源码运行时；打包 App 为 `~/Library/Application Support/WeChatAI/cosyvoice/`）：

```
_local/cosyvoice/
  venv-qwen3tts/                        # Python 3.10（mlx-audio + fastapi/uvicorn）
  models/Qwen3-TTS-12Hz-1.7B-Base-bf16/ # MLX 模型（约 4.2GB）
  voices/<voice-id>/{prompt.wav,prompt.txt,meta.json}   # 合并后的合成用 prompt
  voices/<voice-id>/refs/{ref-N.wav,ref-N.txt}          # 原始参考片段（1–5 条）
  voices/voices.json
  .installed-qwen3tts                   # 安装标记
  # 以下仅旧版遗留，可由 App 清理：
  venv/  repo/  models/Fun-CosyVoice3-0.5B-2512/  .installed
```

可用 `WECHATAI_COSYVOICE_HOME` 覆盖安装根目录；脚本位置可用
`WECHATAI_COSYVOICE_INSTALL_SCRIPT` / `WECHATAI_COSYVOICE_SCRIPT` 覆盖。
脚本/目录名中的 `cosyvoice` 是历史命名（App 契约仍使用），产品上只安装/运行 Qwen3-TTS。

### 3.2 命令行（开发/排障）

```bash
# 安装（幂等；每步输出 PROGRESS 0..1 中文说明；默认不生成音色）
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

前置条件：macOS 26 + Apple Silicon、`uv`（或 conda）、`ffmpeg`；约 5 GB 磁盘。
脚本会显式搜索 `/opt/homebrew/bin`、`/usr/local/bin`、`/opt/anaconda3/bin`，不依赖 GUI 进程的 PATH。

## 4. 音色与参考音（只存本机）

> **分发包边界**：仓库与 App 包不包含任何参考音频、`prompt.txt`、`voices.json`。
> 每个用户需要自行导入自己的参考音；请勿把个人音色目录或音频提交/分享。

导入规则：

- **格式**：只要 AVFoundation 能解码就接受——wav / mp3 / m4a / aac / aiff / aif / caf / flac 等，
  拖入或多选均可。
- **条数与时长**：一个音色 1–5 段；每段 ≥1 秒，单段没有上限；合并 prompt 以 **≤30 秒**
  （含片段间 0.25 秒静音）为硬约束。超出总预算的部分在导入时**自动截取**并提示，保存时再做兜底。
  （30 秒是历史引擎 tokenizer 的限制；Qwen3 本身无此硬限制，但保持共享规则以兼容旧音色。）
- **参考文本**：导入/更换音频后默认**自动转写**（可关闭、可手动修改）。文本越准确，克隆越像；
  留空也能合成，但 Qwen3 会走 x-vector fallback，相似度下降：
  - 全部为空 → `cross_lingual`（只克隆音色，文本不参与合成）；
  - 部分为空 → 保存前自动补齐；仍失败则按 `cross_lingual` 落盘，App 会提示；
  - ICL 时 `prompt.txt` 是非空参考文本按顺序用换行 `\n` 连接，必须与合并 `prompt.wav`
    中各片段逐字对应；文本缺失/错配会降低克隆相似度。
- **存储布局**（v2）：

  ```
  voices/
    voices.json
    <id>/
      prompt.wav        # 合并 prompt（24k mono 16-bit），服务端合成用
      prompt.txt        # 合并参考文本（`\n` 连接；cross-lingual 时可为空）
      refs/ref-1.wav    # 第 1 条参考音频（24k mono 16-bit）
      refs/ref-1.txt    # 第 1 条参考文本（可为空文件）
      refs/ref-2.wav
      refs/ref-2.txt
      meta.json
  ```

- 旧音色兼容：只有 `prompt.wav` + `prompt.txt`、没有 `refs/` 的音色按 **1 条**读取并继续可用；
  只有用户主动编辑参考片段时才迁移到 `refs/` 布局。

### 4.1 新增与管理音色（App 内）

入口：机器人 → 语音 → 语音引擎与音色 → 音色 →「管理音色…」。

- 列表：本机已有音色 + 自定义音色；显示名称、简介、时长、参考音频条数、
  是否有参考文本；支持试听、设为当前、编辑、删除（仅自定义）。
- 新增：
  1. 名称（必填，≤40 字）、简介（可选）；
  2. 参考音频 **1–5 段**（可拖入或一次多选；常见格式即可，单人、干净无伴奏）；
  3. 导入后按剩余预算自动截取超长部分，并 toast「已自动截取到 x 秒」；
  4. 默认自动转写参考文本（工具条「导入后自动转写」可关闭）；可逐条或「自动转写全部」，
     也可手动修正；参考文本越准确克隆越像；
  5. 保存后按顺序拼接为 `voices/<id>/prompt.wav`（片段间 0.25s 静音），非空文本用换行连接为
     `prompt.txt`，原始片段写入 `voices/<id>/refs/ref-N.wav|txt` 并更新 `voices.json`；
     服务运行中就调用 `POST /voices/reload` 立即生效，未运行则下次启动生效。
- 编辑：自定义音色可整组增删/替换参考片段，可用上下箭头调整合并顺序；更换音频会清空该条旧文本
  并自动重新转写。仅改名称/简介不重写音频；旧单参考音色在首次编辑参考片段时迁移到 `refs/` 布局。
- 文本输入：参考文本使用原生文本视图，支持中文输入法组词；`cross-lingual` 不锁死输入框，
  手动输入文本或自动转写成文本时会自动关闭 `cross-lingual`；保存前会先提交正在组词的内容。
- 校验：参考片段 1–5 条；音频必须可解码、至少 1 秒、合计 ≤30 秒；空/无声/不可解码仍有明确提示；
  保存时统一转 24k mono 16-bit 并做峰值归一，避免削波。
- **导出自定义音色（本人备份）**：导出为 `.zip`（`prompt.wav`、`prompt.txt`、`meta.json`、
  `voice.json`、`README.txt`，多条参考音色另含 `refs/ref-N.wav|txt`），仅本机备份、无网络上传。
  预置音色不可导出。

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

- `voiceComputeDevice`：`gpu`（默认，MLX Metal）/ `cpu`（MLX CPU，极慢，实验性）；
  缺键/非法值回退 `gpu`。切换设备会停旧服务，再按自动启动策略拉起。旧键 `voiceEngine` 已删除，
  解码时忽略、保存时不再写入；
- `cosyVoiceVoiceID`：本机 `voices.json` 中的音色 id；未选择/音色库为空时显示「未选择音色」；
- `cosyVoiceEndpoint`：默认 `http://127.0.0.1:5051`（只允许回环）；
- `cosyVoiceAutoStart`：默认 `true`；**仅当「允许语音回复」开启、本开关开启、已安装且有音色时**，
  启动 App / 打开语音面板会拉起本地服务；
- `cosyVoiceSpeed`：已无 UI 且 Qwen3 不支持，保留字段仅兼容旧配置，内部固定 1.0。

回退：模型未安装 / 服务未启动 / 运行中的服务不是 Qwen3（旧版 CosyVoice3 残留）/ 合成失败或超时
→ 本条改发文字，不做跨模型自动回退。回退原因写入运行日志。

## 6. HTTP 契约（v2.0.0）

完整字段、错误码与 curl 示例见 [`devtools/cosyvoice/CONTRACT.md`](../devtools/cosyvoice/CONTRACT.md)。
摘要：

- `GET /health`：200 就绪；503 加载中；500 加载失败。字段：`engine="qwen3tts"`、
  `device="gpu"|"cpu"`、`model`、`model_dir`、`sample_rate`、`voices`/`voices_detail`、
  `state`/`progress`/`load_seconds`/`memory_rss_mb`/`stats`；不再有 `hybrid`/`flow_steps`；
- `GET /voices`：`{"ok":true,"voices":[{"id","name","description","mode","duration_s",
  "personal_use_only","builtin","reference_count","has_prompt_text"}]}`；
- `POST /voices/reload`：重新读取 `voices.json` 并重建音色表（不重载模型）；
- `POST /tts`：`{"text","voice_id","speed","instruct"}` → `audio/wav` 24k mono 16-bit；
  响应头含 `X-CosyVoice-Engine: qwen3tts` / `X-CosyVoice-Device: gpu|cpu` /
  `X-CosyVoice-RTF` 等；`speed`/`instruct` 仍校验但忽略；
  错误 JSON（`invalid_request` / `empty_text` / `text_too_long` / `unknown_voice` /
  `not_ready` / `synthesis_failed` 等）。

## 7. 性能与限制

- **GPU（默认）**：冷加载约 17–30s（文件缓存热时 1–4s）；首次合成约 9s Metal 预热；
  热态 23 字 → 4.7s 音频约 2.6–2.9s（RTF≈0.54–0.78）。MLX peak 约 9–10GB，
  macOS footprint 约 16GB。
- **CPU（实验性）**：ready 约 1.7s（自动跳过 warmup）；实测「你好」1.04s 音频 synth **644s**
  （RTF≈619），23 字更慢。App 合成超时 180s，CPU 模式通常超时改发文字；仅建议排障或降 GPU 占用。
- 文本上限 500 字；长文本上游分句合成，耗时线性增加。
- 运行时内存约 10GB 量级（建议单并发使用）。
- 打包 `.app` 把 `scripts/{install,run}_cosyvoice.sh`、`server.py`、契约/说明复制到
  `Contents/Resources/cosyvoice/`；Python 环境与模型首次使用时下载，不随包分发。
- App 强杀时子进程可能遗留；正常退出会在 `willTerminate` 终止（见 `CosyVoiceProcessRegistry`）。
- macOS 13/14 不保证可用；目标 macOS 26+（与 App 一致）。

### 7.1 实测（Apple Silicon，macOS 26，2026-11-04）

| 场景 | 实测 |
| --- | --- |
| GPU 冷启动（新进程） | 约 17–30s（含 import/权重/预热；文件缓存热时 1–4s） |
| GPU 热态 23 字 → 4.78s 音频 | synth 2.57s，RTF 0.538 |
| GPU 真机 E2E（App 路径） | 3.92s 音频，整请求 12.86s（含冷加载） |
| CPU ready | 1.7s（load 1.7s；warmup 自动跳过） |
| CPU 1.04s 音频 | synth 644s，RTF 619.3 |
| 模型下载 | 约 4.2GB / 14 文件（权重 3.6GB + tokenizer 0.65GB） |
| MLX peak / footprint | 9.25–10.02GB / ≈16GB |

RTF 口径：`duration = samples / sample_rate`，`rtf = processing_time_seconds / duration`。
**不要用** `GenerationResult.real_time_factor`（它是 audio_time/processing_time，语义相反）。

## 8. 隐私

- 安装后推理全在本机；`/tts` 只监听 127.0.0.1，文本不出设备。
- 日志只记录 `text_len`、音色、设备、耗时、RTF，不打印正文。
- 模型下载是用户显式同意的网络请求；参考音、合成音频只存本机。

## 9. 故障排查

| 现象 | 排查 |
| --- | --- |
| 显示“未安装” | 看安装日志尾部；确认 `uv`/`conda`、磁盘 ≥5GB、网络可达 Hugging Face |
| 启动失败（旧服务占用） | 若 `/health.engine` 为空或 `cosyvoice3`：旧版 CosyVoice3 服务仍在跑。退出旧版/重启 App，或 `pkill -f devtools/cosyvoice/server.py` 后「重新检测」 |
| `/health` 一直 503 | GPU 模型仍在加载；首次 17–30s 正常；查 sidecar stderr |
| 端口 5051 被占 | 换端口或停掉旧进程：`lsof -nP -iTCP:5051 -sTCP:LISTEN` |
| 合成超时/CPU 模式很慢 | CPU 为实验功能（RTF≈619），建议切回 GPU；超时按既有策略改发文字 |
| 新增音色失败 | 参考片段 1–5 段、可解码、每段 ≥1 秒、合计 ≤30 秒（超长自动截取） |
| 旧版文件占空间 | 设置页「清理旧版语音文件（约 xGB）」；只删旧模型/repo/venv/标记，保留音色 |
| 切换设备后语音没生效 | 切换会停服务再按自动启动；确认 `/health.device` 与设置一致 |
| App 退出后进程仍在 | 正常退出应终止；异常时 `pkill -f devtools/cosyvoice/server.py` |

## 10. 代码位置

| 层 | 文件 |
| --- | --- |
| App 合成入口 | `app/Sources/WeChatBot/Services/VoiceSynthesisService.swift` |
| App HTTP 客户端 | `app/Sources/WeChatBot/Services/CosyVoiceClient.swift` |
| 服务生命周期 | `app/Sources/WeChatBot/Services/CosyVoiceRuntime.swift` |
| 安装/下载/删除/旧版清理 | `app/Sources/WeChatBot/Services/CosyVoiceInstaller.swift` |
| 音色/健康模型 | `app/Sources/WeChatBot/Models/CosyVoiceVoice.swift` |
| 设备选择（`VoiceComputeDevice`） | `app/Sources/WeChatBot/Models/Models.swift` |
| 参考片段规则（条数/时长/合并/预算） | `app/Sources/WeChatBot/Models/CosyVoiceReference.swift` |
| 音色管理（增删改/多片段音频导入/导出） | `app/Sources/WeChatBot/Services/CosyVoiceVoiceStore.swift` |
| 音色管理 UI | `app/Sources/WeChatBot/Views/Components/CosyVoiceVoiceManagerSheet.swift` |
| 设置 UI | `app/Sources/WeChatBot/Views/VoiceSettingsPanel.swift` |
| 试听 | `app/Sources/WeChatBot/Services/VoicePreviewController.swift` |
| Sidecar | `devtools/cosyvoice/server.py`、`CONTRACT.md` |
| 安装/启动脚本 | `scripts/install_cosyvoice.sh`、`scripts/run_cosyvoice.sh`（历史文件名） |
| 打包 | `scripts/build_app.sh`（复制到 `Contents/Resources/cosyvoice/`） |

## 11. 测试与验证状态（2026-11-04）

已完成：

- `swift test`：**603 项执行（601 通过 / 2 跳过）0 失败**；`--filter CosyVoice` 与
  `--filter ReferenceImport` 通过；真实 GPU E2E（`WECHATAI_COSYVOICE_E2E=1`）通过；
- `python3 devtools/cosyvoice/test_server.py`：**72 项通过**（设备解析/auto、fake MLX 设备设置、
  health device、合成、x-vector fallback、headers、前置检查）；
- 真实 GPU `/tts`：24k WAV，RTF≈0.54–0.78；run 脚本 `--device auto/gpu` 与 `--wait-health` 实测通过；
- 真实 CPU：ready 1.7s（warmup 跳过）、1.04s 音频 synth 644s；确认 App 180s 超时后改发文字；
- `bash -n`、`py_compile`、`scripts/check.sh --docs`、`check_docs.py` 全部通过；
- 安装脚本 `--dry-run` 两路径（源码/生产 home）输出正确；完整真实下载/安装在此前版本已跑通。

未完成/待用户环境验证：

- CPU 模式在 App 内的端到端超时/改文字未实际点验（sidecar 数据已确认必然超时）；
- 真机微信 24k SILK 发送未复测（发送链路未改）。
