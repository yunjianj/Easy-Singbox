# easy-singbox 分阶段开发 Prompt

> 用法：每个 Phase 的 Prompt 都可以**独立**发给另一个 AI 实现。发送时，先粘贴「第 0 节 共享项目规格」，再粘贴对应 Phase 的 Prompt。各 Phase 之间有依赖顺序，请按 P0→P5 顺序实现。

---

## 第 0 节 · 共享项目规格（每个 Phase 前必读）

**项目目标**：一个面向 Linux 服务器的 sing-box 一键部署 Bash 脚本。要求：强制 TLS、安装完成后直接输出节点信息（URI + 二维码，**不生成订阅链接**）、多协议共存、证书由脚本自动申请。

**硬性技术约束**
- 协议集：AnyTLS + Hysteria2 + TUIC v5，三者作为 3 个 inbound **共存**于同一份 `config.json`，各自独立端口，共享同一份 TLS 证书。
- 强制 TLS：三个协议都必须 `tls.enabled=true` 并指向真实证书；不支持无证书模式。
- 证书：仅由脚本**自动申请**（acme.sh → Let's Encrypt），不支持用户手动上传。两种验证方式：
  - HTTP-01：需要域名 A 记录指向本机 IP，且签发时 80 端口可用。
  - DNS-01：**仅支持 Cloudflare**，需要用户输入 CF API Token。
  - 证书统一存放：`/etc/sing-box/ssl/{fullchain.pem, privkey.pem}`（权限 600）。
  - 续期：acme.sh 自带 cron，续期后执行 `systemctl reload sing-box`。
- 端口：默认随机高位端口（建议 10000–65535 且不冲突），支持用户逐个自定义。
- 端口开放（安装时三选一）：① 自动开放全部端口（含 80 等 ACME 所需）② 自动开放节点端口（仅 3 个协议端口）③ 不开放（用户手动配置）。注意：选②/③ 且用 HTTP-01 时，签发阶段仍需临时放行 80。
- 节点输出：安装完成后终端打印三种协议 URI + 二维码，并写入 `/etc/sing-box/nodes.txt`（权限 600）。**严禁生成订阅链接**。
- 管理命令：安装后将脚本注册为系统指令 **`sb`**（不是 `sing-box`）。
- 主页面（统一入口）：执行 `install.sh` 首次运行，或安装后输入 `sb`，都进入同一个主页面。主页面先打印系统信息，再显示菜单。
- sing-box 版本：安装最新 stable，要求 ≥ 1.13（AnyTLS 需 1.12+）。
- 防火墙后端适配优先级：`ufw` → `firewalld` → `iptables` → 无则跳过并提示。

**主页面布局规范**
```
==============================================================
      easy-singbox  管理面板
--------------------------------------------------------------
 系统      : Debian 12 (Bookworm) x86_64
 指令集    : amd64 (AES-NI: 支持)
 虚拟化    : KVM
 BBR       : 已开启 (bbr)
 IP / 地区 : 1.2.3.4  |  Hong Kong / CN
 Sing-Box  : 已运行  v1.13.0  (3 协议在线)
--------------------------------------------------------------
 [1] 一键安装 / 卸载 Sing-Box
 [2] 变更代理配置      (协议 / 端口 / 凭证)
 [3] 变更证书配置      (HTTP-01 / DNS-01 / 重签)
 [4] 重启 Sing-Box
 [5] 更新 / 切换内核版本
 [6] 更新脚本
 [0] 退出
==============================================================
 请选择 [0-6]:
```

**目录结构**
```
easy-singbox/
├── install.sh                    # 主入口（首次运行进入主页面）
├── sb                            # 管理命令本体（安装时软链到 /usr/local/bin/sb）
├── lib/
│   ├── core.sh                   # 工具/系统探测/日志/颜色
│   ├── cert.sh                   # 证书管理（acme.sh）
│   ├── config.sh                 # 生成 config.json（3 inbound 共存）
│   ├── node.sh                   # 节点 URI 生成 + 二维码
│   ├── service.sh                # systemd 管理
│   └── protocol/
│       ├── anytls.sh
│       ├── hysteria2.sh
│       └── tuic.sh
├── templates/config.json.tpl
├── uninstall.sh
└── README.md
```

