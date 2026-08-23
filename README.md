# easy-singbox

面向 Linux 服务器的 **sing-box 一键部署脚本**。

## 一键安装

以 root 在目标服务器执行以下任一命令，自动下载并进入安装主页面：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/yunjianj/Easy-Singbox/main/sb.sh)
```

或（使用 curl）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yunjianj/Easy-Singbox/main/sb.sh)
```

> 默认使用 GitHub raw 官方域名（避免第三方 CDN 缓存被投毒）。若拉取缓慢可改用 jsDelivr 镜像（仅引导下载，安装后自更新同样默认走官方源）：
> `bash <(wget -qO- https://cdn.jsdelivr.net/gh/yunjianj/Easy-Singbox@main/sb.sh)`

也可先克隆再安装（已装 git 时）：

```bash
git clone https://github.com/yunjianj/Easy-Singbox.git && cd Easy-Singbox && bash install.sh
```

> 安装后脚本本体存放于 `/usr/local/share/easy-singbox`，管理命令 `sb` 软链到 `/usr/local/bin/sb`。卸载请另执行仓库内 `uninstall.sh`。


- **强制 TLS**：AnyTLS + Hysteria2 + TUIC v5 三协议共存于同一份 `config.json`，各自独立端口、共享同一份真实证书，`tls.enabled` 均为 `true`，**不支持无证书模式、不支持手动上传证书**。
- **不生成订阅链接**：安装完成后直接在终端打印三种协议的节点 URI，并写入 `/etc/sing-box/nodes.txt`（权限 600）。
- **证书自动申请**：通过 acme.sh 向 Let's Encrypt 自动签发，支持 HTTP-01 与 DNS-01(Cloudflare) 两种验证方式。

## 支持系统

- Debian 11/12、Ubuntu 20.04/22.04/24.04 等 systemd 发行版（x86_64 / aarch64）
- **Alpine Linux 3.19+**（OpenRC init，v1.2.0 起支持，x86_64 / aarch64；容器环境内的 Alpine 不支持，因容器通常不运行 init 系统）
- 防火墙后端自动适配：`ufw → firewalld → iptables`，均无则跳过并提示

## 依赖

脚本仅依赖 `curl` + `bash` + 常见 coreutils。其余工具在安装时自动安装：

- `sing-box`（从 GitHub Releases 下载最新 stable，要求 ≥ 1.13，下载后比对 GitHub Release API 官方 digest（sha256），校验失败即拒绝安装）
- `acme.sh`（证书申请，先落盘校验 shebang 再执行，不再 `curl | sh` 盲执行）
- `ncurses`（可选，提供 `tput` 彩色输出；缺失时静默降级为无色，不影响功能。Alpine 上安装：`apk add ncurses`）

## 三种协议

| 协议 | 传输 | 凭证 | 说明 |
| --- | --- | --- | --- |
| AnyTLS (TCP) | TCP | password | 抗探测，需服务端默认 padding |
| Hysteria2 (QUIC) | UDP | password | 可选 salamander obfs |
| TUIC v5 (QUIC) | UDP | uuid + password | 双字段 |

三者均使用同一份 TLS 证书，由证书模块统一签发到 `/etc/sing-box/ssl/`。

## 两种证书模式

1. **HTTP-01**：域名 A 记录指向本机 IP，签发阶段需 80 端口空闲。脚本在签发前临时放行 80、完成后回收。
2. **DNS-01 (Cloudflare)**：填入 Cloudflare API Token（需 `Zone:DNS:Edit` 权限），无需 80 端口。Token 持久化于 `/etc/sing-box/.cf.env`（权限 600）以便续期。

证书续期由 acme.sh 自带 cron 负责，续期后执行 `systemctl reload sing-box`。

## 端口开放三选一

安装时会询问端口开放策略（直接回车默认选 1）：

1. 全部开放（22/SSH + 80 + 三协议端口；Hy2 跳跃段由 REDIRECT 自动转发到基础端口）
2. 开放所有端口（直接关闭防火墙，存在安全风险，仅建议可信网络使用）
3. 不开放（自行在防火墙/安全组配置）

默认随机高位端口（49152–65535，避让 Hy2 跳跃段），可在「变更代理配置」中逐个自定义。

## 使用

```bash
# 首次运行（进入统一主页面）
bash install.sh

# 安装后，任意位置输入管理命令
sb
```

主页面菜单：

```
==============================================================
      easy-singbox  管理面板  v1.2.26
--------------------------------------------------------------
 系统      : Debian 12 (Bookworm) x86_64
 指令集    : amd64 (AES-NI: 支持)
 虚拟化    : KVM
 BBR       : 已开启 (bbr)
 IP / 地区 :
             IPv4 1.2.3.4  |  中国/香港 / HKBN
             IPv6 2001:db8::1  |  日本/东京 / 某ISP
 Sing-Box  : 已运行  v1.13.0  (3 协议在线)
 脚本版本  : v1.2.26  [已是最新]
--------------------------------------------------------------
 [1] 一键安装 / 卸载 Sing-Box
 [2] 变更代理配置      (协议 / 端口 / 凭证)
 [3] 变更证书配置      (HTTP-01 / DNS-01 / 重签)
 [4] 启动 Sing-Box
 [5] 停止 Sing-Box
 [6] 重启 / 查看节点
 [7] 更新 / 切换内核版本
 [8] 更新脚本            (当前 v1.2.26)
 [9] 诊断与日志        (排查节点不通，生成可发送的报告)
 [10] BBR + FQ 拥塞控制  (一键启用 / 禁用，独立于 sing-box)
 [0] 退出
==============================================================
```

