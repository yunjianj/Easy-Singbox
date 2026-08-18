#!/usr/bin/env bash
# sb.sh — 一键引导脚本（可独立运行）
#   bash <(wget -qO- https://raw.githubusercontent.com/yunjianj/Easy-Singbox/main/sb.sh)
# 设计原则：绝不解析脚本自身路径（bash <(wget ...) 下自身是 /dev/fd/* 伪路径，
# 无法据此 cd）。改为判断“当前工作目录是否就是仓库”，否则下载后运行。
set -euo pipefail

REPO="yunjianj/Easy-Singbox"
BRANCH="main"

# 若当前目录即为仓库（含 install.sh）：直接运行本地 install.sh，避免重复下载。
# 通过 bash <(wget ...) 运行时 CWD 为用户家目录，不会命中，会走下方下载分支。
if [[ -f "./install.sh" ]]; then
  exec bash ./install.sh "$@"
fi

echo "==> 下载 Easy-Singbox ($BRANCH) ..."
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

URL="https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$URL" -o "$TMP/esb.tar.gz"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$TMP/esb.tar.gz" "$URL"
else
  echo "需要 curl 或 wget 才能下载，请先安装其一" >&2
  exit 1
fi

echo "==> 解压 ..."
tar -xzf "$TMP/esb.tar.gz" -C "$TMP"
DIR="$(find "$TMP" -maxdepth 1 -type d -name 'Easy-Singbox-*' | head -1)"
if [[ -z "$DIR" || ! -f "$DIR/install.sh" ]]; then
  echo "解压失败或未找到 install.sh" >&2
  exit 1
fi

cd "$DIR"
exec bash ./install.sh "$@"
