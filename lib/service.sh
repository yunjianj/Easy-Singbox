#!/usr/bin/env bash
# lib/service.sh — 服务单元管理（systemd / OpenRC 双 init 适配，幂等）
# 依赖 lib/init.sh 提供的 INIT_SYSTEM 变量；所有函数签名与 systemd 时代保持一致。

# 写入服务单元文件（已存在则覆盖，内容固定 → 幂等）
service_write_unit() {
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    service_write_openrc_unit
    return
  fi
  cat > "$SB_SERVICE" <<'EOF'
[Unit]
Description=sing-box service
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
ExecStartPre=/usr/local/bin/sing-box check -c /etc/sing-box/config.json
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=always
RestartSec=5
LimitNOFILE=100000
# 降权运行：以非 root 用户运行（端口均为高位随机，无需 CAP_NET_BIND_SERVICE）
User=singbox
Group=singbox
# 最小加固（纯收紧，不改变运行行为）：sing-box 不写本地路径，日志走 stdout/journald
NoNewPrivileges=true
ProtectSystem=strict
ReadOnlyPaths=/etc/sing-box
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
}

# 生成 OpenRC init 脚本（Alpine）
# 使用 supervise-daemon 实现崩溃自动重启（respawn_max=0 等价 systemd Restart=always）。
# 注意：不写 need net——Alpine 无名为 net 的服务（networking 才提供虚拟 net），
# 且多数场景无需显式网络依赖，避免启动流程被依赖解析卡住。
service_write_openrc_unit() {
  cat > "$SB_SERVICE" <<'OPENRC_EOF'
#!/sbin/openrc-run
# OpenRC init script for sing-box
# Managed by easy-singbox — do not edit manually

description="sing-box service"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
supervise_daemon_args="--user singbox --group singbox --stdout /var/log/sing-box/sing-box.log --stderr /var/log/sing-box/sing-box.log"
pidfile="/run/sing-box.pid"
respawn_delay=5
respawn_max=0
rc_ulimit="-n 100000"

depend() {
  after firewall
}

start_pre() {
  checkpath -d -m 0755 -o singbox:singbox /var/log/sing-box
  "$command" check -c /etc/sing-box/config.json || return 1
}
OPENRC_EOF
  chmod 755 "$SB_SERVICE"
}

# 创建专用低权限用户（幂等）
service_ensure_user() {
  if ! id singbox >/dev/null 2>&1; then
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
      # BusyBox adduser：先确保同名组存在（BusyBox 默认不一定创建 singbox 组，
      # 缺失会导致后续 chown singbox:singbox 静默失败、敏感文件滞留 root 属主）。
      addgroup -S singbox 2>/dev/null || true
      adduser -S -H -s /sbin/nologin -D -G singbox singbox 2>/dev/null || \
      adduser -S -H -s /sbin/nologin -G singbox singbox 2>/dev/null || \
      adduser -S -H -G singbox singbox 2>/dev/null || true
    else
      useradd --system --no-create-home --shell /usr/sbin/nologin singbox 2>/dev/null || \
      useradd --system --no-create-home singbox 2>/dev/null || true
    fi
  fi
  # 兜底：无论用户是否新建，都确保 singbox 组存在（openrc 下 chown user:group 依赖它）
  if [[ "$INIT_SYSTEM" == "openrc" ]] && ! getent group singbox >/dev/null 2>&1; then
    addgroup -S singbox 2>/dev/null || true
  fi
}

