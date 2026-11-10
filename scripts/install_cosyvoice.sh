#!/usr/bin/env bash
# 本地旁路 TTS —— Qwen3-TTS-1.7B（Apple MLX）幂等安装脚本（macOS arm64 优先）。
#
# 历史命名：文件名保持 `install_cosyvoice.sh`（App 打包与调用路径是固定契约），
# 但 v2.0.0 起只安装 Qwen3-TTS-1.7B，CosyVoice3 已移除，不再有 --engine。
#
# 安装内容（home 默认 _local/cosyvoice，打包 App 为 Application Support 下的 cosyvoice）：
#   <home>/venv-qwen3tts/  Python 3.10 venv
#       → mlx-audio==0.6.4 + huggingface_hub + fastapi/uvicorn/pydantic（不装 torch、不 clone 仓库）
#   <home>/models/Qwen3-TTS-12Hz-1.7B-Base-bf16/
#       → huggingface_hub.snapshot_download（mlx-community 版，约 4.2GB / 14 文件）
#   <home>/voices/         空音色目录 + 空 voices.json（不内置任何音色，由 App 内添加）
#   <home>/.installed-qwen3tts  安装 marker
#
# 输出契约（App 逐行解析）：每步一行 `PROGRESS <0.00-1.00> <中文说明>`（stdout）。
# 人类可读的诊断写 stderr；失败时 stderr 有明确原因 + 非 0 退出码。
#
# 用法：
#   scripts/install_cosyvoice.sh [选项]
#     --home DIR        安装根目录（App 生产路径；推导 venv/model/refs）
#     --model-dir DIR   --venv DIR   --refs DIR
#     --skip-model      --skip-deps  --dry-run  --force  -h/--help
#   （同名环境变量：COSYVOICE_HOME / COSYVOICE_MODEL_DIR / COSYVOICE_VENV /
#     COSYVOICE_REFS / COSYVOICE_LOCAL_DIR / COSYVOICE_SERVER_DIR）
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# App 是 GUI 启动的，Process 继承的 PATH 往往只有 /usr/bin:/bin:/usr/sbin:/sbin，
# 没有 Homebrew / anaconda。这里统一补齐，并优先用绝对路径探测工具。
export PATH="/opt/homebrew/bin:/usr/local/bin:/opt/anaconda3/bin:$HOME/.local/bin:$PATH"

find_tool() {
  # find_tool <name> [candidate_abs_paths...] -> 打印绝对路径
  local name="$1"; shift
  local found
  found="$(command -v "$name" 2>/dev/null || true)"
  if [[ -n "$found" && -x "$found" ]]; then printf '%s' "$found"; return 0; fi
  local cand
  for cand in "$@"; do
    if [[ -x "$cand" ]]; then printf '%s' "$cand"; return 0; fi
  done
  return 1
}

# 路径解析：--home（App 生产路径）> 显式 flag > 环境变量 > 仓库内 _local 默认
HOME_DIR_ARG=""
VENV_ARG=""
MODEL_DIR_ARG=""
REFS_ARG=""

QWEN3_MODEL_NAME="Qwen3-TTS-12Hz-1.7B-Base-bf16"
QWEN3_MODEL_ID="mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16"
# 实测通过：mlx-audio 0.6.4（requires-python >=3.10）
QWEN3_PIP_SPEC="mlx-audio==0.6.4"
# 服务端（FastAPI + uvicorn）是独立依赖：本安装不装 torch 栈。
QWEN3_WEB_DEPS=("fastapi==0.115.6" "uvicorn==0.30.0" "pydantic==2.7.0")
QWEN3_VENV_DIR_NAME="venv-qwen3tts"

SKIP_MODEL=0
SKIP_DEPS=0
DRY_RUN=0
FORCE=0
say() { printf '%s\n' "$*" >&2; }
die() { local _code="${2:-1}"; printf 'ERROR: %s\n' "$1" >&2; exit "$_code"; }
progress() { printf 'PROGRESS %.2f %s\n' "$1" "$2"; }

CURRENT_PID=""
on_signal() {
  say ""
  say "收到中断信号，正在停止当前步骤（已下载内容会保留，重跑即可续传）……"
  if [[ -n "$CURRENT_PID" ]]; then
    kill -TERM "$CURRENT_PID" 2>/dev/null || true
    wait "$CURRENT_PID" 2>/dev/null || true
  fi
  exit 143
}
trap on_signal TERM INT

