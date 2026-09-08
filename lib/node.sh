#!/usr/bin/env bash
# lib/node.sh — 节点 URI 生成
# 严禁生成订阅链接。安装完成或选“查看节点”后打印三种协议 URI，写入 nodes.txt(600)。

node_gen() {
  if [[ ! -f "$SB_STATE" ]]; then
    error "未找到配置状态文件，请先完成安装/配置（选项 1 / 2）"
    return 1
  fi
  set -a; . "$SB_STATE"; set +a

  local name="$DOMAIN"
  # 仅输出当前内核支持的协议节点（与 config_gen 的裁剪保持一致）。
  # 不支持的协议（切到旧内核时尚未适配）不生成 URI，但 .state 已保留其配置，
  # 切回支持的高版本内核时由 config_rebuild_from_state 恢复后再生成（见 DEVELOPMENT.md）。
  local sb_ver supported
  sb_ver=$(core_sb_ver 2>/dev/null) || sb_ver=""
  supported=$(core_supported_protos "$sb_ver")

  local anytls_uri="" hy2_uri="" tuic_uri=""
  if [[ " $supported " == *" anytls "* ]]; then
    anytls_uri="anytls://${PASS_ANYTLS}@${DOMAIN}:${PORT_ANYTLS}?sni=${DOMAIN}&insecure=0#${name}"
  fi
  if [[ " $supported " == *" hysteria2 "* ]]; then
    hy2_uri="hysteria2://${PASS_HY2}@${DOMAIN}:${PORT_HY2}?alpn=h3&sni=${DOMAIN}&insecure=0"
    if [[ -n "$OBS_HY2" ]]; then
      hy2_uri="${hy2_uri}&obfs=salamander:${OBS_HY2}"
    fi
    # Hysteria2 端口跳跃（mport）：sing-box 核心 inbound 不支持服务端端口跳跃（无 listen_port 范围），
    # 脚本用 nftables/iptables REDIRECT 把整个跳跃段重定向到基础监听端口，回包由 conntrack 自动还原
    # 源端口，客户端 mport 跳变完全可用（v1.0.7 曾据此移除 mport，实为误判——真正导致节点不通的
    # 是 DNS detour 崩溃，已于 v1.1.0 修复）。启用跳跃后需在云安全组放行整个 UDP 范围。
    if [[ -n "$HOP_HY2" ]]; then
      hy2_uri="${hy2_uri}&mport=${HOP_HY2}"
    fi
    hy2_uri="${hy2_uri}#${name}"
  fi
  if [[ " $supported " == *" tuic "* ]]; then
    tuic_uri="tuic://${UUID_TUIC}:${PASS_TUIC}@${DOMAIN}:${PORT_TUIC}?congestion_control=bbr&udp_relay_mode=native&sni=${DOMAIN}&alpn=h3&insecure=0#${name}"
  fi

  {
    echo "# easy-singbox 节点信息（无订阅链接，请勿分享订阅地址）"
    echo ""
    if [[ -n "$anytls_uri" ]]; then
      echo "## AnyTLS"
      echo "$anytls_uri"
      echo ""
    fi
    if [[ -n "$hy2_uri" ]]; then
      echo "## Hysteria2"
      echo "$hy2_uri"
      echo ""
    fi
    if [[ -n "$tuic_uri" ]]; then
      echo "## TUIC v5"
      echo "$tuic_uri"
      echo ""
    fi
    if [[ -n "$anytls_uri" ]]; then
      echo "## AnyTLS sing-box outbound JSON 兜底（部分客户端不识别 anytls:// 时使用）"
      cat <<JSON
{
  "type": "anytls",
  "tag": "anytls",
  "server": "$DOMAIN",
  "server_port": $PORT_ANYTLS,
  "password": "$PASS_ANYTLS",
  "tls": { "enabled": true, "server_name": "$DOMAIN", "insecure": false }
}
JSON
      echo ""
    fi
  } > "$SB_NODES"

  # umask 077 下重定向创建即为 600，保险起见显式收紧
  chmod 600 "$SB_NODES"; chown root:root "$SB_NODES"

  # 终端展示
  echo ""
  info "===== 节点信息（已写入 $SB_NODES，权限 600）====="
  echo ""
  if [[ -n "$anytls_uri" ]]; then
    echo -e "${C_CYN}## AnyTLS${C_RST}"
    echo "$anytls_uri"
    echo ""
  fi
  if [[ -n "$hy2_uri" ]]; then
    echo -e "${C_CYN}## Hysteria2${C_RST}"
    echo "$hy2_uri"
    echo ""
  fi
  if [[ -n "$tuic_uri" ]]; then
    echo -e "${C_CYN}## TUIC v5${C_RST}"
    echo "$tuic_uri"
    echo ""
  fi
  if [[ -z "$anytls_uri" && -z "$hy2_uri" && -z "$tuic_uri" ]]; then
    warn "当前内核 v${sb_ver} 不支持任何已适配协议，未生成节点（请升级内核）"
  fi
}
