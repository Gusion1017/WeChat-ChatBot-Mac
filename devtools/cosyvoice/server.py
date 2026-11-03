#!/usr/bin/env python3
"""本地旁路 TTS 服务（FastAPI + uvicorn）：Qwen3-TTS-1.7B（Apple MLX）单引擎。

模型
----
* **qwen3tts**：`Qwen3-TTS-12Hz-1.7B-Base-bf16`（Apple MLX，依赖 `mlx-audio`），
  ICL 零样本克隆，需要音色参考文本（缺失时走 x-vector fallback，仍能出声但相似度下降）。
* 推理设备：`--device gpu|cpu|auto`（env `COSYVOICE_DEVICE`），默认 `gpu`。
  - `gpu`：MLX Metal（`mx.set_default_device(mx.gpu)`）；
  - `cpu`：MLX CPU（`mx.set_default_device(mx.cpu)`）；
  - `auto`：`mx.metal.is_available()` 为真 → gpu，否则 cpu。
  默认设备在**加载模型之前**设置（mlx-audio 的权重加载与 generate 都走默认设备）。

设计要点
--------
* **预加载**：进程启动后先用后台线程加载模型，`GET /health` 在加载期间返回 503
  `{"ok": false, "loading": true}`，就绪后返回 200。App 启动时轮询该接口即可。
* **常驻内存**：模型只加载一次；每次请求由 MLX 现算参考音特征，无需 prompt 缓存。
* **串行合成**：单机上并发合成没有收益，用一把全局锁排队，避免内存峰值。
* **输出**：24k mono 16-bit PCM WAV（RIFF），可直接被 AVAudioPlayer / AVAudioFile 读取。
* **日志**：只记录文本长度、音色、设备、耗时、RTF，**不记录请求正文**。
* **speed/instruct**：Qwen3-TTS 不支持，`/tts` 仍接受这两个字段（兼容旧 App），
  服务端忽略并记日志。

用法
----
    # --venv 仅用于日志/自检提示
    python server.py --host 127.0.0.1 --port 5051 \
        --model-dir ../../_local/cosyvoice/models/Qwen3-TTS-12Hz-1.7B-Base-bf16 \
        --refs ../../_local/cosyvoice/voices \
        --venv ../../_local/cosyvoice/venv-qwen3tts \
        --device gpu

对外接口见同目录 CONTRACT.md。
"""

import argparse
import importlib
import io
import json
import logging
import os
import socket
import sys
import threading
import time
import wave
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

VERSION = "2.0.0"  # 2.0.0：移除旧引擎，Qwen3-TTS 单引擎 + GPU/CPU 设备选择
MAX_TEXT_CHARS = 500
MAX_INSTRUCT_CHARS = 200
MIN_SPEED = 0.5
MAX_SPEED = 2.0
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 5051

# --------------------------------------------------------------------------- #
# 引擎 / 模型 / 设备
# --------------------------------------------------------------------------- #
ENGINE = "qwen3tts"
ENGINE_LABEL = "Qwen3-TTS-1.7B"
QWEN3_MODEL_NAME = "Qwen3-TTS-12Hz-1.7B-Base-bf16"
VENV_DIR_NAME = "venv-qwen3tts"
MLX_AUDIO_MODULE = "mlx_audio"
# 前置检查要求 venv 里可导入的模块（sidecar 自身依赖 + MLX 推理栈）
REQUIRED_MODULES = ("mlx_audio", "fastapi", "uvicorn")
MLX_AUDIO_INSTALL_HINT = ("请先运行 scripts/install_cosyvoice.sh 安装 Qwen3-TTS 运行环境"
                          "（venv-qwen3tts + mlx-audio + fastapi/uvicorn）")

DEVICE_CHOICES = ("gpu", "cpu", "auto")
DEFAULT_DEVICE = "gpu"
DEVICE_LABELS = {"gpu": "GPU（MLX Metal）", "cpu": "CPU（MLX）", "auto": "自动（Metal 可用则 GPU）"}
# auto：`mx.metal.is_available()` 为真 → gpu，否则 cpu；显式 gpu 但 Metal 不可用时回退 cpu。
GPU_CPU_CHOICES = ("gpu", "cpu")

# 参考文本缺失时 Qwen3 会静默走 speaker-encoder（x-vector）fallback，音色相似度下降。
QWEN3_MISSING_REF_TEXT_WARNING = "该音色无参考文本，Qwen3 走 x-vector fallback，克隆相似度会下降"
# 多段结果拼接时插入的静音（秒）
QWEN3_SEGMENT_GAP_S = 0.1

# 内置音色 id；其余（custom-* / 用户新增）builtin=false
BUILTIN_VOICE_IDS = ("girl", "loli", "onee")
# v2 音色布局：`<id>/prompt.wav` 是 App 合并出的合成用 prompt，原始参考片段在 `<id>/refs/` 下。
# 服务端不做运行时音频拼接，只在元数据里统计 reference_count，合成仍然只读 prompt.wav。
REFERENCE_DIR_NAME = "refs"
# references 条目里可接受的音频路径键（`audio`/`audio_path` 二选一，兼容旧写法 `prompt_wav`）
REFERENCE_AUDIO_KEYS = ("audio", "audio_path", "prompt_wav")

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_LOCAL_DIR = REPO_ROOT / "_local" / "cosyvoice"
DEFAULT_MODEL_DIR = DEFAULT_LOCAL_DIR / "models" / QWEN3_MODEL_NAME
DEFAULT_VOICES_DIR = DEFAULT_LOCAL_DIR / "voices"
DEFAULT_VENV = DEFAULT_LOCAL_DIR / VENV_DIR_NAME

log = logging.getLogger("cosyvoice.server")


# --------------------------------------------------------------------------- #
# 基础工具
# --------------------------------------------------------------------------- #
def _env(name: str, default: str) -> str:
    value = os.environ.get(name, "").strip()
    return value or default


def setup_logging(level: str) -> None:
    fmt = "%(asctime)s %(levelname)s %(name)s %(message)s"
    logging.basicConfig(level=getattr(logging, level.upper(), logging.INFO),
                        format=fmt, datefmt="%H:%M:%S", stream=sys.stderr)
    # sidecar 自身只记 text_len/音色/设备/耗时/RTF，不记请求正文。
    logging.getLogger("uvicorn.error").setLevel(logging.INFO)