**代码风格约定**
- 纯 Bash，开头 `set -euo pipefail`。
- 函数命名：`snake_case`，按模块加前缀（如 `core_`、`cert_`、`config_`）。
- 日志函数：`info/warn/error`，颜色用 `tput` 或 `printf '\033[...m'`，不要污染写入文件的内容。
- 所有写盘/安装操作必须**幂等**（重复执行不报错、不产生重复 systemd 单元/重复软链）。
- 运行时必须是 root，进入即 `core_root_check`。
- 仅依赖 `curl` + `bash` + 常见 coreutils；其他工具（acme.sh、qrencode 等）由脚本自动安装。
- 不在脚本里硬编码私密信息；Token/密码只存在于本机文件且权限 600。

---

## Phase P0 · 框架与统一入口

**目标**：搭好脚本骨架与主入口；能探测并显示系统信息；展示主页面菜单（除安装/卸载/退出外，其余选项可先显示“暂未实现”）；完成 sing-box 二进制下载安装 + systemd + 卸载主链路。

**依赖**：无（首个阶段）。

**需创建/修改文件**
- `install.sh`
- `sb`
- `lib/core.sh`
- `lib/service.sh`
- `uninstall.sh`（或把卸载逻辑放进 `sb`，保留 `uninstall.sh` 作为独立入口）

**详细要求**
1. `lib/core.sh` 实现探测函数（供主页面顶部信息块使用）：
   - `core_root_check`：非 root 报错退出。
   - `core_detect_os`：读 `/etc/os-release` 得发行版名+版本。
   - `core_detect_arch`：读 `uname -m`，映射 `x86_64→amd64`、`aarch64→arm64`，其余报错。
   - `core_detect_virt`：`systemd-detect-virt` 优先，失败用 `virt-what` 兜底，再失败显示 `unknown`。
   - `core_detect_bbr`：读 `sysctl net.ipv4.tcp_congestion_control`，判断是否含 `bbr`。
   - `core_detect_ip_region`：`curl` 公网 IP 接口（如 `https://api.ipify.org` + 一个 IP 地理库）得 IP / 地区 / ISP；超时则用 `未知` 不阻塞。
   - `core_sb_status`：返回 sing-box 是否安装、是否运行、`sing-box version` 版本号、当前在线协议数（可先留 0）。
   - `info/warn/error/ok` 日志函数 + 颜色。
2. `install.sh`：解析参数（如 `--version x.y.z` 可选），最终调用主页面函数。
3. 主页面函数（放在 `sb` 或 `lib/core.sh` 中合适位置）：打印上方信息块 + 菜单，读取输入 `0-6`，路由到处理函数。P0 阶段：选项 1（安装/卸载）、0（退出）实现；2/3/4/5/6 先 `warn "功能尚未实现"` 后回到菜单。
4. 安装主链路（选项 1 的“安装”分支）：
   - 从 `https://github.com/SagerNet/sing-box/releases` 下载 latest stable 对应 arch 的压缩包，解压，安装二进制到 `/usr/local/bin/sing-box`，`chmod 755`。
   - 生成**最小可用** `config.json`（可仅 `inbounds` 占位 + `outbounds: [{type:direct}]`），放到 `/etc/sing-box/config.json`。
   - 写 systemd 单元 `/etc/systemd/system/sing-box.service`（`ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json`，`Restart=always`，`LimitNOFILE=100000`），`daemon-reload` + `enable` + `start`。
   - 软链 `sb` 到 `/usr/local/bin/sb`。
5. 卸载主链路（选项 1 的“卸载”分支）：`systemctl stop/disable sing-box`，删单元，`rm /usr/local/bin/sing-box`、`/usr/local/bin/sb`、`/etc/sing-box/config.json`；证书目录 `/etc/sing-box/ssl` 与 acme.sh 账户可提示是否一并删除。

**约束与陷阱**
- arch 映射必须正确，arm64 机器下错包会直接跑不起来。
- systemd 单元 `WantedBy=multi-user.target`，且首次 `start` 前先 `daemon-reload`。
- 下载建议带超时与重试；sha256 校验可留 TODO 注释但先不强制。
- 幂等：重复运行安装不应产生第二个 systemd 单元或重复软链。

**验收标准**
- 在干净 Debian/Ubuntu 上跑 `bash install.sh` → 显示主页面信息块（系统/指令集/虚拟化/BBR/IP地区/sing-box状态）→ 选 1 安装 → `sing-box` 进程运行、`sb` 命令可用、再次 `sb` 进入主页面且状态显示“已运行”。
- 选 1 卸载 → 进程停止、二进制与软链清除、再次 `sb` 提示“未安装”。

---

## Phase P1 · 证书模块（acme.sh 自动申请）

