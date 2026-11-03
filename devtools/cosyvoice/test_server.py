#!/usr/bin/env python3
"""devtools/cosyvoice/server.py 的纯逻辑单测（标准库 unittest）。

Qwen3-TTS 单引擎 + GPU/CPU 设备选择（v2.0.0）。不依赖真实 mlx / 模型 / 网络：

* 音色元数据：用 `wave` + `struct` 生成 24 kHz 单声道 16-bit WAV，构造临时 voices 目录
  验证 v2「多条参考音频」元数据契约（服务端**不做运行时音频拼接**，合成只读 `prompt.wav`）。
* 设备：`--device` 解析/默认/非法值、`auto` → gpu/cpu（注入 fake `mx.metal.is_available`）、
  `configure_mlx_device` 调用 `mx.set_default_device(mx.gpu/mx.cpu)`（注入 fake `mlx.core`）。
* 引擎：用 `sys.modules` 注入 fake `mlx_audio`（含官方 `mlx_audio.tts.utils.load_model`
  路径）验证 Qwen3Engine 的加载、`generate()` 参数、多段拼接、int16 转换与缺参考文本 warning。
* 服务层：`/health` 的 `engine`/`device` 字段、`/tts` 响应头、`EngineError` → HTTP 错误映射、
  启动前置检查错误路径与 main() 返回码。
* 需要 numpy 的合成用例在缺少 numpy 时自动 skip（标准库单测仍可跑）。

运行：

    python3 devtools/cosyvoice/test_server.py
"""

import contextlib
import importlib.util
import io
import json
import logging
import os
import struct
import sys
import tempfile
import types
import unittest
import wave
from pathlib import Path
from unittest import mock

try:  # Qwen3 的 int16/拼接用例需要 numpy；缺失时相关用例 skip，其余用例不受影响。
    import numpy as np
    HAS_NUMPY = True
except Exception:  # pragma: no cover - 极简环境没有 numpy
    np = None
    HAS_NUMPY = False

SERVER_PATH = Path(__file__).resolve().with_name("server.py")
SAMPLE_RATE = 24_000


def _load_server():
    """按文件路径加载 server.py（避免依赖工作目录 / 包结构）。"""
    spec = importlib.util.spec_from_file_location("cosyvoice_server_under_test", SERVER_PATH)
    if spec is None or spec.loader is None:  # pragma: no cover - 文件缺失才会走到
        raise RuntimeError(f"无法加载 {SERVER_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


server = _load_server()
# 正常用例不关心预期的 warning（坏片段/坏条目本就会记日志），压到 ERROR 保持输出干净；
# 需要断言 warning 的用例用 assertLogs 临时把级别提高到 WARNING。
server.log.setLevel(logging.ERROR)


def write_wav(path: Path, seconds: float = 1.0, sample_rate: int = SAMPLE_RATE) -> None:
    """生成 24 kHz / 单声道 / 16-bit PCM 的静音 WAV（只用 wave + struct）。"""
    path.parent.mkdir(parents=True, exist_ok=True)
    frames = max(1, int(round(seconds * sample_rate)))
    payload = struct.pack("<h", 0) * frames
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        wav.writeframes(payload)


class VoiceFixtureTestCase(unittest.TestCase):
    """临时 voices 目录 + 构造工具。"""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="cosyvoice-server-test-")
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)
        self.voices = self.tmp / "voices"
        self.voices.mkdir()

    def make_voice_dir(self, voice_id: str, *, prompt_seconds: float = 1.0) -> Path:
        directory = self.voices / voice_id
        directory.mkdir(parents=True, exist_ok=True)
        write_wav(directory / "prompt.wav", seconds=prompt_seconds)
        return directory

    def make_refs(self, voice_dir: Path, count: int) -> None:
        for index in range(1, count + 1):
            write_wav(voice_dir / "refs" / f"ref-{index}.wav")
            (voice_dir / "refs" / f"ref-{index}.txt").write_text(
                f"第 {index} 条参考文本", encoding="utf-8"
            )

    def write_manifest(self, entries, *, version: int = 2) -> None:
        (self.voices / "voices.json").write_text(
            json.dumps({"version": version, "voices": entries}, ensure_ascii=False),
            encoding="utf-8",
        )

    def load(self, *, strict: bool = False):
        return server.load_voices(self.voices, strict_manifest=strict)


# --------------------------------------------------------------------------- #
# 音色元数据（与引擎无关，保留原有覆盖）
# --------------------------------------------------------------------------- #
class LegacyManifestTest(VoiceFixtureTestCase):
    """用例 1：旧 manifest（无 references）→ 1 条。"""

    def test_legacy_entry_without_references_is_one(self) -> None:
        voice_dir = self.make_voice_dir("girl")
        (voice_dir / "prompt.txt").write_text("旧的参考文本", encoding="utf-8")
        self.write_manifest([{
            "id": "girl",
            "name": "预置女声",
            "mode": "zero_shot",
            "prompt_wav": "girl/prompt.wav",
            "prompt_text": "旧的参考文本",
            "personal_use_only": True,
            "builtin": True,
        }])

        voices = self.load()

        self.assertEqual([voice.id for voice in voices], ["girl"])
        voice = voices[0]
        self.assertEqual(voice.reference_count, 1)
        self.assertEqual(voice.prompt_text, "旧的参考文本")
        self.assertEqual(voice.to_public()["reference_count"], 1)