# 服务运行用户精确授权：仅 config.json 与证书两文件交给 singbox；
# .cf.env / .state / nodes.txt / diag.log 必须保持 root:root 600，
# 绝不交给 singbox（进程沦陷时不得泄漏 CF Token 与全部节点凭证）。
service_grant_conf() {
  id singbox >/dev/null 2>&1 || return 0
  chown singbox:singbox "$SB_DIR_CONF" 2>/dev/null || chown singbox "$SB_DIR_CONF" 2>/dev/null || true
  chmod 755 "$SB_DIR_CONF" 2>/dev/null || true
  for f in "$SB_CONF" "$SB_DIR_SSL/fullchain.pem" "$SB_DIR_SSL/privkey.pem"; do
    if [[ -f "$f" ]]; then
      # 组缺失（BusyBox 常见）时降级为仅设属主，确保 singbox 至少能读
      chown singbox:singbox "$f" 2>/dev/null || chown singbox "$f" 2>/dev/null || true
    fi
  done
  # 敏感文件强制回到 root:root 600（修复历史安装中被 chown -R 污染的存量机器）
  for f in "$SB_STATE" "$SB_NODES" "$SB_CF_ENV" "$SB_DIR_CONF/diag.log"; do
    [[ -f "$f" ]] && { chown root:root "$f" 2>/dev/null || true; chmod 600 "$f" 2>/dev/null || true; }
  done
  chmod 755 "$SB_DIR_SSL" 2>/dev/null || true

  # 自检：确认 singbox 确实可读 config.json——否则上述 chown 静默失败会让
  # 服务启动时报 "open config.json: permission denied"，此处在安装期直接暴露。
  if [[ -f "$SB_CONF" ]]; then
    local ok=0
    if command -v runuser >/dev/null 2>&1 && runuser -u singbox -- test -r "$SB_CONF" 2>/dev/null; then ok=1; fi
    if [[ $ok -eq 0 ]] && su -s /bin/sh singbox -c "test -r '$SB_CONF'" 2>/dev/null; then ok=1; fi
    if [[ $ok -eq 0 ]]; then
      warn "singbox 用户无法读取 $SB_CONF（属主/组或权限异常），服务将启动失败。"
      warn "请手动执行：chown singbox:singbox $SB_CONF && chmod 600 $SB_CONF"
    fi
  fi
}

# 将配置/证书目录按最小权限模型交给 singbox（保留函数名，调用点无需改动）
service_chown_conf() {
  service_grant_conf
}

service_install() {
  service_ensure_user
  service_write_unit
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    rc-update add sing-box default 2>/dev/null || true
    # acme.sh 续期依赖 cron；Alpine 需确保 cron 已安装并运行（仅提示，不强制）
    if ! rc-service crond status 2>/dev/null | grep -qw started; then
      warn "cron 服务未运行，acme.sh 证书将无法自动续期。请安装并启动：apk add dcron && rc-update add crond default && rc-service crond start"
    fi
  else
    systemctl daemon-reload
    systemctl enable sing-box
  fi
}

service_start() {
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    service_start_openrc
    return
  fi
  systemctl daemon-reload
  # systemctl start 仅表示 systemd 接受了启动请求，不保证进程真的起来；
  # 用 || true 避免 set -e 在 start 失败时直接中止，以便下方健康检查能打印真实日志。
  systemctl start sing-box 2>/dev/null || true
  # 重启服务后重新应用 Hysteria2 端口跳跃重定向（如已配置）
  if [[ -f "$SB_STATE" ]]; then
    set -a; . "$SB_STATE"; set +a
    [[ -n "$HOP_HY2" && -n "$PORT_HY2_LISTEN" ]] && hop_apply "$PORT_HY2_LISTEN" "$HOP_HY2"
  fi
  # 健康检查：等待服务真正 active（最多 15s），否则打印日志并失败，避免“假成功”
  local i
  for i in $(seq 1 15); do
    systemctl is-active --quiet sing-box && break
    sleep 1
  done
  if ! systemctl is-active --quiet sing-box; then
    error "sing-box 服务未能启动，节点将无法连接。最近日志："
    journalctl -u sing-box -n 30 --no-pager >&2 || true
    return 1
  fi
  ok "sing-box 服务已启动并运行"
}

