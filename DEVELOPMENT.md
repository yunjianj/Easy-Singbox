# DEVELOPMENT — 开发指南

面向维护者/开发者的开发约定。**面向用户的使用说明见 `README.md`**，本文档只记录代码组织与适配策略，新增功能前先读这里。

## 1. 协议与 sing-box 内核基线版本（核心约定）

> **约定（2026-09-08 起，v1.5.0 确立为单一基线）**：
> **本脚本只适配 sing-box 的单一内核大版本（基线 `SB_VER_BASE`，当前 = 1.14）。**
> 所有协议一律只按该大版本的最新稳定内核语法编写；**不保留多版本语法分支**，
> 也不按运行内核做协议裁剪。安装与升级内核时只下载 `SB_VER_BASE.x` 大版本下的
> 最新补丁（如 1.14.x 最新），不可手动切换/降级到其它大版本。

### 1.1 版本常量与支持检测

内核基线常量与版本比较在 `lib/core.sh`：

```bash
SB_VER_BASE="1.14"     # 脚本适配的内核基线大版本（发新脚本版本适配更大版本时更新）
core_sb_ver()          # 探测已装内核版本（"sing-box version <ver>" 第3词）
core_ver_ge()          # cur >= target 比较（纯 shell，兼容 busybox，无 sort -V）
sb_latest_version()    # sb 内：查 GitHub Releases 取 SB_VER_BASE.x 大版本最新正式补丁
```

- **版本支持检测**：主面板在已装内核 < `SB_VER_BASE` 时红色提示「请执行选项 7 升级」；
  选项 7 升级时同样先比较，已是最新补丁则提示无需操作。
- 协议编号函数族（`core_proto_letter` / `core_proto_display` / `core_proto_transport` /
  `core_protos_from_letters` / `core_protos_human` / `core_all_protos` / `core_rand_user`）
  与协议内容/数量解耦，见下。

### 1.2 协议编号与自选启用

安装与「变更代理配置」均让用户**自选启用哪些协议**：字母编号组合（如 `bc` = Hysteria2 + TUIC），交互统一由 `config_pick_protos()`（`lib/config.sh`）实现。编号固定如下（新增协议按顺序续编 e/f/...，同步改 `core_proto_letter` / `core_proto_transport` / 菜单）：

| 字母 | 协议 | 传输 | 认证 | 备注 |
| --- | --- | --- | --- | --- |
| a | anytls | tcp | password | 强制 TLS |
| b | hysteria2 | udp | password | 强制 TLS |
| c | tuic | udp | uuid+password | 强制 TLS |
| d | socks | tcp | user+password | 明文（sing-box socks 无 tls 字段） |

**生成集 = 用户选择(PROTOS)**。`.state` 的 `PROTOS` 保存用户原始字母选择；
`config_gen` / `node_gen` / `diag` 全部只依据 `PROTOS` 生成对应 inbound 与 URI
（不再受已装内核版本影响——安装/升级已保证内核恒为 `SB_VER_BASE.x`）。

### 1.3 新增协议步骤

1. **协议片段模块**：在 `lib/protocol/<name>.sh` 新增 `proto_<name>_inbound()`。若该协议官方**不支持 TLS**（如 socks），必须在模块头显著注明「非强制 TLS 例外」并在 `config_pick_protos` 菜单标红/警示。
2. **登记编号与元数据**：`core_proto_letter()` / `core_proto_display()` / `core_proto_transport()` / `core_all_protos()` 补充该协议；`config_pick_protos()` 菜单补一行。协议内容**只按 `SB_VER_BASE` 大版本的最新语法编写**——不要为旧内核写分支。
3. **接入 `config_gen`**：按 `active`（PROTOS 解析出的协议集）条件输出该协议 inbound（复制现有任一段，注意 `first` 逗号标记）；`.state` 写入该协议的端口/凭证字段。
4. **接入 `node_gen`**：按 `active` 输出该协议 URI；无标准 URI 时输出 sing-box outbound JSON 兜底（如 socks/anytls）。
5. **接入联动点**（避免误报/误放行）：
   - `lib/service.sh` → `service_verify_ports()`：只校验启用协议的端口（空端口参数自动跳过）。
   - `lib/firewall.sh` → `fw_apply_choice()`：防火墙仅放行启用协议端口。
   - `lib/diag.sh` 第 6 节：未启用协议标注「未启用」而非「未监听」（已有模板）。
6. **用真实内核验证**：开发机下载 `SB_VER_BASE.x` 的官方二进制跑 `sing-box check`，确认新协议 inbound 语法合法（见 §4）。

### 1.4 代码写法约定

- **不做版本分支**：协议模块与 `config_gen` 里不再有 `ge114` 之类的多版本参数；语法字段恒按 `SB_VER_BASE` 大版本最新写法。
- 判断已装内核与基线的关系用 `core_ver_ge`（纯 shell，兼容 busybox）。
- 版本探测失败时给出 `warn` 但不中断（多数路径只在"已有内核"场景用到探测，如面板检测/升级判断）。

### 1.5 内核升级（选项 7）

`sb` 选项 7（`sb_version_menu`）是**一键升级**（无手动切换/降级）：
探测已装版本 → 若低于基线或落后于 `SB_VER_BASE.x` 最新补丁 → 备份旧二进制 →
`sb_download` 下载（含官方 digest 校验）→ `config_rebuild_from_state()` 把存量配置
按基线语法平滑重建（对 v1.3.x 等旧脚本生成的 1.13 语法配置必要）→ reload + 刷新节点 →
失败回滚 `.bak`。

## 2. 代码组织

```
install.sh          # 主入口（exec sb）
sb                  # 管理命令本体（含主菜单、安装/卸载/内核升级/自更新）
sb.sh               # 一键引导（curl | sh 安全版，内含完整性校验）
uninstall.sh        # 独立卸载
lib/
  core.sh           # 工具/系统探测/日志/颜色 + 版本比较 + 协议编号/元数据
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
- **强制 TLS（SOCKS5 除外）、不生成订阅链接**是产品边界，任何改动不得突破。
- **只适配内核基线大版本**：协议配置一律按 `SB_VER_BASE` 最新语法，禁止为旧大版本写分支或加"切换版本"入口。
- 发布新版本：同步 `sb` 内 `SB_SCRIPT_VERSION`、根 `VERSION`、`README.md` 面板示例三处；若更新了适配的内核大版本，同步修改 `SB_VER_BASE` 并在 README「依赖」节注明。

## 4. 测试

见 `TESTING.md`（服务器端到端清单）。开发机验证用 mock 二进制：`mock-sing-box version`
输出 `sing-box version <MOCK_VER>`、`check` 恒真，驱动 `config_rebuild_from_state` +
`node_gen`，比对 `config.json` 中 inbound 与 `nodes.txt` 的 URI。
覆盖：全协议/子集生成、任意已装内核下均输出基线最新语法（不做版本裁剪）、升级判断
（低于基线需升 / 已最新无需升）、`.state` 保留参数。

**适配新的大版本内核时**（如未来升级到 1.15）：改 `SB_VER_BASE`，用官方 1.15 二进制对
每个协议 inbound 跑 `sing-box check` 回归，更新本文档与 README。
