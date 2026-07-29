# sub_to_gist

> 网页内容中转推送器 — 读取远程网页内容，原样推送到 GitHub Gist，作为下游内容处理服务的数据源。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Shell: POSIX sh](https://img.shields.io/badge/Shell-POSIX%20sh-blue.svg)](https://en.wikipedia.org/wiki/POSIX)
[![Platform: OpenWrt+Linux](https://img.shields.io/badge/Platform-OpenWrt%20%7C%20fnOS%20%7C%20Linux-green.svg)](#兼容环境)

---

## 项目背景

下游内容处理服务部署在 Cloudflare Workers / Vercel 等边缘平台时，常常**无法直接访问源站点 URL**（被源站点防火墙拦截或 IP被封）。

`sub_to_gist` 解决这个问题：在能访问源站点的设备上（OpenWrt 路由器 / 飞牛OS NAS / 任意 Linux）定时拉取网页内容，原样推送到 GitHub Gist，下游服务再从 Gist raw URL 拉取，绕过访问限制。

```
源站点  ──HTTPS──▶  sub_to_gist (你的设备)  ──HTTPS──▶  GitHub Gist  ──HTTPS──▶  下游内容处理服务
                              自定义 UA + 请求头         Bearer PAT              raw URL
```

---

## 功能特性

- **多环境自适应**：OpenWrt（BusyBox ash）/ 飞牛OS fnOS（bash）/ 通用 Linux（dash），运行时自动检测
- **多源内容管理**：每个内容源一个独立任务配置，CLI 表格化查看状态
- **交互式菜单**：添加 / 查看 / 删除 / 运行 / cron 管理 / 卸载，6 个选项一键操作
- **定时推送**：cron 定时执行，BEGIN/END 标记原子块，幂等安装/卸载
- **失败降级**：永不修改 gist 文件内容，仅更新 gist description 反映状态（OK / FAIL xN / CRITICAL）
- **自定义 UA**：每个任务可设置独立 User-Agent 和额外请求头，绕过源站点 UA 检测
- **安全加固**：禁止 source 配置 / mkdir 原子锁 / curl --config - stdin 注入敏感参数 / 日志自动脱敏
- **sysupgrade 保留**：部署到 `/etc/sub_to_gist/`，OpenWrt 固件升级后配置与 state 不丢失
- **POSIX sh 兼容**：禁用 bash 专有语法，一份脚本处处运行

---

## 兼容环境

| 环境 | Shell | 包管理器 | cron 配置 |
|------|-------|----------|-----------|
| OpenWrt / ImmortalWrt | BusyBox ash | opkg | `/etc/crontabs/root`（5 字段） |
| 飞牛OS fnOS | bash | apt-get | `/etc/cron.d/sub_to_gist`（6 字段含 root） |
| 通用 Linux（Debian/Ubuntu/CentOS） | bash / dash | apt-get / yum / dnf | `/etc/cron.d/sub_to_gist`（6 字段含 root） |

脚本启动时通过 `detect_env()` 自动检测环境，无需手动指定。

---

## 快速开始

### 一键部署

```sh
# 下载并部署（OpenWrt / 飞牛OS / 通用 Linux 均可）
sh -c "$(curl -sSL https://raw.githubusercontent.com/ciskonc/sub_to_gist/main/src/install.sh)"
```


> **注意**：URL 必须用双引号 `"` 包裹，**不能**用反引号 `` ` ``（否则 shell 会将其解释为命令替换，导致脚本内容被当作命令执行）。

或手动部署：

```sh
# 1. 克隆仓库
git clone https://github.com/ciskonc/sub_to_gist.git
cd sub_to_gist

# 2. 执行部署脚本
sh src/install.sh
```

### 部署后配置

```sh
# 1. 编辑配置文件，填入 GitHub Token
vi /etc/sub_to_gist/config.conf
# 找到 GIST_TOKEN 行，替换为你的 PAT

# 2. 启动交互菜单
/etc/sub_to_gist/pusher.sh
```

### GitHub Token 生成

1. 访问 https://github.com/settings/tokens
2. 选择 **Fine-grained tokens** → Generate new token
3. 权限：仅勾选 **Account permissions → Gists → Read and write**
4. 过期时间：建议 90 天
5. 复制 token（格式 `github_pat_xxx`），填入 `config.conf`

---

## 使用方法

### 交互菜单

```sh
/etc/sub_to_gist/pusher.sh
```

```
=== Gist 内容推送器 v1.0.2 ===
运行环境：openwrt
Token 状态：已配置
当前已有 2 个推送任务

  1) 添加内容推送到 Gist
  2) 查看现在已有推送
  3) 删除任务
  4) 立即运行所有任务
  5) 安装/管理 cron 定时
  6) 卸载本工具和清理 cron
  7) 配置 Gist Token
  8) 检查更新
  0) 退出
