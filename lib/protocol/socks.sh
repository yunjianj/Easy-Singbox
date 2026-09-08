#!/usr/bin/env bash
# lib/protocol/socks.sh — SOCKS5 inbound 片段生成（TCP，明文）
#
# 重要：sing-box 的 socks inbound 官方**不支持 tls 字段**（文档 Structure 仅有
# Listen Fields + users）。因此这是本项目**唯一不受「强制 TLS」约束**的协议：
# 握手与目标地址均为明文，可被链路识别，且无认证时等同开放代理（极易被扫描滥用）。
# 故默认生成随机用户名与密码，并在安装/节点输出处显著告警。
#
# users 为空数组或不给 users 字段 = 不认证（不推荐）。
# 参数：port [user] [pass]；user/pass 任一为空即不启用认证。
proto_socks_inbound() {
  local port=$1 user=${2:-} pass=${3:-}
  # users 块需带前导逗号：紧跟在 listen_port 之后，无认证时整块省略，
  # 避免留下 "listen_port": 1080, 的悬空逗号导致 JSON 非法。
  local users_block=""
  if [[ -n "$user" && -n "$pass" ]]; then
    users_block=$',\n    "users": [ { "username": "'"$user"'", "password": "'"$pass"'" } ]'
  fi
  cat <<EOF
  {
    "type": "socks",
    "tag": "socks-in",
    "listen": "::",
    "listen_port": $port${users_block}
  }
EOF
}