service_start_openrc() {
  # 不吞掉 OpenRC 的 [ ok ]/[ !! ] 标记，方便观察启动结果
  rc-service sing-box start || true
  # 重新应用端口跳跃（与 systemd 分支一致）
  if [[ -f "$SB_STATE" ]]; then
    set -a; . "$SB_STATE"; set +a
    [[ -n "$HOP_HY2" && -n "$PORT_HY2_LISTEN" ]] && hop_apply "$PORT_HY2_LISTEN" "$HOP_HY2"
  fi
  # 健康检查：等待服务起来（最多 15s），否则打印日志并失败
  local i
  for i in $(seq 1 15); do
    rc-service sing-box status 2>/dev/null | grep -qw started && break
    sleep 1
  done
  if ! rc-service sing-box status 2>/dev/null | grep -qw started; then
    error "sing-box 服务未能启动，节点将无法连接。"
    info "服务状态: $(rc-service sing-box status 2>/dev/null || true)"
    info "init 脚本: $SB_SERVICE"
    error "最近日志（$SB_LOG_FILE）："
    if [[ -s "$SB_LOG_FILE" ]]; then
      tail -n 30 "$SB_LOG_FILE" >&2 2>/dev/null || true
    else
      warn "日志文件为空。请手动前台运行以查看真实报错："
      warn "  su -s /bin/sh singbox -c '/usr/local/bin/sing-box run -c /etc/sing-box/config.json'"
    fi
    return 1
  fi
  ok "sing-box 服务已启动并运行"
}

# 校验三协议端口是否真的处于监听状态。参数：port_any(tcp) port_hy2(udp) port_tuic(udp)
# 服务 active 只代表进程活着，不代表端口 bind 成功（如端口被占用时 sing-box 会退出重启）。
# 客户端报 "connection refused" 的直接原因就是此处无监听，故安装/变更后必须显式校验。
service_verify_ports() {
  local pa=$1 ph=$2 pt=$3 bad=0 tcp udp
  if ! command -v ss >/dev/null 2>&1; then
    warn "未安装 ss(iproute2)，跳过端口监听校验"
    return 0
  fi
  # 各协议只列一次，纯 bash 精确匹配（不依赖 ss 过滤器语法）
  tcp=$(core_listening_ports tcp)
  udp=$(core_listening_ports udp)
  if [[ "$tcp" == *" $pa "* ]]; then ok "AnyTLS 监听正常 tcp/$pa"; else error "AnyTLS 未监听 tcp/$pa"; bad=1; fi
  if [[ "$udp" == *" $ph "* ]]; then ok "Hysteria2 监听正常 udp/$ph"; else error "Hysteria2 未监听 udp/$ph"; bad=1; fi
  if [[ "$udp" == *" $pt "* ]]; then ok "TUIC 监听正常 udp/$pt"; else error "TUIC 未监听 udp/$pt"; bad=1; fi
  if (( bad )); then
    error "存在未监听的端口，客户端会报 connection refused。最近日志："
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
      tail -n 40 /var/log/sing-box/sing-box.log >&2 2>/dev/null || true
    else
      journalctl -u sing-box -n 40 --no-pager >&2 || true
    fi
    warn "可执行 sb → 选项 9 生成完整诊断报告"
    return 1
  fi
  return 0
}

service_stop() {
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    rc-service sing-box stop 2>/dev/null || true
  else
    systemctl stop sing-box 2>/dev/null || true
  fi
}

service_restart() {
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    rc-service sing-box restart 2>/dev/null || true
  else
    systemctl daemon-reload
    systemctl restart sing-box
  fi
}

service_reload() {
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    # OpenRC 的 reload 发 SIGHUP，sing-box 不支持热重载，restart 等价
    rc-service sing-box restart 2>/dev/null || true
  else
    systemctl reload sing-box 2>/dev/null || systemctl restart sing-box
  fi
}

service_disable() {
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    rc-update del sing-box default 2>/dev/null || true
  else
    systemctl disable sing-box 2>/dev/null || true
  fi
}

# 服务是否运行；参数可选（默认 sing-box），供 firewalld 等其它服务探测复用
service_is_active() {
  local svc=${1:-sing-box}
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    rc-service "$svc" status 2>/dev/null | grep -qw started
  else
    systemctl is-active --quiet "$svc" 2>/dev/null
  fi
}

# 卸载时清理单元
service_remove_unit() {
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    rc-service sing-box stop 2>/dev/null || true
    rc-update del sing-box default 2>/dev/null || true
    rm -f "$SB_SERVICE"
  else
    systemctl stop sing-box 2>/dev/null || true
    systemctl disable sing-box 2>/dev/null || true
    rm -f "$SB_SERVICE"
    systemctl daemon-reload 2>/dev/null || true
  fi
}