**目标**：实现 `lib/cert.sh`，用 acme.sh 自动签发并管理 Let's Encrypt 证书，支持 HTTP-01 与 DNS-01(Cloudflare)，统一存放到 `/etc/sing-box/ssl/`，并处理续期 reload。

**依赖**：P0（systemd reload 能力、root 环境）。

**需创建/修改文件**
- `lib/cert.sh`（新建）
- 主页面选项 3“变更证书配置”接入口（P0 中先占位，此处实现）

**详细要求**
1. `cert_install_acme`：安装 acme.sh（官方安装脚本或 git clone 到 `~/.acme.sh`），注册可用命令。
2. `cert_issue_http01 <domain>`：
   - 用 `acme.sh --issue -d <domain> --standalone`（standalone 需要 80 端口空闲；若 80 被占，提示或临时放行，见下方陷阱）。
   - 签发成功后 `acme.sh --install-cert -d <domain> --fullchain-file /etc/sing-box/ssl/fullchain.pem --key-file /etc/sing-box/ssl/privkey.pem --reloadcmd "systemctl reload sing-box"`。
   - 证书文件权限设 600，属主 root。
3. `cert_issue_dns01_cf <domain> <cf_token>`：
   - `export CF_Token=<cf_token>`（仅当前 shell，不写入磁盘明文；如需持久化放进 600 的 env 文件）。
   - `acme.sh --issue -d <domain> --dns dns_cf`，同样 install 到 `/etc/sing-box/ssl/` 并带 reloadcmd。
4. `cert_renew`：依赖 acme.sh 自带 cron（安装 acme.sh 时已注册）；确认 reloadcmd 指向 `systemctl reload sing-box`。
5. `cert_change`：变更证书配置（主页面选项 3）——切换验证方式、修改域名、强制重签（`--force`）、重装证书路径；变更后 `systemctl reload sing-box`。

**约束与陷阱**
- **不支持用户手动上传证书**，证书只能由脚本申请。
- DNS-01 仅 Cloudflare（其他服务商本期不做）。CF_Token 不要落盘明文；若必须持久化，放 `/etc/sing-box/.cf.env` 权限 600。
- HTTP-01 与端口开放策略协调：若用户在 P0/P2 选“仅开放节点端口/不开放”，签发阶段脚本需**临时放行 80**（用当前防火墙后端），完成挑战后回收；或明确提示用户先手动开放 80。
- 申请邮箱用 `no@eff.org` 或让用户可选输入。
- 证书目录提前 `mkdir -p /etc/sing-box/ssl`。

**验收标准**
- HTTP-01 模式：域名 A 记录指向本机、80 可用 → 能签出有效证书，`/etc/sing-box/ssl` 下有两个文件，`openssl x509 -in fullchain.pem -noout -dates` 正常。
- DNS-01(Cloudflare) 模式：填入 CF Token → 能签出有效证书（无需 80 端口）。
- 修改证书配置后 `sing-box` 能 reload 且不报错。

---

## Phase P2 · 代理配置（三协议共存）

**目标**：实现 `lib/config.sh` + `lib/protocol/*.sh`，生成包含 AnyTLS / Hysteria2 / TUIC 三个 inbound 的 `config.json`，共享同一证书，端口随机或用户自定义，凭证随机生成。

**依赖**：P0（config 路径、systemd reload）、P1（证书已签发到 `/etc/sing-box/ssl/`）。

**需创建/修改文件**
- `lib/config.sh`
- `lib/protocol/anytls.sh`
- `lib/protocol/hysteria2.sh`
- `lib/protocol/tuic.sh`
- `templates/config.json.tpl`
- 主页面选项 2“变更代理配置”接入口

