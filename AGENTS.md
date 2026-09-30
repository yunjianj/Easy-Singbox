# AGENTS — easy-singbox 开发约定

> 本文件是**面向维护者与 AI 代理（Claude Code / Codex / Cursor 等）的唯一开发约定**。
> 面向**终端用户**的使用说明见 `README.md`，服务器端到端验证清单见 `TESTING.md`。
> 改动本仓库前先读完本文件；与本文件冲突的改动一律视为 bug。

## 0. 速览（60 秒版）

| 项 | 值 |
| --- | --- |
| 项目形态 | 纯 bash（无编译、无外部依赖），管理 sing-box 的安装/配置/诊断脚本 |
| 入口 | `install.sh` → `sb`；一键引导 `sb.sh`；卸载 `uninstall.sh` |
| 内核基线 | `SB_VER_BASE="1.14"`，**只适配这一个内核大版本**，无多版本分支 |
| 协议 | a=anytls / b=hysteria2 / c=tuic / d=socks（均强制 TLS，socks 除外） |
| 脚本版本 | 三处同步：`sb` 的 `SB_SCRIPT_VERSION`、根 `VERSION`、`README.md` 面板示例 |
| 必跑测试 | `bash test_width.sh`（改了面板/`ui_*`/节点展示就必须跑） |
| shell | 目标环境含 busybox（OpenWrt/安卓 Termux），**禁止** `sort -V`、`awk length()` 等非 POSIX 依赖 |
| 换行 | `.gitattributes` 强制 LF；提交 shell 脚本时不得引入 CRLF（会嵌入 `\r` 导致服务起不来） |

**最高优先级的 5 条红线**（违反即回滚）：

1. **强制 TLS**（socks 除外）——不得为任何协议加 `tls: {enabled: false}` 之类的开关。
2. **不生成订阅链接**，节点 **整行原样打印**，禁止分段/折行/截断/Base64/二维码。
3. **不做多内核大版本分支**——协议语法恒按 `SB_VER_BASE` 最新写法，禁止 `ge114` 式条件参数。
4. **任何一行面板输出不得超过终端宽度**（中文双宽，测量只能用 `core_dwidth`）。
5. **凭证/端口只落 `/etc/sing-box/.state`**，`config.json` 永远由 `config_gen` 生成、不手工编辑。

## 1. 代码组织

```
install.sh          # 主入口（exec sb）
sb                  # 管理命令本体（含主菜单、安装/卸载/内核升级/自更新）
sb.sh               # 一键引导（curl | sh 安全版，内含完整性校验）
uninstall.sh        # 独立卸载
test_width.sh       # 面板宽度回归（改 UI 必跑）
lib/
  core.sh           # 工具/系统探测/日志/颜色 + 版本比较 + 协议编号/元数据 + ui_* 助手
  init.sh           # init 系统探测（systemd/OpenRC）
  service.sh        # 服务管理 + 降权用户 + 端口监听校验
  firewall.sh       # 防火墙后端（ufw/firewalld/iptables/nftables）
  cert.sh           # acme.sh 证书
  config.sh         # config_gen 生成 config.json + .state + config_rebuild_from_state
  node.sh           # node_gen 节点 URI
  port_hop.sh       # Hy2 端口跳跃 REDIRECT
  diag.sh           # 一键诊断
  bbrfq.sh          # BBR + FQ
  protocol/         # anytls / hysteria2 / tuic / socks inbound 片段
templates/config.json.tpl   # （已废弃，未被引用，勿再依赖，勿删勿用）
```

新增代码请放进对应的 `lib/*.sh`；`sb` 只做菜单编排与调度，不要把业务逻辑堆进 `sb`。

## 2. 协议与 sing-box 内核基线（核心约定）

> **约定（2026-09-08 起，v1.5.0 确立为单一基线）**：
> **本脚本只适配 sing-box 的单一内核大版本（基线 `SB_VER_BASE`，当前 = 1.14）。**
> 所有协议一律只按该大版本的最新稳定内核语法编写；**不保留多版本语法分支**，
> 也不按运行内核做协议裁剪。安装与升级内核时只下载 `SB_VER_BASE.x` 大版本下的
> 最新补丁（如 1.14.x 最新），不可手动切换/降级到其它大版本。

### 2.1 版本常量与支持检测

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
  与协议内容/数量解耦，新增协议不要动它们的内部结构。
- 版本探测失败时给 `warn` 但**不中断**（多数路径只在「已有内核」场景用到探测）。

### 2.2 协议编号与自选启用

安装与「变更代理配置」均让用户**自选启用哪些协议**：字母编号组合（如 `bc` = Hysteria2 + TUIC），交互统一由 `config_pick_protos()`（`lib/config.sh`）实现。编号固定如下（新增协议按顺序续编 e/f/...，同步改 `core_proto_letter` / `core_proto_transport` / 菜单）：

