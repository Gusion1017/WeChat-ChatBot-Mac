# 本地旁路服务契约（v2.0.0）

`devtools/cosyvoice/server.py` 是 App 的本地 TTS sidecar：常驻 Python 进程，启动即预加载
**Qwen3-TTS-12Hz-1.7B-Base-bf16**（Apple MLX，依赖 `mlx-audio`），HTTP 提供本机已导入音色的
语音合成。v2.0.0 起只有这一个引擎：CosyVoice3 / `--engine` / repo / PyTorch / MPS / flow-steps
全部移除。

- 模型：`Qwen3-TTS-12Hz-1.7B-Base-bf16`（MLX 社区版，约 4.2GB / 14 文件）
- 推理设备：`gpu`（MLX Metal，默认）/ `cpu`（MLX CPU）/ `auto`（Metal 可用则 GPU，否则 CPU）
- 默认地址：`http://127.0.0.1:5051`（只监听回环地址）
- 启动方式：`scripts/run_cosyvoice.sh`（App 用 `Process` 直接 spawn，前台运行）
- 安装方式：`scripts/install_cosyvoice.sh`（文件名是 App 历史契约，内容已是 Qwen3-only）
- 协议：HTTP/1.1 + JSON；TTS 成功返回二进制 WAV
- 相关文档：[`docs/cosyvoice.md`](../../docs/cosyvoice.md)

---

## 0. 启动参数与环境变量

`scripts/run_cosyvoice.sh`（recommended）：

```bash
scripts/run_cosyvoice.sh [--home DIR] [--host 127.0.0.1] [--port 5051] \
                         [--model-dir DIR] [--venv DIR] [--refs DIR] \
                         [--device gpu|cpu|auto] [--log-level info] \
                         [--wait-health] [--require-voices]
```

也可直接运行 `python devtools/cosyvoice/server.py <同名参数>`。

| 参数 | 环境变量 | 默认值 |
|---|---|---|
| `--home`（仅脚本） | `COSYVOICE_HOME` / `COSYVOICE_LOCAL_DIR` | 源码运行 `_local/cosyvoice`；打包 App 为 `~/Library/Application Support/WeChatAI/cosyvoice` |
| `--host` | `COSYVOICE_HOST` | `127.0.0.1` |
| `--port` | `COSYVOICE_PORT` | `5051` |
| `--model-dir` | `COSYVOICE_MODEL_DIR` | `<home>/models/Qwen3-TTS-12Hz-1.7B-Base-bf16` |
| `--venv` | `COSYVOICE_VENV` | `<home>/venv-qwen3tts`（server.py 只用于日志/自检展示） |
| `--refs` | `COSYVOICE_REFS` | `<home>/voices` |
| `--device` | `COSYVOICE_DEVICE` | `gpu`；`gpu`=MLX Metal，`cpu`=MLX CPU，`auto`=`mx.metal.is_available()` 为真则 gpu 否则 cpu |
| `--log-level` | `COSYVOICE_LOG_LEVEL` | `info` |
| `--no-warmup` | — | 关闭启动预热合成（CPU 模式无论如何都会自动跳过） |

**已删除的参数**：`--engine`、`--repo`、`--flow-steps`、`--threads`（脚本与 server.py 都不再接受；
传了会以「未知参数」报错退出）。不再有 `COSYVOICE_ENGINE` / `COSYVOICE_REPO` / `COSYVOICE_FLOW_STEPS`。

### 0.1 推理设备（GPU / CPU）

- 设备必须在**加载模型之前**设置：`import mlx.core as mx; mx.set_default_device(mx.gpu|mx.cpu)`。
  mlx-audio 的权重加载与 `generate()` 都使用 MLX 默认设备。
- 默认 `gpu`；`--device gpu` 但 `mx.metal.is_available()` 为假时回退 `cpu` 并记 warning。
- `--device auto`：Metal 可用 → `gpu`，否则 `cpu`。
- `/health` 的 `device` 始终返回**实际**推理设备：`"gpu"` 或 `"cpu"`（不再有 `"mlx"`/`"mps"`）。
- **CPU 模式极慢**：实测 warmup「你好。」约 244s，后续合成更慢。因此 `--device cpu` 时
  sidecar **自动跳过 warmup**，模型加载完直接 `ready`；启动日志会打印 warning：
  「CPU 模式使用 MLX CPU 后端，极慢（短句可能数分钟），仅建议排障/无 Metal 环境使用；已自动跳过预热合成」。
  注意：跳过 warmup 只保证启动就绪快，**首次 `/tts` 仍需承担 kernel 编译 + CPU 推理的分钟级耗时**。