def memory_rss_mb() -> Optional[float]:
    """当前进程 RSS（MB）。macOS 上 ru_maxrss 单位是字节，Linux 是 KB。"""
    try:
        import resource
        value = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        return round(value / (1024 * 1024), 1) if sys.platform == "darwin" else round(value / 1024, 1)
    except Exception:  # pragma: no cover
        return None


def check_port(host: str, port: int) -> Optional[str]:
    """端口是否可绑定；返回错误信息或 None。"""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind((host, port))
        return None
    except OSError as exc:
        return f"EADDRINUSE {host}:{port} 无法绑定：{exc}"
    finally:
        sock.close()


def read_wav_info(path: Path) -> Tuple[float, int, int]:
    """返回 (时长秒, 采样率, 声道)；读不出来返回 (0,0,0)。"""
    try:
        with wave.open(str(path), "rb") as wav:
            frames, rate = wav.getnframes(), wav.getframerate()
            return (frames / rate if rate else 0.0, rate, wav.getnchannels())
    except Exception:
        return (0.0, 0, 0)


def wav_bytes(samples_int16_bytes: bytes, sample_rate: int) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        wav.writeframes(samples_int16_bytes)
    return buf.getvalue()


# --------------------------------------------------------------------------- #
# MLX 推理设备
# --------------------------------------------------------------------------- #
def resolve_device(requested: str, metal_available: bool) -> str:
    """把 `--device` 解析为实际设备（`gpu` / `cpu`）。

    * `cpu`  → `cpu`
    * `gpu`  → Metal 可用则 `gpu`，不可用回退 `cpu`（调用方负责记 warning）
    * `auto` → Metal 可用则 `gpu`，否则 `cpu`

    非法值抛 ValueError（CLI 由 argparse choices 拦截，env 值由 parse_args 兜底）。
    """
    if requested == "cpu":
        return "cpu"
    if requested == "gpu":
        return "gpu" if metal_available else "cpu"
    if requested == "auto":
        return "gpu" if metal_available else "cpu"
    raise ValueError(f"未知推理设备：{requested}（可选：{' | '.join(DEVICE_CHOICES)}）")


def configure_mlx_device(requested: str, mx_module: Any = None) -> str:
    """在加载模型前设置 MLX 默认设备；返回实际设备（`gpu` / `cpu`）。

    * `gpu`：`mx.set_default_device(mx.gpu)`；
    * `cpu`：`mx.set_default_device(mx.cpu)`；
    * `auto`：`mx.metal.is_available()` 为真 → gpu，否则 cpu。

    必须在 `load_model()` 之前调用：mlx-audio 的权重加载与 generate 都使用默认设备。
    `mx_module` 仅用于单测注入（默认 `import mlx.core as mx`）。
    """
    mx = mx_module if mx_module is not None else importlib.import_module("mlx.core")
    metal_available = False
    try:
        metal_available = bool(mx.metal.is_available())
    except Exception as exc:  # noqa: BLE001 - 老版本 mlx / 受限环境按不可用处理
        log.warning("无法检测 MLX Metal 可用性（按不可用处理）：%s", exc)
    resolved = resolve_device(requested, metal_available)
    if requested == "gpu" and resolved != "gpu":
        log.warning("--device gpu 但当前 MLX Metal 不可用，回退 CPU 推理（会明显变慢）")
    mx.set_default_device(mx.gpu if resolved == "gpu" else mx.cpu)
    log.info("MLX 推理设备：%s（--device %s，Metal %s）",
             resolved, requested, "可用" if metal_available else "不可用")
    return resolved


# --------------------------------------------------------------------------- #
# 音色
# --------------------------------------------------------------------------- #
@dataclass
class Voice:
    id: str
    name: str
    description: str
    prompt_wav: Path
    prompt_text: str = ""
    mode: str = "zero_shot"  # zero_shot | cross_lingual
    duration_s: float = 0.0
    sample_rate: int = 0
    channels: int = 0
    cached: bool = False
    # 个人使用标记：用户上传/合成的音色仅供本人使用，服务不提供导出/分发能力。缺省 true。
    personal_use_only: bool = True
    # 内置音色（girl/loli/onee）为 true；custom-* 为 false
    builtin: bool = True
    # 可选来源说明（用户原创/授权自某个 TTS 声线等），仅供元数据展示
    source: str = ""
    # v2：该音色保存的参考音频条数（旧音色/无 references = 1）。仅元数据展示：
    # 合成仍只用合并后的 prompt_wav，服务端不做多条参考音的运行时拼接。
    reference_count: int = 1

    def to_public(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "name": self.name,
            "description": self.description,
            "mode": self.mode,
            "duration_s": round(self.duration_s, 2),
            # 参考音频条数（v2 元数据；旧音色/无 references = 1）。合成仍只用 prompt_wav。
            "reference_count": max(1, int(self.reference_count or 1)),
            "has_prompt_text": bool(self.prompt_text.strip()),
            # 个人使用 / 来源标记（App 只读展示，服务不提供导出/分发）
            "personal_use_only": bool(self.personal_use_only),
            "builtin": bool(self.builtin),
            "source": self.source,
        }


def _resolve_manifest_path(raw: Any, base_dir: Path) -> Optional[Path]:
    """解析清单里的路径：支持绝对路径与相对 base_dir；空值/非法值返回 None。"""
    if raw is None:
        return None
    value = str(raw).strip()
    if not value:
        return None
    try:
        path = Path(value)
        if not path.is_absolute():
            path = base_dir / path
        return path.resolve()
    except (OSError, RuntimeError, ValueError):
        return None


def _is_relative_to(path: Path, directory: Path) -> bool:
    """path 是否位于 directory 之内（两者的 resolve 结果）。"""
    try:
        path.relative_to(directory)
        return True
    except ValueError:
        return False