| 字母 | 协议 | 传输 | 认证 | 备注 |
| --- | --- | --- | --- | --- |
| a | anytls | tcp | password | 强制 TLS |
| b | hysteria2 | udp | password | 强制 TLS |
| c | tuic | udp | uuid+password | 强制 TLS |
| d | socks | tcp+udp | user+password | 明文（sing-box socks 无 tls 字段） |

**生成集 = 用户选择(PROTOS)**。`.state` 的 `PROTOS` 保存用户原始字母选择；
`config_gen` / `node_gen` / `diag` 全部只依据 `PROTOS` 生成对应 inbound 与 URI
（不再受已装内核版本影响——安装/升级已保证内核恒为 `SB_VER_BASE.x`）。

### 2.3 新增协议步骤

1. **协议片段模块**：在 `lib/protocol/<name>.sh` 新增 `proto_<name>_inbound()`。若该协议官方**不支持 TLS**（如 socks），必须在模块头显著注明「非强制 TLS 例外」并在 `config_pick_protos` 菜单标红/警示。
2. **登记编号与元数据**：`core_proto_letter()` / `core_proto_display()` / `core_proto_transport()` / `core_all_protos()` 补充该协议；`config_pick_protos()` 菜单补一行。协议内容**只按 `SB_VER_BASE` 大版本的最新语法编写**——不要为旧内核写分支。
3. **接入 `config_gen`**：按 `active`（PROTOS 解析出的协议集）条件输出该协议 inbound（复制现有任一段，注意 `first` 逗号标记）；`.state` 写入该协议的端口/凭证字段。
4. **接入 `node_gen`**：按 `active` 输出该协议 URI；无标准 URI 时输出 sing-box outbound JSON 兜底（如 socks/anytls）。
5. **接入联动点**（避免误报/误放行）：
   - `lib/service.sh` → `service_verify_ports()`：只校验启用协议的端口（空端口参数自动跳过）。
   - `lib/firewall.sh` → `fw_apply_choice()`：防火墙仅放行启用协议端口。
   - `lib/diag.sh` 第 6 节：未启用协议标注「未启用」而非「未监听」（已有模板）。
6. **用真实内核验证**：开发机下载 `SB_VER_BASE.x` 的官方二进制跑 `sing-box check`，确认新协议 inbound 语法合法（见 §5）。

### 2.4 内核升级（选项 7）

`sb` 选项 7（`sb_version_menu`）是**一键升级**（无手动切换/降级）：
探测已装版本 → 若低于基线或落后于 `SB_VER_BASE.x` 最新补丁 → 备份旧二进制 →
`sb_download` 下载（含官方 digest 校验）→ `config_rebuild_from_state()` 把存量配置
按基线语法平滑重建（对 v1.3.x 等旧脚本生成的 1.13 语法配置必要）→ reload + 刷新节点 →
失败回滚 `.bak`。

## 3. 终端输出约定

### 3.1 硬性不变量：任何一行输出都不得超过终端实际宽度

违反它会让终端替我们软换行，面板被撑高、超出手机可视高度，`clear` 重绘后顶部被顶出屏幕，
用户长按复制只剩后半截（安卓手机竖屏终端常只有 40~50 列，是最容易触发的环境）。

- **测量宽度用 `core_dwidth`（`lib/core.sh`），不要用 `${#s}`、`wc -m` 或 `awk length()`**：
  中文是双宽字符（显示宽度 ≠ 字符数）。`core_dwidth` 用「字符数 + 非 ASCII 字符数」计算，
  纯 bash 参数展开，在 busybox awk（`length()` 对中文返回字节数）与各 locale 下行为一致。
- **渲染一律走 `ui_*` 助手**：`ui_rule` / `ui_banner` / `ui_field` / `ui_item` / `ui_note`。
  它们自己按 `core_term_width` 预算宽度：放不下就截断（`…`）或缩排折行，
  **绝不把超宽内容丢给终端去折**。新增输出不要手写 `echo "====..."` 这类定宽字符串。
- **缩排宽度必须从终端宽度推出**，不能写死再拿另一个缩排量去减——混算会算出超宽行。
- 改完面板渲染一律跑 `bash test_width.sh`：它在 20~120 列逐档渲染并断言无溢出。

### 3.2 屏幕输出与清屏

`sb_show_menu` 开头 `clear` 是必要的（菜单要干净屏），但**主循环里打印过长内容后
必须跳过下一轮清屏**，否则用户刚看到的内容瞬间消失——安卓端尤其致命，因为屏幕小、
没有回滚，节点看起来就是「没打印」。

- 任何会打印**用户需要阅读/复制**的长内容（节点 URI、诊断报告）的选项，
  执行完要置 `SB_KEEP_SCREEN=1`。`main_menu` 检测到该变量后不清屏，
  提示用户并等待回车，确认后才重绘菜单。