### 0.2 安装脚本

```bash
scripts/install_cosyvoice.sh [--home DIR] [--model-dir DIR] [--venv DIR] [--refs DIR] \
                             [--skip-model] [--skip-deps] [--dry-run] [--force]
```

安装内容（幂等）：

1. 创建/复用 Python ≥3.10 的 `<home>/venv-qwen3tts`（优先 `uv venv --python 3.10`）；
2. 安装 `mlx-audio==0.6.4` + `huggingface_hub` + `fastapi==0.115.6` / `uvicorn==0.30.0` /
   `pydantic==2.7.0`（**不装 torch、不 clone 仓库、不打补丁**）；
3. `huggingface_hub.snapshot_download("mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16")` 到模型目录；
4. 创建空 `voices/` + 空 `voices.json`（**不内置任何音色**，安装成功 ≠ 有音色）；
5. 写 marker `<home>/.installed-qwen3tts`。

- `--dry-run` 打印解析后的 `ENGINE=qwen3tts / LOCAL_DIR / VENV / MODEL_DIR / REFS / MARKER / SERVER_DIR / PY`
  以及即将执行的步骤（仍是逐行 `PROGRESS <0.00-1.00>`）。
- 已安装判定：marker 存在 + venv python 可执行 + 模型完整（`config.json` + 至少一个
  >1MB 的 `*.safetensors`）+ venv 可 `import mlx_audio, fastapi, uvicorn`；不满足则修复式安装。
- 不创建 `repo/`；不删除已有的 `voices/`、模型或 marker，除非用户显式删除安装。

退出码：

| code | 含义 |
|---|---|
| `0` | 正常退出（`--dry-run`、已安装、安装完成；服务收到 SIGTERM/SIGINT 优雅停止） |
| `2` | run 脚本前置检查失败（模型目录/文件不全、依赖缺失、音色目录缺失、端口被占 `EADDRINUSE`） |
| `3` | 脚本层错误（venv/python/server.py 缺失、参数非法） |
| `143` | 安装/服务被 SIGTERM/SIGINT 中断 |

---

## 1. `GET /health`

健康检查 + 就绪状态。App 启动时轮询本接口；已 `ready` 则复用进程，不要重启。

- `engine` 固定 `"qwen3tts"`；`device` 为实际推理设备 `"gpu"` / `"cpu"`；`model` 是模型目录名。
- 就绪 200、加载中 503、加载失败 500。

**就绪 200（GPU）**

```json
{
  "ok": true,
  "ready": true,
  "version": "2.0.0",
  "engine": "qwen3tts",
  "model": "Qwen3-TTS-12Hz-1.7B-Base-bf16",
  "model_dir": "/…/cosyvoice/models/Qwen3-TTS-12Hz-1.7B-Base-bf16",
  "sample_rate": 24000,
  "voices": ["custom-a"],
  "voices_detail": [
    {"id": "custom-a", "name": "我的音色", "description": "…", "mode": "zero_shot",
     "duration_s": 28.89, "reference_count": 2, "has_prompt_text": true,
     "personal_use_only": true, "builtin": false, "source": "app-import"}
  ],
  "device": "gpu",
  "state": "ready",
  "progress": "就绪",
  "load_seconds": 4.2,
  "memory_rss_mb": 4583.4,
  "stats": {"requests": 2, "errors": 0, "last_rtf": 0.777, "last_synth_ms": 2611}
}
```

**就绪 200（CPU）**（差异字段）

```json
{
  "engine": "qwen3tts",
  "device": "cpu",
  "state": "ready",
  "progress": "就绪",
  "load_seconds": 1.7
}
```

CPU 模式启动时已自动跳过预热合成，因此 `ready` 很快；实际合成耗时会很长（见 §6.2）。

**加载中 503**