class MultiReferenceManifestTest(VoiceFixtureTestCase):
    """用例 2：2 条 references → reference_count == 2，prompt_text 原样保留。"""

    def test_two_references_are_counted_and_prompt_text_kept(self) -> None:
        voice_dir = self.make_voice_dir("custom-a", prompt_seconds=13.25)
        self.make_refs(voice_dir, 2)
        self.write_manifest([{
            "id": "custom-a",
            "name": "我的音色",
            "description": "两条参考音频",
            "mode": "zero_shot",
            "prompt_wav": "custom-a/prompt.wav",
            "prompt_text": "第一条\n第二条",
            "references": [
                {"audio": "custom-a/refs/ref-1.wav", "text": "第一条", "duration": 6.0},
                {"audio": "custom-a/refs/ref-2.wav", "text": "第二条", "duration": 7.0},
            ],
            "duration": 13.25,
            "personal_use_only": True,
            "builtin": False,
            "source": "app-import",
        }])

        voices = self.load()

        self.assertEqual(len(voices), 1)
        voice = voices[0]
        self.assertEqual(voice.reference_count, 2)
        self.assertEqual(voice.prompt_text, "第一条\n第二条")
        self.assertAlmostEqual(voice.duration_s, 13.25, places=2)
        self.assertEqual(voice.mode, "zero_shot")
        public = voice.to_public()
        self.assertEqual(public["reference_count"], 2)
        self.assertFalse(public["builtin"])
        self.assertEqual(public["source"], "app-import")

    def test_absolute_path_and_audio_path_key_are_supported(self) -> None:
        voice_dir = self.make_voice_dir("custom-abs")
        self.make_refs(voice_dir, 2)
        absolute = str((voice_dir / "refs" / "ref-1.wav").resolve())
        self.write_manifest([{
            "id": "custom-abs",
            "prompt_wav": "custom-abs/prompt.wav",
            "prompt_text": "a\nb",
            "references": [
                {"audio": absolute, "text": "a"},  # 绝对路径（在 voices 目录内）
                {"audio_path": "custom-abs/refs/ref-2.wav", "text": "b"},
            ],
        }])

        voices = self.load()

        self.assertEqual(len(voices), 1)
        self.assertEqual(voices[0].reference_count, 2)


class InvalidReferenceTest(VoiceFixtureTestCase):
    """用例 3：坏片段跳过；全部无效时回退 1。"""

    def test_bad_reference_entries_are_skipped_valid_ones_still_counted(self) -> None:
        voice_dir = self.make_voice_dir("custom-b")
        self.make_refs(voice_dir, 2)
        outside = self.tmp / "outside.wav"
        write_wav(outside)
        self.write_manifest([{
            "id": "custom-b",
            "prompt_wav": "custom-b/prompt.wav",
            "prompt_text": "a\nb",
            "references": [
                {"audio": "custom-b/refs/ref-1.wav"},          # 有效
                {"audio_path": "custom-b/refs/ref-2.wav"},     # 有效（audio_path 键）
                {"audio": "../outside.wav"},                    # 相对路径逃逸
                {"audio": str(outside.resolve())},              # 绝对路径但越出 voices 目录
                {"audio": "custom-b/refs/ref-404.wav"},         # 文件不存在
                {"audio": ""},                                  # 空路径
                "not-an-object",                                # 非对象
                42,                                             # 非对象
            ],
        }])

        voices = self.load()

        self.assertEqual(len(voices), 1)
        self.assertEqual(voices[0].reference_count, 2)

    def test_all_invalid_references_fall_back_to_one(self) -> None:
        self.make_voice_dir("custom-c")
        self.write_manifest([{
            "id": "custom-c",
            "prompt_wav": "custom-c/prompt.wav",
            "prompt_text": "只有一条参考文本",
            "references": [{"audio": "custom-c/refs/missing.wav"}],
        }])

        self.assertEqual(self.load()[0].reference_count, 1)

    def test_empty_or_non_list_references_fall_back_to_one(self) -> None:
        self.make_voice_dir("custom-empty")
        base = {"id": "custom-empty", "prompt_wav": "custom-empty/prompt.wav", "prompt_text": "x"}

        self.write_manifest([dict(base, references=[])])
        self.assertEqual(self.load()[0].reference_count, 1)

        self.write_manifest([dict(base, references="custom-empty/refs/ref-1.wav")])
        self.assertEqual(self.load()[0].reference_count, 1)


class MissingPromptWavTest(VoiceFixtureTestCase):
    """用例 4：references 存在但 prompt_wav 缺失 → 跳过该音色（不拿单片段 prompt 合成）。"""

    def test_voice_with_references_but_no_prompt_wav_is_skipped(self) -> None:
        broken = self.voices / "custom-broken"
        broken.mkdir()
        self.make_refs(broken, 2)  # 有 refs/，但没有 prompt.wav
        self.make_voice_dir("girl")
        self.write_manifest([
            {
                "id": "custom-broken",
                "name": "坏音色",
                "prompt_wav": "custom-broken/prompt.wav",
                "prompt_text": "a\nb",
                "references": [
                    {"audio": "custom-broken/refs/ref-1.wav"},
                    {"audio": "custom-broken/refs/ref-2.wav"},
                ],
            },
            {"id": "girl", "name": "预置女声", "prompt_wav": "girl/prompt.wav"},
        ])

        with self.assertLogs(server.log, level="WARNING") as captured:
            voices = self.load()

        self.assertEqual([voice.id for voice in voices], ["girl"])
        self.assertTrue(any("跳过该音色" in line for line in captured.output))

    def test_missing_prompt_wav_key_is_skipped_even_in_strict_mode(self) -> None:
        broken = self.voices / "custom-keyless"
        broken.mkdir()
        self.make_refs(broken, 1)
        self.write_manifest([{
            "id": "custom-keyless",
            "references": [{"audio": "custom-keyless/refs/ref-1.wav"}],
        }])

        with self.assertLogs(server.log, level="WARNING"):
            voices = self.load(strict=True)

        self.assertEqual(voices, [])


class DirectoryScanTest(VoiceFixtureTestCase):
    """用例 5：manifest 缺失时目录扫描统计 refs/ref-*.wav；仍要求 prompt.wav 存在。"""

    def test_directory_scan_counts_refs_and_requires_prompt_wav(self) -> None:
        multi = self.make_voice_dir("custom-multi")
        self.make_refs(multi, 3)
        (multi / "refs" / "notes.txt").write_text("不是音频", encoding="utf-8")
        write_wav(multi / "refs" / "other.wav")  # 非 ref-* 命名不计

        legacy = self.make_voice_dir("custom-legacy")
        (legacy / "prompt.txt").write_text("旧参考文本", encoding="utf-8")

        half = self.voices / "custom-half"
        half.mkdir()
        self.make_refs(half, 2)  # 有 refs 但没有 prompt.wav → 不收录

        voices = self.load()

        by_id = {voice.id: voice for voice in voices}
        self.assertEqual(sorted(by_id), ["custom-legacy", "custom-multi"])
        self.assertEqual(by_id["custom-multi"].reference_count, 3)
        self.assertEqual(by_id["custom-legacy"].reference_count, 1)
        self.assertEqual(by_id["custom-legacy"].prompt_text, "旧参考文本")

    def test_voice_without_refs_dir_is_one(self) -> None:
        self.make_voice_dir("custom-single")
        self.assertEqual(self.load()[0].reference_count, 1)


