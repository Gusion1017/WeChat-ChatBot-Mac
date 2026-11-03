# Qwen3-TTS-1.7B 本地 TTS（devtools）

Qwen3-TTS-1.7B（Apple MLX，`Qwen3-TTS-12Hz-1.7B-Base-bf16`）的本地推理运行时与 HTTP sidecar，
也是 App 唯一的语音模型。**仓库不提供任何音色或参考音频**，用户需在 App 的
「语音 → 语音引擎与音色 → 管理音色…」中导入自己的参考音（建议 3–15 秒、逐字对应文本）。

> 2026-11-04 起 CosyVoice3 已移除；目录名 `devtools/cosyvoice/` 与脚本名
> `install_cosyvoice.sh` / `run_cosyvoice.sh` 为历史兼容保留。

```
devtools/cosyvoice/
  server.py           # FastAPI/uvicorn 服务：预加载模型，/health /voices /voices/reload /tts（24k WAV）
                      # 零音色可启动（ready + /voices 空 + /tts 400 no_voices）
  CONTRACT.md         # HTTP 契约 v2.0.0（App 对接以此为准）
  test_server.py      # 单测（标准库 unittest，无真实 mlx/fastapi 依赖）
  README.md           # 本文件
```

安装与启动在仓库级脚本：

```bash
scripts/install_cosyvoice.sh                 # 安装 venv-qwen3tts + mlx-audio + 模型（约 4.7GB）
scripts/run_cosyvoice.sh                     # 前台 spawn（App 用；零音色也能启动）
scripts/run_cosyvoice.sh --device cpu        # 强制 MLX CPU（极慢，仅排障；自动跳过 warmup）
scripts/run_cosyvoice.sh --device auto       # Metal 可用则 GPU，否则 CPU
scripts/run_cosyvoice.sh --wait-health       # 启动并等 /health 就绪（人类/CI）
scripts/run_cosyvoice.sh --require-voices    # 零音色直接报错退出（默认只警告并继续）
```

**分发边界**：App 安装包**不内置音色**，也不包含参考音频、`prompt.txt`、`refs/` 或 `voices.json`。
普通用户安装后 `voices/` 为空、服务零音色启动（`/voices` 空、`/tts` 400 `no_voices`），
在 App 音色管理添加后 `POST /voices/reload` 即可生效。

## 运行时事实（Apple Silicon / macOS 26 / mlx-audio 0.6.4）

| 项目 | 值 |
|---|---|
| 模型 | `Qwen3-TTS-12Hz-1.7B-Base-bf16`，约 4.2GB（3.6GB 权重 + 0.65GB tokenizer） |
| venv | `venv-qwen3tts`（独立于旧 CosyVoice3 vendored venv），mlx-audio 0.6.4 + fastapi/uvicorn |
| 输出 | 24kHz mono 16-bit PCM WAV |
| 推理设备 | `--device gpu`（默认，MLX Metal）/ `cpu`（MLX CPU，极慢）/ `auto` |
| 常驻内存 | MLX peak 约 9–10GB；macOS footprint 约 16GB |
| 速度 | GPU：热态 RTF≈0.54–0.78；CPU：实测 1 秒音频约 644s（RTF≈619），不建议日常使用 |

冷启动 GPU 约 17s（文件缓存热时 1–4s），首次合成有约 9s Metal 预热；
`--device cpu` 自动跳过 warmup（否则 90s 启动轮询会超时），加载完直接 ready。
CPU 端口实现在 `server.py` 的 `configure_mlx_device()`（加载模型前设置 MLX 默认设备）。
`/health` 的 `device` 返回实际 `gpu`/`cpu`；`/tts` 的 `X-CosyVoice-Device` 同义。

## 相关文档

- HTTP 契约与错误码：[`CONTRACT.md`](CONTRACT.md)
- App 集成、安装/音色/性能：[`../../docs/cosyvoice.md`](../../docs/cosyvoice.md)
- 旧版 CosyVoice3 文件清理：App「机器人 → 语音」检测到残留时提供「清理旧版语音文件」入口。