```json
{"ok": false, "ready": false, "loading": true,
 "state": "loading", "progress": "加载模型权重 Qwen3-TTS-12Hz-1.7B-Base-bf16（bf16，约 5~20s）",
 "engine": "qwen3tts", "model": "Qwen3-TTS-12Hz-1.7B-Base-bf16", "sample_rate": 24000,
 "device": "gpu", "voices": ["custom-a"], "voices_detail": []}
```

**加载失败 500**

```json
{"ok": false, "ready": false, "state": "failed", "error": "model_load_failed",
 "detail": "RuntimeError: …", "engine": "qwen3tts",
 "model": "Qwen3-TTS-12Hz-1.7B-Base-bf16", "device": "gpu"}
```

App 建议：`loading` 时每 0.5–1s 轮询，上限 90s（CPU 模式跳过 warmup，通常秒级就绪）；
`failed` 时展示 `detail` 并提供「重试/查看日志」。

> v2.0.0 起 `/health` **不再包含** `hybrid` / `flow_steps` 字段（旧引擎专属）；App 解码时忽略即可。

---

## 2. `GET /voices`

返回可用音色（即使模型仍在加载也可用，音色由磁盘配置决定）。

> **分发边界**：App 安装包**不内置任何音色**。普通用户安装后 `voices/` 为空，
> `GET /voices` 返回 `"voices": []`；音色由用户在 App 音色管理中添加（写入
> `prompt.wav` + `voices.json` 后调 `POST /voices/reload`）。

```json
{
  "ok": true,
  "voices": [
    {"id": "custom-a", "name": "我的音色", "description": "本机导入的参考音",
     "mode": "zero_shot", "duration_s": 12.0, "reference_count": 2,
     "has_prompt_text": true, "personal_use_only": true, "builtin": false,
     "source": "local-upload"}
  ]
}
```

- `mode`：`zero_shot`（带参考文本）或 `cross_lingual`（无参考文本）。Qwen3 的 `mode` 只作展示；
  合成时实际看 `prompt_text` 是否为空：有文本走 ICL，无文本走 x-vector fallback（见 §3）。
- `reference_count`：该音色保存的参考音频条数（1–5）。**仅元数据**：服务端合成始终只用合并后的
  `prompt.wav`，不会在运行时拼接多条参考音（合并由 App 保存音色时完成，见 §2.2 / §5）。
  旧 `voices.json` 缺少 `references` 时按 1 条补齐；`references` 里无效片段会被跳过，
  全部无效时也按 1 条计。
- 排序：预置音色（girl/loli/onee，如存在）在前，自定义音色按名称/ID 追加。
- `personal_use_only`：内部元数据（默认 `true`）。服务只提供本机合成，**不提供网络导出/打包接口**。
- `builtin`：预置音色为 `true`；用户新增（`custom-*` 等）为 `false`。
- 字段均向后兼容：旧 `voices.json` 缺少这些键时按「`personal_use_only=true`、`builtin` 按 id 判定、
  `source=""`、`reference_count=1`」补齐。

## 2.1 `POST /voices/reload`

新增/删除/修改自定义音色后，让服务重读音色清单，**不重载大模型**。

- Qwen3 不缓存 prompt 特征（每次 `/tts` 现算参考音），reload 只更新清单：
  `added` / `reused` 恒为 `0`，`removed` 语义相同；耗时通常 <100ms。
- 请求：无（`Content-Type` 可为空；带空 JSON `{}` 也接受）
- 成功 200：

```json
{
  "ok": true,
  "voices": ["custom-a"],
  "voices_detail": [
    {"id": "custom-a", "name": "我的音色", "personal_use_only": true, "builtin": false,
     "mode": "zero_shot", "duration_s": 12.9, "reference_count": 2,
     "has_prompt_text": true, "source": "local-upload"}
  ],
  "added": 0,
  "reused": 0,
  "removed": [],
  "reload_ms": 12.3
}
```

- `added` / `reused` 为兼容旧响应保留，Qwen3 恒 0；`removed` 是从清单消失的 id；
  `reload_ms` 是总耗时。
- 与 `/tts` 共用同一把锁：reload 期间的合成请求会排队，不会出现「清单与合成错位」。
- 错误：

| HTTP | `error` | 说明 |
|---|---|---|
| 503 | `not_ready` | 模型仍在加载（`detail` 为当前进度） |
| 500 | `reload_failed` | `voices.json` 解析失败；`detail` 是可读原因 |

