#!/usr/bin/env bash
# lib/protocol/tuic.sh — TUIC v5 inbound 片段生成（UDP/QUIC）
# 强制 TLS，使用 uuid + password 双字段。
# 参数：port uuid pass domain。v1.5.0 起只适配基线大版本（SB_VER_BASE=1.14），
# 恒输出该大版本最新语法字段（如 handshake_timeout），不再有多版本分支。
proto_tuic_inbound() {
  local port=$1 uuid=$2 pass=$3 domain=$4
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
      "handshake_timeout": "8s",
      "certificate_path": "/etc/sing-box/ssl/fullchain.pem",
      "key_path": "/etc/sing-box/ssl/privkey.pem"
    }
  }
EOF
}