class PublicPayloadTest(VoiceFixtureTestCase):
    """用例 6：to_public()（/voices、/health.voices_detail、/voices/reload 共用）含 reference_count。"""

    def test_to_public_always_exposes_reference_count(self) -> None:
        voice_dir = self.make_voice_dir("custom-x")
        explicit = server.Voice(
            id="custom-x",
            name="X",
            description="",
            prompt_wav=voice_dir / "prompt.wav",
            reference_count=3,
        )
        public = explicit.to_public()
        self.assertEqual(public["reference_count"], 3)
        self.assertIsInstance(public["reference_count"], int)

        default = server.Voice(
            id="legacy", name="L", description="", prompt_wav=voice_dir / "prompt.wav"
        )
        self.assertEqual(default.to_public()["reference_count"], 1)

    def test_loaded_voice_public_payload_contains_reference_count(self) -> None:
        voice_dir = self.make_voice_dir("custom-p")
        self.make_refs(voice_dir, 2)
        self.write_manifest([{
            "id": "custom-p",
            "prompt_wav": "custom-p/prompt.wav",
            "prompt_text": "a\nb",
            "references": [
                {"audio": "custom-p/refs/ref-1.wav"},
                {"audio": "custom-p/refs/ref-2.wav"},
            ],
        }])

        payload = self.load()[0].to_public()
        self.assertEqual(payload["reference_count"], 2)


# --------------------------------------------------------------------------- #
# 版本 / 引擎契约（v2.0.0：单引擎，旧引擎代码必须彻底删除）
# --------------------------------------------------------------------------- #
class ContractVersionTest(unittest.TestCase):
    def test_version_is_2_0_0(self) -> None:
        self.assertEqual(server.VERSION, "2.0.0")

    def test_single_engine_id_is_qwen3tts(self) -> None:
        self.assertEqual(server.ENGINE, "qwen3tts")

    def test_legacy_engine_classes_are_gone(self) -> None:
        self.assertFalse(hasattr(server, "EngineBase"))
        self.assertFalse(hasattr(server, "CosyVoice3Engine"))
        self.assertFalse(hasattr(server, "create_engine"))
        self.assertFalse(hasattr(server, "ENGINE_COSYVOICE3"))

    def test_server_source_has_no_legacy_engine_code(self) -> None:
        source = SERVER_PATH.read_text(encoding="utf-8")
        for forbidden in ("CosyVoice3Engine", "EngineBase", "cosyvoice3", "torch",
                          "flow_steps", "hybrid", "MPS"):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, source)

    def test_default_paths_are_qwen_only(self) -> None:
        self.assertTrue(str(server.DEFAULT_MODEL_DIR).endswith(server.QWEN3_MODEL_NAME))
        self.assertEqual(Path(server.DEFAULT_VENV).name, "venv-qwen3tts")
        self.assertEqual(server.DEVICE_CHOICES, ("gpu", "cpu", "auto"))
        self.assertEqual(server.DEFAULT_DEVICE, "gpu")


# --------------------------------------------------------------------------- #
# 环境隔离 + fake mlx / mlx_audio 注入
# --------------------------------------------------------------------------- #
# 本机/CI 可能导出 COSYVOICE_* 作为真实运行配置，解析类用例必须隔离掉。
COSYVOICE_ENV_KEYS = (
    "COSYVOICE_MODEL_DIR", "COSYVOICE_REFS", "COSYVOICE_VENV", "COSYVOICE_HOST",
    "COSYVOICE_PORT", "COSYVOICE_DEVICE", "COSYVOICE_LOG_LEVEL",
)


@contextlib.contextmanager
def clean_cosyvoice_env(**overrides):
    """隔离环境变量：删掉本机可能存在的 COSYVOICE_*，可选注入 overrides。"""
    with mock.patch.dict(os.environ, overrides, clear=False):
        for key in COSYVOICE_ENV_KEYS:
            if key not in overrides:
                os.environ.pop(key, None)
        yield


def install_fake_mlx_core(testcase: unittest.TestCase, metal_available: bool = True):
    """把 fake `mlx.core` 注入 sys.modules，记录 set_default_device 调用。

    返回 (mx_module, set_default_device_calls)。fake 的 `mx.metal.is_available()`
    可被用例通过参数控制（auto → gpu/cpu）。
    """
    mx = types.ModuleType("mlx.core")
    mx.cpu = types.SimpleNamespace(name="cpu")
    mx.gpu = types.SimpleNamespace(name="gpu")
    calls = []
    mx.set_default_device = calls.append
    mx.metal = types.SimpleNamespace(is_available=lambda: metal_available)
    mlx_pkg = types.ModuleType("mlx")
    mlx_pkg.core = mx
    previous = {"mlx": sys.modules.get("mlx"), "mlx.core": sys.modules.get("mlx.core")}
    sys.modules.update({"mlx": mlx_pkg, "mlx.core": mx})

    def restore():
        for name, old in previous.items():
            if old is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = old

    testcase.addCleanup(restore)
    return mx, calls


class FakeQwenModel:
    """模拟 mlx_audio 的 Model：`generate()` 返回结果迭代器。"""

    def __init__(self, results=None, sample_rate: int = SAMPLE_RATE):
        self.results = list(results or [])
        self.sample_rate = sample_rate
        self.generate_calls = []

    def generate(self, **kwargs):
        self.generate_calls.append(kwargs)
        return iter(self.results)


def fake_generation_result(samples, sample_rate: int = SAMPLE_RATE,
                           processing_time_seconds: float = None):
    """模拟 mlx_audio 的 GenerationResult（`.audio` / `.sample_rate` / `processing_time_seconds`）。"""
    return types.SimpleNamespace(audio=samples, sample_rate=sample_rate,
                                 processing_time_seconds=processing_time_seconds)