```bash
# 新增自定义音色后（把 prompt.wav + voices.json 条目写好）触发热重载
curl -s -X POST http://127.0.0.1:5051/voices/reload | jq
```

> 注意：`/voices/reload` 对 `voices.json` 的解析是**严格模式**（坏 JSON 直接 500 `reload_failed`，
> 不会静默降级为目录扫描）；启动加载时仍宽松（坏清单会回退目录扫描，保证服务能起来）。

## 2.2 多条参考音频（v2 元数据）

一个音色可保存 **1–5 条**参考音频（每条 ≥1 秒、24 kHz 单声道 16-bit；App 会按 30 秒总预算
自动截取长音频，合并总时长 ≤ 30 秒）。
**合成方式不变**：App 在保存音色时把各条参考音频按顺序拼接为一条 `prompt.wav`（片段间插入
0.25 秒静音），各条文本按顺序用换行 `\n` 连接写入 `prompt.txt`；服务端 `/tts` 始终只读这一条
合并 prompt，**不做运行时的多条音频拼接**。

- `/voices`、`/health.voices_detail`、`/voices/reload` 返回的 `reference_count` 即参考音频条数，
  数据来自 `voices.json` 的 `references` 数组（v2 布局；原始片段在 `<id>/refs/`，见 §5）。
- Qwen3 没有旧引擎的 30s tokenizer 硬限制，但 App 仍统一按 ≤30 秒保存。
- Qwen3 的 ICL 克隆需要 `ref_audio` + 逐字对应的 `ref_text`；`prompt.wav` 缺参考文本时只能走
  speaker-encoder（x-vector）fallback（能出声、相似度下降，服务端记 warning）。建议音色都填写参考文本。
- 兼容：旧条目没有 `references` → 1 条（音频 `prompt_wav`，文本 `prompt_text`/`prompt.txt`）。
- 容错：`references` 中路径缺失/越出 voices 目录/文件不存在的片段会被跳过并记 warning；
  全部无效或 `references` 不是数组时回退为 1 条。
- `references` 存在但 `prompt_wav` 缺失的条目会被**跳过**（记 warning），避免服务用错误的
  单片段 prompt 合成；补齐 `prompt.wav` 后 `POST /voices/reload` 即可。

---

## 3. `POST /tts`

请求体（`Content-Type: application/json`）：

```json
{"text": "今天天气不错，我们出去走走吧。", "voice_id": "custom-a", "speed": 1.0}
```

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `text` | string | 是 | 1–500 字（按 Unicode 字符计；前后空白会被 trim） |
| `voice_id` | string | 是 | 音色 id，必须在 `/voices` 列表里 |
| `speed` | number | 否 | **兼容字段，Qwen3 忽略**（0.5–2.0 校验后按 1.0 处理，记 debug 日志） |
| `instruct` | string | 否 | **兼容字段，Qwen3 忽略**（≤200 字校验后忽略，记 warning） |

合成方式：以 `voices.json` 里该音色的 `prompt.wav` 作为 `ref_audio`：

- 有参考文本 → ICL（`ref_audio` + `ref_text`，相似度最好）；
- 无参考文本 → 只传 `ref_audio`，上游静默走 x-vector fallback（正常出声、相似度下降），
  服务端记 warning 并正常返回 200，**不会因此报错**；
- `split_pattern=None`、`stream=False`：一次性生成；仅 fallback 路径可能按换行拆段，
  服务端会把多段按顺序拼接并在段间插 100ms 静音。

**成功 200**

- `Content-Type: audio/wav`
- 正文：RIFF/WAVE，**24000 Hz、单声道、16-bit PCM**
- 响应头（保留 `X-CosyVoice-*` 前缀，App 兼容）：

| Header | 示例 | 含义 |
|---|---|---|
| `X-CosyVoice-Version` | `2.0.0` | 服务版本 |
| `X-CosyVoice-Engine` | `qwen3tts` | 实际引擎（固定） |
| `X-CosyVoice-Voice` | `custom-a` | 实际音色 |
| `X-CosyVoice-Sample-Rate` | `24000` | 采样率 |
| `X-CosyVoice-Duration-Ms` | `3840` | 音频时长 |
| `X-CosyVoice-Synth-Ms` | `2917` | 纯合成耗时 |
| `X-CosyVoice-RTF` | `0.76` | 实时率（`合成耗时 / 音频时长`，越小越快） |
| `X-CosyVoice-Device` | `gpu` / `cpu` | 实际推理设备 |

