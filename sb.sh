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

# 引导期完整性校验（引导时本地无信任锚，做最低限度齐套检查）：
# install.sh 首行需为 sh shebang；sb 与全部 lib/*.sh 必须齐全，否则拒绝执行。
if ! head -1 "$DIR/install.sh" | grep -qE '^#!.*sh'; then
  echo "解压内容异常：install.sh 缺少 shebang，已中止（疑似下载被篡改）" >&2
  exit 1
fi
for _f in "$DIR/sb" "$DIR/uninstall.sh" "$DIR/lib/core.sh" "$DIR/lib/service.sh" \
          "$DIR/lib/firewall.sh" "$DIR/lib/port_hop.sh" "$DIR/lib/cert.sh" \
          "$DIR/lib/config.sh" "$DIR/lib/node.sh" "$DIR/lib/diag.sh" \
          "$DIR/lib/protocol/anytls.sh" "$DIR/lib/protocol/hysteria2.sh" "$DIR/lib/protocol/tuic.sh"; do
  if [[ ! -f "$_f" ]]; then
    echo "解压内容不完整：缺少 $_f，已中止（疑似下载被篡改）" >&2
    exit 1
  fi
done

# 安装到持久目录后再运行。
# 原因：此前直接在 mktemp 临时目录里 exec install.sh，导致 /usr/local/bin/sb 软链
# 指向临时目录；/tmp 被清理或重启后 sb 失效，且残留的旧 lib 模块会与新版 sb 混用，
# 造成“代码已修好但线上仍是旧行为”的版本错配。
DEST="/usr/local/share/easy-singbox"
if [[ $EUID -eq 0 ]]; then
  echo "==> 安装到 $DEST ..."
  mkdir -p "$DEST"
  # 先清掉旧的模块目录，避免残留文件与新版本混用
  rm -rf "$DEST/lib" "$DEST/templates"
  cp -rf "$DIR/." "$DEST/"
  chmod 755 "$DEST/sb" "$DEST/install.sh" "$DEST/uninstall.sh" 2>/dev/null || true
  cd "$DEST"
  exec bash ./install.sh "$@"
fi

echo "==> 非 root 运行，直接在临时目录执行（建议用 root 以安装到 $DEST）"
cd "$DIR"
exec bash ./install.sh "$@"