## 排查节点不通

选项 `[9]` 提供一键诊断，把定位问题所需的信息一次性收集齐（凭证自动脱敏，可直接复制发送）：

```bash
sb            # 选 [9] → [1] 生成完整诊断报告
sb debug      # 等效的命令行入口，报告同时写入 /etc/sing-box/diag.log
sb log        # 直接查看最近 200 行服务日志
```

报告包含 13 个小节：系统/内核环境（含 `bindv6only`）、服务状态、`journalctl` 日志、`sing-box check` 结果、状态文件端口、**端口监听实况**、本机自连测试（IPv4/回环分别验证）、防火墙规则、端口跳跃 REDIRECT 规则、证书有效期与 SAN、`singbox` 用户可读性、域名解析与出口 IP、脱敏后的 `config.json`，最后附「自动结论」小节依据以上信息直接给出最可能原因与下一步。

判读要点：

| 客户端现象 | 含义 | 看报告哪一节 |
| --- | --- | --- |
| `connection refused`（主动拒绝，收到 RST） | 包已到达机器，但**端口无监听** | 第 6 节端口监听实况、第 3 节服务日志 |
| 连接超时（无响应） | 包被丢弃，通常是**防火墙/云安全组**未放行 | 第 8 节防火墙规则 + 云厂商安全组 |
| TLS 握手失败 / 证书错误 | 证书或 SNI 不匹配 | 第 10 节证书、第 11 节域名解析 |

若需更详细日志，选 `[9] → [3]` 把 sing-box 日志级别切到 `debug`，复现问题后再生成一次报告。

## 节点导入方式

安装完成（或选「查看节点」）后，终端显示三种协议 URI，并写入 `/etc/sing-box/nodes.txt`。

- **Hysteria2 / TUIC**：直接复制 URI 导入客户端。
- **Hysteria2 端口跳跃**：若启用了跳跃段，URI 会携带 `mport=段`（如 `50001-51000`），客户端将向该 UDP 范围随机跳变发包。需在**云安全组/上游防火墙放行整个 UDP 范围**，否则 Hy2 会超时连不上（本机防火墙无需放行该段，由 REDIRECT 自动转发到基础端口）。
- **AnyTLS**：部分 GUI 客户端尚不识别 `anytls://`，此时终端会额外输出该节点的 sing-box outbound JSON 片段，可手动粘贴导入。
- **严禁订阅链接**：脚本不会输出任何 `http(s)://.../sub` 形式的订阅地址。

## 卸载与更新

- **卸载**：主页面选项 1（已安装时变为卸载），或独立执行 `bash uninstall.sh`。会二次确认是否一并删除证书目录与 acme.sh 账户。
- **切换版本**：选项 7，下载指定版本前备份当前二进制（`/usr/local/bin/sing-box.bak`），失败可手动恢复。下载的二进制强制比对官方 `checksums.sha256`，校验失败打印期望/实际哈希并拒绝安装。
- **更新脚本**：选项 8，从 GitHub raw 官方源（`sb` 顶部 `SB_UPDATE_BASE`）拉取最新代码，保留本机 `/etc/sing-box/config.json` 与证书。覆盖本地前会先用 `cmp -s` 列出所有变更文件并要求确认，拒绝则本地不被改动。
- **版本自检**：主面板标题与「脚本版本」行显示当前版本（`sb` 内 `SB_SCRIPT_VERSION` 常量），并自动对比仓库根 `VERSION` 文件——已最新显示绿色 `[已是最新]`，有新版本显示红色 `[发现新版本 vX，可执行选项 8 更新]`，检测失败（网络受限）显示黄色 `[远程版本未知]`。检测结果本地缓存 10 分钟，不会拖慢菜单。发布新版本时请同步修改 `SB_SCRIPT_VERSION` 与 `VERSION` 文件。

## 安全设计

**供应链完整性（v1.1.2）**

- **sing-box 二进制**：每次下载（安装/切换内核版本）都会比对 **GitHub Release API 官方 asset digest（sha256）**——GitHub 为每个资产签发的 digest 无法伪造，比"与二进制同 release 的 checksums 文件"更强（sing-box 官方也未附带该文件）。校验失败打印期望/实际 SHA256 并拒绝安装、清理临时文件；API 不可用或缺失 `sha256sum`/`shasum` 时显著警告并要求显式确认，绝不静默跳过。
- **脚本自更新**：更新源固定为 GitHub raw 官方域名（`SB_UPDATE_BASE`），覆盖本地前列出变更文件并要求确认；拒绝则本地不被改动。
- **acme.sh 安装**：不再 `curl | sh` 盲执行，改为 git clone 官方仓库或下载官方 master 单文件，先落盘、校验非空与 shebang，再本地执行；兜底 `get.acme.sh` 同样先落盘校验并要求确认。
- **引导脚本 sb.sh**：解压后校验 `install.sh` shebang 及 `sb`/`lib/*.sh` 齐套，不完整即中止。