**错误**：JSON，HTTP 4xx/5xx，统一含 `ok: false`、`error`（机器码）、`detail`（可读原因）。

```json
{"ok": false, "error": "unknown_voice", "detail": "未知音色 xx，可选：custom-a, custom-b"}
```

| HTTP | `error` | 触发条件 |
|---|---|---|
| 400 | `invalid_request` | 请求体不是合法 JSON / 字段类型不对 / 缺 `voice_id` |
| 400 | `empty_text` | `text` 为空 |
| 400 | `text_too_long` | `text` 超过 500 字 |
| 400 | `no_voices` | 服务当前零音色（普通用户安装后尚未添加音色） |
| 400 | `unknown_voice` | `voice_id` 不在 `/voices` 列表 |
| 400 | `invalid_speed` | `speed` 非数字或越界（兼容字段，校验后忽略） |
| 400 | `instruct_too_long` | `instruct` 超过 200 字（兼容字段，校验后忽略） |
| 503 | `not_ready` | 模型仍在加载（`detail` 为当前进度） |
| 500 | `model_load_failed` | 模型加载失败（仅 `/health`） |
| 500 | `synthesis_failed` | 合成过程异常（`detail` 为异常摘要） |
| 500 | `internal_error` | 未预期异常 |

示例：

```bash
# 健康检查（device 为 gpu/cpu）
curl -s http://127.0.0.1:5051/health | jq '{engine,device,model,ready}'

# 音色列表
curl -s http://127.0.0.1:5051/voices | jq

# 合成（保存 24k WAV）
curl -s -X POST http://127.0.0.1:5051/tts \
  -H 'Content-Type: application/json' \
  -d '{"text":"今天天气不错，我们出去走走吧。","voice_id":"custom-a"}' \
  -o custom-a.wav -D -

# 错误示例
curl -s -X POST http://127.0.0.1:5051/tts \
  -H 'Content-Type: application/json' -d '{"text":"","voice_id":"custom-a"}'
# {"ok":false,"error":"empty_text","detail":"text 不能为空"}
```

---

## 4. 行为约定

- **零音色可启动**：普通用户安装后没有音色，服务仍会 `ready`（`/health` 200、`/voices` 空），
  此时 `/tts` 返回 400 `no_voices`。用户添加音色后 `POST /voices/reload` 即可，无需重启服务。
- **串行合成**：服务端用全局锁排队，同一时刻只合成一条。App 不应并发大量 `/tts`。
- **不记录正文**：日志只记录 `text_len`、音色、设备、耗时、RTF；请求 body 不落日志。
- **无 prompt 缓存**：每次 `/tts` 由 MLX 现算参考音特征（reload 只换清单）。
- **多条参考音**：服务端只在元数据里统计 `reference_count`，不拼接、不读取 `refs/` 音频；
  合成始终只用 App 合并好的 `prompt.wav` + `prompt.txt`（见 §2.2 / §5）。
- **预热**：GPU 模式启动就绪前会合成一句「你好。」（kernel 编译，实测约 1–2s，冷机更久），
  之后首包更稳定。**CPU 模式自动跳过预热**（见 §0.1）；`--no-warmup` 可显式关闭预热。
  预热失败只记 warning，不会让 GPU 引擎进入 `failed`；零音色跳过预热。
- **文本分句**：Qwen3 用 `split_pattern=None` 一次性生成；仅 fallback 路径可能按换行拆段。
- **进程生命周期**：只监听回环地址；SIGTERM/SIGINT 后 uvicorn 优雅退出（最多等 5s）。

---

## 5. 安装目录与音色文件布局（v2：合并 prompt + 原始片段）

home：源码运行是 `_local/cosyvoice`，打包 App 是
`~/Library/Application Support/WeChatAI/cosyvoice`，可用 `--home` / `COSYVOICE_HOME` 覆盖。