def _reference_audio_path(ref: Any, voices_root: Path, voice_id: str, index: int) -> Optional[Path]:
    """取一条 references 条目的有效音频路径；无效（缺失/越界/不存在）返回 None。"""
    if not isinstance(ref, dict):
        log.warning("音色 %s 的第 %d 条参考音频不是对象（跳过）", voice_id, index)
        return None
    raw = next((ref[key] for key in REFERENCE_AUDIO_KEYS if ref.get(key)), None)
    if raw is None:
        log.warning("音色 %s 的第 %d 条参考音频缺少路径（audio/audio_path，跳过）", voice_id, index)
        return None
    path = _resolve_manifest_path(raw, voices_root)
    if path is None:
        log.warning("音色 %s 的第 %d 条参考音频路径无效：%r（跳过）", voice_id, index, raw)
        return None
    if not _is_relative_to(path, voices_root):
        log.warning("音色 %s 的第 %d 条参考音频不在 voices 目录内：%s（跳过）", voice_id, index, path)
        return None
    if not path.is_file():
        log.warning("音色 %s 的第 %d 条参考音频不存在：%s（跳过）", voice_id, index, path)
        return None
    return path


def _manifest_reference_count(refs: Any, voices_root: Path, voice_id: str) -> int:
    """voices.json 条目的参考音频条数：无 references / 全部无效时按 1 条。"""
    if refs is None:
        return 1
    if not isinstance(refs, list):
        log.warning("音色 %s 的 references 不是数组（按 1 条参考音处理）", voice_id)
        return 1
    valid = 0
    for index, ref in enumerate(refs, 1):
        if _reference_audio_path(ref, voices_root, voice_id, index) is not None:
            valid += 1
    if valid == 0:
        if refs:
            log.warning("音色 %s 的 references 没有有效参考音频（回退为 1 条）", voice_id)
        return 1
    return valid


def _scan_reference_count(voice_dir: Path, voices_root: Path) -> int:
    """目录扫描兜底：统计 `<id>/refs/ref-*.wav`（文件需存在且仍在 voices 目录内）。"""
    refs_dir = voice_dir / REFERENCE_DIR_NAME
    if not refs_dir.is_dir():
        return 0
    count = 0
    for child in sorted(refs_dir.iterdir()):
        if not child.name.startswith("ref-") or child.suffix.lower() != ".wav":
            continue
        try:
            resolved = child.resolve()
        except (OSError, RuntimeError):
            continue
        if not child.is_file() or not _is_relative_to(resolved, voices_root):
            continue
        count += 1
    return count


def _voice_from_manifest_entry(item: Any, voices_root: Path) -> Optional[Voice]:
    """把一条 voices.json 条目转成 Voice；不可用时记录 warning 并返回 None。"""
    if not isinstance(item, dict):
        log.warning("voices.json 里有非对象条目（跳过）：%r", item)
        return None
    voice_id = str(item.get("id") or "").strip()
    if not voice_id:
        log.warning("voices.json 里有缺少 id 的条目（跳过）")
        return None
    has_references = isinstance(item.get("references"), list) and bool(item["references"])
    wav = _resolve_manifest_path(item.get("prompt_wav"), voices_root)
    if wav is None or not wav.is_file():
        if has_references:
            # 有 references 但合成用的合并 prompt 缺失：宁可跳过，也不要拿错误的单片段 prompt 合成。
            log.warning("音色 %s 有 references 但合并 prompt.wav 缺失：%s（跳过该音色）",
                        voice_id, item.get("prompt_wav") or "<未填写>")
        else:
            log.warning("音色 %s 的参考音不存在：%s（跳过）", voice_id,
                        item.get("prompt_wav") or "<未填写>")
        return None
    duration, rate, channels = read_wav_info(wav)
    return Voice(
        id=voice_id,
        name=str(item.get("name") or voice_id),
        description=str(item.get("description") or ""),
        prompt_wav=wav,
        prompt_text=str(item.get("prompt_text") or ""),
        mode=str(item.get("mode") or ("zero_shot" if item.get("prompt_text") else "cross_lingual")),
        duration_s=duration,
        sample_rate=rate,
        channels=channels,
        # 缺省：personal_use_only=true；builtin 仅 girl/loli/onee
        personal_use_only=bool(item.get("personal_use_only", True)),
        builtin=bool(item.get("builtin", voice_id in BUILTIN_VOICE_IDS)),
        source=str(item.get("source") or ""),
        reference_count=_manifest_reference_count(item.get("references"), voices_root, voice_id),
    )


def load_voices(voices_dir: Path, strict_manifest: bool = False) -> List[Voice]:
    """读取音色。

    优先 `voices.json`（安装脚本/App 生成，字段见 CONTRACT.md），否则扫描子目录：
    每个子目录里必须有 `prompt.wav`；`prompt.txt` 存在则作为参考文本。

    多条参考音频（v2 布局 `<id>/refs/ref-*.wav`）只影响元数据：`Voice.reference_count`
    用于 `/voices` 展示；服务端**不做运行时音频拼接**，合成仍只用合并后的 `prompt.wav`。
    旧条目没有 `references` 时按 1 条处理。

    `strict_manifest=True`（/voices/reload 用）时，manifest 解析失败直接抛错，
    避免把「清单写坏了」静默降级成目录扫描（音色名/描述会丢）；启动加载仍宽松，
    保证服务能起来。
    """
    voices: List[Voice] = []
    voices_root = voices_dir.resolve()
    manifest = voices_root / "voices.json"
    if manifest.is_file():
        try:
            data = json.loads(manifest.read_text(encoding="utf-8"))
            entries = data.get("voices", data) if isinstance(data, dict) else data
            if not isinstance(entries, list):
                raise ValueError("voices.json 顶层应为数组，或包含 voices 数组的对象")
            for item in entries:
                voice = _voice_from_manifest_entry(item, voices_root)
                if voice is not None:
                    voices.append(voice)
            log.info("从 voices.json 载入 %d 个音色", len(voices))
            return voices
        except Exception as exc:  # noqa: BLE001 - 解析失败按既有策略回退/抛错
            if strict_manifest:
                raise EngineError(f"解析 {manifest} 失败：{exc}") from exc
            log.error("解析 %s 失败（回退到目录扫描）：%s", manifest, exc)

    if not voices_root.is_dir():
        return voices
    for child in sorted(voices_root.iterdir()):
        if not child.is_dir() or child.name.startswith("."):
            continue
        wav = child / "prompt.wav"
        if not wav.is_file():
            continue
        text = ""
        text_file = child / "prompt.txt"
        if text_file.is_file():
            try:
                text = text_file.read_text(encoding="utf-8").strip()
            except OSError as exc:
                log.warning("读取 %s 失败：%s（按无参考文本处理）", text_file, exc)
        duration, rate, channels = read_wav_info(wav)
        voices.append(Voice(
            id=child.name,
            name=child.name,
            description="",
            prompt_wav=wav,
            prompt_text=text,
            mode="zero_shot" if text else "cross_lingual",
            duration_s=duration,
            sample_rate=rate,
            channels=channels,
            personal_use_only=True,
            builtin=child.name in BUILTIN_VOICE_IDS,
            # 目录扫描兜底：refs/ref-*.wav 存在时按实际条数计，否则旧音色 = 1 条
            reference_count=max(1, _scan_reference_count(child, voices_root)),
        ))
    order = {"girl": 0, "loli": 1, "onee": 2}
    voices.sort(key=lambda v: (order.get(v.id, 99), v.id))
    log.info("扫描目录载入 %d 个音色：%s", len(voices), ", ".join(v.id for v in voices))
    return voices


