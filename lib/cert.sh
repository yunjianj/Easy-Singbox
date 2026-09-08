#!/usr/bin/env bash
# lib/cert.sh — 证书管理（acme.sh 自动申请 Let's Encrypt）
# 仅支持脚本自动申请，不支持手动上传。HTTP-01 / DNS-01(Cloudflare)。

# 安装 acme.sh（幂等）
# 供应链防护：不再 `curl ... | sh` 盲执行远程脚本，改为“先落盘、再校验、后执行”。
# 校验项：文件非空 + 首行 sh shebang。安装源按可达性依次尝试：
#   git clone 官方仓库 → github.com 官方 master tarball（raw 域名被墙时仍可用）
#   → raw.githubusercontent.com 单文件 → get.acme.sh（要求用户显式确认）。
# 关键：最终以 $ACME_HOME/acme.sh 真实存在为准，绝不轻信中间命令的退出码
# （get.acme.sh 在网络不可达时可能退出 0 但未真正安装）。
cert_install_acme() {
  if [[ -x "$ACME_HOME/acme.sh" ]]; then
    ok "acme.sh 已安装 ($ACME_HOME/acme.sh)"
    return 0
  fi
  info "正在安装 acme.sh ..."
  local tmp; tmp=$(mktemp -d)
  local src=""

  # 方式一（首选）：git clone 官方仓库
  if command -v git >/dev/null 2>&1; then
    if git clone --depth 1 https://github.com/acmesh-official/acme.sh.git "$tmp/acme.sh-src" >/dev/null 2>&1 \
       && [[ -s "$tmp/acme.sh-src/acme.sh" ]]; then
      src="$tmp/acme.sh-src/acme.sh"
    fi
  fi

  # 方式二：github.com 官方 master tarball（github.com 可达而 raw.githubusercontent.com 被墙时兜底）
  if [[ -z "$src" ]]; then
    if curl -fsSL --retry 3 --max-time 90 -o "$tmp/acme.sh.tar.gz" \
           "https://github.com/acmesh-official/acme.sh/archive/refs/heads/master.tar.gz" \
       && gzip -t "$tmp/acme.sh.tar.gz" 2>/dev/null; then
      tar -xzf "$tmp/acme.sh.tar.gz" -C "$tmp" 2>/dev/null || true
      local d
      d=$(find "$tmp" -maxdepth 2 -type f -name acme.sh -path '*/acme.sh-master/*' 2>/dev/null | head -1 || true)
      [[ -n "$d" && -s "$d" ]] && src="$d"
    fi
  fi

  # 方式三：raw.githubusercontent.com 官方单文件
  if [[ -z "$src" ]]; then
    if curl -fsSL --retry 3 --max-time 60 -o "$tmp/acme.sh" \
           "https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh" \
       && [[ -s "$tmp/acme.sh" ]]; then
      src="$tmp/acme.sh"
    fi
  fi

  # 内容校验（供应链防护）：以上三种方式此前只校验"文件在、首行是 shebang"，无内容
  # 校验。此处统一以 GitHub API 返回的 acme.sh 官方 blob SHA1 为锚点校验实际内容，
  # 防止上游文件被劫持替换。不符则丢弃该来源（继续尝试兜底方式）；
  # 取不到官方值时仅提示降级，不静默通过。
  if [[ -n "$src" && -s "$src" ]]; then
    local acme_want acme_got
    acme_want=$(curl -fsSL --retry 2 --max-time 20 \
      "https://api.github.com/repos/acmesh-official/acme.sh/contents/acme.sh?ref=master" 2>/dev/null \
      | grep -oE '"sha": *"[0-9a-f]{40}"' | head -1 | sed -E 's/.*: *"//;s/"$//' || true)
    acme_got=$(_core_blob_sha1 "$src" 2>/dev/null || true)
    if [[ -n "$acme_want" && -n "$acme_got" ]]; then
      if [[ "$acme_got" != "$acme_want" ]]; then
        error "acme.sh 内容与官方不一致（blob SHA1 不符），已丢弃该来源（供应链安全风险）"
        src=""
      else
        ok "acme.sh 官方 blob SHA1 校验通过（${acme_got:0:12}…）"
      fi
    else
      warn "无法获取 acme.sh 官方内容校验值（GitHub API 不可达或缺少 sha1sum/shasum），沿用基础校验"
    fi
  fi

  # 统一安装：校验 shebang 后，cd 到源码目录执行自安装。
  # 注意：
  # 1. acme.sh 的 --install 内部用相对路径 cp acme.sh ...，
  #    必须在 acme.sh 所在目录执行，否则 "cannot stat acme.sh" 静默失败。
  # 2. acme.sh 安装前会 Pre-check crontab——系统无 cron 时直接拒绝安装
  #    （实测 Debian 最小化安装即如此）。先尝试装 cron；装不上则用
  #    --install --force 降级（证书可用，但无法自动续期，需手动续）。
  # 3. acme.sh 还会 Pre-check openssl（生成密钥的硬依赖，--force 无法绕过，
  #    实测 Alpine 最小化安装缺 openssl 时 Pre-check 直接拒绝）。缺失则自动安装。
  local install_args=""
  if ! command -v openssl >/dev/null 2>&1; then
    warn "系统缺少 openssl（acme.sh Pre-check 的硬依赖，用于生成密钥）。尝试安装..."
    if command -v apk >/dev/null 2>&1; then
      apk add --no-cache openssl >/dev/null 2>&1 || true
    elif command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq >/dev/null 2>&1 || true
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssl >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
      yum install -y -q openssl >/dev/null 2>&1 || true
    fi
    if command -v openssl >/dev/null 2>&1; then
      ok "openssl 已安装"
    else
      error "openssl 安装失败，acme.sh 无法安装（其 Pre-check 强制要求 openssl，且无法用 --force 绕过）。请手动安装后重试：apk add openssl / apt install openssl / yum install openssl"
      rm -rf "$tmp"; return 1
    fi
  fi
  if ! command -v crontab >/dev/null 2>&1; then
    warn "系统缺少 crontab（acme.sh 要求 cron 做自动续期，其 Pre-check 会拒绝安装）。尝试安装 cron..."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq >/dev/null 2>&1 || true
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cron >/dev/null 2>&1 || true
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache dcron >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
      yum install -y -q cronie >/dev/null 2>&1 || true
    fi
    if command -v crontab >/dev/null 2>&1; then
      ok "crontab 已安装"
      if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now cron >/dev/null 2>&1 || systemctl enable --now crond >/dev/null 2>&1 || true
      elif command -v rc-service >/dev/null 2>&1; then
        rc-update add crond default >/dev/null 2>&1 || true
        rc-service crond start >/dev/null 2>&1 || true
      fi
    else
      warn "cron 安装失败，将以 --force 安装 acme.sh（证书可用，但不会自动续期，需手动执行 sb 证书续期）"
      install_args="--force"
    fi
  fi

  if [[ -n "$src" ]] && head -1 "$src" | grep -qE '^#!.*sh'; then
    chmod +x "$src"
    (cd "$(dirname "$src")" && ./acme.sh --install $install_args >/dev/null 2>&1) || true
    if [[ ! -x "$ACME_HOME/acme.sh" ]]; then
      warn "acme.sh 源码已下载（方式一/二/三），但自安装失败（Pre-check 或运行报错被静默）。"
      warn "可在 $(dirname "$src") 下手动执行 ./acme.sh --install 查看真实报错"
    fi
  fi

  # 方式四（兜底）：get.acme.sh 安装脚本，同样先落盘校验，并要求用户确认
  if [[ ! -x "$ACME_HOME/acme.sh" ]]; then
    warn "自动安装未成功（下载或安装环节失败），改用 get.acme.sh 安装脚本（已先落盘校验，非管道直执行）"
    if core_prompt_yn "确认继续安装 acme.sh？"; then
      if curl -fsSL --retry 3 --max-time 60 -o "$tmp/acme-install.sh" "https://get.acme.sh" \
         && [[ -s "$tmp/acme-install.sh" ]] \
         && head -1 "$tmp/acme-install.sh" | grep -qE '^#!.*sh'; then
        bash "$tmp/acme-install.sh" >/dev/null 2>&1 || true
      fi
    fi
  fi

  rm -rf "$tmp"
  # 最终判定以文件真实存在为准
  if [[ ! -x "$ACME_HOME/acme.sh" ]]; then
    error "acme.sh 安装失败：$ACME_HOME/acme.sh 不存在。请检查到 github.com 的网络、以及系统是否安装了 cron/crontab（acme.sh 安装前会 Pre-check）"
    return 1
  fi
  # 注册默认 CA 为 Let's Encrypt
  "$ACME_HOME/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
  ok "acme.sh 安装完成"
}