```
<home>/
  venv-qwen3tts/                 # 唯一 venv（mlx-audio + fastapi/uvicorn；不装 torch）
  voices/                        # 音色目录（见 §5.1）
  models/
    Qwen3-TTS-12Hz-1.7B-Base-bf16/   # config.json + *.safetensors + speech_tokenizer/…
  logs/
  .installed-qwen3tts            # 安装标记
```

- 不再创建 `repo/`，不再有 `<home>/venv` / `.installed`（旧 CosyVoice3 残留不影响新服务运行，
  App 可提供「清理旧文件」入口；删除只动这些旧文件，保留 `voices/` 与 Qwen 文件）。
- 安装命令：

```bash
scripts/install_cosyvoice.sh                        # 默认 home + 默认路径
scripts/install_cosyvoice.sh --home <home>          # App 生产路径
scripts/install_cosyvoice.sh --home <home> --dry-run   # 只打印路径/步骤
```

### 5.1 音色文件布局

```
<home>/voices/
  voices.json                  # 音色清单（缺失时服务会扫描子目录；普通用户安装后为 {"voices": []}）
  <custom-id>/
    prompt.wav                 # 【合成用】App 合并出的单条 prompt：24k mono 16-bit
    prompt.txt                 # 【合成用】合并参考文本：各条按顺序 \n 连接；可为空
    refs/ref-1.wav             # 第 1 条原始参考音频（24k mono 16-bit，≥1s；长音频 App 自动截取）
    refs/ref-1.txt             # 第 1 条原始参考文本（逐字对应；可为空文件）
    refs/ref-2.wav
    refs/ref-2.txt
    meta.json                  # 可选：App 维护的音色元数据（references 等）
```

- `prompt.wav` / `prompt.txt` 是**服务端合成的事实来源**；`refs/` 不参与合成，只用于 App 编辑、导出、
  回放与 `reference_count` 统计。
- 旧版布局（只有 `prompt.wav` + `prompt.txt`、没有 `refs/`）继续支持，视为 1 条。
- **普通安装不生成音色**：安装脚本只创建空 `voices/` + 空 `voices.json`，安装成功
  （`.installed-qwen3tts`）≠ 有音色；音色由用户在 App 内导入。

`voices.json`：

```json
{
  "version": 2,
  "voices": [
    {
      "id": "custom-a",
      "name": "我的音色",
      "description": "…",
      "mode": "zero_shot",
      "prompt_wav": "custom-a/prompt.wav",
      "prompt_text": "第一条文本\n第二条文本",
      "references": [
        {"audio": "custom-a/refs/ref-1.wav", "text": "第一条文本", "duration": 6.0},
        {"audio": "custom-a/refs/ref-2.wav", "text": "第二条文本", "duration": 7.0}
      ],
      "duration": 13.25,
      "personal_use_only": true,
      "builtin": false,
      "source": "app-import"
    }
  ]
}
```

- `references[].audio` 在 `voices.json` 里**相对 voices 目录**（也支持绝对路径）；也接受
  `audio_path` / `prompt_wav` 键。解析后必须存在且位于 voices 目录内，否则跳过该片段。
  `meta.json` 里的 `references[].audio` 则**相对音色目录**（如 `refs/ref-1.wav`）。
- `prompt_wav` 必填：服务端只按它合成。`references` 存在但 `prompt_wav` 缺失/不存在时该音色被跳过。
- `duration`：合并总时长（含 0.25s×（条数-1）静音）；`prompt_text` = 合并文本（`\n` 连接）。
- 旧条目没有 `references` 时视为 1 条：音频 = `prompt_wav`，文本 = `prompt_text` / `prompt.txt`。
- 手工新增单个参考音：建 `voices/<id>/prompt.wav`（≥1s、≥16k、单声道）+ `prompt.txt`，
  在 `voices.json` 追加条目（`id`/`name`/`prompt_wav` 必填），然后 `POST /voices/reload`。
  **不要重启服务。**
- **本机存储**：音色、`refs/` 与参考音仅存本机 `voices/`（gitignored），服务不提供网络导出/打包接口。

### 5.2 恢复备份

1. 把 App 导出的音色 zip 解压回 `<home>/voices/`（保持 `<id>/` 目录名）；
2. 必须**同时**恢复 `prompt.wav` + `prompt.txt`（合成用）与 `refs/`（多条参考音的原始片段）；
   只恢复 `refs/` 无法合成。旧备份只含 `prompt.wav` / `prompt.txt` 也能直接使用（= 1 条参考音）。