- 不要用「打印完立刻 redraw 菜单」的方式收尾（参考 `yonggekkk/sing-box-yg` 的
  `sbshare`：它把查看节点放进二级菜单，看完先回二级菜单，同样是为了留住输出）。
- 终端宽度自适应（`ui_*` 系列）解决的是「长行被终端软换行导致复制不全」，
  与「输出被 clear 刷掉」是两个独立问题，不要混为一谈。

### 3.3 节点 URI 的红线（是 3.1 宽度约束的唯一例外）

上面「不得超宽」的约束**只针对面板装饰与菜单说明**。节点 URI 是例外，且必须原样输出：

- **节点必须整行原样打印**（写入 `nodes.txt` 时一行一个），用户才能长按复制、整行粘贴进
  代理客户端。**禁止**对节点做分段、折行、截断、Base64 编码、二维码等任何加工——
  分段后无法整行粘贴，节点反而变得不可用。
- **不做写入剪贴板一类有侵入性的功能**（不碰 `termux-clipboard-set`/`pbcopy`/`xclip` 等）。
- 窄屏取不到节点的正解是**修好面板**（不让面板把自己顶出屏幕、复制不全），
  而不是改动节点的输出形式。

## 4. 通用约束

- **凭证/端口等全部持久化参数只放 `.state`**（`/etc/sing-box/.state`，被 source 的 shell 文件，权限 600），`config.json` 永远由 `config_gen` 生成、**不手工编辑**。
- **强制 TLS（SOCKS5 除外）、不生成订阅链接**是产品边界，任何改动不得突破。
- **只适配内核基线大版本**：协议配置一律按 `SB_VER_BASE` 最新语法，禁止为旧大版本写分支或加"切换版本"入口。
- 发布新版本：同步 `sb` 内 `SB_SCRIPT_VERSION`、根 `VERSION`、`README.md` 面板示例三处；若更新了适配的内核大版本，同步修改 `SB_VER_BASE` 并在 README「依赖」节注明。

## 5. 测试

见 `TESTING.md`（服务器端到端清单）。开发机验证用 mock 二进制：`mock-sing-box version`
输出 `sing-box version <MOCK_VER>`、`check` 恒真，驱动 `config_rebuild_from_state` +
`node_gen`，比对 `config.json` 中 inbound 与 `nodes.txt` 的 URI。
覆盖：全协议/子集生成、任意已装内核下均输出基线最新语法（不做版本裁剪）、升级判断
（低于基线需升 / 已最新无需升）、`.state` 保留参数。

**终端输出回归**：`bash test_width.sh` 在 COLUMNS=20/24/30/35/40/45/50/55/60/62/72/80/100/120
逐档渲染主面板，断言每一行显示宽度都不超过 `min(终端宽, 62)`。改面板 / `ui_*` / 节点展示后必跑。

**适配新的大版本内核时**（如未来升级到 1.15）：改 `SB_VER_BASE`，用官方 1.15 二进制对
每个协议 inbound 跑 `sing-box check` 回归，更新本文件与 README。

### 5.1 改完代码的自查顺序

1. `bash -n` 语法检查所有改动的 shell 文件。
2. `bash test_width.sh` 若触碰了面板 / `ui_*` / 节点展示。
3. 确认无 CRLF：`git diff | grep -c $'\r'` 应为 0。
4. 确认没引入新外部依赖（`command -v` 探测的工具必须在 busybox / 精简发行版存在）。
5. 若改了协议或配置生成：更新 §2.2 表格与 `README.md` 对应描述。

## 6. 提交与上传节奏

- **普通（功能/重构，feat/refactor 等）提交**：先本地提交、**不推送**，由用户测试验证后明确下达上传指令再推送。
- **修复 bug（fix）类提交**：完成并通过验证后**立即同步推送 GitHub**（2026-09-08 约定），无需等待单独的上传指令——bug 修复通常直接关系线上可用性，尽早同步便于用户拉取部署。
- 推送后保留 tag 与否按用户习惯（本仓库当前不打 tag）。
- 本地私有状态与工具产物不入库，见 `.gitignore`。

## 7. 已废弃 / 不要复活的东西

| 机制 | 状态 |
| --- | --- |
| 1.13/1.14 双语法分支（v1.3.0） | 已随 v1.5.0 移除 |
| 大版本切换自动重建（v1.3.1） | 已移除，升级只保留「一键升到基线最新补丁」 |
| 按内核版本裁剪协议（v1.3.3） | 已移除，协议集只由用户 `PROTOS` 决定 |
| `templates/config.json.tpl` | 无引用，勿依赖 |
| 订阅链接 / 剪贴板写入 / 节点分段 | 产品边界，永不做 |