# --------------------------------------------------------------------------- #
# 引擎（Qwen3-TTS / MLX）
# --------------------------------------------------------------------------- #
class EngineError(Exception):
    pass


def resolve_load_model(mlx_audio_module: Any = None) -> Any:
    """取 mlx_audio 的 load_model。

    官方路径是 `mlx_audio.tts.utils.load_model`；旧版本/测试注入的简化模块可能只在
    `mlx_audio.load_model`，这里做两级兜底。
    """
    try:
        from mlx_audio.tts.utils import load_model as load_model_fn
        return load_model_fn
    except Exception:  # noqa: BLE001 - 兼容旧版本与注入的简化模块
        module = mlx_audio_module
        if module is None:
            import mlx_audio as module  # type: ignore[no-redef]
        load_model_fn = getattr(module, "load_model", None)
        if load_model_fn is None:
            raise EngineError(f"{MLX_AUDIO_MODULE} 里找不到 load_model（请升级 mlx-audio）")
        return load_model_fn


def to_float32_array(audio: Any) -> Any:
    """把 mlx array / 样本数组转成一维 float32 numpy（延迟 import numpy）。

    实测 `np.array(r.audio)` 即可（mlx array 支持 __array__），不要用
    `GenerationResult.audio_duration`（字符串）或 `audio_samples`。
    """
    import numpy as np
    try:
        return np.array(audio, dtype=np.float32).reshape(-1)
    except Exception:  # noqa: BLE001 - 极少数 mlx 版本不支持 __array__，退回 tolist()
        return np.array(audio.tolist(), dtype=np.float32).reshape(-1)