def install_fake_mlx_audio(testcase: unittest.TestCase, load_model_fn):
    """把 fake `mlx_audio` 注入 sys.modules（含官方 tts.utils 路径），用例结束自动清理。"""
    package = types.ModuleType("mlx_audio")
    tts_module = types.ModuleType("mlx_audio.tts")
    utils_module = types.ModuleType("mlx_audio.tts.utils")
    utils_module.load_model = load_model_fn
    package.load_model = load_model_fn
    package.tts = tts_module
    tts_module.utils = utils_module
    fake_modules = {
        "mlx_audio": package,
        "mlx_audio.tts": tts_module,
        "mlx_audio.tts.utils": utils_module,
    }
    previous = {name: sys.modules.get(name) for name in fake_modules}
    sys.modules.update(fake_modules)

    def restore():
        for name, old in previous.items():
            if old is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = old

    testcase.addCleanup(restore)
    return package


# --------------------------------------------------------------------------- #
# 设备：--device 解析 / auto / set_default_device
# --------------------------------------------------------------------------- #
class DeviceResolutionTest(unittest.TestCase):
    def test_resolve_device_matrix(self) -> None:
        self.assertEqual(server.resolve_device("cpu", True), "cpu")
        self.assertEqual(server.resolve_device("cpu", False), "cpu")
        self.assertEqual(server.resolve_device("gpu", True), "gpu")
        self.assertEqual(server.resolve_device("gpu", False), "cpu")   # 显式 gpu 不可用时回退
        self.assertEqual(server.resolve_device("auto", True), "gpu")
        self.assertEqual(server.resolve_device("auto", False), "cpu")

    def test_resolve_device_rejects_unknown_value(self) -> None:
        for bad in ("mlx", "metal", "", "GPU"):
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError):
                    server.resolve_device(bad, True)

    def test_configure_gpu_sets_mlx_gpu_default(self) -> None:
        mx, calls = install_fake_mlx_core(self, metal_available=True)
        self.assertEqual(server.configure_mlx_device("gpu"), "gpu")
        self.assertEqual(calls, [mx.gpu])

    def test_configure_cpu_sets_mlx_cpu_default(self) -> None:
        mx, calls = install_fake_mlx_core(self, metal_available=True)
        self.assertEqual(server.configure_mlx_device("cpu"), "cpu")
        self.assertEqual(calls, [mx.cpu])

    def test_configure_auto_uses_gpu_when_metal_available(self) -> None:
        mx, calls = install_fake_mlx_core(self, metal_available=True)
        self.assertEqual(server.configure_mlx_device("auto"), "gpu")
        self.assertEqual(calls, [mx.gpu])

    def test_configure_auto_uses_cpu_when_metal_unavailable(self) -> None:
        mx, calls = install_fake_mlx_core(self, metal_available=False)
        with self.assertLogs(server.log, level="INFO") as captured:
            resolved = server.configure_mlx_device("auto")
        self.assertEqual(resolved, "cpu")
        self.assertEqual(calls, [mx.cpu])
        self.assertTrue(any("Metal 不可用" in line for line in captured.output))

    def test_configure_gpu_falls_back_to_cpu_with_warning(self) -> None:
        mx, calls = install_fake_mlx_core(self, metal_available=False)
        with self.assertLogs(server.log, level="WARNING") as captured:
            self.assertEqual(server.configure_mlx_device("gpu"), "cpu")
        self.assertEqual(calls, [mx.cpu])
        self.assertTrue(any("回退 CPU" in line for line in captured.output))

    def test_configure_tolerates_missing_metal_probe(self) -> None:
        mx = types.ModuleType("mlx.core")
        mx.cpu = types.SimpleNamespace(name="cpu")
        mx.gpu = types.SimpleNamespace(name="gpu")
        calls = []
        mx.set_default_device = calls.append  # 没有 mx.metal
        self.assertEqual(server.configure_mlx_device("auto", mx_module=mx), "cpu")
        self.assertEqual(calls, [mx.cpu])


class DeviceArgParseTest(unittest.TestCase):
    def test_default_device_is_gpu(self) -> None:
        with clean_cosyvoice_env():
            args = server.parse_args([])
        self.assertEqual(args.device, "gpu")

    def test_device_from_env(self) -> None:
        with clean_cosyvoice_env(COSYVOICE_DEVICE="cpu"):
            self.assertEqual(server.parse_args([]).device, "cpu")
        with clean_cosyvoice_env(COSYVOICE_DEVICE="auto"):
            self.assertEqual(server.parse_args([]).device, "auto")

    def test_cli_device_overrides_env(self) -> None:
        with clean_cosyvoice_env(COSYVOICE_DEVICE="auto"):
            self.assertEqual(server.parse_args(["--device", "gpu"]).device, "gpu")

    def test_invalid_cli_device_is_rejected(self) -> None:
        with clean_cosyvoice_env():
            for bad in ("mlx", "metal", "GPU", ""):
                with self.subTest(bad=bad):
                    with contextlib.redirect_stderr(io.StringIO()):
                        with self.assertRaises(SystemExit):
                            server.parse_args(["--device", bad])

    def test_invalid_env_device_is_rejected(self) -> None:
        with clean_cosyvoice_env(COSYVOICE_DEVICE="mlx"):
            with contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    server.parse_args([])


