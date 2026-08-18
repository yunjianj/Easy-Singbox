#!/usr/bin/env bash
# lib/cert.sh — 证书管理（acme.sh 自动申请 Let's Encrypt）
# 仅支持脚本自动申请，不支持手动上传。HTTP-01 / DNS-01(Cloudflare)。

# 安装 acme.sh（幂等）
# 供应链防护：不再 `curl ... | sh` 盲执行远程脚本，改为“先落盘、再校验、后执行”。
# 校验项：文件非空 + 首行 sh shebang。优先 git clone 官方仓库，其次下载官方 master
# 单文件本地执行，最后才退回 get.acme.sh（此时要求用户显式确认）。
cert_install_acme() {
  if [[ -x "$ACME_HOME/acme.sh" ]]; then
    ok "acme.sh 已安装 ($ACME_HOME/acme.sh)"
    return 0
  fi
  info "正在安装 acme.sh ..."
  local tmp; tmp=$(mktemp -d)
  local installed=0

  # 方式一（首选）：git clone 官方仓库到本地后再安装
  if command -v git >/dev/null 2>&1; then
    if git clone --depth 1 https://github.com/acmesh-official/acme.sh.git "$tmp/acme.sh-src" >/dev/null 2>&1 \
       && [[ -s "$tmp/acme.sh-src/acme.sh" ]] \
       && head -1 "$tmp/acme.sh-src/acme.sh" | grep -qE '^#!.*sh'; then
      (cd "$tmp/acme.sh-src" && ./acme.sh --install >/dev/null 2>&1) && installed=1
    fi
  fi

  # 方式二：下载官方 master 单文件，落盘校验后本地执行（acme.sh 支持自安装）
  if [[ $installed -eq 0 ]]; then
    if curl -fsSL --retry 3 --max-time 60 -o "$tmp/acme.sh" \
           "https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh" \
       && [[ -s "$tmp/acme.sh" ]] \
       && head -1 "$tmp/acme.sh" | grep -qE '^#!.*sh'; then
      chmod +x "$tmp/acme.sh"
      "$tmp/acme.sh" --install >/dev/null 2>&1 && installed=1
    fi
  fi

  # 方式三（兜底）：get.acme.sh 安装脚本，同样先落盘校验，并要求用户确认
  if [[ $installed -eq 0 ]]; then
    warn "官方仓库/文件下载失败，改用 get.acme.sh 安装脚本（已先落盘校验，非管道直执行）"
    if core_prompt_yn "确认继续安装 acme.sh？"; then
      if curl -fsSL --retry 3 --max-time 60 -o "$tmp/acme-install.sh" "https://get.acme.sh" \
         && [[ -s "$tmp/acme-install.sh" ]] \
         && head -1 "$tmp/acme-install.sh" | grep -qE '^#!.*sh'; then
        bash "$tmp/acme-install.sh" >/dev/null 2>&1 && installed=1
      fi
    fi
  fi

  rm -rf "$tmp"
  if [[ $installed -eq 0 ]]; then
    error "acme.sh 安装失败，请检查网络后重试"
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
  "$ACME_HOME/acme.sh" --install-cert -d "$domain" \
    --key-file      "$SB_DIR_SSL/privkey.pem" \
    --fullchain-file "$SB_DIR_SSL/fullchain.pem" \
    --reloadcmd "systemctl is-enabled sing-box >/dev/null 2>&1 && systemctl reload sing-box || true" --ecc
  chown root:root "$SB_DIR_SSL/fullchain.pem" "$SB_DIR_SSL/privkey.pem"
  chmod 600 "$SB_DIR_SSL/fullchain.pem" "$SB_DIR_SSL/privkey.pem"
  # 精确授权：仅把 config.json 与证书两文件交给 singbox，敏感文件保持 root:root 600
  service_grant_conf
}

# HTTP-01 签发（standalone 需要 80 空闲）
cert_issue_http01() {
  local domain=$1
  mkdir -p "$SB_DIR_SSL"
  # 探测防火墙后端，并临时放行 80（即使端口策略选了 2/3，签发阶段也需 80 可达）
  fw_detect
  fw_open_http_temp
  info "HTTP-01 签发中（需 80 端口对外可达）: $domain"
  if ! "$ACME_HOME/acme.sh" --issue -d "$domain" --standalone --keylength ec-256 --server letsencrypt --accountemail no@eff.org; then
    fw_close_http_temp
    error "HTTP-01 签发失败：请确认域名 A 记录指向本机且 80 端口对外可达"
    return 1
  fi
  fw_close_http_temp
  cert_install_files "$domain"
  ok "HTTP-01 证书已签发并安装到 $SB_DIR_SSL"
}

# DNS-01(Cloudflare) 签发（无需 80）
cert_issue_dns01_cf() {
  local domain=$1 token=$2
  mkdir -p "$SB_DIR_SSL"
  # 持久化 CF_Token 以便续期（权限 600，仅本机）
  printf 'CF_Token=%s\n' "$token" > "$SB_CF_ENV"
  chmod 600 "$SB_CF_ENV"; chown root:root "$SB_CF_ENV"
  export CF_Token="$token"
  info "DNS-01(Cloudflare) 签发中: $domain"
  if ! "$ACME_HOME/acme.sh" --issue -d "$domain" --dns dns_cf --keylength ec-256 --server letsencrypt --accountemail no@eff.org; then
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
  ok "续期检查完成（acme.sh cron 会自动续期，reloadcmd 指向 systemctl reload sing-box）"
}

# 变更证书配置（主页面选项 3）
cert_change() {
  local domain mode token
  if [[ ! -f "$SB_CONF" ]]; then
    error "尚未安装，请先执行安装（选项 1）"
    return 1
  fi
  [[ -f "$SB_STATE" ]] && set -a && . "$SB_STATE" && set +a
  domain=$(core_prompt "证书域名" "${DOMAIN:-}")
  echo "证书验证方式："
  echo "  [1] HTTP-01（需 80 端口 + 域名 A 记录指向本机）"
  echo "  [2] DNS-01 Cloudflare（需 CF API Token）"
  mode=$(core_prompt "选择验证方式" "1")
  if [[ "$mode" == "2" ]]; then
    token=$(core_prompt "Cloudflare API Token")
    cert_issue_dns01_cf "$domain" "$token"
  else
    cert_issue_http01 "$domain"
  fi
  # 更新 state 中的域名
  sed -i "s/^DOMAIN=.*/DOMAIN=$domain/" "$SB_STATE" 2>/dev/null || \
    printf 'DOMAIN=%s\n' "$domain" >> "$SB_STATE"
  service_reload
  ok "证书配置已变更并 reload"
}