class Qwen3Engine:
    """Qwen3-TTS-12Hz-1.7B-Base（MLX / mlx-audio）ICL 零样本克隆。

    实测（本机 / mlx-audio 0.6.4 / mlx 0.32.4 / Python 3.10 venv，GPU）：
    冷加载 17.2s、热加载 1.7–2.2s；热态 RTF ≈ 0.60（23 字/4.7s 音频）、0.51（40 字/7.3s）；
    首次合成含 Metal kernel 编译（4.7s 音频 ≈ 8.8s）；MLX peak 内存 9.25–10.02GB，
    macOS footprint ≈ 16GB。模型下载约 3.6GB。

    行为：
    * 延迟 `import mlx_audio`，只依赖 Apple MLX；
    * 默认设备由 `configure_mlx_device()` 在启动时（load_model 之前）设置；
    * `generate()` 用 `ref_audio` + 参考文本走 ICL；无参考文本时只传 `ref_audio`
      （上游静默走 x-vector fallback，仍能出声但克隆相似度下降，记 warning）；
    * 不支持 `speed`（忽略并记 debug）与 `instruct`（忽略并记 warning）；
    * 不需要 prompt 特征缓存，`_prime_voices` 只更新 voice_map（reload 仍返回 added/reused/removed）。
    """

    ENGINE = ENGINE
    LOADER_THREAD_NAME = "qwen3tts-loader"
    PRIME_PROGRESS = "准备音色清单（Qwen3 无需 prompt 特征缓存）"

    def __init__(self, model_dir: Path, voices: List[Voice], device: str = DEFAULT_DEVICE,
                 warmup: bool = True, voices_dir: Optional[Path] = None):
        if device not in GPU_CPU_CHOICES:
            raise ValueError(f"Qwen3Engine 的 device 必须是 {'/'.join(GPU_CPU_CHOICES)}，"
                             f"收到：{device}（auto 需先经 configure_mlx_device 解析）")
        self.model_dir = model_dir
        self.voices = voices
        self.voice_map = {v.id: v for v in voices}
        self.voices_dir = voices_dir
        self.device = device
        self.warmup = warmup
        self.state = "starting"          # starting | loading | warming | ready | failed
        self.progress = "等待加载"
        self.error: Optional[str] = None
        self.model = None
        self.sample_rate = 24000
        self.load_s: Optional[float] = None
        self.loaded_at: Optional[float] = None
        self.lock = threading.Lock()
        self.stats = {"requests": 0, "errors": 0, "last_rtf": None, "last_synth_ms": None}
        self._mlx_audio = None

    # -- 加载 ---------------------------------------------------------------
    def start_loading(self) -> None:
        thread = threading.Thread(target=self.load, name=self.LOADER_THREAD_NAME, daemon=True)
        thread.start()

    def load(self) -> None:
        started = time.perf_counter()
        try:
            self.state = "loading"
            self._load_backend()
            if not self.voices:
                # 零音色也允许启动：普通用户安装后 App 内还没有音色，服务仍需 ready
                # 以便 App 在音色管理里写入 prompt.wav 后调用 POST /voices/reload。
                log.warning("当前没有任何音色（%s），服务将以零音色启动；"
                            "请在 App 音色管理中添加后调用 POST /voices/reload", self._voice_dir_hint())
            self._load_model()
            log.info("模型加载完成：device=%s，sample_rate=%d，耗时 %.1fs",
                     self.device, self.sample_rate, time.perf_counter() - started)
            self.progress = self.PRIME_PROGRESS
            self._prime_voices()
            if self.warmup and self.device == "cpu":
                # 实测（Apple Silicon / MLX CPU）：warmup「你好。」约 244s，App 90s 启动轮询会超时。
                # CPU 模式强制跳过预热：加载完直接 ready，首次 /tts 由请求方超时兜底。
                log.warning("CPU 模式已自动跳过预热合成（warmup 仅对 GPU 执行；"
                            "CPU 合成单句可能需要数分钟）")
            elif self.warmup:
                self.state = "warming"
                self.progress = "预热合成"
                self._warmup()
            self.load_s = time.perf_counter() - started
            self.loaded_at = time.time()
            self.state = "ready"
            self.progress = "就绪"
            log.info("引擎就绪：device=%s，音色=%s，加载 %.1fs，RSS %.0fMB",
                     self.device, list(self.voice_map), self.load_s, memory_rss_mb() or 0)
        except Exception as exc:  # noqa: BLE001 - 需要把失败原因透出给 /health
            self.state = "failed"
            self.error = f"{type(exc).__name__}: {exc}"
            self.progress = "加载失败"
            log.exception("模型加载失败")

    def _voice_dir_hint(self) -> str:
        return "请先运行 scripts/install_cosyvoice.sh 或检查 --refs 目录里的 voices.json/prompt.wav"

    def _load_backend(self) -> None:
        self.progress = "导入 mlx-audio（延迟 import，约 5~10s）"
        import mlx_audio
        self._mlx_audio = mlx_audio

    def _load_model(self) -> None:
        self.progress = f"加载模型权重 {self.model_dir.name}（bf16，约 5~20s）"
        load_model_fn = resolve_load_model(self._mlx_audio)
        self.model = load_model_fn(str(self.model_dir))
        self.sample_rate = int(getattr(self.model, "sample_rate", 0) or 24000)

    def _prime_voices(self, voices: Optional[List[Voice]] = None,
                      force: bool = False) -> Tuple[int, int]:
        """Qwen3 每次请求现算参考音特征，不需要 prompt 缓存，只保留清单。"""
        target = list(self.voices if voices is None else voices)
        for voice in target:
            voice.cached = False
        return 0, 0

    def reload_voices(self) -> Dict[str, Any]:
        """重读 --refs/voices.json，重建音色表；不重载大模型。

        与 /tts 共用 self.lock：reload 期间不会有合成并发（避免 voice_map 与缓存错位）。
        """
        if self.state != "ready" or self.model is None:
            raise EngineError("model_not_ready")
        if self.voices_dir is None:
            raise EngineError("voices_dir 未配置，无法重载音色清单")
        started = time.perf_counter()
        new_voices = load_voices(self.voices_dir, strict_manifest=True)  # 读盘不持锁
        # 空清单是合法状态（用户删除了最后一个音色）；解析失败才会在上一行抛错
        with self.lock:
            added, reused = self._prime_voices(new_voices)
            old_ids = {v.id for v in self.voices}
            self.voices = new_voices
            self.voice_map = {v.id: v for v in new_voices}
            elapsed_ms = round((time.perf_counter() - started) * 1000, 1)
        new_ids = {v.id for v in new_voices}
        result = {
            "voices": [v.id for v in new_voices],
            "voices_detail": [v.to_public() for v in new_voices],
            "added": added,
            "reused": reused,
            "removed": sorted(old_ids - new_ids),
            "reload_ms": elapsed_ms,
        }
        log.info("音色清单已重载：%d 个（新提取 %d / 复用缓存 %d / 移除 %d），耗时 %.0fms",
                 len(new_voices), added, reused, len(old_ids - new_ids), elapsed_ms)
        return result

    def _warmup(self) -> None:
        """Qwen3 首次合成会触发 Metal/CPU kernel 编译。

        有音色时用第一个音色预热「你好。」；零音色跳过。预热失败只 warning，
        不让引擎进入 failed（App 仍能看到 /health 200、/voices 可用）。
        """
        if not self.voices:
            log.info("零音色，跳过 Qwen3 预热合成")
            return
        try:
            self._synth("你好。", self.voices[0], 1.0, None, warmup=True)
            log.info("预热完成（device=%s，首次含 kernel 编译）", self.device)
        except Exception as exc:  # noqa: BLE001 - 预热失败不影响启动，首次请求会重试
            log.warning("Qwen3 预热合成失败（不影响启动，首次合成会重试）：%s", exc)

    # -- 合成 ---------------------------------------------------------------
    def _iter_generation_results(self, result: Any) -> List[Any]:
        """mlx_audio 的 generate 返回生成器；兼容直接返回单个结果对象的实现。

        注意：不要依赖 `is_final_chunk`（mlx-audio 0.6.4 有整除边界 bug），
        以迭代结束为准；本服务 `stream=False`，一次拿完整结果。
        """
        if result is None:
            return []
        if hasattr(result, "audio"):
            return [result]
        return list(result)

    def _collect_audio(self, result: Any) -> Tuple[List[Any], int, float]:
        """返回 (float32 段列表, 采样率, 上游 processing_time_seconds 之和)。

        采样率用 `GenerationResult.sample_rate`（实测 24000），时长由 `samples/sample_rate`
        计算；耗时优先用上游 `processing_time_seconds`（多段求和），缺失时由调用方用墙钟兜底。
        """
        segments: List[Any] = []
        rate = 0
        processing_s = 0.0
        for item in self._iter_generation_results(result):
            audio = getattr(item, "audio", None)
            if audio is None:
                continue
            samples = to_float32_array(audio)
            if samples.size == 0:
                continue
            item_rate = int(getattr(item, "sample_rate", 0) or 0)
            if rate <= 0 and item_rate > 0:
                rate = item_rate
            elif item_rate > 0 and rate > 0 and item_rate != rate:
                log.warning("Qwen3 返回的多段采样率不一致（%d vs %d），按首段处理", rate, item_rate)
            item_processing = float(getattr(item, "processing_time_seconds", 0) or 0)
            if item_processing > 0:
                processing_s += item_processing
            segments.append(samples)
        if rate <= 0:
            rate = int(self.sample_rate or 24000)
        return segments, rate, processing_s

    def _synth(self, text: str, voice: Voice, speed: float, instruct: Optional[str],
               warmup: bool = False) -> Tuple[bytes, int, float]:
        """返回 (int16 PCM bytes, 实际采样率, 耗时秒)。

        耗时优先用上游 `GenerationResult.processing_time_seconds`（多段求和，缺失时用墙钟兜底），
        上层用它算 `rtf = elapsed / duration`（duration = samples / sample_rate）；
        **不要**用 GenerationResult.real_time_factor（它是 audio_time/processing_time，
        越大越快，语义与常规 RTF 相反）。
        """
        import numpy as np
        if speed != 1.0:
            log.debug("Qwen3-TTS 不支持语速倍率，忽略 speed=%.2f", speed)
        if instruct:
            log.warning("Qwen3-TTS 不支持 instruct，已忽略（%d 字）", len(instruct))
        ref_text = voice.prompt_text.strip()
        kwargs: Dict[str, Any] = {
            "text": text,
            "ref_audio": str(voice.prompt_wav),
            "lang_code": "auto",
            # ICL 路径本身忽略 split_pattern；统一传 None，避免 fallback 路径按换行拆段。
            "split_pattern": None,
            "stream": False,
        }
        if ref_text:
            # 有参考文本走 ICL（相似度最好）：ref_audio + ref_text 必须同时传。
            kwargs["ref_text"] = ref_text
        else:
            # 只传 ref_audio 时上游静默走 speaker-encoder（x-vector）fallback，仍能出声但相似度下降。
            log.warning(QWEN3_MISSING_REF_TEXT_WARNING + "（voice=%s）", voice.id)

        started = time.perf_counter()
        result = self.model.generate(**kwargs)
        segments, rate, processing_s = self._collect_audio(result)
        # RTF = processing_time / duration（duration = samples / sample_rate）；
        # 上游未给出 processing_time_seconds 时用本次墙钟时间兜底。
        elapsed = processing_s if processing_s > 0 else (time.perf_counter() - started)
        if not segments:
            raise EngineError("模型没有返回任何音频")
        if len(segments) == 1:
            audio = segments[0]
        else:
            # 多段（fallback 路径可能按换行拆段）按顺序拼接，段间插 100ms 静音
            gap = np.zeros(int(round(rate * QWEN3_SEGMENT_GAP_S)), dtype=np.float32)
            parts: List[Any] = []
            for index, segment in enumerate(segments):
                if index:
                    parts.append(gap)
                parts.append(segment)
            audio = np.concatenate(parts)
        np.clip(audio, -0.999, 0.999, out=audio)
        pcm = (audio * 32767.0).round().astype(np.int16).tobytes()
        if not pcm:
            raise EngineError("合成结果为空")
        return pcm, rate, elapsed

    # -- 对外 ---------------------------------------------------------------
    def synthesize(self, text: str, voice_id: str, speed: float,
                   instruct: Optional[str]) -> Tuple[bytes, int, Dict[str, Any]]:
        if self.state != "ready" or self.model is None:
            raise EngineError("model_not_ready")
        voice = self.voice_map.get(voice_id)
        if voice is None:
            raise EngineError("unknown_voice")
        try:
            with self.lock:
                pcm, rate, elapsed = self._synth(text, voice, speed, instruct)
                duration_s = len(pcm) / 2 / rate
                self.stats["requests"] += 1
                self.stats["last_rtf"] = round(elapsed / duration_s, 3) if duration_s else None
                self.stats["last_synth_ms"] = round(elapsed * 1000)
                info = {"duration_s": round(duration_s, 3), "synth_ms": round(elapsed * 1000),
                        "rtf": self.stats["last_rtf"], "device": self.device,
                        "sample_rate": rate}
                return pcm, rate, info
        except Exception as exc:  # noqa: BLE001
            self.stats["errors"] += 1
            raise EngineError(str(exc) or "synthesis_failed") from exc

    def health_payload(self) -> Tuple[int, Dict[str, Any]]:
        base: Dict[str, Any] = {
            "ok": self.state == "ready",
            "ready": self.state == "ready",
            "version": VERSION,
            "engine": self.ENGINE,
            "model": self.model_dir.name or QWEN3_MODEL_NAME,
            "model_dir": str(self.model_dir),
            "sample_rate": self.sample_rate,
            "voices": [v.id for v in self.voices],
            "voices_detail": [v.to_public() for v in self.voices],
            "device": self.device,
            "state": self.state,
            "progress": self.progress,
            "load_seconds": round(self.load_s, 2) if self.load_s else None,
            "memory_rss_mb": memory_rss_mb(),
            "stats": dict(self.stats),
        }
        if self.state == "ready":
            return 200, base
        if self.state == "failed":
            base.update({"error": "model_load_failed", "detail": self.error or "unknown"})
            return 500, base
        base.update({"loading": True, "detail": self.progress})
        return 503, base