class CliContractTest(unittest.TestCase):
    def test_defaults_are_qwen_only(self) -> None:
        with clean_cosyvoice_env():
            args = server.parse_args([])
        self.assertEqual(args.host, "127.0.0.1")
        self.assertEqual(args.port, 5051)
        self.assertEqual(args.model_dir, str(server.DEFAULT_MODEL_DIR))
        self.assertEqual(args.refs, str(server.DEFAULT_VOICES_DIR))
        self.assertEqual(args.venv, str(server.DEFAULT_VENV))
        self.assertTrue(args.venv.endswith("venv-qwen3tts"))

    def test_env_overrides_paths(self) -> None:
        with clean_cosyvoice_env(COSYVOICE_MODEL_DIR="/tmp/qwen-model",
                                 COSYVOICE_REFS="/tmp/qwen-voices",
                                 COSYVOICE_VENV="/tmp/qwen-venv",
                                 COSYVOICE_HOST="127.0.0.2", COSYVOICE_PORT="5099"):
            args = server.parse_args([])
        self.assertEqual(args.model_dir, "/tmp/qwen-model")
        self.assertEqual(args.refs, "/tmp/qwen-voices")
        self.assertEqual(args.venv, "/tmp/qwen-venv")
        self.assertEqual(args.host, "127.0.0.2")
        self.assertEqual(args.port, 5099)

    def test_legacy_flags_are_removed(self) -> None:
        legacy = (
            ["--engine", "qwen3tts"], ["--engine", "cosyvoice3"],
            ["--repo", "/tmp/repo"], ["--flow-steps", "4"], ["--threads", "8"],
        )
        with clean_cosyvoice_env():
            for argv in legacy:
                with self.subTest(argv=argv):
                    with contextlib.redirect_stderr(io.StringIO()):
                        with self.assertRaises(SystemExit):
                            server.parse_args(argv)

    def test_help_mentions_device_not_engine(self) -> None:
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            with self.assertRaises(SystemExit):
                server.parse_args(["--help"])
        text = stdout.getvalue()
        self.assertIn("--device", text)
        self.assertNotIn("--engine", text)
        self.assertIn("gpu", text)


# --------------------------------------------------------------------------- #
# 引擎夹具 + health
# --------------------------------------------------------------------------- #
class QwenFixtureTestCase(VoiceFixtureTestCase):
    """在临时 voices 目录上构造引擎（Qwen3 不 import 真实 mlx / 不读模型）。"""

    def setUp(self) -> None:
        super().setUp()
        self.model_dir = self.tmp / "models" / server.QWEN3_MODEL_NAME

    def make_voice(self, voice_id: str = "girl", text: str = "参考文本") -> "server.Voice":
        directory = self.make_voice_dir(voice_id)
        if text:
            (directory / "prompt.txt").write_text(text, encoding="utf-8")
        return server.Voice(
            id=voice_id,
            name=voice_id,
            description="",
            prompt_wav=directory / "prompt.wav",
            prompt_text=text,
            mode="zero_shot" if text else "cross_lingual",
        )

    def make_engine(self, voices=None, *, state: str = "ready", model=None,
                    device: str = "gpu") -> "server.Qwen3Engine":
        if voices is None:
            voices = [self.make_voice()]
        engine = server.Qwen3Engine(
            model_dir=self.model_dir, voices=voices, device=device,
            voices_dir=self.voices, warmup=False,
        )
        engine.state = state
        if model is not None:
            engine.model = model
        return engine


class EngineHealthTest(QwenFixtureTestCase):
    def test_health_reports_engine_device_and_model(self) -> None:
        engine = self.make_engine()
        status, payload = engine.health_payload()
        self.assertEqual(status, 200)
        self.assertEqual(payload["engine"], "qwen3tts")
        self.assertEqual(payload["device"], "gpu")
        self.assertEqual(payload["version"], "2.0.0")
        self.assertEqual(payload["model"], server.QWEN3_MODEL_NAME)
        self.assertEqual(payload["sample_rate"], 24000)
        self.assertEqual(payload["state"], "ready")
        self.assertTrue(payload["ok"])
        self.assertTrue(payload["ready"])
        # 旧引擎专属字段不再出现
        self.assertNotIn("hybrid", payload)
        self.assertNotIn("flow_steps", payload)

    def test_health_reports_cpu_device(self) -> None:
        engine = self.make_engine(device="cpu")
        status, payload = engine.health_payload()
        self.assertEqual(status, 200)
        self.assertEqual(payload["device"], "cpu")

    def test_health_loading_is_503(self) -> None:
        engine = self.make_engine(state="loading")
        engine.progress = "加载模型权重"
        status, payload = engine.health_payload()
        self.assertEqual(status, 503)
        self.assertTrue(payload["loading"])
        self.assertEqual(payload["engine"], "qwen3tts")
        self.assertEqual(payload["device"], "gpu")
        self.assertEqual(payload["detail"], "加载模型权重")

    def test_health_failed_is_500(self) -> None:
        engine = self.make_engine(state="failed")
        engine.error = "ImportError: mlx_audio"
        status, payload = engine.health_payload()
        self.assertEqual(status, 500)
        self.assertEqual(payload["error"], "model_load_failed")
        self.assertIn("ImportError", payload["detail"])

    def test_engine_rejects_unresolved_device(self) -> None:
        for bad in ("auto", "mlx", ""):
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError):
                    server.Qwen3Engine(model_dir=self.model_dir, voices=[],
                                       device=bad, warmup=False)


class CpuWarmupTest(QwenFixtureTestCase):
    """实测 MLX CPU 的 warmup「你好。」约 244s：CPU 模式必须自动跳过预热，加载完直接 ready。"""

    def test_cpu_mode_auto_skips_warmup_and_reaches_ready(self) -> None:
        fake_model = FakeQwenModel()
        install_fake_mlx_audio(self, lambda _path: fake_model)
        engine = server.Qwen3Engine(model_dir=self.model_dir, voices=[self.make_voice()],
                                    device="cpu", warmup=True, voices_dir=self.voices)
        with self.assertLogs(server.log, level="WARNING") as captured:
            engine.load()

        self.assertEqual(fake_model.generate_calls, [])  # 没有触发预热合成
        self.assertEqual(engine.state, "ready")
        self.assertIsNotNone(engine.load_s)
        status, payload = engine.health_payload()
        self.assertEqual(status, 200)
        self.assertEqual(payload["device"], "cpu")
        self.assertTrue(any("自动跳过预热" in line for line in captured.output))

    def test_gpu_mode_still_warms_up(self) -> None:
        fake_model = FakeQwenModel()
        install_fake_mlx_audio(self, lambda _path: fake_model)
        engine = server.Qwen3Engine(model_dir=self.model_dir, voices=[self.make_voice()],
                                    device="gpu", warmup=True, voices_dir=self.voices)
        # 只验证 load 会进入预热分支（_synth 需要 numpy；这里用假的 _warmup 记录调用）
        called = []
        engine._warmup = lambda: called.append("warmup")
        engine.load()
        self.assertEqual(called, ["warmup"])
        self.assertEqual(engine.state, "ready")


