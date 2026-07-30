# sub_to_gist — 使用说明

> 网页内容中转推送器：读取远程网页内容，原样推送到 GitHub Gist，作为下游内容处理服务的数据源。

---

## 兼容环境

| 环境 | Shell | 包管理器 | cron 配置 |
|------|-------|----------|-----------|
| OpenWrt / ImmortalWrt | BusyBox ash | opkg | `/etc/crontabs/root`（5 字段） |
| 飞牛OS fnOS | bash | apt-get | `/etc/cron.d/sub_to_gist`（6 字段含 root） |
| 通用 Linux（Debian/Ubuntu/CentOS） | bash / dash | apt-get / yum / dnf | `/etc/cron.d/sub_to_gist`（6 字段含 root） |

脚本启动时通过 `detect_env()` 自动检测环境，无需手动指定。

---

## 一、部署

### 1.1 网络一键安装（推荐）

无需 clone 仓库，直接在目标设备执行（OpenWrt / 飞牛OS / 通用 Linux 均可）：

```sh
sh -c "$(curl -sSL https://raw.githubusercontent.com/ciskonc/sub_to_gist/main/src/install.sh)"
```

> **注意**：URL 必须用双引号 `"` 包裹（不能用反引号 `` ` ``，否则会被 shell 解释为命令替换）。脚本会自动检测网络安装模式，从 GitHub 下载 pusher.sh 和 config.example 到临时目录后部署。

### 1.2 本地部署（clone 仓库后）

```sh
git clone https://github.com/ciskonc/sub_to_gist.git
cd sub_to_gist/src
sh install.sh
```

部署脚本会执行 5 个步骤：检查依赖 → 创建目录 → 部署脚本与配置 → 设置权限 → 验证部署。

### 1.3 静默部署（使用默认值）

```sh
sh install.sh --auto
```

### 1.4 部署结果

| 路径 | 权限 | 说明 |
|------|------|------|
| `/etc/sub_to_gist/pusher.sh` | 755 | 主脚本 |
| `/etc/sub_to_gist/config.conf` | 600 | 全局配置（含 Token，必须 600） |
| `/etc/sub_to_gist/tasks.d/` | 700 | 任务配置目录（每任务一个 `.conf`） |
| `/etc/sub_to_gist/cache.d/` | 700 | 源内容缓存目录 |
| `/etc/sub_to_gist/state.d/` | 700 | 任务状态目录（最后结果 / 失败计数） |
| `/etc/sub_to_gist/logs/` | 700 | 日志目录（按日期分文件） |

> OpenWrt 部署到 `/etc/` 可被 sysupgrade 默认保留，固件升级后配置与 state 不丢失。

---

## 二、配置

### 2.1 全局配置 `/etc/sub_to_gist/config.conf`

**推荐方式**：启动菜单后选择「7) 配置 Gist Token」，脚本会交互式引导输入并自动验证有效性。

```sh
/etc/sub_to_gist/pusher.sh
# 选择 7) 配置 Gist Token
```

**手动方式**（也可直接编辑文件）：

```sh
vi /etc/sub_to_gist/config.conf
```

关键字段：

| 字段 | 必填 | 说明 |
|------|------|------|
| `GIST_TOKEN` | ✅ | GitHub PAT（fine-grained，仅 `gist` 权限，90 天过期） |
| `GIST_DESCRIPTION_PREFIX` | 否 | Gist description 前缀，默认 `sub_to_gist` |

PAT 生成地址：https://github.com/settings/tokens

> ⚠ 配置文件格式强制为 `KEY="VALUE"` 单行赋值，禁止使用 `source` 加载（命令注入防护）。
>
> ℹ 关于「单 token + 多 gist」设计：所有任务共用同一个 GitHub 账号的 PAT，但每个任务推送到独立的 Gist 文件（通过 `TASK_GIST_ID` 区分）。如需使用不同 GitHub 账号，请创建多个 sub_to_gist 实例（不同 `INSTALL_DIR`）。

### 2.2 任务配置 `tasks.d/{task_id}.conf`

每个内容源一个任务配置文件，建议通过菜单选项 1 添加（自动生成），也可手动创建。字段：

| 字段 | 必填 | 说明 |
|------|------|------|
| `TASK_NAME` | ✅ | 任务显示名称（用于菜单与日志） |
| `TASK_URL` | ✅ | 源 URL（必须 `https://` 开头） |
| `TASK_UA` | 否 | 自定义 User-Agent（留空使用 curl 默认 UA） |
| `TASK_HEADERS` | 否 | 额外请求头，格式 `Key: Value\|Key2: Value2` |
| `TASK_GIST_ID` | 否 | 已有 Gist ID 或 URL（留空则首次运行时自动创建新 Gist），支持格式：`https://gist.github.com/{user}/{id}` / 裸 ID（20-40 位十六进制） |
| `TASK_GIST_FILENAME` | 自动 | Gist 中的文件名，默认 `{task_id}.txt` |

