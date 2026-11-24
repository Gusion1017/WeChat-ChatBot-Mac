#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT_DIR"
PYTHONPATH=tools python3 -m unittest discover -s tools/wechat_port/tests -v