# --------------------------------------------------------------------------- #
# Qwen3Engine：fake mlx_audio 的加载 / 合成
# --------------------------------------------------------------------------- #
@unittest.skipUnless(HAS_NUMPY, "Qwen3 合成用例需要 numpy")
class Qwen3EngineTest(QwenFixtureTestCase):
    def test_load_model_uses_injected_mlx_audio(self) -> None:
        fake_model = FakeQwenModel()
        loaded_paths = []

        def load_model(path):
            loaded_paths.append(path)
            return fake_model

        install_fake_mlx_audio(self, load_model)
        engine = self.make_engine(state="starting", model=None)
        engine._load_backend()          # 延迟 import mlx_audio（走 sys.modules 的 fake）
        self.assertIs(engine._mlx_audio, sys.modules["mlx_audio"])
        engine._load_model()
        self.assertIs(engine.model, fake_model)
        self.assertEqual(engine.sample_rate, 24000)
        self.assertEqual(loaded_paths, [str(self.model_dir)])

    def test_load_failure_marks_engine_failed(self) -> None:
        def load_model(_path):
            raise RuntimeError("权重损坏")

        install_fake_mlx_audio(self, load_model)
        engine = self.make_engine(state="starting", model=None)
        engine.load()
        self.assertEqual(engine.state, "failed")
        self.assertIn("权重损坏", engine.error)
        status, payload = engine.health_payload()
        self.assertEqual(status, 500)
        self.assertEqual(payload["engine"], "qwen3tts")

    def test_generate_kwargs_and_int16_conversion(self) -> None:
        fake_model = FakeQwenModel([
            fake_generation_result(np.array([0.0, 0.5, -1.5], dtype=np.float32)),
        ])
        engine = self.make_engine(model=fake_model)

        pcm, rate, info = engine.synthesize("你好", "girl", 1.0, None)

        self.assertEqual(rate, 24000)
        self.assertEqual(info["device"], "gpu")
        self.assertEqual(info["sample_rate"], 24000)
        self.assertEqual(len(pcm) % 2, 0)
        samples = np.frombuffer(pcm, dtype=np.int16)
        # -1.5 clamp 到 -0.999 后再转 int16，不会溢出成正值
        np.testing.assert_array_equal(samples, np.array([0, 16384, -32734], dtype=np.int16))

        call = fake_model.generate_calls[0]
        self.assertEqual(call["text"], "你好")
        self.assertEqual(call["ref_audio"], str(self.voices / "girl" / "prompt.wav"))
        self.assertEqual(call["ref_text"], "参考文本")
        self.assertEqual(call["lang_code"], "auto")
        self.assertIsNone(call["split_pattern"])  # 统一传 None，避免 fallback 路径按换行拆段
        self.assertFalse(call["stream"])
        self.assertNotIn("speed", call)
        self.assertNotIn("instruct", call)
        self.assertEqual(engine.stats["requests"], 1)
        self.assertEqual(engine.stats["errors"], 0)

    def test_cpu_engine_reports_cpu_device(self) -> None:
        engine = self.make_engine(
            device="cpu",
            model=FakeQwenModel([fake_generation_result(np.zeros(10, dtype=np.float32))]),
        )
        _, _, info = engine.synthesize("hi", "girl", 1.0, None)
        self.assertEqual(info["device"], "cpu")

    def test_rtf_uses_processing_time_over_duration(self) -> None:
        # RTF = processing_time_seconds / (samples / sample_rate)；不要用 real_time_factor
        engine = self.make_engine(model=FakeQwenModel([
            fake_generation_result(np.zeros(SAMPLE_RATE, dtype=np.float32),
                                   processing_time_seconds=2.0),
        ]))
        _, rate, info = engine.synthesize("hi", "girl", 1.0, None)
        self.assertEqual(rate, 24000)
        self.assertAlmostEqual(info["duration_s"], 1.0, places=3)
        self.assertEqual(info["synth_ms"], 2000)
        self.assertAlmostEqual(info["rtf"], 2.0, places=3)

    def test_multi_segment_result_is_concatenated_with_100ms_gap(self) -> None:
        first = np.full(240, 0.1, dtype=np.float32)
        second = np.full(120, 0.2, dtype=np.float32)
        engine = self.make_engine(model=FakeQwenModel([
            fake_generation_result(first),
            fake_generation_result(second),
        ]))

        pcm, rate, _ = engine.synthesize("第一段\n第二段", "girl", 1.0, None)

        samples = np.frombuffer(pcm, dtype=np.int16)
        gap = 2400  # 100ms @ 24kHz
        self.assertEqual(rate, 24000)
        self.assertEqual(len(samples), 240 + gap + 120)
        self.assertEqual(int(samples[0]), 3277)       # round(0.1 * 32767)
        np.testing.assert_array_equal(samples[240:240 + gap], np.zeros(gap, dtype=np.int16))
        self.assertEqual(int(samples[240 + gap]), 6553)  # round(0.2 * 32767)

    def test_single_result_object_is_supported(self) -> None:
        # 兼容 generate() 直接返回单个结果对象的实现
        engine = self.make_engine(model=FakeQwenModel())
        engine.model.generate = lambda **kwargs: fake_generation_result(
            np.array([1.0, -1.0], dtype=np.float32)
        )
        pcm, _, _ = engine.synthesize("hi", "girl", 1.0, None)
        samples = np.frombuffer(pcm, dtype=np.int16)
        np.testing.assert_array_equal(samples, np.array([32734, -32734], dtype=np.int16))

    def test_empty_generation_raises(self) -> None:
        engine = self.make_engine(model=FakeQwenModel([]))
        with self.assertRaises(server.EngineError) as raised:
            engine.synthesize("hi", "girl", 1.0, None)
        self.assertEqual(str(raised.exception), "模型没有返回任何音频")
        self.assertEqual(engine.stats["errors"], 1)

    def test_missing_ref_text_falls_back_to_xvector_with_warning(self) -> None:
        # 实测：只传 ref_audio 会静默走 speaker-encoder/x-vector fallback 并正常出声，
        # 因此缺参考文本不报错，只 warning（音色相似度下降）。
        engine = self.make_engine(
            voices=[self.make_voice(text="")],
            model=FakeQwenModel([fake_generation_result(np.zeros(10, dtype=np.float32))]),
        )
        with self.assertLogs(server.log, level="WARNING") as captured:
            pcm, rate, info = engine.synthesize("hi", "girl", 1.0, None)
        self.assertTrue(pcm)
        self.assertEqual(rate, 24000)
        self.assertEqual(info["device"], "gpu")
        self.assertTrue(any("x-vector fallback" in line for line in captured.output))
        call = engine.model.generate_calls[0]
        self.assertNotIn("ref_text", call)
        self.assertEqual(call["ref_audio"], str(self.voices / "girl" / "prompt.wav"))
        self.assertIsNone(call["split_pattern"])
        self.assertEqual(engine.stats["errors"], 0)

    def test_warmup_synthesizes_with_first_voice(self) -> None:
        # 实测首次合成含 kernel 编译，所以预热必须真的合成一句
        engine = self.make_engine(model=FakeQwenModel([
            fake_generation_result(np.zeros(240, dtype=np.float32)),
        ]))
        engine._warmup()
        self.assertEqual(len(engine.model.generate_calls), 1)
        call = engine.model.generate_calls[0]
        self.assertEqual(call["text"], "你好。")
        self.assertEqual(call["ref_audio"], str(self.voices / "girl" / "prompt.wav"))

    def test_warmup_failure_only_warns(self) -> None:
        class BrokenModel(FakeQwenModel):
            def generate(self, **kwargs):
                self.generate_calls.append(kwargs)
                raise RuntimeError("Metal 初始化失败")

        engine = self.make_engine(model=BrokenModel())
        with self.assertLogs(server.log, level="WARNING") as captured:
            engine._warmup()  # 不抛异常、不把引擎标成 failed
        self.assertTrue(any("预热合成失败" in line for line in captured.output))
        self.assertEqual(engine.state, "ready")

    def test_warmup_skipped_without_voices(self) -> None:
        engine = self.make_engine(voices=[], model=FakeQwenModel())
        with self.assertLogs(server.log, level="INFO") as captured:
            engine._warmup()
        self.assertTrue(any("跳过 Qwen3 预热" in line for line in captured.output))
        self.assertEqual(engine.model.generate_calls, [])

    def test_speed_and_instruct_are_ignored_with_logs(self) -> None:
        engine = self.make_engine(model=FakeQwenModel([
            fake_generation_result(np.zeros(10, dtype=np.float32)),
        ]))
        with self.assertLogs(server.log, level="DEBUG") as captured:
            engine.synthesize("hi", "girl", 1.5, "用温柔的语气说")
        output = "\n".join(captured.output)
        self.assertIn("speed", output)
        self.assertIn("instruct", output)
        call = engine.model.generate_calls[0]
        self.assertNotIn("speed", call)
        self.assertNotIn("instruct", call)

    def test_not_ready_and_unknown_voice_errors(self) -> None:
        engine = self.make_engine(state="loading", model=FakeQwenModel())
        with self.assertRaises(server.EngineError) as raised:
            engine.synthesize("hi", "girl", 1.0, None)
        self.assertEqual(str(raised.exception), "model_not_ready")

        engine = self.make_engine(model=FakeQwenModel())
        with self.assertRaises(server.EngineError) as raised:
            engine.synthesize("hi", "ghost", 1.0, None)
        self.assertEqual(str(raised.exception), "unknown_voice")

    def test_reload_voices_updates_manifest_without_touching_model(self) -> None:
        self.write_manifest([{
            "id": "girl",
            "name": "预置女声",
            "mode": "zero_shot",
            "prompt_wav": "girl/prompt.wav",
            "prompt_text": "参考文本",
        }])
        self.make_voice()
        engine = self.make_engine(voices=[], model=FakeQwenModel())

        result = engine.reload_voices()

        self.assertEqual(result["voices"], ["girl"])
        self.assertEqual(result["added"], 0)
        self.assertEqual(result["reused"], 0)
        self.assertEqual(result["removed"], [])
        self.assertIn("girl", engine.voice_map)
        self.assertFalse(engine.voices[0].cached)  # Qwen3 不缓存 prompt 特征
        self.assertEqual(engine.model.generate_calls, [])

    def test_reload_voices_strict_manifest_failure(self) -> None:
        (self.voices / "voices.json").write_text("{not json", encoding="utf-8")
        engine = self.make_engine(voices=[], model=FakeQwenModel())
        with self.assertRaises(server.EngineError):
            engine.reload_voices()

    def test_reload_voices_requires_ready(self) -> None:
        engine = self.make_engine(state="loading", model=FakeQwenModel())
        with self.assertRaises(server.EngineError) as raised:
            engine.reload_voices()
        self.assertEqual(str(raised.exception), "model_not_ready")


