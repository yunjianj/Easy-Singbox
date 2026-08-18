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
AmbientCapabilities=CAP_NET_BIND_SERVICE

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
  # 让 singbox 可读证书/配置目录
  chown -R singbox:singbox "$SB_DIR_CONF" 2>/dev/null || true
}

# 将配置/证书目录交给 singbox 低权限用户读取（用户不存在时静默跳过）
service_chown_conf() {
  id singbox >/dev/null 2>&1 || return 0
  chown -R singbox:singbox "$SB_DIR_CONF" 2>/dev/null || true
}

service_install() {
  service_ensure_user
  service_write_unit
  systemctl daemon-reload
  systemctl enable sing-box
}

service_start()   {
  systemctl daemon-reload
  systemctl start sing-box
  # 重启服务后重新应用 Hysteria2 端口跳跃重定向（如已配置）
  if [[ -f "$SB_STATE" ]]; then
    set -a; . "$SB_STATE"; set +a
    [[ -n "$HOP_HY2" && -n "$PORT_HY2_LISTEN" ]] && hop_apply "$PORT_HY2_LISTEN" "$HOP_HY2"
  fi
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
