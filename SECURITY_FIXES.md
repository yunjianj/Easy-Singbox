# easy-singbox 高危安全漏洞修复文档

> 交付对象：负责实施修改的 AI/开发者
> 范围：仅本文件列出的 2 个高危问题。按编号逐项修复，不要扩大改动范围，不要顺手重构无关代码。
> 全局约束：改动后 `bash -n` 语法检查必须通过；不改变任何用户可见的交互流程与输出格式；所有现有功能（安装/卸载/变更/诊断/端口跳跃）不得回归。
> 项目版本基线：v1.1.1（sb:SB_SCRIPT_VERSION）。修改完成后将 SB_SCRIPT_VERSION 与根目录 VERSION 同步升至 1.1.2。

---

## 问题 1：供应链下载无完整性校验（多处 root 任意代码执行入口）

### 1.1 现状与风险

以下 4 处下载远程内容后直接以 root 执行，均无任何签名 / sha256 校验：

| # | 位置 | 内容 |
|---|------|------|
| a | `lib/cert.sh` `cert_install_acme()`（约 12 行） | `curl -sL https://get.acme.sh \| sh` |
| b | `sb` `sb_self_update()`（约 297-331 行） | 从 jsDelivr 下载脚本，`cp -rf` 覆盖本地后由用户再次执行 |
| c | `sb` `sb_download()`（约 44-64 行） | 下载 sing-box 二进制，仅 `gzip -t` 检查后 `install -m 755` |
| d | `sb.sh` 引导脚本（约 22-33 行） | 下载 GitHub tarball 后解压执行 install.sh |

GitHub 账号被盗 / jsDelivr 缓存投毒 / 仓库被入侵，都会直接转化为已部署服务器的 root 代码执行。

### 1.2 修复要求

**(c) sing-box 二进制 —— 必须做，收益最高：**

- **实勘修正（v1.2.2）**：实测 sing-box 官方 release **不附带** `sing-box-${version}-checksums.sha256`（最新版亦无），原"每个 release 均附带"前提有误。但 GitHub Release API（`/repos/SagerNet/sing-box/releases/tags/v{version}`）为每个资产提供官方 `digest` 字段（`sha256:<hex>`），作为权威校验锚点。
- 在 `sb_download()` 中：下载 tar.gz 后按以下顺序校验，通过才允许 `tar` 解压与 `install`：
  1. **首选**：查询 Release API 提取目标资产 digest，与本地 `sha256sum` 比对；
  2. **备选**：发行方若附带 `checksums.sha256`（部分项目提供），下载并比对对应行；
  3. **兜底**：以上均不可用（API 限流/无校验工具）时打印显著警告并要求用户确认，不得静默跳过。
  - 校验失败打印期望值与实际值，删除临时目录并 `return 1`。
  - `sha256sum` 缺失时可用 `shasum -a 256`（macOS 风格环境）备选。

**(b) 脚本自更新 —— 必须做：**

- 目标：把"内容来源"从 jsDelivr 第三方缓存改回 GitHub 官方域名，并加两层防护：
  1. `SB_UPDATE_BASE` 默认值改为 `https://raw.githubusercontent.com/yunjianj/Easy-Singbox/main`（保留环境变量可覆盖的能力）。
  2. 下载完成后、覆盖本地之前，向用户展示变更摘要：对每个与本地不同的文件打印文件名（`cmp -s` 比对即可，不必输出 diff 全文），并 `core_prompt_yn` 要求确认后再覆盖。确认前绝不写 `$SB_DIR`。
- `sb_script_latest()`（读取 VERSION 的函数）同步把 jsDelivr 域名替换为 raw.githubusercontent.com，避免继续依赖第三方缓存。

**(a) acme.sh —— 必须做：**