**各协议 inbound 字段参考（sing-box ≥ 1.13）**
```jsonc
// AnyTLS (TCP)
{
  "type": "anytls", "tag": "anytls-in",
  "listen": "::", "listen_port": <PORT>,
  "users": [{ "name": "user1", "password": "<PASS>" }],
  "tls": { "enabled": true, "server_name": "<DOMAIN>",
           "certificate_path": "/etc/sing-box/ssl/fullchain.pem",
           "key_path": "/etc/sing-box/ssl/privkey.pem" }
  // padding_scheme 可留空用服务端默认，或给一组默认混淆规则
}

// Hysteria2 (UDP/QUIC)
{
  "type": "hysteria2", "tag": "hy2-in",
  "listen": "::", "listen_port": <PORT>,
  "up_mbps": 100, "down_mbps": 100,
  "users": [{ "name": "user1", "password": "<PASS>" }],
  "tls": { "enabled": true, "server_name": "<DOMAIN>",
           "certificate_path": "/etc/sing-box/ssl/fullchain.pem",
           "key_path": "/etc/sing-box/ssl/privkey.pem" }
  // 可选 obfs: { "type": "salamander", "password": "<OBS>" }
}

// TUIC v5 (UDP/QUIC)
{
  "type": "tuic", "tag": "tuic-in",
  "listen": "::", "listen_port": <PORT>,
  "users": [{ "name": "user1", "uuid": "<UUID>", "password": "<PASS>" }],
  "tls": { "enabled": true, "server_name": "<DOMAIN>",
           "certificate_path": "/etc/sing-box/ssl/fullchain.pem",
           "key_path": "/etc/sing-box/ssl/privkey.pem" }
  // congestion_control 由客户端协商，服务端可不显式设
}
```

**详细要求**
1. `config_gen`：读取域名、三个端口（随机或用户给）、三个密码（随机）、TUIC 的 uuid（用 `sing-box generate uuid` 或 `uuidgen`），组装完整 `config.json`（含 `inbounds` 三协议 + 基础 `route`/`dns`/`outbounds:[{type:direct}]`，可加 `sniff`）。
2. 三个 inbound 的 `tls` 全部指向 `/etc/sing-box/ssl/` 同一份证书。
3. 端口：默认随机且不互相同、不与已占用端口冲突；用户可在安装问答中逐个指定。
4. 生成后必须执行 `sing-box check -c /etc/sing-box/config.json` 校验，通过再 `systemctl reload sing-box`。
5. 变更代理配置（主页面选项 2）：重生成端口/凭证/可开关某协议，校验后 reload。

**约束与陷阱**
- 三个协议 `tls.enabled` 必须 true，禁止无证书模式。
- 端口不可重复；若用户指定端口被占要报错或改随机。
- TUIC 必须用 `uuid`+`password` 双字段；Hysteria2 / AnyTLS 用 `password`。
- AnyTLS `padding_scheme` 留空即可用服务端默认，不要写错格式导致 check 失败。
- 配置必须有 `outbounds: direct` 否则 check 失败。

**验收标准**
- 生成的 `config.json` 通过 `sing-box check`。
- 启动后三个 inbound 各自监听端口；`tls` 使用真实证书（可用 `openssl s_client` 验证 443/对应端口握手成功）。

---

## Phase P3 · 节点输出（URI + 二维码）

**目标**：实现 `lib/node.sh`，根据当前配置生成三种协议的可导入 URI，终端打印 + 二维码，并写入 `nodes.txt`。

**依赖**：P2（配置中已知域名/端口/密码/uuid）。

**需创建/修改文件**
- `lib/node.sh`（新建）
- 主页面增加“查看节点”入口（可并入选项 4 重启附近，或独立，按你习惯；最终主页面需能打印节点）

**节点 URI 格式**
```
# AnyTLS（客户端 GUI 格式尚未完全统一，若不被识别则额外输出 sing-box outbound JSON 兜底）
anytls://<PASS>@<DOMAIN>:<PORT>?sni=<DOMAIN>&insecure=0#<NAME>

# Hysteria2
hysteria2://<PASS>@<DOMAIN>:<PORT>?alpn=h3&sni=<DOMAIN>&insecure=0#<NAME>
# 若启用 salamander obfs：追加 &obfs=salamander:<OBS>

# TUIC v5
tuic://<UUID>:<PASS>@<DOMAIN>:<PORT>?congestion_control=bbr&udp_relay_mode=native&sni=<DOMAIN>&alpn=h3&insecure=0#<NAME>
```
说明：`insecure=0` 表示客户端严格校验证书（因使用真实域名证书）。节点名 `<NAME>` 可用域名或自定义。

**详细要求**
1. `node_gen`：从 `config.json` 解析出各协议端口/密码/uuid/域名，按上面格式拼 URI。
2. 二维码：`qrencode` 可用时生成终端可显示的二维码（UTF8/ANSI），每个节点一个；不可用时退化为只打印 URI（不报错）。
3. 输出：终端打印全部 URI + 二维码；写入 `/etc/sing-box/nodes.txt` 权限 600。
4. **严禁生成订阅链接**（不要输出 http(s)://.../sub 之类的订阅地址）。
5. AnyTLS 兜底：若目标 GUI 不识别 `anytls://`，额外在终端输出该节点的 sing-box outbound JSON 片段，供手动导入。

