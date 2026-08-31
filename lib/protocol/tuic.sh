#!/usr/bin/env bash
# lib/protocol/tuic.sh — TUIC v5 inbound 片段生成（UDP/QUIC）
# 强制 TLS，使用 uuid + password 双字段。
# 参数：port uuid pass domain [ge114]；ge114=1 表示 sing-box >= 1.14（启用 1.14 新增 TLS 字段）。
proto_tuic_inbound() {
  local port=$1 uuid=$2 pass=$3 domain=$4 ge114=${5:-0}
  local tls_hs=""
  [[ "$ge114" == 1 ]] && tls_hs=$'      "handshake_timeout": "8s",\n'
  cat <<EOF
  {
    "type": "tuic",
    "tag": "tuic-in",
    "listen": "::",
    "listen_port": $port,
    "users": [ { "name": "user1", "uuid": "$uuid", "password": "$pass" } ],
    "tls": {
      "enabled": true,
      "server_name": "$domain",
      "alpn": ["h3"],
${tls_hs}      "certificate_path": "/etc/sing-box/ssl/fullchain.pem",
      "key_path": "/etc/sing-box/ssl/privkey.pem"
    }
  }
EOF
}
