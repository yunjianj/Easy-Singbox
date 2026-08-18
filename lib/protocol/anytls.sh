#!/usr/bin/env bash
# lib/protocol/anytls.sh — AnyTLS inbound 片段生成（TCP）
# 强制 TLS，无证书模式不可用。
proto_anytls_inbound() {
  local port=$1 pass=$2 domain=$3
  cat <<EOF
  {
    "type": "anytls",
    "tag": "anytls-in",
    "listen": "::",
    "listen_port": $port,
    "users": [ { "name": "user1", "password": "$pass" } ],
    "tls": {
      "enabled": true,
      "server_name": "$domain",
      "certificate_path": "/etc/sing-box/ssl/fullchain.pem",
      "key_path": "/etc/sing-box/ssl/privkey.pem"
    }
  }
EOF
}
