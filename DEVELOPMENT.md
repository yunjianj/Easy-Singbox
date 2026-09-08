# DEVELOPMENT — 开发指南

面向维护者/开发者的开发约定。**面向用户的使用说明见 `README.md`**，本文档只记录代码组织与适配策略，新增功能前先读这里。

## 1. 协议与 sing-box 内核版本适配（核心约定）

> **约定（2026-09-08 确立）**：
> **新增协议时，默认只适配最新版本的 sing-box（当前为 1.14）。**
> 切换至旧内核版本时，尚未适配该内核版本的协议**不生成相关节点**（inbound 不写入
> `config.json`、不输出 URI），但**其配置参数保留在 `.state`**；当切换回支持该协议
> 的高版本内核时，自动用 `.state` 中保留的配置重新生成节点。

### 1.1 实现机制

每个协议声明其**最低支持内核版本**，由 `lib/core.sh` 统一管理：

```bash
# lib/core.sh
SB_VER_LATEST="1.14"          # 最新稳定版（发新版时同步更新）
core_proto_min_ver()          # 返回某协议的最低内核版本
core_proto_supported()        # 判断 cur_ver 是否 >= 某协议最低版本
core_supported_protos()       # 输出当前内核支持的协议名列表
core_proto_letter()           # 协议名 -> 字母编号（a/b/c/d...）
core_protos_from_letters()    # 字母串 -> 协议名列表（空格分隔，自动去重排序）
core_protos_human()           # 字母串 -> 人类可读名（"Hysteria2 + TUIC v5"）
core_proto_transport()        # 协议名 -> tcp|udp（防火墙/端口校验用）
core_rand_user()              # 随机用户名（SOCKS5 认证，字母开头）
```

现有 `anytls`/`hysteria2`/`tuic` 兼容 1.13（项目整体要求 ≥ 1.13），故 `core_proto_min_ver` 对三者返回 `1.13`；**未登记的新协议默认返回 `$SB_VER_LATEST`**（即新协议只按最新版适配）。`socks` 即为首个按此约定只适配 1.14 的协议。

### 1.2 协议编号与自选启用

安装与「变更代理配置」均让用户**自选启用哪些协议**：字母编号组合（如 `bc` = Hysteria2 + TUIC），交互统一由 `config_pick_protos()`（`lib/config.sh`）实现。编号固定如下（新增协议按顺序续编 e/f/...，同步改 `core_proto_letter` / `core_proto_transport` / 菜单）：

| 字母 | 协议 | 传输 | 认证 | 内核约束 |
| --- | --- | --- | --- | --- |
| a | anytls | tcp | password | >= 1.13 |
| b | hysteria2 | udp | password | >= 1.13 |
| c | tuic | udp | uuid+password | >= 1.13 |
| d | socks | tcp | user+password | >= 1.14（按约定只适配最新版） |

**生效集 = 用户选择(PROTOS) ∩ 内核支持**。`.state` 的 `PROTOS` 字段保存用户**原始字母选择**（而非生效集），因此内核降/升级不丢用户意图：未适配协议的参数一并保留在 `.state`，切回支持它的高版本内核时自动恢复生成（`node_gen`/`diag` 均按同一交集判断，与 `config_gen` 严格一致）。

### 1.3 新增协议步骤

1. **协议片段模块**：在 `lib/protocol/<name>.sh` 新增 `proto_<name>_inbound()`。若该协议官方**不支持 TLS**（如 socks），必须在模块头显著注明「非强制 TLS 例外」并在 `config_pick_protos` 菜单标红/警示。
2. **登记最低版本与编号**：`core_proto_min_ver()` 登记最低内核版本；`core_proto_letter()` / `core_proto_transport()` / `config_pick_protos()` 菜单补充编号——默认只适配最新版，**不要**顺手把旧版本语法也做出来。
3. **接入 `config_gen`**：按 `active`（生效集）条件输出该协议 inbound（复制现有任一段，注意 `first` 逗号标记）；`.state` 写入该协议的端口/凭证字段与 `PROTOS`。
4. **接入 `node_gen`**：按 `active` 输出该协议 URI；无标准 URI 时输出 sing-box outbound JSON 兜底（如 socks/anytls）。
5. **接入联动点**（避免误报/误放行）：
   - `lib/service.sh` → `service_verify_ports()`：端口按生效集清空未启用项（已有模板）。
   - `lib/firewall.sh` → `fw_apply_choice()`：防火墙仅放行生效协议端口（已有模板）。
   - `lib/diag.sh` 第 6 节：未启用协议标注「未启用」而非「未监听」（已有模板）。