# --------------------------------------------------------------------------- #
# /tts 响应头 + EngineError → HTTP 映射
# --------------------------------------------------------------------------- #
class TtsContractTest(unittest.TestCase):
    INFO = {"duration_s": 1.0, "synth_ms": 5, "rtf": 0.1, "device": "gpu"}

    def test_headers_are_app_compatible(self) -> None:
        headers = server.tts_response_headers("qwen3tts", "girl", SAMPLE_RATE, self.INFO)
        self.assertEqual(headers["X-CosyVoice-Engine"], "qwen3tts")
        self.assertEqual(headers["X-CosyVoice-Version"], "2.0.0")
        self.assertEqual(headers["X-CosyVoice-Device"], "gpu")
        self.assertEqual(headers["X-CosyVoice-Sample-Rate"], "24000")
        self.assertEqual(headers["X-CosyVoice-Duration-Ms"], "1000")
        self.assertEqual(headers["X-CosyVoice-Synth-Ms"], "5")
        self.assertEqual(headers["X-CosyVoice-RTF"], "0.1")
        self.assertEqual(headers["Cache-Control"], "no-store")

    def test_headers_report_cpu_device(self) -> None:
        headers = server.tts_response_headers(
            "qwen3tts", "girl", SAMPLE_RATE, dict(self.INFO, device="cpu"),
        )
        self.assertEqual(headers["X-CosyVoice-Device"], "cpu")

    def test_engine_errors_map_to_http_status(self) -> None:
        self.assertEqual(
            server.map_tts_error(server.EngineError("model_not_ready"), "girl", "加载模型"),
            (503, "not_ready", "加载模型"),
        )
        self.assertEqual(
            server.map_tts_error(server.EngineError("unknown_voice"), "ghost", "ready"),
            (400, "unknown_voice", "ghost"),
        )
        self.assertEqual(
            server.map_tts_error(server.EngineError("boom"), "girl", "ready"),
            (500, "synthesis_failed", "boom"),
        )


