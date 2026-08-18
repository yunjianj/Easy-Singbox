#!/usr/bin/env bash
# lib/service.sh — systemd 单元管理（幂等）

# 写入 systemd 单元文件（已存在则覆盖，内容固定 → 幂等）
service_write_unit() {
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

# 创建专用低权限用户（幂等）
service_ensure_user() {
  if ! id singbox >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin singbox 2>/dev/null || \
    useradd --system --no-create-home singbox 2>/dev/null || true
  fi
}

# 服务运行用户精确授权：仅 config.json 与证书两文件交给 singbox；
# .cf.env / .state / nodes.txt / diag.log 必须保持 root:root 600，
# 绝不交给 singbox（进程沦陷时不得泄漏 CF Token 与全部节点凭证）。
service_grant_conf() {
  id singbox >/dev/null 2>&1 || return 0
  chown singbox:singbox "$SB_DIR_CONF" 2>/dev/null || true
  chmod 755 "$SB_DIR_CONF" 2>/dev/null || true
  for f in "$SB_CONF" "$SB_DIR_SSL/fullchain.pem" "$SB_DIR_SSL/privkey.pem"; do
    [[ -f "$f" ]] && chown singbox:singbox "$f" 2>/dev/null || true
  done
  # 敏感文件强制回到 root:root 600（修复历史安装中被 chown -R 污染的存量机器）
  for f in "$SB_STATE" "$SB_NODES" "$SB_CF_ENV" "$SB_DIR_CONF/diag.log"; do
    [[ -f "$f" ]] && { chown root:root "$f" 2>/dev/null || true; chmod 600 "$f" 2>/dev/null || true; }
  done
  chmod 755 "$SB_DIR_SSL" 2>/dev/null || true
}

# 将配置/证书目录按最小权限模型交给 singbox（保留函数名，调用点无需改动）
service_chown_conf() {
  service_grant_conf
}

service_install() {
  service_ensure_user
  service_write_unit
  systemctl daemon-reload
  systemctl enable sing-box
}

service_start()   {
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
    journalctl -u sing-box -n 40 --no-pager >&2 || true
    warn "可执行 sb → 选项 9 生成完整诊断报告"
    return 1
  fi
  return 0
}

service_stop()    { systemctl stop sing-box 2>/dev/null || true; }
service_restart() { systemctl daemon-reload; systemctl restart sing-box; }
service_reload()  { systemctl reload sing-box 2>/dev/null || systemctl restart sing-box; }
service_disable() { systemctl disable sing-box 2>/dev/null || true; }

service_is_active() { systemctl is-active --quiet sing-box 2>/dev/null; }

# 卸载时清理单元
service_remove_unit() {
  systemctl stop sing-box 2>/dev/null || true
  systemctl disable sing-box 2>/dev/null || true
  rm -f "$SB_SERVICE"
  systemctl daemon-reload 2>/dev/null || true
}