请选择 [0-6]:
```

### CLI 表格输出

选择菜单 2 查看任务列表：

```
任务ID          任务名称              上次结果    连续失败     Gist URL
-----------------------------------------------------------------------------------------
source_a       源站点A                 ✓ OK       0            https://gist.githubusercontent.com/abc.../raw/source_a.txt
proxy_task       代理B                 ✗ FAIL     3            https://gist.githubusercontent.com/def.../raw/proxy_task.txt
```

### 命令行用法

```sh
pusher.sh                          # 启动交互菜单（默认）
pusher.sh run-all                  # 运行所有任务（cron 调用）
pusher.sh run <task_id>            # 运行单个任务
pusher.sh rotate-gist <task_id>    # 删除并重建 gist（token 轮换时使用）
pusher.sh cron-install [hh:mm]     # 安装 cron 定时（默认 06:00）
pusher.sh cron-uninstall           # 卸载 cron 定时
pusher.sh check-deps               # 检查依赖
pusher.sh install-deps             # 安装依赖（自适应环境）
pusher.sh version                  # 显示版本
pusher.sh help                     # 显示帮助
```

详细使用说明见 [src/README.md](src/README.md)。

---

## 配置说明

### 全局配置 `/etc/sub_to_gist/config.conf`

| 字段 | 必填 | 说明 |
|------|------|------|
| `GIST_TOKEN` | ✅ | GitHub PAT（fine-grained，仅 gist 权限） |
| `GIST_DESCRIPTION_PREFIX` | 否 | Gist description 前缀，默认 `sub_to_gist` |

### 任务配置 `tasks.d/{task_id}.conf`

| 字段 | 必填 | 说明 |
|------|------|------|
| `TASK_NAME` | ✅ | 任务显示名称 |
| `TASK_URL` | ✅ | 源 URL（必须 `https://` 开头） |
| `TASK_UA` | 否 | 自定义 User-Agent（留空使用 curl 默认 UA） |
| `TASK_HEADERS` | 否 | 额外请求头，格式 `Key: Value\|Key2: Value2` |
| `TASK_GIST_ID` | 自动 | 首次推送后自动填入，勿手动修改 |
| `TASK_GIST_FILENAME` | 自动 | Gist 中的文件名，默认 `{task_id}.txt` |

任务 ID 命名规则：`^[a-z][a-z0-9_]{0,31}$`（小写字母开头，仅小写字母/数字/下划线，最长 32 字符）。

---

## 失败处理状态机

| 拉取结果 | cache 存在 | gist 文件内容 | gist description | 失败计数 |
|----------|------------|---------------|-------------------|----------|
| OK | 是 | 新内容 | `[OK] ${TASK} ${time}` | → 0 |
| OK | 否 | 新内容 | `[OK] ${TASK} ${time}` | → 0 |
| FAIL | 是 | **不改**（保留上次成功内容） | `[FAIL x${N+1}] ${TASK} ${time}` | +1 |
| FAIL | 否 | 错误占位内容 | `[INIT FAIL] ${TASK} ${time}` | → 1 |
| FAIL（≥7 次） | 是 | **不改** | `[CRITICAL x${N}] ${TASK} ${time}` | +1 |

**核心原则**：永不修改 gist 文件内容，仅更新 gist `description` 字段。原因：JSON / base64 内容源加注释会破坏下游内容处理服务解析；清空 gist 会导致下游内容处理服务拉到空内容。

---

## 安全特性

