#!/usr/bin/env bash
# lib/protocol/socks.sh — SOCKS5 inbound 片段生成（明文）
#
# 重要：sing-box 的 socks inbound 官方**不支持 tls 字段**（文档 Structure 仅有
# Listen Fields + users）。因此这是本项目**唯一不受「强制 TLS」约束**的协议：
# 握手与目标地址均为明文，可被链路识别，且无认证时等同开放代理（极易被扫描滥用）。
# 故默认生成随机用户名与密码，并在安装/节点输出处显著告警。
#
# 监听行为（sing-box 1.14 源码实证，勿再用旧认知判断）：
#   - 启动时 protocol/socks/inbound.go 里 Network: []string{N.NetworkTCP}，
#     **只 bind TCP**（日志只有 "tcp server started at ..."），1.13 起 legacy
#     inbound 的 network 字段已移除，无法在配置里要求它同时监听 UDP。
#   - 但 UDP ASSOCIATE **仍然可用**：客户端发来 UDP ASSOCIATE 时，sing 库的
#     HandleConnectionEx 才调 Listener.ListenPacket，在**同一端口**懒绑定一个
#     UDP 套接字（该方法不校验 Network 白名单），并回 success；该 UDP 会话随
#     控制 TCP 连接关闭而销毁。
#   => 结论：启动态只有 tcp 是确定保证，udp 要等客户端发起 UDP ASSOCIATE 才出现，
#      所以**静态 ss 检测不到 udp 属正常，不能据此判失败**（历史上就是这么误报的）。
#      端口校验（service_verify_ports）只查 tcp；防火墙仍需 tcp+udp 都放行，
#      否则客户端一旦用 UDP ASSOCIATE 就会失败。
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