任务 ID 命名规则：`^[a-z][a-z0-9_]{0,31}$`（小写字母开头，仅小写字母/数字/下划线，最长 32 字符）。

---

## 三、交互菜单

启动菜单：

```sh
/etc/sub_to_gist/pusher.sh
```

或直接运行（无参数等同于 `menu`）。

### 菜单选项

```
=== Gist 内容推送器 v1.0.6 ===
运行环境：openwrt
Token 状态：已配置 / 未配置
当前已有 N 个推送任务

  1) 添加内容推送到 Gist
  2) 查看现在已有推送
  3) 删除任务
  4) 立即运行所有任务
  5) 安装/管理 cron 定时
  6) 卸载本工具和清理 cron
  7) 配置 Gist Token
  8) 检查更新
  0) 退出
请选择 [0-8]:
```

| 选项 | 功能 |
|------|------|
| 1 | 交互式添加新任务：输入任务名称（ID 自动生成）/ 源 URL / UA / 请求头 / 已有 Gist URL（留空自动创建） |
| 2 | 以 CLI 表格列出所有任务（详见 §四） |
| 3 | 删除指定任务（仅删除本地配置与状态，**不删除已创建的 Gist**） |
| 4 | 立即按顺序运行所有任务（与 `run-all` 命令等价） |
| 5 | 进入 cron 子菜单：安装 / 自定义时间 / 卸载 |
| 6 | 卸载本工具：清理 cron → 删除 `/etc/sub_to_gist/` 目录（不删除已创建的 Gist） |
| 7 | 配置 Gist Token：交互式输入 PAT → 验证有效性 → 保存到 config.conf（无需手动 vi） |
| 8 | 检查更新：从 GitHub 获取远程版本号 → 与本地版本对比 → 有更新则自主更新（备份旧版本→覆盖→提示回滚命令） |

> **首次使用流程**：启动菜单 → 7) 配置 Gist Token → 1) 添加内容推送任务 → 5) 安装 cron 定时

### 自主更新机制（v1.0.2 新增）

脚本内置版本检测和自主更新功能，支持两种触发方式：

**方式一：菜单触发**（推荐）

启动 pusher.sh → 选择「8) 检查更新」

**方式二：命令行触发**

```sh
# 如果本地有 install.sh
sh /etc/sub_to_gist/install.sh --upgrade

# 如果本地没有 install.sh（从 GitHub 下载临时副本执行）
sh -c "$(curl -sSL https://raw.githubusercontent.com/ciskonc/sub_to_gist/main/src/install.sh)" -- --upgrade
```

**更新流程**：
1. 读取本地版本号（从 `pusher.sh` 的 `VERSION` 字段）
2. 从 GitHub raw 下载远程 `pusher.sh`，提取版本号
3. 语义化版本对比（major.minor.patch）
4. 本地 = 远程 → 提示"已是最新版本"，不下载
5. 本地 > 远程 → 提示"本地版本更新"，跳过
6. 本地 < 远程 → 备份当前版本（`pusher.sh.bak.YYYYMMDDHHMMSS`）→ 覆盖更新 → 提示回滚命令

> 重复运行 install.sh 时，如果本地版本已是最新的，不会重复下载和覆盖文件。

### cron 子菜单（选项 5）

```
=== cron 定时管理 ===
  1) 安装 cron（默认每日 06:00）
  2) 自定义时间安装（输入 HH:MM）
  3) 卸载 cron
  0) 返回主菜单
```

---

## 四、CLI 表格输出

菜单选项 2 或命令 `pusher.sh list`（菜单内部调用）输出格式：