# --------------------------------------------------------------------------- #
# HTTP 层
# --------------------------------------------------------------------------- #
def map_tts_error(exc: EngineError, voice_id: str, progress: str) -> Tuple[int, str, str]:
    """把引擎错误映射成 (HTTP status, error code, detail)，HTTP 层与单测共用。"""
    code = str(exc)
    if code == "model_not_ready":
        return 503, "not_ready", progress
    if code == "unknown_voice":
        return 400, "unknown_voice", voice_id
    return 500, "synthesis_failed", code[:500]


def tts_response_headers(engine_id: str, voice_id: str, rate: int,
                         info: Dict[str, Any]) -> Dict[str, str]:
    """`/tts` 成功响应头（便于调试/UI 展示；保留 `X-CosyVoice-*` 前缀与 App 兼容）。"""
    return {
        "X-CosyVoice-Version": VERSION,
        "X-CosyVoice-Engine": engine_id,
        "X-CosyVoice-Voice": voice_id,
        "X-CosyVoice-Sample-Rate": str(rate),
        "X-CosyVoice-Duration-Ms": str(round(info["duration_s"] * 1000)),
        "X-CosyVoice-Synth-Ms": str(info["synth_ms"]),
        "X-CosyVoice-RTF": str(info["rtf"]),
        "X-CosyVoice-Device": info["device"],
        "Cache-Control": "no-store",
    }