# 把已签发证书安装到统一目录并设置权限
cert_install_files() {
  local domain=$1
  mkdir -p "$SB_DIR_SSL"
  # 根据 init 系统选择 reloadcmd：OpenRC 下 rc-service restart，systemd 下 systemctl reload
  local reload_cmd
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    reload_cmd="rc-service sing-box restart 2>/dev/null || true"
  else
    reload_cmd="systemctl is-enabled sing-box >/dev/null 2>&1 && systemctl reload sing-box || true"
  fi
  "$ACME_HOME/acme.sh" --install-cert -d "$domain" \
    --key-file      "$SB_DIR_SSL/privkey.pem" \
    --fullchain-file "$SB_DIR_SSL/fullchain.pem" \
    --reloadcmd "$reload_cmd" --ecc
  chown root:root "$SB_DIR_SSL/fullchain.pem" "$SB_DIR_SSL/privkey.pem"
  chmod 600 "$SB_DIR_SSL/fullchain.pem" "$SB_DIR_SSL/privkey.pem"
  # 精确授权：仅把 config.json 与证书两文件交给 singbox，敏感文件保持 root:root 600
  service_grant_conf
}

# 检查 acme.sh 是否已持有该域名的有效（未到期）ECC 证书。
# 返回 0=存在且可用（证书目录完整）；1=不存在/不完整（需签发）。
# 场景：重装/换验证方式时卸载保留了 acme.sh 账户与证书，acme.sh --issue 会因
# "Domains not changed. Skipping." 跳过（退出码非零）——脚本此前误判为签发失败。
# 判断依据：acme.sh 数据目录 $ACME_HOME/<domain>_ecc/ 存在且 fullchain.cer/key 齐备。
# 到期判断不依赖 --list 文本解析（多版本输出不一），直接读 conf 中的
# Le_NextRenewTimeStr（秒级时间戳）与当前时间比较；conf 缺失/解析失败则保守按
# "需重新签发"处理（避免把过期证书当有效用）。
cert_has_valid() {
  local domain=$1 d conf renew_ts now
  # 域名中的 * 与通配符在 acme.sh 目录中按字面保留，路径为 $ACME_HOME/<domain>_ecc
  d=$(printf '%s' "$domain" | tr -d '/')
  [[ -n "$d" ]] || return 1
  [[ -f "$ACME_HOME/${d}_ecc/fullchain.cer" ]] || return 1
  [[ -f "$ACME_HOME/${d}_ecc/${d}.key" ]] || return 1
  conf="$ACME_HOME/${d}_ecc/${d}.conf"
  [[ -f "$conf" ]] || return 1
  # acme.sh 的 _save_conf 写配置为 key='value' 带单引号（如 Le_NextRenewTimeStr='1700...'），
  # 正则需容忍可选引号；值本身是秒级时间戳（_time2str 生成），提取数字后比较。
  renew_ts=$(sed -n "s/^Le_NextRenewTimeStr=['\"]\?\([0-9][0-9]*\)['\"]\?.*/\1/p" "$conf" 2>/dev/null | head -1)
  if [[ -z "$renew_ts" || ! "$renew_ts" =~ ^[0-9]+$ ]]; then
    return 1   # 无法确认续期时间，保守需重签
  fi
  now=$(date +%s)
  # 若下一次续期时间在未来，说明证书仍在有效期内（acme.sh 会在到期前约 60 天续期）
  (( renew_ts > now )) || return 1
  return 0
}