# 在后台跑命令并 wait，这样能立刻响应 SIGTERM（App 取消 = terminate）
run_step() {
  "$@" &
  CURRENT_PID=$!
  wait "$CURRENT_PID"
  local rc=$?
  CURRENT_PID=""
  return $rc
}

usage() {
  awk 'NR > 1 { if ($0 ~ /^#/) { sub(/^# ?/, ""); print } else { exit } }' "${BASH_SOURCE[0]}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --home) HOME_DIR_ARG="${2:?}"; shift 2 ;;
    --model-dir) MODEL_DIR_ARG="${2:?}"; shift 2 ;;
    --venv) VENV_ARG="${2:?}"; shift 2 ;;
    --refs) REFS_ARG="${2:?}"; shift 2 ;;
    --skip-model) SKIP_MODEL=1; shift ;;
    --skip-deps) SKIP_DEPS=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1（--help 查看用法）" ;;
  esac
done

LOCAL_DIR="${HOME_DIR_ARG:-${COSYVOICE_HOME:-${COSYVOICE_LOCAL_DIR:-$REPO_ROOT/_local/cosyvoice}}}"
VENV="${VENV_ARG:-${COSYVOICE_VENV:-$LOCAL_DIR/$QWEN3_VENV_DIR_NAME}}"
MODEL_DIR="${MODEL_DIR_ARG:-${COSYVOICE_MODEL_DIR:-$LOCAL_DIR/models/$QWEN3_MODEL_NAME}}"
REFS="${REFS_ARG:-${COSYVOICE_REFS:-$LOCAL_DIR/voices}}"
MARKER="$LOCAL_DIR/.installed-qwen3tts"
PY="$VENV/bin/python"
ENGINE_LABEL="Qwen3-TTS-1.7B（MLX）"
CV_DEVTOOLS="${COSYVOICE_SERVER_DIR:-$REPO_ROOT/devtools/cosyvoice}"
# 打包版 App：脚本与 server.py 同目录（Contents/Resources/cosyvoice/），
# 手动在 bundle 里运行时也能找到，不依赖 App 注入 COSYVOICE_SERVER_DIR。
if [[ ! -f "$CV_DEVTOOLS/server.py" && -f "$SCRIPT_DIR/server.py" ]]; then
  CV_DEVTOOLS="$SCRIPT_DIR"
fi
export COSYVOICE_SERVER_DIR="$CV_DEVTOOLS"

[[ -f "$CV_DEVTOOLS/server.py" ]] || die "找不到 server.py（COSYVOICE_SERVER_DIR=${CV_DEVTOOLS}）"

# --------------------------------------------------------------------------- #
# 0. 环境检查
# --------------------------------------------------------------------------- #
progress 0.00 "检查安装环境"
say "=============================================================="
say " ${ENGINE_LABEL} 本地旁路安装（Qwen3-TTS 单引擎）"
say "   仓库根   : $REPO_ROOT"
say "   venv     : $VENV"
say "   模型目录 : $MODEL_DIR"
say "   音色目录 : $REFS"
say "   安装标记 : $MARKER"
say "=============================================================="

[[ -d "$REPO_ROOT" ]] || die "仓库根不存在：$REPO_ROOT"

# 需要能创建/复用 Python 3.10 venv（mlx-audio requires-python >=3.10）
UV_BIN="$(find_tool uv /opt/homebrew/bin/uv /usr/local/bin/uv || true)"
PY310="$(find_tool python3.10 /opt/homebrew/bin/python3.10 /usr/local/bin/python3.10 || true)"
CONDA_BIN="$(find_tool conda /opt/anaconda3/bin/conda /opt/homebrew/bin/conda || true)"
if [[ -z "$UV_BIN" && -z "$PY310" && -z "$CONDA_BIN" ]]; then
  die "找不到 uv / python3.10 / conda。请先安装其一：
  - 推荐：brew install uv
  - 或：brew install python@3.10
  - 或：安装 Miniconda 后用 conda 创建 python=3.10 环境"
fi