def build_app(engine: Qwen3Engine):
    from fastapi import FastAPI, Request
    from fastapi.exceptions import RequestValidationError
    from fastapi.responses import JSONResponse, Response
    from pydantic import BaseModel, Field

    app = FastAPI(title=f"{ENGINE_LABEL} Sidecar", version=VERSION,
                  docs_url=None, redoc_url=None, openapi_url=None)

    class ApiError(Exception):
        def __init__(self, status: int, code: str, detail: str):
            self.status, self.code, self.detail = status, code, detail

    class TTSRequest(BaseModel):
        text: str = Field(..., description="待合成文本，1~500 字")
        voice_id: str = Field(..., description="voices.json 里的音色 id")
        speed: float = Field(1.0, description="兼容字段；Qwen3-TTS 忽略")
        instruct: Optional[str] = Field(None, description="兼容字段；Qwen3-TTS 忽略")

    @app.exception_handler(ApiError)
    async def _api_error_handler(_request: Request, exc: ApiError):
        return JSONResponse(status_code=exc.status,
                            content={"ok": False, "error": exc.code, "detail": exc.detail})

    @app.exception_handler(RequestValidationError)
    async def _validation_handler(_request: Request, exc: RequestValidationError):
        detail = "; ".join(f"{'.'.join(str(x) for x in e.get('loc', []))}: {e.get('msg')}"
                           for e in exc.errors())[:500]
        return JSONResponse(status_code=400,
                            content={"ok": False, "error": "invalid_request", "detail": detail})

    @app.exception_handler(Exception)
    async def _unhandled_handler(_request: Request, exc: Exception):
        log.exception("未处理异常")
        return JSONResponse(status_code=500,
                            content={"ok": False, "error": "internal_error", "detail": str(exc)[:500]})

    @app.get("/")
    def root():
        return {"name": f"{engine.ENGINE}-sidecar", "version": VERSION,
                "endpoints": ["/health", "/voices", "/tts"], "docs": "devtools/cosyvoice/CONTRACT.md"}

    @app.get("/health")
    def health():
        status, payload = engine.health_payload()
        return JSONResponse(status_code=status, content=payload)

    @app.get("/voices")
    def voices():
        return {"ok": True, "voices": [v.to_public() for v in engine.voices]}

    @app.post("/voices/reload")
    def reload_voices():
        """重读音色清单（新增/删除自定义音色后调用），不重载大模型。"""
        if engine.state != "ready":
            _, payload = engine.health_payload()
            raise ApiError(503, "not_ready", payload.get("detail") or engine.progress)
        try:
            result = engine.reload_voices()
        except EngineError as exc:
            if str(exc) == "model_not_ready":
                raise ApiError(503, "not_ready", engine.progress)
            log.error("重载音色失败：%s", exc)
            raise ApiError(500, "reload_failed", str(exc)[:500])
        except Exception as exc:  # noqa: BLE001
            log.exception("重载音色异常")
            raise ApiError(500, "reload_failed", str(exc)[:500])
        return {"ok": True, **result}

    @app.post("/tts")
    def tts(req: TTSRequest):
        text = (req.text or "").strip()
        if not text:
            raise ApiError(400, "empty_text", "text 不能为空")
        if len(text) > MAX_TEXT_CHARS:
            raise ApiError(400, "text_too_long",
                           f"text 长度 {len(text)} 超过上限 {MAX_TEXT_CHARS} 字")
        if not engine.voices:
            raise ApiError(400, "no_voices",
                           "尚未添加音色，请先在 App 音色管理中添加")
        voice_id = (req.voice_id or "").strip()
        if voice_id not in engine.voice_map:
            raise ApiError(400, "unknown_voice",
                           f"未知音色 {voice_id}，可选：{', '.join(engine.voice_map) or '（无音色）'}")
        try:
            speed = float(req.speed if req.speed is not None else 1.0)
        except (TypeError, ValueError):
            raise ApiError(400, "invalid_speed", "speed 必须是数字")
        if not (MIN_SPEED <= speed <= MAX_SPEED):
            raise ApiError(400, "invalid_speed", f"speed 需在 {MIN_SPEED}~{MAX_SPEED} 之间")
        instruct = (req.instruct or "").strip() or None
        if instruct and len(instruct) > MAX_INSTRUCT_CHARS:
            raise ApiError(400, "instruct_too_long",
                           f"instruct 长度 {len(instruct)} 超过上限 {MAX_INSTRUCT_CHARS} 字")

        if engine.state != "ready":
            _, payload = engine.health_payload()
            raise ApiError(503, "not_ready", payload.get("detail") or engine.progress)

        started = time.perf_counter()
        try:
            pcm, rate, info = engine.synthesize(text, voice_id, speed, instruct)
        except EngineError as exc:
            status, error, detail = map_tts_error(exc, voice_id, engine.progress)
            if status >= 500:
                log.error("合成失败 voice=%s text_len=%d: %s", voice_id, len(text), exc)
            raise ApiError(status, error, detail)

        data = wav_bytes(pcm, rate)
        total_ms = round((time.perf_counter() - started) * 1000)
        log.info("tts voice=%s text_len=%d speed=%.2f device=%s synth_ms=%d total_ms=%d rtf=%s audio_ms=%d",
                 voice_id, len(text), speed, info["device"], info["synth_ms"], total_ms, info["rtf"],
                 round(info["duration_s"] * 1000))
        headers = tts_response_headers(engine.ENGINE, voice_id, rate, info)
        return Response(content=data, media_type="audio/wav", headers=headers)

    return app


# --------------------------------------------------------------------------- #
# 入口
# --------------------------------------------------------------------------- #
def _voices_dir_problem(voices_dir: Path) -> Optional[str]:
    if not voices_dir.is_dir():
        return f"找不到音色目录：{voices_dir}（请先运行 scripts/install_cosyvoice.sh）"
    return None


def dependencies_problem(importer: Optional[Callable[[str], Any]] = None) -> Optional[str]:
    """检查 venv 可导入 mlx_audio / fastapi / uvicorn；返回可读错误或 None。

    `importer` 仅供单测注入（默认 importlib.import_module），不依赖真实 mlx。
    """
    import_module = importer or importlib.import_module
    for name in REQUIRED_MODULES:
        try:
            import_module(name)
        except Exception as exc:  # noqa: BLE001 - 把真实原因透出给启动日志
            return (f"无法导入 {name}（{type(exc).__name__}: {exc}）；"
                    f"{MLX_AUDIO_INSTALL_HINT}")
    return None