- 放弃 `curl ... | sh` 管道模式，改为"先落盘、再校验、后执行"：
  1. `curl -fsSL https://get.acme.sh -o "$tmp/acme-install.sh"`；
  2. 基本健全性检查：文件非空、首行含 `sh` shebang（`head -1` 匹配 `^#!.*sh`）；
  3. 有条件时做 Pin 校验：acme.sh 官方仓库 `acmesh-official/acme.sh` 的 master 提供稳定地址 `https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh`，可改为直接 `git clone --depth 1`（若系统有 git）或下载该文件后 `sh acme.sh --install` 安装——acme.sh 支持以脚本方式自安装（`./acme.sh --install -m my@example.com`）。任一方式都必须避免 `curl | sh` 盲执行。
  4. 无 git 且下载失败时，退回现状（get.acme.sh）但打印警告要求确认，不得静默。

**(d) 引导脚本 —— 尽力做：**

- `sb.sh` 下载 tarball 后，先校验解压出的 `install.sh` 首行为 shebang、`sb`/`lib/*.sh` 齐全，再执行。完整签名校验在此场景难以实施（引导时本地无信任锚），最低要求：域名固定 GitHub（已是）、解压前后校验 gzip 完整性（已有）+ 文件齐套检查。

### 1.3 验收标准

- 断网或篡改 hosts 模拟下载失败时，四条路径均安全退出、不留半成品文件。
- `sb 7`（切换内核版本）与 `sb 8`（自更新）在正常网络下行为不变（自更新多一步确认属预期变更）。
- 手工把 GitHub API digest 或 checksums.sha256 中对应哈希改错一位，`sb_download` 必须拒绝安装（打印期望/实际哈希并清理临时文件）。

---

## 问题 2：`chown -R` 把 Cloudflare API Token 与全部凭证交给低权限服务用户

### 2.1 现状与风险

服务以 `singbox` 系统用户运行（`lib/service.sh` systemd 单元 `User=singbox`）。但三处对整个 `/etc/sing-box` 递归授权：

| 位置 | 函数 |
|---|---|
| `lib/service.sh` `service_ensure_user()` 末行 `chown -R singbox:singbox "$SB_DIR_CONF"` |
| `lib/service.sh` `service_chown_conf()` `chown -R singbox:singbox "$SB_DIR_CONF"` |
| `lib/cert.sh` `cert_install_files()` 末行 `chown -R singbox:singbox "$SB_DIR_CONF"` |

后果——服务进程实际不需要、却被授予了以下文件的属主权限：

- `/etc/sing-box/.cf.env`：Cloudflare API Token。`cert_issue_dns01_cf()` 明明先写了 `chown root:root; chmod 600`，随后被 `cert_install_files()` 的递归 chown 覆盖成 singbox。**sing-box 进程一旦被 RCE，攻击者直接获得该域名 DNS 编辑权**（可劫持解析、抢签证书）。
- `/etc/sing-box/.state`：三协议全部密码 + TUIC UUID。
- `/etc/sing-box/nodes.txt`：全部节点 URI（含凭证）。

### 2.2 修复要求

新增一个精确授权函数（放在 `lib/service.sh`），并**删除/替换所有 `chown -R`**：

```bash
# 服务运行用户仅需要读 config.json 与证书私钥；
# .cf.env / .state / nodes.txt / diag.log 必须保持 root:root 600，
# 绝不交给 singbox（进程沦陷时不得泄漏 CF Token 与全部凭证）。
service_grant_conf() {
  id singbox >/dev/null 2>&1 || return 0
  chown singbox:singbox "$SB_DIR_CONF" 2>/dev/null || true
  chmod 755 "$SB_DIR_CONF" 2>/dev/null || true
  for f in "$SB_CONF" "$SB_DIR_SSL/fullchain.pem" "$SB_DIR_SSL/privkey.pem"; do
    [[ -f "$f" ]] && chown singbox:singbox "$f" 2>/dev/null || true
  done
  # 敏感文件强制回到 root:root 600（修复历史安装中被 chown -R 污染的存量机器）
  for f in "$SB_STATE" "$SB_NODES" "$SB_CF_ENV" "$SB_DIR_CONF/diag.log"; do
    [[ -f "$f" ]] && { chown root:root "$f" 2>/dev/null || true; chmod 600 "$f" 2>/dev/null || true; }
  done
  chmod 755 "$SB_DIR_SSL" 2>/dev/null || true
}
```

逐点修改：