6. **真实版本约束若高于 1.13**：`core_proto_min_ver` 返回真实最低版本（如 `1.14`），切到 1.13 时该协议自动被裁剪、配置保留、切回 1.14 自动恢复。

### 1.4 各文件版本分支写法约定

- 语法分支参数用**语义名**（`ge114` 表示内核 ≥ 1.14），协议模块签名尾部追加，默认 `0` 保持旧语法，避免破坏既有调用。
- 判断大版本用 `core_ver_ge` / `core_ver_family`（纯 shell，兼容 busybox，无 `sort -V`）。
- 版本探测失败时**按最低兼容版本（1.13）输出**并 `warn`，不中断（见 `config_gen` 起始处）。

### 1.5 大版本切换自动重建

`sb` 选项 7（`sb_version_menu`）在切换成功且大版本族变化时调用
`config_rebuild_from_state()`（`lib/config.sh`）：从 `.state` 恢复参数 → `config_gen` 按
新内核语法/协议集重建 → `node_gen` 刷新节点 → 失败回滚 `${SB_CONF}.pre-ver.$$`。

## 2. 代码组织

```
install.sh          # 主入口（exec sb）
sb                  # 管理命令本体（含主菜单、安装/卸载/版本切换/自更新）
sb.sh               # 一键引导（curl | sh 安全版，内含完整性校验）
uninstall.sh        # 独立卸载
lib/
  core.sh           # 工具/系统探测/日志/颜色 + 版本函数 + 协议版本登记
  init.sh           # init 系统探测（systemd/OpenRC）
  service.sh        # 服务管理 + 降权用户 + 端口监听校验
  firewall.sh       # 防火墙后端（ufw/firewalld/iptables/nftables）
  cert.sh           # acme.sh 证书
  config.sh         # config_gen 生成 config.json + .state + config_rebuild_from_state
  node.sh           # node_gen 节点 URI（严禁订阅链接）
  port_hop.sh       # Hy2 端口跳跃 REDIRECT
  diag.sh           # 一键诊断
  bbrfq.sh          # BBR + FQ
  protocol/         # anytls / hysteria2 / tuic / socks inbound 片段
templates/config.json.tpl   # （已废弃，未被引用，勿再依赖）
```

## 3. 通用约束

- **凭证/端口等全部持久化参数只放 `.state`**（被 source 的 shell 文件，权限 600），`config.json` 永远由 `config_gen` 生成、**不手工编辑**。
- **强制 TLS、不生成订阅链接**是产品边界，任何改动不得突破。
- 新功能改动默认**只适配最新内核**；向下兼容是例外而非默认，需在文档/PR 说明理由。
- 发布新版本：同步 `sb` 内 `SB_SCRIPT_VERSION`、根 `VERSION`、`README.md` 面板示例三处；README 在「依赖」节注明最小内核要求与版本适配说明。

## 4. 测试

见 `TESTING.md`（服务器端到端清单）。协议裁剪逻辑可在开发机用 mock 二进制验证：
`mock-sing-box version` 输出 `sing-box version <MOCK_VER>`、`check` 恒真，再驱动
`config_rebuild_from_state` + `node_gen`，比对 `config.json` 中 inbound 与 `nodes.txt` 的 URI。
覆盖：全版本适配、裁剪（模拟协议最低版本 > 当前内核）、恢复、`.state` 保留。
