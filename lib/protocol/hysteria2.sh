#!/usr/bin/env bash
# lib/protocol/hysteria2.sh — Hysteria2 inbound 片段生成（UDP/QUIC）
# 强制 TLS，无证书模式不可用。可选 salamander obfs（传入第4参数为 obfs 密码）。
proto_hysteria2_inbound() {
  local port=$1 pass=$2 domain=$3 obfs=${4:-} hop=${5:-}
  local hop_line=""
  [[ -n "$hop" ]] && hop_line=$'\n    '"\"hop_ports\": \"$hop\","
  if [[ -n "$obfs" ]]; then
    cat <<EOF
  {
    "type": "hysteria2",
    "tag": "hy2-in",
    "listen": "::",
    "listen_port": $port,$hop_line
    "up_mbps": 100,
    "down_mbps": 100,
    "users": [ { "name": "user1", "password": "$pass" } ],
    "tls": {
      "enabled": true,
      "server_name": "$domain",
      "certificate_path": "/etc/sing-box/ssl/fullchain.pem",
      "key_path": "/etc/sing-box/ssl/privkey.pem"
    },
    "obfs": { "type": "salamander", "password": "$obfs" }
  }
EOF
  else
    cat <<EOF
  {
    "type": "hysteria2",
    "tag": "hy2-in",
    "listen": "::",
    "listen_port": $port,$hop_line
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
