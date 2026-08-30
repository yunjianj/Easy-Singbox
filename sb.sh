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
for _f in "$DIR/sb" "$DIR/uninstall.sh" "$DIR/lib/core.sh" "$DIR/lib/init.sh" \
          "$DIR/lib/service.sh" "$DIR/lib/firewall.sh" "$DIR/lib/port_hop.sh" "$DIR/lib/cert.sh" \
          "$DIR/lib/config.sh" "$DIR/lib/node.sh" "$DIR/lib/diag.sh" "$DIR/lib/bbrfq.sh" \
          "$DIR/lib/protocol/anytls.sh" "$DIR/lib/protocol/hysteria2.sh" "$DIR/lib/protocol/tuic.sh"; do
  if [[ ! -f "$_f" ]]; then
    echo "解压内容不完整：缺少 $_f，已中止（疑似下载被篡改）" >&2
    exit 1
  fi
done

# 内容级完整性校验（供应链防护）：齐套检查只能确认"文件在"，无法发现"文件齐全但
# 内容被整体替换"的投毒。以 GitHub git trees API 的官方 blob SHA1 为锚点逐文件比对。
# 本脚本需独立运行（不依赖 lib/），故在此内联实现。
# 校验不符→中止；无法校验（API 不可达 / 缺 sha1 工具）→ 降级为交互式确认。
_blob_sha1() {
  local f=$1 len tool
  [[ -f "$f" ]] || return 1
  if command -v sha1sum >/dev/null 2>&1; then
    tool="sha1sum"
  elif command -v shasum >/dev/null 2>&1; then
    tool="shasum -a 1"
  else
    return 1
  fi
  len=$(wc -c < "$f" 2>/dev/null | tr -d '[:space:]' || true)
  [[ -n "$len" ]] || return 1
  { printf 'blob %s\0' "$len"; cat "$f"; } | $tool 2>/dev/null | awk '{print $1}'
}

verify_content() {
  local dir=$1 tree_json map f want got cnt=0
  tree_json=$(curl -fsSL --retry 2 --max-time 25 \
    "https://api.github.com/repos/$REPO/git/trees/$BRANCH?recursive=1" 2>/dev/null || true)
  # 显式 if 而非 `[[ ]] && return`：本脚本 set -e，后者在条件不成立时整条语句
  # 返回非零会直接终止脚本（除非调用方用 || 包裹）。
  if [[ -z "$tree_json" ]]; then return 2; fi
  # GitHub API 返回美化 JSON（字段分行），按 path → type → sha 解析出 blob 映射；
  # 首个 sha 是树对象自身摘要（此时 p 为空），被 p != "" 条件跳过。
  map=$(printf '%s' "$tree_json" | awk '
    /"path":/ { p=$0; gsub(/.*"path": *"|",?$/,"",p); next }
    /"type":/ { t=$0; gsub(/.*"type": *"|",?$/,"",t); next }
    /"sha":/ && p != "" { s=$0; gsub(/.*"sha": *"|",?$/,"",s)
                          if (t=="blob" && s ~ /^[0-9a-f]{40}$/) print p" "s; p=""; t=""; next }
  ' || true)
  if [[ -z "$map" ]]; then return 2; fi
  for f in install.sh sb uninstall.sh VERSION \
           lib/core.sh lib/init.sh lib/service.sh lib/firewall.sh lib/port_hop.sh lib/cert.sh \
           lib/config.sh lib/node.sh lib/diag.sh lib/bbrfq.sh \
           lib/protocol/anytls.sh lib/protocol/hysteria2.sh lib/protocol/tuic.sh \
           templates/config.json.tpl; do
    want=$(printf '%s\n' "$map" | grep -m1 "^${f} " | awk '{print $2}' || true)
    if [[ -z "$want" ]]; then return 2; fi
    got=$(_blob_sha1 "$dir/$f" || true)
    if [[ -z "$got" ]]; then return 2; fi
    if [[ "$got" != "$want" ]]; then
      echo "内容校验不符: $f（官方 ${want:0:12}… 实际 ${got:0:12}…）" >&2
      return 1
    fi
    cnt=$((cnt+1))
  done
  if [[ $cnt -eq 0 ]]; then return 2; fi
  return 0
}

echo "==> 校验内容完整性 ..."
_vrc=0
verify_content "$DIR" || _vrc=$?
if [[ $_vrc -eq 1 ]]; then
  echo "内容校验失败：下载内容与 GitHub 官方不一致，已中止（疑似下载被篡改）" >&2
  exit 1
elif [[ $_vrc -eq 2 ]]; then
  echo "警告：无法获取官方内容校验值（GitHub API 不可达，或缺少 sha1sum/shasum）" >&2
  printf "确认在仅做齐套校验、无内容校验的情况下继续？[y/N]: "
  _ans=""; read -r _ans || true
  case "$_ans" in
    y|Y) echo "已确认，继续（无内容校验）" ;;
    *)   echo "已取消" >&2; exit 1 ;;
  esac
else
  echo "==> 内容完整性校验通过（与 GitHub 官方 blob SHA1 逐文件比对）"
fi

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
  # 立即建立管理命令软链：即使后续 install.sh 中途失败/卡住，sb 也可用于排查
  ln -sf "$DEST/sb" /usr/local/bin/sb 2>/dev/null || true
  cd "$DEST"
  exec bash ./install.sh "$@"
fi

echo "==> 非 root 运行，直接在临时目录执行（建议用 root 以安装到 $DEST）"
cd "$DIR"
exec bash ./install.sh "$@"