if [[ $DRY_RUN -eq 1 ]]; then
  say "   --- 最终解析路径（App 会用这些路径判定已安装）---"
  say "   ENGINE    = qwen3tts ($ENGINE_LABEL)"
  say "   LOCAL_DIR = $LOCAL_DIR"
  say "   VENV      = $VENV"
  say "   MODEL_DIR = $MODEL_DIR"
  say "   REFS      = $REFS"
  say "   MARKER    = $MARKER"
  say "   SERVER_DIR= $CV_DEVTOOLS"
  say "   PY        = $PY"
  say "   ---------------------------------------------"
  progress 0.05 "[dry-run] 将复用/创建 venv：${VENV}（Python ≥3.10，优先 3.10）"
  if [[ $SKIP_DEPS -eq 1 ]]; then
    progress 0.15 "[dry-run] --skip-deps：跳过 ${QWEN3_PIP_SPEC} 安装"
  else
    progress 0.15 "[dry-run] 将在独立 venv 安装 ${QWEN3_PIP_SPEC} + huggingface_hub + fastapi/uvicorn/pydantic（不装 torch，不 clone 仓库）"
  fi
  if [[ $SKIP_MODEL -eq 1 ]]; then
    progress 0.40 "[dry-run] --skip-model：跳过模型下载"
  else
    progress 0.40 "[dry-run] 将用 snapshot_download 下载 ${QWEN3_MODEL_ID}（约 4.2GB）-> $MODEL_DIR"
  fi
  progress 0.85 "[dry-run] 将创建空音色目录（不内置音色）-> $REFS"
  progress 1.00 "演练完成（未做任何修改）"
  exit 0
fi