# HTTP-01 签发（standalone 需要 80 空闲）。参数：domain [force]；force=1 时强制重签。
cert_issue_http01() {
  local domain=$1 force=${2:-0}
  [[ -x "$ACME_HOME/acme.sh" ]] || { error "acme.sh 未安装，请先完成安装（重新执行 sb 安装流程）"; return 1; }
  mkdir -p "$SB_DIR_SSL"
  # 重装场景：非 force 且 acme.sh 已持有同域名有效证书时直接复用，
  # 避免 --issue 因 "Domains not changed. Skipping." 跳过而被误判失败
  if [[ "$force" != "1" ]] && cert_has_valid "$domain"; then
    info "acme.sh 已持有 $domain 的有效证书，直接安装复用"
    cert_install_files "$domain"
    ok "HTTP-01 证书已安装到 $SB_DIR_SSL（复用既有证书）"
    return 0
  fi
  # 探测防火墙后端，并临时放行 80（即使端口策略选了 2/3，签发阶段也需 80 可达）
  fw_detect
  fw_open_http_temp
  info "HTTP-01 签发中（需 80 端口对外可达）: $domain"
  local args=(--issue -d "$domain" --standalone --keylength ec-256 --server letsencrypt --accountemail no@eff.org)
  [[ "$force" == "1" ]] && args+=(--force)
  if ! "$ACME_HOME/acme.sh" "${args[@]}"; then
    fw_close_http_temp
    error "HTTP-01 签发失败：请确认域名 A 记录指向本机且 80 端口对外可达"
    return 1
  fi
  fw_close_http_temp
  cert_install_files "$domain"
  ok "HTTP-01 证书已签发并安装到 $SB_DIR_SSL"
}

