#!/usr/bin/env bash
# lib/protocol/hysteria2.sh — Hysteria2 inbound 片段生成（UDP/QUIC）
# 强制 TLS，无证书模式不可用。可选 salamander obfs（传入第4参数为 obfs 密码）。
proto_hysteria2_inbound() {
  local port=$1 pass=$2 domain=$3 obfs=${4:-} hop=${5:-}
  # sing-box 1.12+ 已移除独立的 hop_ports 字段：端口跳跃通过 listen_port 直接写范围字符串实现
  local listen="$port"
  [[ -n "$hop" ]] && listen="$hop"
  local lp_line
  if [[ -n "$hop" ]]; then
    lp_line="\"listen_port\": \"$listen\""
  else
    lp_line="\"listen_port\": $listen"
  fi
  if [[ -n "$obfs" ]]; then
    cat <<EOF
  {
    "type": "hysteria2",
    "tag": "hy2-in",
    "listen": "::",
    $lp_line,
    "obfs": { "type": "salamander", "password": "$obfs" },
    "up_mbps": 100,
    "down_mbps": 100,
    "users": [ { "name": "user1", "password": "$pass" } ],
    "tls": {
      "enabled": true,
      "server_name": "$domain",
      "certificate_path": "/etc/sing-box/ssl/fullchain.pem",
      "key_path": "/etc/sing-box/ssl/privkey.pem"
    }
  }
EOF
  else
    cat <<EOF
  {
    "type": "hysteria2",
    "tag": "hy2-in",
    "listen": "::",
    $lp_line,
    "up_mbps": 100,
    "down_mbps": 100,
    "users": [ { "name": "user1", "password": "$pass" } ],
    "tls": {
      "enabled": true,
      "server_name": "$domain",
      "certificate_path": "/etc/sing-box/ssl/fullchain.pem",
      "key_path": "/etc/sing-box/ssl/privkey.pem"
    }
  }
EOF
  fi
}