```
=== 当前推送任务列表 ===

任务ID          任务名称              上次结果    连续失败     Gist URL
-----------------------------------------------------------------------------------------
source_a       源站点A                 ✓ OK       0            https://gist.githubusercontent.com/abc.../raw/source_a.txt
proxy_task       代理B                 ✗ FAIL     3            https://gist.githubusercontent.com/def.../raw/proxy_task.txt
task_001         测试                  - N/A      ⚠ 7!         （未推送）
```

| 列 | 含义 |
|----|------|
| 任务ID | 任务配置文件名（去 `.conf` 后缀） |
| 任务名称 | `TASK_NAME` 字段值 |
| 上次结果 | `OK` / `FAIL` / `N/A`（从未运行） |
| 连续失败 | 连续失败次数，达到 7 次显示 `⚠ N!` 告警 |
| Gist URL | Gist raw URL，未推送时显示 `（未推送）` |

---

## 五、命令行用法

```sh
pusher.sh                          # 启动交互菜单（默认）
pusher.sh menu                     # 同上
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

### 5.1 `rotate-gist` 使用场景

当 GitHub Token 轮换或 Gist 被误删时，旧 `TASK_GIST_ID` 失效。此命令会：

1. 删除旧 Gist（如存在）
2. 清空 `TASK_GIST_ID`
3. 重新推送内容，获取新 Gist ID

---

## 六、cron 定时

### 6.1 安装

```sh
/etc/sub_to_gist/pusher.sh cron-install        # 默认每日 06:00
/etc/sub_to_gist/pusher.sh cron-install 08:30  # 自定义时间
```

或通过菜单选项 5 → 1 / 2。

### 6.2 cron 配置位置

| 环境 | 文件 | 格式 |
|------|------|------|
| OpenWrt | `/etc/crontabs/root` | `0 6 * * * /etc/sub_to_gist/pusher.sh run-all >> /etc/sub_to_gist/logs/cron.log 2>&1` |
| 飞牛OS / 通用 | `/etc/cron.d/sub_to_gist` | `0 6 * * * root /etc/sub_to_gist/pusher.sh run-all >> /etc/sub_to_gist/logs/cron.log 2>&1` |

### 6.3 卸载

```sh
/etc/sub_to_gist/pusher.sh cron-uninstall
```

或菜单选项 5 → 3。卸载仅移除本工具的 cron 块（`# BEGIN sub_to_gist` 到 `# END sub_to_gist` 标记之间），不影响其他任务。

---

## 七、失败处理状态机

| 拉取结果 | cache 存在 | gist 文件内容 | gist description | 失败计数 |
|----------|------------|---------------|-------------------|----------|
| OK | 是 | 新内容 | `[OK] ${TASK} ${time}` | → 0 |
| OK | 否 | 新内容 | `[OK] ${TASK} ${time}` | → 0 |
| FAIL | 是 | **不改**（保留上次成功内容） | `[FAIL x${N+1}] ${TASK} ${time}` | +1 |
| FAIL | 否 | 错误占位内容 | `[INIT FAIL] ${TASK} ${time}` | → 1 |
| FAIL（≥7 次） | 是 | **不改** | `[CRITICAL x${N}] ${TASK} ${time}` | +1 |

**核心原则**：永不修改 gist 文件内容，仅更新 gist `description` 字段。原因：JSON / base64 内容源加注释会破坏下游内容处理服务解析；清空 gist 会导致下游内容处理服务拉到空内容。

### 404 自愈

当 gist 被误删导致 PATCH 返回 404 时，自动清空 `TASK_GIST_ID`，下次运行时重新 POST 创建新 Gist。

---

## 八、安全特性

| 特性 | 实现 |
|------|------|
| 配置加载 | 手动 `KEY="VALUE"` 解析，禁止 `source`（防命令注入） |
| 任务 ID 校验 | 白名单 `^[a-z][a-z0-9_]{0,31}$`（防路径穿越） |
| Token 注入 | `curl --config -` 从 stdin 注入敏感参数，避免出现在 `/proc/PID/cmdline` |
| 日志脱敏 | 自动过滤 `ghp_*` / `github_pat_*` / `Bearer *` / `token=*` / `password=*` |
| 文件权限 | 配置与 state 文件 `chmod 600`，目录 `chmod 700`，脚本启动 `umask 077` |
| 并发锁 | `mkdir` 原子锁（OpenWrt 无 flock）+ trap 清理 |
| Secret Gist | 非私密，URL 即访问凭据，token 轮换请用 `rotate-gist` 命令 |

