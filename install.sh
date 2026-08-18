#!/usr/bin/env bash
# install.sh — 首次运行入口，进入统一主页面
set -euo pipefail
SB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
exec bash "$SB_DIR/sb" "$@"