# --------------------------------------------------------------------------- #
# 模型完整性 / 已安装判定
# --------------------------------------------------------------------------- #
qwen_model_complete() {
  [[ -f "$MODEL_DIR/config.json" ]] || return 1
  local f size
  for f in "$MODEL_DIR"/*.safetensors; do
    [[ -f "$f" ]] || continue
    size=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null || echo 0)
    [[ "$size" -gt 1000000 ]] && return 0
  done
  return 1
}

qwen_installed_ok() {
  [[ -x "$PY" ]] || return 1
  qwen_model_complete || return 1
  # deps 被删掉时也应视为「未安装」，让用户重跑脚本修复
  "$PY" -c 'import mlx_audio, fastapi, uvicorn' >/dev/null 2>&1 || return 1
  return 0
}

if [[ $FORCE -eq 0 && -f "$MARKER" && -x "$PY" ]] && qwen_installed_ok; then
  progress 1.00 "已安装（$MARKER 校验通过），无需重装"
  say "已安装且校验通过（Qwen3-TTS）。需要重装请加 --force。"
  exit 0
fi
if [[ $FORCE -eq 0 && -f "$MARKER" && -x "$PY" ]]; then
  say "已有 $MARKER 但校验不通过，继续修复式安装。"
fi

mkdir -p "$LOCAL_DIR" "$(dirname "$MODEL_DIR")" "$REFS" "$LOCAL_DIR/logs"

# --------------------------------------------------------------------------- #
# 1. venv（复用 ≥3.10 的已有 venv；否则创建 3.10）
# --------------------------------------------------------------------------- #
progress 0.03 "准备 Python 虚拟环境"
if [[ -x "$PY" ]]; then
  PY_OK="$("$PY" -c 'import sys; print(1 if sys.version_info >= (3, 10) else 0)' 2>/dev/null || echo 0)"
else
  PY_OK=0
fi
if [[ "$PY_OK" == "1" ]]; then
  say "复用已有 venv：$VENV ($("$PY" -V 2>&1))"
else
  if [[ -x "$PY" ]]; then
    # 不自动删除用户目录：版本不满足时交给用户显式处理（或 --venv 指向新目录）
    die "已有 venv 的 Python 版本不满足要求（需 ≥3.10，当前 $("$PY" -V 2>&1)）：$VENV
请备份/删除该 venv 后重跑，或用 --venv 指定新目录"
  fi
  if [[ -n "$UV_BIN" ]]; then
    "$UV_BIN" venv --python 3.10 "$VENV" || die "uv venv 创建失败（${VENV}）"
  elif [[ -n "$PY310" ]]; then
    "$PY310" -m venv "$VENV" || die "python3.10 -m venv 创建失败（${VENV}）"
  else
    "$CONDA_BIN" create -y -p "$VENV" python=3.10 || die "conda 创建 python 3.10 环境失败（${VENV}）"
  fi
fi
[[ -x "$PY" ]] || die "venv 里没有 python：$PY"
say "Python: $("$PY" -V 2>&1)"

# --------------------------------------------------------------------------- #
# 2. 依赖（mlx-audio；不装 torch、不 clone 仓库、不打补丁）
# --------------------------------------------------------------------------- #
if [[ $SKIP_DEPS -eq 1 ]]; then
  progress 0.10 "--skip-deps：跳过 ${QWEN3_PIP_SPEC} 安装"
else
  progress 0.08 "安装 mlx-audio（MLX 推理，不装 torch；首次约 1–3 分钟）"
  # uv venv 默认不带 pip：优先用 `uv pip install --python <venv>`；没有 uv 才用 venv 自带 pip。
  if [[ -n "$UV_BIN" ]]; then
    run_step "$UV_BIN" pip install --python "$PY" --upgrade \
      "$QWEN3_PIP_SPEC" "huggingface_hub" "${QWEN3_WEB_DEPS[@]}" \
      || die "mlx-audio 安装失败（见上方 pip 输出）"
  else
    run_step "$PY" -m pip install --upgrade \
      "$QWEN3_PIP_SPEC" "huggingface_hub" "${QWEN3_WEB_DEPS[@]}" \
      || die "mlx-audio 安装失败（见上方 pip 输出）"
  fi
  progress 0.30 "mlx-audio 安装完成"
fi

# --------------------------------------------------------------------------- #
# 3. 模型（Qwen3-TTS-12Hz-1.7B-Base-bf16）
# --------------------------------------------------------------------------- #
if [[ $SKIP_MODEL -eq 1 ]]; then
  progress 0.40 "--skip-model：跳过模型下载"
elif qwen_model_complete; then
  progress 0.40 "模型已存在且完整：$MODEL_DIR"
else
  progress 0.40 "下载模型 ${QWEN3_MODEL_ID}（约 4.2GB / 14 文件）"
  # 支持镜像：huggingface_hub 自动读取 HF_ENDPOINT（如 https://hf-mirror.com）。
  say "   HF_ENDPOINT=${HF_ENDPOINT:-https://huggingface.co}（镜像可设 HF_ENDPOINT）"
  "$PY" -c 'import huggingface_hub' >/dev/null 2>&1 \
    || die "venv 里缺少 huggingface_hub，无法下载模型。先运行本脚本（勿加 --skip-deps）或 $PY -m pip install -U huggingface_hub"
  mkdir -p "$MODEL_DIR"
  "$PY" - "$QWEN3_MODEL_ID" "$MODEL_DIR" <<'PY' &
import sys

from huggingface_hub import snapshot_download

repo_id, local_dir = sys.argv[1], sys.argv[2]
snapshot_download(repo_id=repo_id, local_dir=local_dir)
print(f"下载完成：{repo_id} -> {local_dir}", file=sys.stderr)
PY
  CURRENT_PID=$!
  # 轮询下载体积，输出 0.40 -> 0.80 的进度（实测模型约 4.2GB：3.6GB 权重 + 0.65GB tokenizer）
  TARGET_BYTES=4200000000
  while kill -0 "$CURRENT_PID" 2>/dev/null; do
    sleep 3
    done_bytes=$(du -sk "$MODEL_DIR" 2>/dev/null | awk '{print $1 * 1024}')
    [[ -z "${done_bytes:-}" ]] && done_bytes=0
    pct=$(( done_bytes * 100 / TARGET_BYTES ))
    [[ $pct -gt 100 ]] && pct=100
    # 0.40 + 0.40 * pct%
    step=$(awk -v p="$pct" 'BEGIN{printf "%.2f", 0.40 + 0.40 * p / 100}')
    progress "$step" "下载模型 ${pct}%（$(awk -v b="$done_bytes" 'BEGIN{printf "%.2f", b/1073741824}') GB / ~4.2GB）"
  done
  wait "$CURRENT_PID"
  rc=$?
  CURRENT_PID=""
  [[ $rc -eq 0 ]] || die "模型下载失败（exit ${rc}），可直接重跑本脚本续传"
  qwen_model_complete || die "模型下载完成但文件不全：${MODEL_DIR}（请重跑）"
  progress 0.80 "模型下载完成"
fi

# --------------------------------------------------------------------------- #
# 4. 音色（不内置；用户在 App 音色管理里添加）
# --------------------------------------------------------------------------- #
mkdir -p "$REFS"
export COSYVOICE_REPO_ROOT="$REPO_ROOT"
progress 0.86 "创建空音色目录（不内置音色，由用户在 App 内添加）"
if [[ ! -f "$REFS/voices.json" ]]; then
  printf '{\n  "version": 2,\n  "voices": []\n}\n' > "$REFS/voices.json"
  say "已写空清单：$REFS/voices.json"
else
  say "已存在音色清单，保留不动：$REFS/voices.json"
fi
if [[ -d "$REFS/girl" || -d "$REFS/loli" || -d "$REFS/onee" ]]; then
  say "检测到本机已有音色目录，保留不动。"
fi

# --------------------------------------------------------------------------- #
# 5. 校验 + 标记
# --------------------------------------------------------------------------- #
progress 0.94 "校验安装结果（venv/模型/依赖；音色可为空）"
"$PY" - "$VENV" "$MODEL_DIR" "$REFS" <<'PY' || die "安装校验失败（见上）"
import json, pathlib, sys

venv, model_dir, refs = (pathlib.Path(x) for x in sys.argv[1:4])
errors = []
if not (venv / "bin" / "python").is_file():
    errors.append(f"venv python 缺失: {venv / 'bin' / 'python'}")
if not (model_dir / "config.json").is_file():
    errors.append(f"模型 config.json 缺失: {model_dir / 'config.json'}")
if not any(p.is_file() for p in model_dir.glob("*.safetensors")):
    errors.append(f"模型缺少 *.safetensors: {model_dir}")
try:
    import mlx_audio  # noqa: F401
    import fastapi  # noqa: F401
    import uvicorn  # noqa: F401
except Exception as exc:  # noqa: BLE001
    errors.append(f"Qwen3-TTS 运行依赖无法导入（{type(exc).__name__}: {exc}）")
if errors:
    print("校验失败：", file=sys.stderr)
    for e in errors:
        print(" -", e, file=sys.stderr)
    sys.exit(1)
# 音色不是安装成功条件（分发边界：普通用户安装后为空）；有清单则做一次可读校验
voice_ids = []
manifest = refs / "voices.json"
if manifest.is_file():
    try:
        data = json.loads(manifest.read_text(encoding="utf-8"))
        voice_ids = [item["id"] for item in data.get("voices", [])]
    except Exception as exc:
        print(f"WARN: 音色清单解析失败（不影响安装，可在 App 内重建）：{exc}", file=sys.stderr)
print(f"校验通过：engine=qwen3tts，venv/模型/依赖齐全；音色 {len(voice_ids)} 个 {voice_ids}", file=sys.stderr)
PY

progress 0.97 "写入安装标记"
"$PY" - "$MARKER" "$MODEL_DIR" "$VENV" "$REFS" <<'PY'
import datetime, json, pathlib, sys

marker, model_dir, venv, refs = (pathlib.Path(x) for x in sys.argv[1:5])
voice_ids = []
manifest = refs / "voices.json"
if manifest.is_file():
    try:
        voice_ids = [v["id"] for v in json.loads(manifest.read_text(encoding="utf-8")).get("voices", [])]
    except Exception:
        voice_ids = []
data = {
    "version": 2,
    "engine": "qwen3tts",
    "installed_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "model": model_dir.name,
    "model_dir": str(model_dir),
    "venv": str(venv),
    "voices_dir": str(refs),
    # 安装成功 ≠ 有音色：普通用户安装后为空，由 App 内添加
    "voices": voice_ids,
    "python": f"{sys.version_info.major}.{sys.version_info.minor}",
    "platform": sys.platform,
    "deps": ["mlx-audio==0.6.4", "huggingface_hub", "fastapi==0.115.6",
             "uvicorn==0.30.0", "pydantic==2.7.0"],
}
tmp = marker.with_suffix(".tmp")
tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
tmp.replace(marker)
print(f"已写入 {marker}", file=sys.stderr)
PY

progress 1.00 "安装完成，可运行 scripts/run_cosyvoice.sh 启动服务"
say ""
say "安装完成（Qwen3-TTS-1.7B / MLX）。启动：scripts/run_cosyvoice.sh --wait-health"
say "标记文件：$MARKER"
say "音色：未内置。请在 App 音色管理中添加后调用 POST /voices/reload。"
exit 0