---

## 九、目录结构与日志

### 9.1 部署后目录

```
/etc/sub_to_gist/
├── pusher.sh              # 主脚本
├── config.conf            # 全局配置（chmod 600）
├── tasks.d/               # 任务配置
│   ├── source_a.conf
│   └── proxy_task.conf
├── cache.d/               # 源内容缓存（失败时保留上次内容）
│   ├── source_a.cache
│   └── proxy_task.cache
├── state.d/               # 任务状态
│   ├── source_a.state
│   └── proxy_task.state
├── logs/                  # 按日期分文件
│   └── 20260728.log
└── run.lock/              # 原子锁目录（运行时存在）
```

### 9.2 日志查看

```sh
# 查看今日日志
cat /etc/sub_to_gist/logs/$(date +%Y%m%d).log

# 实时跟踪日志
tail -f /etc/sub_to_gist/logs/$(date +%Y%m%d).log

# 查看 cron 输出
tail -f /etc/sub_to_gist/logs/cron.log
```

日志格式：`[YYYY-MM-DD HH:MM:SS] [LEVEL] message`，敏感字段已脱敏。

---

## 十、故障排查

### 10.1 创建 gist 失败

| 现象 | 可能原因 | 处理 |
|------|----------|------|
| HTTP 401 | Token 无效或过期 | 重新生成 PAT，更新 `config.conf` |
| HTTP 403 | Token 无 `gist` 权限 | 重新生成 PAT，勾选 `gist` 权限 |
| HTTP 422 | 文件名冲突或内容超 1MB | 检查 `TASK_GIST_FILENAME` 是否重复；源内容超 1MB 需联系源站点 |
| 速率限制 | 超过 5000 req/h | 减少 cron 频率；检查是否有其他工具占用配额 |

### 10.2 拉取内容失败

| 现象 | 可能原因 | 处理 |
|------|----------|------|
| HTTP 403 | UA 被源站点拦截 | 通过菜单 1 添加任务时填写自定义 UA |
| HTTP 404 | 源 URL 失效 | 联系源站点获取新 URL |
| SSL 证书错误 | CA 证书缺失 | 运行 `pusher.sh install-deps` |
| 连接超时 | 网络问题或源站点封禁 IP | 检查网络；尝试更换 UA 或请求头 |

### 10.3 cron 不执行

| 环境 | 检查命令 |
|------|----------|
| OpenWrt | `/etc/init.d/cron enabled && echo OK` |
| 飞牛OS / 通用 | `systemctl is-enabled cron` |

确认 cron 服务已启用，并检查 `/etc/sub_to_gist/logs/cron.log` 是否有输出。

### 10.4 查看任务状态文件

```sh
cat /etc/sub_to_gist/state.d/{task_id}.state
```

字段：`LAST_RESULT` / `LAST_TIME` / `CONSECUTIVE_FAILURES` / `LAST_GIST_URL`。

---

## 十一、卸载

### 11.1 通过菜单

运行 `pusher.sh` → 选项 6 → 确认卸载。

### 11.2 手动卸载

```sh
/etc/sub_to_gist/pusher.sh cron-uninstall    # 先清理 cron
rm -rf /etc/sub_to_gist/                     # 再删除目录
```

> 卸载**不会**删除已创建的 GitHub Gist。如需清理，请手动到 https://gist.github.com 删除，或运行 `pusher.sh rotate-gist <task_id>` 后中断（会删除旧 gist 但不创建新 gist 仅当内容拉取失败时）。

---

## 十二、关联项目

- **下游内容处理服务**：本工具产出的 Gist raw URL 作为其内容输入
- **openwrt-easytier-updater**：同为 OpenWrt POSIX sh 工具，共享 shell 兼容性经验

---

## 十三、参考文档

- GitHub Gist REST API：https://docs.github.com/en/rest/gists/gists
- GitHub REST API 速率限制：https://docs.github.com/en/rest/overview/rate-limits-for-the-rest-api
- OpenWrt crond 配置：https://openwrt.org/docs/guide-user/base-system/cron
