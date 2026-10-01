#!/usr/bin/env bash
# 面板宽度回归测试：模拟各种终端宽度渲染面板，断言「没有任何一行超出终端宽度」。
# 这是安卓端截断问题的核心不变量——只要有一行超宽，终端就会软换行并把面板顶出屏幕。
export LC_ALL=C.UTF-8
cd "$(dirname "$0")" || exit 1
source lib/core.sh

C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_CYN=""; C_BOLD=""; C_RST=""

# 与 sb 中 sb_show_menu 的渲染逻辑保持一致的模拟实现
render_panel() {
  local os="Debian GNU/Linux 13 (trixie)"
  local arch_disp="amd64 (AES-NI: 支持)"
  local virt="kvm" bbr="未开启 (cubic)"
  local inst="已安装" running="已运行" ver="1.14.2" proto=2
  local nv="1.5.9" SB_VER_BASE="1.14"

  ui_banner "easy-singbox  管理面板" "v1.5.5"
  ui_field "系统"     "$os"
  ui_field "指令集"   "$arch_disp"
  ui_field "虚拟化"   "$virt"
  ui_field "BBR / FQ" "$bbr"
  ui_field "IP / 地区" ""
  local uw ind lw line; uw=$(core_term_width); (( uw > 62 )) && uw=62
  for line in "IPv4 103.27.77.117 | Hong Kong/Hong Kong / NetLab Global" \
             "IPv6 不支持（本机无公网 IPv6）"; do
    lw=$(core_dwidth "$line")
    ind=13
    (( ind + lw > uw - 1 )) && ind=$(( uw - 1 - lw ))
    (( ind < 1 )) && ind=1
    printf '%*s%s\n' "$ind" "" "$(core_dcut "$line" $(( uw - ind )))"
  done
  ui_field "Sing-Box" "$inst / $running  v$ver  ($proto 协议在线)"
  # 低版本告警路径
  if ! core_ver_ge "$ver" "$SB_VER_BASE"; then
    local wmsg="[内核版本过低：本脚本需 sing-box ${SB_VER_BASE}.x，请执行选项 7 升级]"
    if (( $(core_dwidth "$wmsg") <= uw - 11 )); then
      ui_note "" "$wmsg" 15
    else
      ui_note "" "[内核版本过低]" 15
      ui_note "" "需 sing-box ${SB_VER_BASE}.x，请执行选项 7 升级" 15
    fi
  fi
  # 「脚本版本 : v1.5.5  [发现新版本 ...]」必须同行（v1.5.6 修复换行回退）
  ui_field_note "脚本版本" "v1.5.5" "" "[发现新版本 v${nv}，可执行选项 8 更新]"
  ui_field_note "脚本版本" "v1.5.5" "" "[已是最新]"
  ui_field_note "脚本版本" "v1.5.5" "" "[远程版本未知，请检查网络]"
  ui_rule "-" 62
  ui_item 1  "卸载 Sing-Box"        ""
  ui_item 2  "变更代理配置"         "协议 / 端口 / 凭证"
  ui_item 3  "变更证书配置"         "HTTP-01 / DNS-01 / 重签"
  ui_item 4  "启动 Sing-Box"        ""
  ui_item 5  "停止 Sing-Box"        ""
  ui_item 6  "重启 / 查看节点"      "reload + 打印节点"
  ui_item 7  "升级内核版本"         "适配 sing-box ${SB_VER_BASE}.x，升到最新补丁"
  ui_item 8  "更新脚本"             "当前 v1.5.5"
  ui_item 9  "诊断与日志"           "排查节点不通，生成可发送的报告"
  ui_item 10 "BBR + FQ 拥塞控制"    "一键启用 / 禁用，独立于 sing-box"
  ui_item 0  "退出"                 ""
  ui_rule "=" 62
}

fail=0
for W in 20 24 30 35 40 45 50 55 60 62 72 80 100 120; do
  out=$(COLUMNS=$W render_panel)
  maxw=0; nlines=0
  while IFS= read -r l; do
    d=$(core_dwidth "$l")
    (( d > maxw )) && maxw=$d
    nlines=$(( nlines + 1 ))
  done <<< "$out"
  # 面板自身上限 62；终端窄时横线应收窄到终端宽
  limit=$W; (( limit > 62 )) && limit=62
  status="OK "
  if (( maxw > limit )); then status="FAIL"; fail=1; fi
  printf '[%s] COLUMNS=%-4s 行数=%-3s 最宽行=%-3s 上限=%-3s\n' \
    "$status" "$W" "$nlines" "$maxw" "$limit"
  if [[ "$status" == "FAIL" ]]; then
    while IFS= read -r l; do
      d=$(core_dwidth "$l")
      (( d > limit )) && printf '        超宽(%d): %s\n' "$d" "$l"
    done <<< "$out"
  fi
  # 同行断言：脚本版本的值与状态注记必须同行显示（v1.5.6 修复换行观感回退）
  # 极窄终端（<30 列）值区之后放不下 4 列注记，此时按设计省略注记而非折行
  (( W < 30 )) && continue
  while IFS= read -r l; do
    case "$l" in
      *脚本版本*)
        case "$l" in
          *"v1.5.5  ["*) ;;
          *) printf '[FAIL] COLUMNS=%-4s 脚本版本注记未同行: %s\n' "$W" "$l"; fail=1 ;;
        esac ;;
    esac
  done <<< "$out"
done

echo "-----"
if (( fail )); then echo "结果: 面板存在宽度溢出或同行断言失败"; exit 1; fi
echo "结果: 全部宽度均无溢出，且脚本版本注记同行显示"