1. `lib/service.sh` `service_ensure_user()`：删除末尾 `chown -R ...` 一行，函数只负责创建用户。
2. `lib/service.sh` `service_chown_conf()`：函数体整体替换为调用 `service_grant_conf`（保留函数名，调用点无需改动）。
3. `lib/cert.sh` `cert_install_files()`：`chown -R singbox:singbox "$SB_DIR_CONF"` 替换为 `service_grant_conf`（注意保持文件开头的 `root:root + chmod 600` 逻辑，随后由 service_grant_conf 精确放行证书两文件）。
4. 全项目 `grep -n "chown -R" lib/ sb sb.sh` 确认已无针对 `$SB_DIR_CONF` 的递归授权。

权限模型（修复后的目标状态）：

| 文件 | 属主 | 权限 |
|---|---|---|
| /etc/sing-box（目录） | singbox:singbox | 755 |
| config.json | singbox:singbox | 600 |
| ssl/（目录） | root:root | 755（目录需可进入） |
| ssl/fullchain.pem, ssl/privkey.pem | singbox:singbox | 600 |
| .state / nodes.txt / .cf.env / diag.log | root:root | 600 |

### 2.3 顺带必须修复的相关缺陷（同一改动内完成）

**2.3.1 umask 竞态**：`lib/node.sh` 的 `tee "$SB_NODES"` 与 `lib/cert.sh` 的 `printf > "$SB_CF_ENV"` 都在默认 umask（022）下创建文件——含密码的文件短暂为 644。修复：在 `sb` 的 `set -euo pipefail` 之后紧邻添加 `umask 077`；`node_gen()` 中把 `| tee "$SB_NODES" >/dev/null` 改为写入后 `chmod 600`（umask 077 后 tee 创建即 600，保险起见保留 chmod）。

**2.3.2 systemd 单元移除多余 capability**：`lib/service.sh` `service_write_unit()` 中注释已说明"端口均为高位随机，无需 CAP_NET_BIND_SERVICE"，却仍写了 `AmbientCapabilities=CAP_NET_BIND_SERVICE`。删除该行，并补充最小加固（不改变运行行为，均为纯收紧）：

```ini
NoNewPrivileges=true
ProtectSystem=strict
ReadOnlyPaths=/etc/sing-box
ProtectHome=true
PrivateTmp=true
```

注意：sing-box 不需要写任何本地路径（日志走 stdout/journald），上述指令应可直接生效；若安装后 `systemctl start sing-box` 失败，逐条回退定位（优先怀疑 ProtectSystem），并在文档中记录结论。

### 2.4 验收标准

- 全新安装完成后执行 `ls -la /etc/sing-box /etc/sing-box/ssl`，权限表必须与 2.2 一致；`id -n singbox; su -s /bin/sh singbox -c 'cat /etc/sing-box/.cf.env'` 必须失败（Permission denied）。
- 在一台**旧版本装过、DNS-01 模式**的机器上重复安装/执行 `sb 3` 重签证书，`.cf.env` 必须被纠回 root:root 600（验证存量修复逻辑）。
- DNS-01 与 HTTP-01 两种模式下服务均可正常启动、`sb 9` 诊断中"singbox 用户可读: config.json / fullchain.pem / privkey.pem"三项全部通过。
- `systemctl show sing-box | grep -E 'Capability|Protect'` 输出符合预期（无 CAP_NET_BIND_SERVICE）。
- 重启服务器后服务自启、端口跳跃（iptables REDIRECT）仍生效。

---

## 回归测试清单（两项修复合并后统一跑一遍）

1. 全新 VPS：`bash install.sh` 走 HTTP-01 + 随机端口 + 端口跳跃 → 安装成功、节点可连。
2. 全新 VPS：DNS-01 + CF Token → 安装成功；`.cf.env` 属主 root:root。
3. `sb 2` 变更配置、`sb 3` 重签证书、`sb 6` 重启看节点、`sb 9` 诊断 → 全部正常。
4. `sb 7` 切换内核版本 → checksums 校验路径生效。
5. `sb 8` 自更新 → 出现变更确认提示，确认后更新成功；拒绝则本地文件未被改动。
6. `sb uninstall` → 卸载干净（含用户、软链、防火墙跳跃规则）。