# DNS-01(Cloudflare) 签发（无需 80）。参数：domain token [force]；force=1 时强制重签。
cert_issue_dns01_cf() {
  local domain=$1 token=$2 force=${3:-0}
  [[ -x "$ACME_HOME/acme.sh" ]] || { error "acme.sh 未安装，请先完成安装（重新执行 sb 安装流程）"; return 1; }
  mkdir -p "$SB_DIR_SSL"
  # 持久化 CF_Token 以便续期（权限 600，仅本机；复用/重签都需写入，acme.sh cron 依赖）
  printf 'CF_Token=%s\n' "$token" > "$SB_CF_ENV"
  chmod 600 "$SB_CF_ENV"; chown root:root "$SB_CF_ENV"
  export CF_Token="$token"
  # 重装场景：非 force 且已持有同域名有效证书时复用（避免 --issue 跳过被误判失败）
  if [[ "$force" != "1" ]] && cert_has_valid "$domain"; then
    unset CF_Token
    info "acme.sh 已持有 $domain 的有效证书，直接安装复用"
    cert_install_files "$domain"
    ok "DNS-01 证书已安装到 $SB_DIR_SSL（复用既有证书，CF Token 已持久化供续期）"
    return 0
  fi
  info "DNS-01(Cloudflare) 签发中: $domain"
  local args=(--issue -d "$domain" --dns dns_cf --keylength ec-256 --server letsencrypt --accountemail no@eff.org)
  [[ "$force" == "1" ]] && args+=(--force)
  if ! "$ACME_HOME/acme.sh" "${args[@]}"; then
    unset CF_Token
    error "DNS-01 签发失败：请检查 Cloudflare API Token 是否正确且具有 Zone:DNS 编辑权限"
    return 1
  fi
  unset CF_Token
  cert_install_files "$domain"
  ok "DNS-01 证书已签发并安装到 $SB_DIR_SSL"
}

# 续期（依赖 acme.sh cron；签发时已写入 reloadcmd）
cert_renew() {
  [[ -r "$SB_CF_ENV" ]] && set -a && . "$SB_CF_ENV" && set +a
  "$ACME_HOME/acme.sh" --renew-all --ecc || "$ACME_HOME/acme.sh" --cron
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    ok "续期检查完成（acme.sh cron 会自动续期，reloadcmd 指向 rc-service sing-box restart）"
  else
    ok "续期检查完成（acme.sh cron 会自动续期，reloadcmd 指向 systemctl reload sing-box）"
  fi
}

# 变更证书配置（主页面选项 3）
cert_change() {
  local domain mode token
  if [[ ! -f "$SB_CONF" ]]; then
    error "尚未安装，请先执行安装（选项 1）"
    return 1
  fi
  # acme.sh 缺失时先安装（如上次安装 acme.sh 失败但仍继续的场景）
  [[ -x "$ACME_HOME/acme.sh" ]] || { cert_install_acme || return 1; }
  [[ -f "$SB_STATE" ]] && set -a && . "$SB_STATE" && set +a
  domain=$(core_prompt "证书域名" "${DOMAIN:-}")
  # 输入校验（安全要求）：仅允许域名合法字符，拒绝 /、&、\、空格、换行等，
  # 防止写入 .state 时破坏状态文件或被注入（本脚本以 root 运行，非提权面但属防御缺陷）。
  if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
    error "域名格式不合法：仅允许字母、数字、点、连字符"
    return 1
  fi
  echo "证书验证方式："
  echo "  [1] HTTP-01（需 80 端口 + 域名 A 记录指向本机）"
  echo "  [2] DNS-01 Cloudflare（需 CF API Token）"
  mode=$(core_prompt "选择验证方式" "1")
  # 选项 3 语义 = 变更/重签：force=1 强制 acme.sh 重新签发（即使同域名已有有效证书），
  # 与"安装复用既有证书"（sb_install 默认行为）相区分。签发失败必须中止并返回非零，
  # 不能静默继续（否则下方提示"已变更"但实际证书没更新）。
  if [[ "$mode" == "2" ]]; then
    token=$(core_prompt "Cloudflare API Token")
    cert_issue_dns01_cf "$domain" "$token" 1 || return 1
  else
    cert_issue_http01 "$domain" 1 || return 1
  fi
  # 更新 state 中的域名：不经 sed（域名已校验，字符集内无元字符），
  # 覆盖式重建文件——保留其它字段行、替换 DOMAIN 行，同目录 tmp + mv 原子写入。
  local tmp="${SB_STATE}.new.$$"
  [[ -f "$SB_STATE" ]] && grep -v '^DOMAIN=' "$SB_STATE" > "$tmp" 2>/dev/null || true
  printf 'DOMAIN=%s\n' "$domain" >> "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$SB_STATE" 2>/dev/null || { printf 'DOMAIN=%s\n' "$domain" >> "$SB_STATE"; rm -f "$tmp"; }
  service_reload
  ok "证书配置已变更并 reload"
}
