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
#   - UDP ASSOCIATE 握手本身能成功，但**转发端口不是 listen_port**：
#     sing 库 protocol/socks/handshake.go 处理 CommandUDPAssociate 时调
#     Listener.ListenPacket(..., M.SocksaddrFrom(addr, 0))，端口写死 0 →
#     内核从 net.ipv4.ip_local_port_range 里分配一个**随机高位端口**（每次会话都变），
#     再把这个随机端口写进 SOCKS5 reply 的 BND.ADDR:BND.PORT 告诉客户端。
#     Listener.ListenPacket 直接用传入的 address bind，不参考 listen_port，
#     且配置里没有任何字段能钉死它。
#   => 结论：
#      1) 启动态只有 tcp 是确定保证 → 端口校验（service_verify_ports）只查 tcp，
#         静态 ss 检测不到 udp 属正常，不能据此判失败（历史上就是这么误报的）。
#      2) SOCKS5 的 UDP 转发要穿透云安全组，必须放行**整个临时端口范围**
#         （如 32768-60999），只放行 listen_port 无效。所以本脚本不为 socks
#         放行 udp（放的是空规则），需要 UDP 的流量请走 Hysteria2 / TUIC。
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