3. 若 `voices.json` 被覆盖，重启服务或调用 `POST /voices/reload`。

---

## 6. 实测性能

环境：Apple Silicon / macOS 26 / `mlx-audio 0.6.4` / `mlx 0.32.4` /
`venv-qwen3tts`（Python 3.10）/ 真实模型 + 真实音色（28.89s 合并 prompt，2 条 references）。

### 6.1 GPU（MLX Metal，默认）

| 项目 | 实测值 |
|---|---|
| 启动到 `/health` ready | **4.2s**（含 import + 权重加载 1.8s + 预热合成；系统页缓存热时） |
| 预热合成「你好。」 | 约 1–2s（首次含 Metal kernel 编译；冷机更久，Lead 另测约 0.9s） |
| `/tts` 15 字 → 3.84s 音频 | synth **2.92s**，RTF **0.76**，端到端 2.94s |
| `/tts` 15 字（第二次）→ 3.36s 音频 | synth **2.61s**，RTF **0.777**，端到端 2.64s |
| `/tts` 23 字 → 4.78s 音频（Lead 实测） | RTF **0.54** |
| 进程 RSS（就绪后） | 约 **4.6GB**（`ru_maxrss`）；MLX peak / macOS footprint 另测 9–10GB / ≈16GB |

- RTF 口径：`duration = samples / sample_rate`，`rtf = processing_time_seconds / duration`。
  **不要用** `GenerationResult.real_time_factor`（`audio_time / processing_time`，越大越快，
  语义与常规 RTF 相反），也不要用 `audio_duration`（字符串）/`audio_samples`。

### 6.2 CPU（MLX CPU）

| 项目 | 实测值 |
|---|---|
| 启动到 `/health` ready | **1.7s**（加载完直接 ready；**自动跳过预热**，否则 App 90s 轮询会超时） |
| warmup「你好。」（不跳过时，Lead 实测） | **约 244s** |
| `/tts`「你好」2 字 → 1.04s 音频（首次，本次实测） | synth **644.06s**，RTF **619.3**，端到端 **644.2s**（≈10m44s） |
| 同机并发负载 | 本次 CPU 测量期间系统 load average ≈4，数值偏悲观；但量级明确：单句分钟到十分钟级 |

- **不建议日常使用 CPU**：单句合成需要数分钟到十分钟级，且长时间占满一个核；仅用于无 Metal 环境排障。
- App 侧合成超时（约 180s）在 CPU 模式下会先触发 → 本条语音回复改发文字，这是预期行为（不会卡住 UI）。
- CPU 首次合成还包含 kernel 编译（本次 644s 含首句编译）；后续句子仍为分钟级，不要指望「第二次就快」。
- 冷启动（系统页缓存冷）会更慢；`load_seconds` 只统计模型加载，不含首次合成。

---

## 7. 兼容性与迁移备注

- 目前是 **HTTP/1.1 非流式**：整段合成完再返回 WAV。若以后需要首包更低，可加
  `stream=1` 分块 WAV/PCM 接口（未实现，App 不要依赖）。
- `X-CosyVoice-*` 响应头前缀是历史命名，v2.0.0 继续保留（App 兼容）；`X-CosyVoice-Engine`
  固定 `qwen3tts`，`X-CosyVoice-Device` 为 `gpu` / `cpu`。
- `speed` / `instruct` 当前不支持：`/tts` 仍接受并做范围校验，服务端忽略并记日志；App 不应再提供
  语速/风格 UI。
- 参考文本为**可选但建议填写**：缺失时上游静默走 x-vector fallback，正常出声、相似度下降
  （服务端 warning），不会返回 400。
- **旧版残留**：v1.x 的 `cosyvoice3` 引擎已删除；`--engine` 传入会报未知参数。若本机仍有旧版
  sidecar 在跑，`/health.engine` 会是 `"cosyvoice3"`，新 App 应拒绝复用并提示先停掉旧服务。
- 服务与 App 解耦：App 只需 `GET /health` 判活（`engine`/`device`/`model` 可展示），不需要知道模型细节。
