#!/usr/bin/env bash
# lib/config.sh — 生成 config.json（三协议共存）并保存状态文件

# 生成完整 config.json + .state；参数：
# domain port_any port_hy2 port_tuic pass_any pass_hy2 pass_tuic uuid_tuic [obfs_hy2] [hop_hy2]
# hop_hy2: Hysteria2 端口跳跃段（如 50001-51000），留空则不启用跳跃
config_gen() {
  local domain=$1 port_any=$2 port_hy2=$3 port_tuic=$4 \
        pass_any=$5 pass_hy2=$6 pass_tuic=$7 uuid_tuic=$8 \
        obfs_hy2=${9:-} hop_hy2=${10:-${HOP_HY2:-}}

  # Hy2 实际监听端口：始终为基础整数端口（sing-box 要求 uint16，核心不支持服务端端口跳跃）。
  # 节点 URI 的 server_port 始终用基础端口 port_hy2（真实监听端口），
  # 范围通过 mport 携带（官方出站字段为 server_ports）。服务端跳跃由 lib/port_hop.sh
  # 的 REDIRECT 把范围转发到该基础端口实现，故“只放行基础端口”也能连，
  # 客户端跳跃需额外在外部防火墙/安全组放行整个范围。
  local hy2_listen="$port_hy2" port_hy2_node="$port_hy2"

  # 端口不可重复（P2 约束）
  if [[ "$port_any" == "$port_hy2" || "$port_any" == "$port_tuic" || "$port_hy2" == "$port_tuic" ]]; then
    error "三个协议端口不能重复（anytls=$port_any hy2=$port_hy2 tuic=$port_tuic）"
    return 1
  fi
  # Hysteria2 跳跃段即 Hy2 监听端口，故仅检查与 anytls / tuic 固定监听端口是否重叠
  if [[ -n "$hop_hy2" ]]; then
    local hlo hhi
    hlo=${hop_hy2%-*}; hhi=${hop_hy2#*-}
    if (( port_any >= hlo && port_any <= hhi )) || \
       (( port_tuic >= hlo && port_tuic <= hhi )); then
      error "Hysteria2 跳跃段 $hop_hy2 与某个监听端口重叠，请更换端口或跳跃段"
      return 1
    fi
  fi

  mkdir -p "$SB_DIR_CONF" "$SB_DIR_SSL"

  {
    printf '{\n'
    printf '  "log": { "level": "info", "timestamp": true },\n'
    printf '  "inbounds": [\n'
    proto_anytls_inbound "$port_any" "$pass_any" "$domain"
    printf ',\n'
    proto_hysteria2_inbound "$hy2_listen" "$pass_hy2" "$domain" "$obfs_hy2"
    printf ',\n'
    proto_tuic_inbound "$port_tuic" "$uuid_tuic" "$pass_tuic" "$domain"
    printf '\n  ],\n'
    # 注意：DoH(https) DNS 服务器不能带 "detour": "direct" —— sing-box 运行期会报
    # FATAL "detour to an empty direct outbound makes no sense" 直接崩溃（check 却能通过）。
    # 留空 detour 即走默认出站（此处 route.final=direct），行为一致且不会崩。
    printf '  "dns": { "servers": [ { "tag": "remote", "type": "https", "server": "1.1.1.1" } ], "final": "remote" },\n'
    printf '  "outbounds": [ { "type": "direct", "tag": "direct" } ],\n'
    printf '  "route": { "final": "direct" }\n'
    printf '}\n'
  } > "$SB_CONF"

  chmod 600 "$SB_CONF"; chown root:root "$SB_CONF" 2>/dev/null || true

  # 状态文件（节点 URI 生成依赖，权限 600）
  cat > "$SB_STATE" <<EOF
DOMAIN=$domain
PORT_ANYTLS=$port_any
PORT_HY2=$port_hy2_node
PORT_HY2_LISTEN=$port_hy2
PORT_TUIC=$port_tuic
PASS_ANYTLS=$pass_any
PASS_HY2=$pass_hy2
PASS_TUIC=$pass_tuic
UUID_TUIC=$uuid_tuic
OBS_HY2=$obfs_hy2
HOP_HY2=$hop_hy2
EOF
  chmod 600 "$SB_STATE"; chown root:root "$SB_STATE" 2>/dev/null || true

  # 清空旧的端口跳跃重定向规则（幂等）
  hop_remove

  # 校验配置
  if ! "$SB_BIN" check -c "$SB_CONF"; then
    error "config.json 校验失败，请检查配置"
    return 1
  fi
  # 降权运行：让 singbox 用户可读配置/证书
  service_chown_conf
  # 应用 Hysteria2 端口跳跃（服务端 REDIRECT；无跳跃则仅清理旧规则）
  if [[ -n "$hop_hy2" ]]; then
    hop_apply "$port_hy2" "$hop_hy2"
  fi
  ok "config.json 已生成并通过 sing-box check"
}

# 变更代理配置（主页面选项 2）
config_change() {
  if [[ ! -f "$SB_CONF" ]]; then
    error "尚未安装，请先执行安装（选项 1）"
    return 1
  fi
  [[ -f "$SB_STATE" ]] && set -a && . "$SB_STATE" && set +a

  local domain port_any port_hy2 port_tuic pass_any pass_hy2 pass_tuic uuid_tuic obfs hop
  domain=$(core_prompt "节点域名" "${DOMAIN:-}")
  port_any=$(core_prompt "AnyTLS 端口" "${PORT_ANYTLS:-$(core_rand_port)}")
  port_hy2=$(core_prompt "Hysteria2 端口" "${PORT_HY2:-$(core_rand_port)}")
  port_tuic=$(core_prompt "TUIC 端口" "${PORT_TUIC:-$(core_rand_port)}")
  pass_any=$(core_prompt  "AnyTLS 密码" "${PASS_ANYTLS:-$(core_rand_pass)}")
  pass_hy2=$(core_prompt  "Hysteria2 密码" "${PASS_HY2:-$(core_rand_pass)}")
  pass_tuic=$(core_prompt "TUIC 密码" "${PASS_TUIC:-$(core_rand_pass)}")
  uuid_tuic=$(core_prompt "TUIC UUID" "${UUID_TUIC:-$(core_rand_uuid)}")
  obfs=$(core_prompt "Hysteria2 obfs 密码(留空关闭)" "${OBS_HY2:-}")
  hop=$(core_prompt "Hysteria2 端口跳跃段(如 50001-51000，留空关闭)" "${HOP_HY2:-}")

  config_gen "$domain" "$port_any" "$port_hy2" "$port_tuic" \
             "$pass_any" "$pass_hy2" "$pass_tuic" "$uuid_tuic" "$obfs" "$hop"
  service_reload
  ok "代理配置已变更并 reload"
  node_gen
}