**最小权限（v1.1.2）**

- **精确授权**：服务以 `singbox` 系统用户降权运行，仅 `config.json` 与证书两文件（`ssl/fullchain.pem`、`ssl/privkey.pem`）授予 `singbox`；`.state`、`nodes.txt`、`.cf.env`（Cloudflare Token）、`diag.log` 一律保持 `root:root 600`，即使进程沦陷也不泄漏 DNS 编辑权与全部节点凭证。旧版本被 `chown -R` 污染的存量文件在安装/重签时会自动纠回。
- **umask 077**：脚本内敏感文件从创建起即为 600，无 644 暴露窗口。
- **systemd 加固**：单元删除多余的 `AmbientCapabilities=CAP_NET_BIND_SERVICE`，增加 `NoNewPrivileges=true`、`ProtectSystem=strict`、`ReadOnlyPaths=/etc/sing-box`、`ProtectHome=true`、`PrivateTmp=true`。OpenRC（Alpine）下等价实现：`supervise-daemon` 崩溃自动重启（`respawn_max=0`）、`rc_ulimit="-n 100000"`、`checkpath` 限权日志目录。

**双 init 支持（v1.2.0）**

- 新增 `lib/init.sh` init 系统探测层：自动识别 systemd / OpenRC，服务管理（启停/状态/自启/日志）全部按 init 系统适配。Debian/Ubuntu 走 systemd，Alpine 走 OpenRC（`rc-service` / `rc-update`）。
- OpenRC 下日志写入 `/var/log/sing-box/sing-box.log`，`sb log` / 诊断报告 / 安装提示均已适配；`reload` 语义等价 `restart`（sing-box 不支持 SIGHUP 热重载）。

## BBR + FQ 拥塞控制

主页面选项 `[10]` 或命令行 `sb bbr` 可一键启用 / 禁用 BBR 拥塞控制 + FQ 队列纪律。

- **独立于 sing-box 安装**：不随一键安装自动开启，需用户手动选择。
- **一键启用**：运行时立即生效，并持久化到 `/etc/sysctl.d/99-easy-singbox-bbr.conf`（重启后保持）。
- **一键禁用**：恢复内核默认（cubic + pfifo_fast），移除持久化文件。
- **内核要求**：BBR 需内核 >= 4.9，FQ 默认队列纪律需 >= 4.13。
- **sysctl 文件独立**：BBR 使用独立的 `99-easy-singbox-bbr.conf`，与双栈配置 `99-easy-singbox.conf` 分离，互不覆写；运行时仅用 `sysctl -w`，不会重放全量配置干扰 Docker 的 `ip_forward`。

BBR 对 Hysteria2 / TUIC (QUIC) 和 AnyTLS (TCP) 流量均有显著加速效果，尤其在高延迟 / 跨境链路上。

## 已知限制

- **AnyTLS 客户端兼容性**：部分客户端不识别 `anytls://` URI，需使用 outbound JSON 兜底导入（见上）。
- 降权运行以 `singbox` 系统用户执行；端口均为高位随机，无需 `CAP_NET_BIND_SERVICE`（systemd 单元已移除该 capability）。
- DNS-01 仅支持 Cloudflare，其他 DNS 服务商本期未实现。
- 自更新默认从 GitHub raw 官方源拉取（非 jsDelivr），网络受 GitHub 限制的区域需代理或手动更新。
- **Alpine 容器环境不支持**（OpenRC 依赖真实 PID1），仅支持 Alpine 虚拟机/物理机。

## 目录结构

```
easy-singbox/
├── install.sh          # 主入口
├── sb                  # 管理命令本体（软链到 /usr/local/bin/sb）
├── uninstall.sh        # 独立卸载入口
├── lib/
│   ├── core.sh         # 工具/系统探测/日志/颜色
│   ├── init.sh         # init 系统探测（systemd/OpenRC）
│   ├── service.sh      # 服务管理（systemd/OpenRC 双适配）+ 降权
│   ├── firewall.sh     # 防火墙后端适配
│   ├── cert.sh         # 证书管理（acme.sh）
│   ├── config.sh       # 生成 config.json
│   ├── node.sh         # 节点 URI 生成
│   ├── port_hop.sh     # Hy2 端口跳跃 REDIRECT 规则
│   ├── bbrfq.sh        # BBR + FQ 拥塞控制管理（选项 10 / sb bbr）
│   ├── diag.sh         # 一键诊断（选项 9 / sb debug）
│   └── protocol/       # anytls / hysteria2 / tuic 片段
├── templates/config.json.tpl
├── README.md
└── TESTING.md
```