# --------------------------------------------------------------------------- #
# 启动前置检查（模型/依赖/音色；不导入真实 mlx）
# --------------------------------------------------------------------------- #
class PreflightTest(VoiceFixtureTestCase):
    def make_model_dir(self, *, config: bool = True, weights: bool = True) -> Path:
        model_dir = self.tmp / "qwen-model"
        model_dir.mkdir(parents=True, exist_ok=True)
        if config:
            (model_dir / "config.json").write_text("{}", encoding="utf-8")
        if weights:
            (model_dir / "model.safetensors").write_bytes(b"stub")
        return model_dir

    def preflight(self, model_dir: Path, *, importer=None, voices_dir: Path = None):
        return server.preflight_problem(
            model_dir=model_dir,
            voices_dir=voices_dir or self.voices,
            importer=importer or (lambda name: None),
        )

    def test_missing_model_dir(self) -> None:
        problem = self.preflight(self.tmp / "no-such-model")
        self.assertIn("找不到 Qwen3-TTS 模型目录", problem)
        self.assertIn("scripts/install_cosyvoice.sh", problem)
        self.assertNotIn("--engine", problem)

    def test_missing_config_json(self) -> None:
        problem = self.preflight(self.make_model_dir(config=False))
        self.assertIn("config.json", problem)

    def test_missing_safetensors(self) -> None:
        problem = self.preflight(self.make_model_dir(weights=False))
        self.assertIn("safetensors", problem)

    def test_dependency_import_failure_has_actionable_hint(self) -> None:
        for module in server.REQUIRED_MODULES:
            with self.subTest(module=module):
                def importer(name, _module=module):
                    if name == _module:
                        raise ImportError(f"No module named {name!r}")
                    return None

                problem = self.preflight(self.make_model_dir(), importer=importer)
                self.assertIn(f"无法导入 {module}", problem)
                self.assertIn("scripts/install_cosyvoice.sh", problem)

    def test_dependencies_problem_checks_all_modules(self) -> None:
        called = []
        self.assertIsNone(server.dependencies_problem(lambda name: called.append(name)))
        self.assertEqual(called, list(server.REQUIRED_MODULES))

    def test_complete_model_passes(self) -> None:
        self.assertIsNone(self.preflight(self.make_model_dir()))

    def test_missing_voices_dir(self) -> None:
        problem = self.preflight(self.make_model_dir(), voices_dir=self.tmp / "no-voices")
        self.assertIn("找不到音色目录", problem)


# --------------------------------------------------------------------------- #
# main() 返回码 / 装配（不加载真实模型）
# --------------------------------------------------------------------------- #
class MainReturnCodeTest(VoiceFixtureTestCase):
    def test_missing_model_returns_exit_2(self) -> None:
        with clean_cosyvoice_env():
            code = server.main([
                "--model-dir", str(self.tmp / "no-such-model"),
                "--refs", str(self.voices),
                "--device", "cpu",
            ])
        self.assertEqual(code, 2)

    def test_port_in_use_returns_exit_2(self) -> None:
        model_dir = self.tmp / "qwen-model"
        model_dir.mkdir()
        with mock.patch.object(server, "preflight_problem", return_value=None), \
                mock.patch.object(server, "check_port", return_value="EADDRINUSE 127.0.0.1:5051"):
            with clean_cosyvoice_env():
                code = server.main([
                    "--model-dir", str(model_dir), "--refs", str(self.voices),
                ])
        self.assertEqual(code, 2)

    def test_device_configure_failure_returns_exit_2(self) -> None:
        model_dir = self.tmp / "qwen-model"
        model_dir.mkdir()
        with mock.patch.object(server, "preflight_problem", return_value=None), \
                mock.patch.object(server, "check_port", return_value=None), \
                mock.patch.object(server, "configure_mlx_device",
                                  side_effect=RuntimeError("MLX 初始化失败")):
            with clean_cosyvoice_env():
                code = server.main([
                    "--model-dir", str(model_dir), "--refs", str(self.voices),
                ])
        self.assertEqual(code, 2)

    def test_main_wires_device_and_runs_uvicorn(self) -> None:
        model_dir = self.tmp / "qwen-model"
        model_dir.mkdir()
        captured = {}

        def fake_build_app(engine):
            captured["engine"] = engine
            return object()

        fake_uvicorn = types.ModuleType("uvicorn")
        fake_uvicorn.run = mock.Mock()

        with mock.patch.object(server, "preflight_problem", return_value=None), \
                mock.patch.object(server, "check_port", return_value=None), \
                mock.patch.object(server, "configure_mlx_device", return_value="cpu"), \
                mock.patch.object(server, "build_app", side_effect=fake_build_app), \
                mock.patch.object(server.Qwen3Engine, "start_loading", lambda self: None), \
                mock.patch.dict(sys.modules, {"uvicorn": fake_uvicorn}):
            with clean_cosyvoice_env():
                code = server.main([
                    "--model-dir", str(model_dir), "--refs", str(self.voices),
                    "--device", "cpu", "--host", "127.0.0.1", "--port", "5058",
                ])

        self.assertEqual(code, 0)
        self.assertEqual(captured["engine"].device, "cpu")
        self.assertEqual(captured["engine"].ENGINE, "qwen3tts")
        fake_uvicorn.run.assert_called_once()
        kwargs = fake_uvicorn.run.call_args.kwargs
        self.assertEqual(kwargs["host"], "127.0.0.1")
        self.assertEqual(kwargs["port"], 5058)
        self.assertFalse(kwargs["access_log"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