def preflight_problem(*, model_dir: Path, voices_dir: Path,
                      importer: Optional[Callable[[str], Any]] = None) -> Optional[str]:
    """启动前置检查：返回可读错误或 None。

    只检查：模型目录（config.json + 至少一个 *.safetensors）、venv 可导入
    mlx_audio/fastapi/uvicorn、音色目录。不再检查旧引擎的 repo / 依赖。
    `importer` 仅供单测注入（默认 importlib.import_module），不依赖真实 mlx。
    """
    if not model_dir.is_dir():
        return (f"找不到 Qwen3-TTS 模型目录：{model_dir}"
                "（请先运行 scripts/install_cosyvoice.sh）")
    if not (model_dir / "config.json").is_file():
        return (f"Qwen3-TTS 模型目录缺少 config.json：{model_dir}"
                "（模型可能没下完，请重跑安装脚本）")
    if not any(path.is_file() for path in model_dir.glob("*.safetensors")):
        return (f"Qwen3-TTS 模型目录里没有 *.safetensors：{model_dir}"
                "（模型可能没下完，请重跑安装脚本）")
    problem = dependencies_problem(importer)
    if problem:
        return problem
    return _voices_dir_problem(voices_dir)


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Qwen3-TTS-1.7B（Apple MLX）本地 TTS sidecar")
    ap.add_argument("--host", default=_env("COSYVOICE_HOST", DEFAULT_HOST))
    ap.add_argument("--port", type=int, default=int(_env("COSYVOICE_PORT", str(DEFAULT_PORT))))
    ap.add_argument("--model-dir", default=_env("COSYVOICE_MODEL_DIR", "") or str(DEFAULT_MODEL_DIR),
                    help=f"Qwen3-TTS 模型目录，默认 {DEFAULT_MODEL_DIR}")
    ap.add_argument("--refs", default=_env("COSYVOICE_REFS", str(DEFAULT_VOICES_DIR)),
                    help="音色目录（voices.json + 各音色 prompt.wav）")
    ap.add_argument("--venv", default=_env("COSYVOICE_VENV", str(DEFAULT_VENV)),
                    help="仅用于日志/自检展示")
    ap.add_argument("--device", default=_env("COSYVOICE_DEVICE", DEFAULT_DEVICE),
                    choices=list(DEVICE_CHOICES),
                    help=("推理设备，默认 gpu：gpu=MLX Metal；cpu=MLX CPU；"
                          "auto=Metal 可用则 GPU，否则 CPU"))
    ap.add_argument("--no-warmup", action="store_true", help="跳过首次预热合成")
    ap.add_argument("--log-level", default=_env("COSYVOICE_LOG_LEVEL", "info"),
                    choices=["debug", "info", "warning", "error"])
    ap.add_argument("--access-log", action="store_true", help="打开 uvicorn 访问日志（默认关闭）")
    ap.add_argument("--version", action="version", version=f"%(prog)s {VERSION}")
    args = ap.parse_args(argv)
    # argparse 不校验 default（env 注入值），这里兜底，避免非法设备值静默走到 resolve_device。
    if args.device not in DEVICE_CHOICES:
        ap.error(f"--device 必须是 {' | '.join(DEVICE_CHOICES)} 之一（收到 {args.device!r}）")
    return args


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)
    setup_logging(args.log_level)
    # tqdm 进度条会污染 App 采集的日志，统一关掉
    os.environ.setdefault("TQDM_DISABLE", "1")
    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

    model_dir = Path(args.model_dir).expanduser().resolve()
    voices_dir = Path(args.refs).expanduser().resolve()
    venv_dir = Path(args.venv).expanduser()

    log.info("qwen3tts sidecar v%s 启动（pid=%d）", VERSION, os.getpid())
    log.info("  model_dir = %s", model_dir)
    log.info("  voices_dir = %s", voices_dir)
    log.info("  venv      = %s", venv_dir)
    log.info("  device    = %s（%s）", args.device, DEVICE_LABELS.get(args.device, args.device))
    log.info("  listen    = http://%s:%d", args.host, args.port)

    # 前置自检：模型/依赖/音色目录，给出可读错误，避免 App 侧只看到 traceback
    problem = preflight_problem(model_dir=model_dir, voices_dir=voices_dir)
    if problem:
        log.error("%s", problem)
        return 2

    port_error = check_port(args.host, args.port)
    if port_error:
        log.error("%s（若已有服务在跑可直接复用；否则换 --port）", port_error)
        return 2

    try:
        voices = load_voices(voices_dir)
    except Exception as exc:  # noqa: BLE001
        log.error("读取音色失败：%s", exc)
        return 2
    for voice in voices:
        if voice.channels > 1:
            log.warning("音色 %s 参考音是 %d 声道，已按单声道处理", voice.id, voice.channels)
        if voice.sample_rate and voice.sample_rate < 16000:
            log.warning("音色 %s 参考音采样率 %d < 16000，Qwen3 会重采样，质量可能下降",
                        voice.id, voice.sample_rate)
        if not voice.prompt_text.strip():
            log.warning("音色 %s 缺少参考文本，合成将走 x-vector fallback（相似度下降）", voice.id)

    # 关键：必须在 load_model 之前设置 MLX 默认设备（gpu/cpu/auto → gpu/cpu）
    try:
        device = configure_mlx_device(args.device)
    except Exception as exc:  # noqa: BLE001
        log.error("配置 MLX 推理设备失败（--device %s）：%s", args.device, exc)
        return 2
    if device == "cpu":
        log.warning("CPU 模式使用 MLX CPU 后端，极慢（短句可能数分钟），"
                    "仅建议排障/无 Metal 环境使用；已自动跳过预热合成")

    engine = Qwen3Engine(model_dir=model_dir, voices=voices, device=device,
                         warmup=not args.no_warmup, voices_dir=voices_dir)
    app = build_app(engine)
    engine.start_loading()

    import uvicorn
    uvicorn.run(app, host=args.host, port=args.port, log_level=args.log_level,
                access_log=args.access_log, timeout_graceful_shutdown=5)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