| 特性 | 实现 |
|------|------|
| 配置加载 | 手动 `KEY="VALUE"` 解析，禁止 `source`（防命令注入） |
| 任务 ID 校验 | 白名单 `^[a-z][a-z0-9_]{0,31}$`（防路径穿越） |
| Token 注入 | `curl --config -` 从 stdin 注入敏感参数，避免出现在 `/proc/PID/cmdline` |
| 日志脱敏 | 自动过滤 `ghp_*` / `github_pat_*` / `Bearer *` / `token=*` / `password=*` |
| 文件权限 | 配置与 state 文件 `chmod 600`，目录 `chmod 700`，脚本启动 `umask 077` |
| 并发锁 | `mkdir` 原子锁（OpenWrt 无 flock）+ trap 清理 + PID 死亡检测 |
| Secret Gist | 非私密，URL 即访问凭据，token 轮换请用 `rotate-gist` 命令 |

> ⚠ **重要安全提示**：
> 1. GitHub Secret Gist **不是私密 gist**，任何知道 URL 的人均可匿名访问
> 2. Gist 内置 git 版本历史，曾推送过的内容视为永久泄露，token 轮换请用 `rotate-gist`
> 3. 建议使用 fine-grained PAT，仅 `gist` 权限，90 天过期

---

## 部署目录结构

```
/etc/sub_to_gist/
├── pusher.sh              # 主脚本（chmod 755）
├── config.conf            # 全局配置（chmod 600，含 Token）
├── tasks.d/               # 任务配置目录（chmod 700）
│   ├── source_a.conf
│   └── proxy_task.conf
├── cache.d/               # 源内容缓存（失败时保留上次内容）
├── state.d/               # 任务状态（最后结果 / 失败计数）
├── logs/                  # 日志目录（按日期分文件）
└── run.lock/              # 原子锁目录（运行时存在）
```

> OpenWrt 部署到 `/etc/` 可被 sysupgrade 默认保留，固件升级后配置与 state 不丢失。

---

## 故障排查

### 创建 gist 失败

| 现象 | 可能原因 | 处理 |
|------|----------|------|
| HTTP 401 | Token 无效或过期 | 重新生成 PAT，更新 `config.conf` |
| HTTP 403 | Token 无 `gist` 权限 | 重新生成 PAT，勾选 `gist` 权限 |
| HTTP 422 | 文件名冲突或内容超 1MB | 检查文件名；源内容超 1MB 需联系源站点 |
| 速率限制 | 超过 5000 req/h | 减少 cron 频率 |

### 拉取内容失败

| 现象 | 可能原因 | 处理 |
|------|----------|------|
| HTTP 403 | UA 被源站点拦截 | 添加任务时填写自定义 UA |
| HTTP 404 | 源 URL 失效 | 联系源站点获取新 URL |
| SSL 证书错误 | CA 证书缺失 | 运行 `pusher.sh install-deps` |

更多故障排查见 [src/README.md](src/README.md) §十。

---

## 卸载

### 通过菜单

运行 `pusher.sh` → 选项 6 → 确认卸载。

### 手动卸载

```sh
/etc/sub_to_gist/pusher.sh cron-uninstall    # 先清理 cron
rm -rf /etc/sub_to_gist/                     # 再删除目录
```

> 卸载**不会**删除已创建的 GitHub Gist。如需清理，请手动到 https://gist.github.com 删除。

---

## 关联项目

- 下游内容处理服务 — 下游内容处理服务，本工具产出的 Gist raw URL 作为其内容输入
- [openwrt-easytier-updater](https://github.com/ciskonc/openwrt-easytier-updater) — 同为 OpenWrt POSIX sh 工具，共享 shell 兼容性经验

---

## 技术实现

- **语言**：POSIX sh（兼容 BusyBox ash / bash / dash）
- **依赖**：curl + CA 证书（脚本自动检测并提示安装）
- **代码量**：主脚本 ~1386 行 / 部署脚本 ~339 行 / 使用说明 ~353 行
- **无第三方依赖**：不依赖 jq / Python / Node.js，纯 shell + awk + sed

---

## 开发

本项目经过 4 维度对抗审查（OpenWrt 兼容性 / 安全性 / Gist API+失败处理 / 菜单+cron），26 个 Critical 问题全部修复。

详见 [src/README.md](src/README.md) 完整使用说明。

---

## License

[MIT](LICENSE) © 2026 ciskonc