**约束与陷阱**
- URI 中特殊字符需正确拼接，密码/uuid 直接明文放入 URI（这是协议 URI 标准做法）。
- 不要因为 qrencode 缺失而中断脚本。
- nodes.txt 权限必须 600。

**验收标准**
- 安装完成或选“查看节点”后，终端显示三种协议 URI 与二维码；`nodes.txt` 存在且权限 600。
- 把 Hysteria2 / TUIC 的 URI 导入支持客户端可成功连接（AnyTLS 以实际客户端为准，不行则 outbound JSON 兜底可用）。

---

## Phase P4 · 管理菜单落地

**目标**：把主页面所有选项做成完整可用功能。

**依赖**：P1、P2、P3。

**需创建/修改文件**
- `sb`（主逻辑整合）
- `lib/cert.sh`（变更证书配置）
- `lib/config.sh`（变更代理配置）
- 内核版本切换逻辑（可放 `lib/core.sh` 或新 `lib/version.sh`）

**详细要求（对应主页面 1-6）**
1. 一键安装 / 卸载：复用 P0 链路；已安装时此选项变为“卸载”（带确认）。
2. 变更代理配置：调用 P2 的 `config_gen`（可交互改端口/凭证/开关协议），校验后 reload。
3. 变更证书配置：调用 P1 的 `cert_change`（切 HTTP-01/DNS-01、改域名、强制重签），reload。
4. 重启 Sing-Box：`systemctl restart sing-box` 并显示状态。
5. 更新 / 切换内核版本：列出可用 sing-box 版本（查 GitHub releases），下载指定版本替换 `/usr/local/bin/sing-box`（切换前备份当前二进制），`sing-box check` 通过后 reload；支持回滚到备份。
6. 更新脚本：从项目源拉取最新 `install.sh`/`sb`/`lib/*` 覆盖（保留本机 `/etc/sing-box/config.json` 与 `/etc/sing-box/ssl/`），不破坏用户配置。
7. 退出：返回 shell。

**约束与陷阱**
- 任何“变更”操作后必须 reload 且刷新主页面状态显示。
- 内核版本切换前必须备份当前二进制，失败可回滚。
- 脚本自更新不能覆盖用户证书与配置；只更新代码文件。
- 危险操作（卸载、切换版本）需二次确认。

**验收标准**
- 主页面 7 个选项全部可用；操作后状态正确刷新；卸载干净；版本切换可回滚；脚本自更新后配置不丢。

---

## Phase P5 · 打磨（防火墙/降权/自测/文档）

**目标**：完善防火墙后端适配、sing-box 降权运行、编写自测清单与 README。

**依赖**：P0–P4。

**需创建/修改文件**
- `lib/service.sh` 或新增 `lib/firewall.sh`
- `README.md`
- systemd 单元（降权相关字段）

**详细要求**
1. 防火墙后端：`detect_firewall` 按 `ufw`→`firewalld`→`iptables` 优先级探测；`open_port <proto tcp|udp> <port>` 适配各后端；实现安装时“端口开放三选一”：① 全部（80 + 3 节点端口）② 仅节点端口 ③ 不开放（提示用户）。HTTP-01 模式下即便选②③ 也需在签发阶段临时放行 80，完成后回收（记录临时规则以便删除）。
2. 降权运行：sing-box 以非 root 用户运行。方案二选一并在 README 说明：a) systemd `User=` + `AmbientCapabilities=CAP_NET_BIND_SERVICE`（端口 ≥1024 时无需 cap）；b) `setcap` 给二进制绑定能力。确保降权后仍能监听各 inbound 端口。
3. 自测清单（写入 README 或 `TESTING.md`）：干净机安装；HTTP-01 与 DNS-01 各测一遍；节点 URI 导入客户端连通；证书续期演练（可临时调短）；变更代理/证书；卸载干净。
4. `README.md`：项目简介、支持系统、依赖、三种协议说明、两种证书模式、端口开放三选一、主页面菜单说明、节点导入方式、卸载与更新、已知限制（AnyTLS 客户端兼容性）。

**约束与陷阱**
- 防火墙操作不要误删已有规则；临时放行的 80 必须回收。
- 降权不能导致 <1024 端口无法监听（本期端口均为高位随机，影响小，但仍要正确）。
- README 不暴露任何私密字段示例，密码用占位符。

**验收标准**
- 三种端口开放选项均按预期放行/提示。
- 降权后 `sing-box` 正常运行且三协议可连。
- 按自测清单在干净机走通；README 完整可读。
