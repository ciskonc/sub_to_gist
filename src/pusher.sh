#!/bin/sh
# =============================================================================
# sub_to_gist — 网页内容中转推送器
# 读取远程网页内容，原样推送到 GitHub Gist，作为下游内容处理服务的数据源
#
# 兼容环境：OpenWrt (BusyBox ash) / 飞牛OS fnOS (bash) / 通用 Linux (bash/dash)
# 适配策略：运行时自适应（detect_env 检测环境，选择 cron 路径/包管理器/重载命令）
# 安全特性：禁止 source 配置 / mkdir 原子锁 / curl --config - stdin 注入敏感参数
# 失败处理：永不修改 gist 文件内容，只更新 gist description
#
# 用法：
#   pusher.sh                   # 启动交互菜单
#   pusher.sh run-all           # 运行所有任务（cron 调用）
#   pusher.sh run <task_id>     # 运行单个任务
#   pusher.sh rotate-gist <task_id>  # 删除并重建 gist（token 轮换时使用）
#   pusher.sh cron-install [hh:mm]   # 安装 cron 定时（默认 06:00）
#   pusher.sh cron-uninstall          # 卸载 cron 定时
#   pusher.sh check-deps              # 检查依赖
# =============================================================================

set -u
umask 077

# ============ 常量 ============
VERSION="1.0.3"
INSTALL_DIR="/etc/sub_to_gist"
CONFIG_FILE="$INSTALL_DIR/config.conf"
TASKS_DIR="$INSTALL_DIR/tasks.d"
CACHE_DIR="$INSTALL_DIR/cache.d"
STATE_DIR="$INSTALL_DIR/state.d"
LOGS_DIR="$INSTALL_DIR/logs"
LOCK_DIR="$INSTALL_DIR/run.lock"
SCRIPT_PATH="$INSTALL_DIR/pusher.sh"
GIST_API_BASE="https://api.github.com/gists"
CRITICAL_THRESHOLD=7

# ============ 环境自适应 ============

# 检测运行环境：openwrt / fnos / generic
detect_env() {
    if [ -f /etc/openwrt_release ]; then
        echo "openwrt"
    elif [ -f /etc/fnos-release ] || grep -q '^ID=fnos' /etc/os-release 2>/dev/null; then
        echo "fnos"
    else
        echo "generic"
    fi
}

# 获取 cron 配置文件路径
get_cron_file() {
    case "$(detect_env)" in
        openwrt) echo "/etc/crontabs/root" ;;
        *)       echo "/etc/cron.d/sub_to_gist" ;;
    esac
}

# 获取 cron 任务行（含用户字段适配）
# $1 = 分钟, $2 = 小时, $3 = 命令
build_cron_line() {
    local min="$1"
    local hour="$2"
    local cmd="$3"
    case "$(detect_env)" in
        openwrt) echo "$min $hour * * * $cmd" ;;
        *)       echo "$min $hour * * * root $cmd" ;;
    esac
}

# 重载 cron 服务
reload_cron() {
    case "$(detect_env)" in
        openwrt)
            /etc/init.d/cron reload 2>/dev/null || /etc/init.d/cron restart 2>/dev/null
            /etc/init.d/cron enabled 2>/dev/null || /etc/init.d/cron enable 2>/dev/null
            ;;
        *)
            systemctl reload cron 2>/dev/null || service cron reload 2>/dev/null
            systemctl enable cron 2>/dev/null || :
            ;;
    esac
}

# 安装依赖
install_deps() {
    local env_type
    env_type=$(detect_env)
    echo "检测到环境：$env_type"
    case "$env_type" in
        openwrt)
            echo "执行：opkg update && opkg install curl ca-bundle ca-certificates"
            opkg update && opkg install curl ca-bundle ca-certificates
            ;;
        *)
            echo "执行：apt-get update && apt-get install -y curl ca-certificates"
            apt-get update && apt-get install -y curl ca-certificates
            ;;
    esac
}

# 检查依赖是否满足
check_deps() {
    local missing=0
    if ! command -v curl >/dev/null 2>&1; then
        echo "缺失：curl"
        missing=1
    fi
    if [ ! -f /etc/ssl/certs/ca-certificates.crt ] && [ ! -d /etc/ssl/certs ]; then
        echo "缺失：CA 证书"
        missing=1
    fi
    if [ "$missing" -eq 1 ]; then
        echo "请运行：$SCRIPT_PATH install-deps"
        return 1
    fi
    return 0
}

# ============ 日志 ============

# 日志函数：log <LEVEL> <MESSAGE>
log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_file="$LOGS_DIR/$(date '+%Y%m%d').log"
    mkdir -p "$LOGS_DIR" 2>/dev/null
    # 脱敏后写入
    sanitize_log "$msg" | while IFS= read -r line; do
        echo "[$timestamp] [$level] $line" >> "$log_file"
    done
    # 同时输出到 stderr（如果非交互）
    if [ -t 1 ]; then
        : # 交互模式，菜单自己处理输出
    else
        echo "[$timestamp] [$level] $msg" >&2
    fi
}

# 日志脱敏：过滤 token / Bearer / 密码模式
sanitize_log() {
    local input="$1"
    printf '%s' "$input" \
        | sed -e 's/ghp_[A-Za-z0-9]*/ghp_***REDACTED***/g' \
              -e 's/github_pat_[A-Za-z0-9_]*/github_pat_***REDACTED***/g' \
              -e 's/Bearer [A-Za-z0-9_]*/Bearer ***REDACTED***/g' \
              -e 's/token=[A-Za-z0-9_]*/token=***REDACTED***/g' \
              -e 's/password=[^& ]*/password=***REDACTED***/g'
}

# ============ 配置加载（禁止 source，手动 key=value 解析）============

# 加载配置文件：load_conf <file>
# 仅允许白名单 KEY，自动去除值两端的引号
# 加载后变量直接可用：GIST_TOKEN / TASK_NAME / TASK_URL 等
load_conf() {
    local file="$1"
    [ -f "$file" ] || return 1
    # 先校验格式：仅允许 KEY="VALUE" 或注释行或空行
    # 注意：BusyBox grep 不支持 \s，用 [[:space:]] 替代
    if ! grep -vE '^[A-Z_]+="[^"]*"$' "$file" | grep -vE '^[[:space:]]*$|^[[:space:]]*#' >/dev/null 2>&1; then
        log "ERROR" "配置文件格式非法：$file（仅允许 KEY=\"VALUE\" 格式）"
        return 1
    fi
    while IFS='=' read -r key val; do
        case "$key" in
            ''|'#'*|' '*)
                continue
                ;;
            GIST_TOKEN|GIST_DESCRIPTION_PREFIX|\
            TASK_NAME|TASK_URL|TASK_UA|TASK_HEADERS|TASK_GIST_ID|TASK_GIST_FILENAME|\
            LAST_RESULT|LAST_TIME|CONSECUTIVE_FAILURES|LAST_GIST_URL)
                # 去除值两端的引号
                val=${val#\"}
                val=${val%\"}
                eval "${key}=\"\$val\""
                ;;
            *)
                log "WARN" "忽略未知配置项：$key（文件：$file）"
                ;;
        esac
    done < "$file"
    return 0
}

# 校验任务 ID：必须匹配 ^[a-z][a-z0-9_]{0,31}$
validate_task_id() {
    local task_id="$1"
    case "$task_id" in
        *[!a-z0-9_]*)
            log "ERROR" "任务 ID 含非法字符：$task_id（仅允许小写字母/数字/下划线）"
            return 1
            ;;
        [0-9]*)
            log "ERROR" "任务 ID 必须以字母开头：$task_id"
            return 1
            ;;
        '')
            log "ERROR" "任务 ID 不能为空"
            return 1
            ;;
        *)
            # 长度检查（最多 32 字符）
            local len
            len=${#task_id}
            if [ "$len" -gt 32 ]; then
                log "ERROR" "任务 ID 过长（>32 字符）：$task_id"
                return 1
            fi
            ;;
    esac
    # basename 剥离路径（防穿越）
    local base
    base=$(basename "$task_id")
    if [ "$base" != "$task_id" ]; then
        log "ERROR" "任务 ID 含路径分隔符：$task_id"
        return 1
    fi
    return 0
}

# 保存配置文件（原子写）：save_conf <file> <key1> <val1> <key2> <val2> ...
save_conf() {
    local file="$1"
    shift
    local tmp
    tmp=$(mktemp 2>/dev/null || echo "/tmp/sub_to_gist_conf.$$")
    while [ $# -ge 2 ]; do
        local key="$1"
        local val="$2"
        shift 2
        # 转义值中的 " 和 \
        local escaped
        escaped=$(printf '%s' "$val" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
        printf '%s="%s"\n' "$key" "$escaped" >> "$tmp"
    done
    mv -f "$tmp" "$file" 2>/dev/null || cat "$tmp" > "$file"
    rm -f "$tmp"
}

# ============ 状态管理 ============

# 读取任务状态：get_state <task_id>
# 输出：LAST_RESULT / LAST_TIME / CONSECUTIVE_FAILURES / LAST_GIST_URL 变量
get_state() {
    local task_id="$1"
    local state_file="$STATE_DIR/${task_id}.state"
    LAST_RESULT=""
    LAST_TIME=""
    CONSECUTIVE_FAILURES=0
    LAST_GIST_URL=""
    if [ -f "$state_file" ]; then
        load_conf "$state_file" || return 1
    fi
    [ -z "$CONSECUTIVE_FAILURES" ] && CONSECUTIVE_FAILURES=0
    return 0
}

# 写入任务状态：set_state <task_id> <result> <time> <failures> <gist_url>
set_state() {
    local task_id="$1"
    local result="$2"
    local time="$3"
    local failures="$4"
    local gist_url="$5"
    mkdir -p "$STATE_DIR" 2>/dev/null
    save_conf "$STATE_DIR/${task_id}.state" \
        LAST_RESULT "$result" \
        LAST_TIME "$time" \
        CONSECUTIVE_FAILURES "$failures" \
        LAST_GIST_URL "$gist_url"
}

# ============ 并发锁（mkdir 原子锁）============

acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo $$ > "$LOCK_DIR/pid"
        trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT INT TERM
        return 0
    else
        local pid
        pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
        if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
            # 旧进程已死亡，清理并重试
            rmdir "$LOCK_DIR" 2>/dev/null
            if mkdir "$LOCK_DIR" 2>/dev/null; then
                echo $$ > "$LOCK_DIR/pid"
                trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT INT TERM
                return 0
            fi
        fi
        log "WARN" "无法获取锁（已有进程运行 PID=$pid）"
        return 1
    fi
}

release_lock() {
    rmdir "$LOCK_DIR" 2>/dev/null
    trap - EXIT INT TERM
}

# ============ Gist API（curl --config - stdin 注入敏感参数）============

# 从 JSON 字符串中提取字段值（无 jq 依赖）
# $1 = json, $2 = field name
# 注意：简单实现，仅适用于不嵌套的字段
json_extract() {
    local json="$1"
    local field="$2"
    printf '%s' "$json" | sed -n 's/.*"'"$field"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

# 验证 token 有效性
# 返回：0 有效 / 1 无效
gist_check_token() {
    local token="$1"
    local http_code
    http_code=$({
        printf -- '--header "Authorization: Bearer %s"\n' "$token"
        printf -- '--header "Accept: application/vnd.github+json"\n'
        printf -- '--header "X-GitHub-Api-Version: 2022-11-28"\n'
        printf -- '--header "User-Agent: sub_to_gist/%s"\n' "$VERSION"
        printf -- '--url "https://api.github.com/gists"\n'
        printf -- '--request "GET"\n'
        printf -- '--silent\n'
        printf -- '--output "/dev/null"\n'
        printf -- '--write-out "%%{http_code}"\n'
    } | curl --config - 2>/dev/null)
    case "$http_code" in
        200) return 0 ;;
        401) log "ERROR" "Token 无效或已过期（HTTP 401）"; return 1 ;;
        403) log "ERROR" "Token 权限不足或触发速率限制（HTTP 403）"; return 1 ;;
        *)   log "ERROR" "Token 验证失败（HTTP $http_code）"; return 1 ;;
    esac
}

# 创建 gist
# $1 = token, $2 = filename, $3 = content_file, $4 = description
# 输出：gist_id（成功）/ 空（失败）
gist_create() {
    local token="$1"
    local filename="$2"
    local content_file="$3"
    local description="$4"
    local payload_file
    payload_file=$(mktemp 2>/dev/null || echo "/tmp/sub_to_gist_payload.$$")

    # 构建 JSON payload（awk 安全转义 \ " \t \n）
    cat "$content_file" | awk -v desc="$description" -v fname="$filename" '
        BEGIN {
            printf("{\"description\":\"")
            gsub(/\\/, "\\\\", desc)
            gsub(/"/, "\\\"", desc)
            printf("%s\",\"public\":false,\"files\":{\"%s\":{\"content\":\"", desc, fname)
        }
        {
            gsub(/\\/, "\\\\")
            gsub(/"/, "\\\"")
            gsub(/\t/, "\\t")
            printf("%s\\n", $0)
        }
        END {
            printf("\"}}}")
        }
    ' > "$payload_file"

    local response
    response=$({
        printf -- '--header "Authorization: Bearer %s"\n' "$token"
        printf -- '--header "Accept: application/vnd.github+json"\n'
        printf -- '--header "X-GitHub-Api-Version: 2022-11-28"\n'
        printf -- '--header "User-Agent: sub_to_gist/%s"\n' "$VERSION"
        printf -- '--header "Content-Type: application/json"\n'
        printf -- '--url "%s"\n' "$GIST_API_BASE"
        printf -- '--request "POST"\n'
        printf -- '--data-binary "@%s"\n' "$payload_file"
        printf -- '--silent\n'
        printf -- '--include\n'
    } | curl --config - 2>/dev/null)

    rm -f "$payload_file"

    # 从 Location 响应头提取 gist_id
    local gist_url
    gist_url=$(printf '%s' "$response" | awk -F'[Ll]ocation: ' '/^[Ll]ocation:/{gsub(/\r/,"",$2); print $2; exit}')
    local gist_id="${gist_url##*/}"

    if [ -z "$gist_id" ]; then
        log "ERROR" "创建 gist 失败（未获取到 Location 头）"
        return 1
    fi

    echo "$gist_id"
    return 0
}

# 更新 gist 文件内容（PATCH）
# $1 = token, $2 = gist_id, $3 = filename, $4 = content_file
# 返回 HTTP 状态码
gist_update_content() {
    local token="$1"
    local gist_id="$2"
    local filename="$3"
    local content_file="$4"
    local payload_file
    payload_file=$(mktemp 2>/dev/null || echo "/tmp/sub_to_gist_payload.$$")

    cat "$content_file" | awk -v fname="$filename" '
        BEGIN {
            printf("{\"files\":{\"%s\":{\"content\":\"", fname)
        }
        {
            gsub(/\\/, "\\\\")
            gsub(/"/, "\\\"")
            gsub(/\t/, "\\t")
            printf("%s\\n", $0)
        }
        END {
            printf("\"}}}")
        }
    ' > "$payload_file"

    local http_code
    http_code=$({
        printf -- '--header "Authorization: Bearer %s"\n' "$token"
        printf -- '--header "Accept: application/vnd.github+json"\n'
        printf -- '--header "X-GitHub-Api-Version: 2022-11-28"\n'
        printf -- '--header "User-Agent: sub_to_gist/%s"\n' "$VERSION"
        printf -- '--header "Content-Type: application/json"\n'
        printf -- '--url "%s/%s"\n' "$GIST_API_BASE" "$gist_id"
        printf -- '--request "PATCH"\n'
        printf -- '--data-binary "@%s"\n' "$payload_file"
        printf -- '--silent\n'
        printf -- '--output "/dev/null"\n'
        printf -- '--write-out "%%{http_code}"\n'
    } | curl --config - 2>/dev/null)

    rm -f "$payload_file"
    echo "$http_code"
}

# 只更新 gist description（不改文件内容）
# $1 = token, $2 = gist_id, $3 = description
# 返回 HTTP 状态码
gist_update_description() {
    local token="$1"
    local gist_id="$2"
    local description="$3"
    local payload_file
    payload_file=$(mktemp 2>/dev/null || echo "/tmp/sub_to_gist_payload.$$")

    # 转义 description 中的特殊字符
    local escaped_desc
    escaped_desc=$(printf '%s' "$description" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    printf '{"description":"%s"}' "$escaped_desc" > "$payload_file"

    local http_code
    http_code=$({
        printf -- '--header "Authorization: Bearer %s"\n' "$token"
        printf -- '--header "Accept: application/vnd.github+json"\n'
        printf -- '--header "X-GitHub-Api-Version: 2022-11-28"\n'
        printf -- '--header "User-Agent: sub_to_gist/%s"\n' "$VERSION"
        printf -- '--header "Content-Type: application/json"\n'
        printf -- '--url "%s/%s"\n' "$GIST_API_BASE" "$gist_id"
        printf -- '--request "PATCH"\n'
        printf -- '--data-binary "@%s"\n' "$payload_file"
        printf -- '--silent\n'
        printf -- '--output "/dev/null"\n'
        printf -- '--write-out "%%{http_code}"\n'
    } | curl --config - 2>/dev/null)

    rm -f "$payload_file"
    echo "$http_code"
}

# 删除 gist（用于 rotate-gist）
# $1 = token, $2 = gist_id
# 返回 HTTP 状态码
gist_delete() {
    local token="$1"
    local gist_id="$2"
    local http_code
    http_code=$({
        printf -- '--header "Authorization: Bearer %s"\n' "$token"
        printf -- '--header "Accept: application/vnd.github+json"\n'
        printf -- '--header "X-GitHub-Api-Version: 2022-11-28"\n'
        printf -- '--header "User-Agent: sub_to_gist/%s"\n' "$VERSION"
        printf -- '--url "%s/%s"\n' "$GIST_API_BASE" "$gist_id"
        printf -- '--request "DELETE"\n'
        printf -- '--silent\n'
        printf -- '--output "/dev/null"\n'
        printf -- '--write-out "%%{http_code}"\n'
    } | curl --config - 2>/dev/null)
    echo "$http_code"
}

# ============ 内容拉取 ============

# 拉取网页内容到指定文件
# $1 = url, $2 = ua, $3 = headers, $4 = output_file
# 返回：0 成功 / 1 失败
fetch_subscription() {
    local url="$1"
    local ua="$2"
    local headers="$3"
    local output_file="$4"

    # 校验 URL 必须以 https:// 开头
    case "$url" in
        https://*) ;;
        http://*)
            log "WARN" "源 URL 使用不安全的 HTTP 协议：$url"
            ;;
        *)
            log "ERROR" "源 URL 必须以 http:// 或 https:// 开头"
            return 1
            ;;
    esac

    {
        printf -- '--url "%s"\n' "$url"
        if [ -n "$ua" ]; then
            printf -- '--header "User-Agent: %s"\n' "$ua"
        fi
        if [ -n "$headers" ]; then
            printf '%s' "$headers" | tr '|' '\n' | while IFS= read -r h; do
                # 去除 CRLF 注入
                h=$(printf '%s' "$h" | tr -d '\r\n')
                [ -n "$h" ] && printf -- '--header "%s"\n' "$h"
            done
        fi
        printf -- '--silent\n'
        printf -- '--fail\n'
        printf -- '--retry "3"\n'
        printf -- '--retry-delay "2"\n'
        printf -- '--connect-timeout "10"\n'
        printf -- '--max-time "60"\n'
        printf -- '--output "%s"\n' "$output_file"
    } | curl --config - 2>/dev/null

    local rc=$?
    if [ $rc -ne 0 ]; then
        log "ERROR" "拉取内容失败（curl 返回码 $rc）"
        return 1
    fi

    # 检查文件大小（>1MB 警告）
    local size
    size=$(wc -c < "$output_file" 2>/dev/null || echo 0)
    if [ "$size" -gt 1048576 ]; then
        log "WARN" "源内容超过 1MB（$size 字节），Gist API 可能截断"
    elif [ "$size" -eq 0 ]; then
        log "ERROR" "源内容为空"
        return 1
    fi

    return 0
}

# ============ 任务执行 ============

# 推送单个任务到 gist
# $1 = task_id
# 返回：0 成功 / 1 失败
push_task() {
    local task_id="$1"

    if ! validate_task_id "$task_id"; then
        return 1
    fi

    local conf_file="$TASKS_DIR/${task_id}.conf"
    if [ ! -f "$conf_file" ]; then
        log "ERROR" "任务配置文件不存在：$conf_file"
        return 1
    fi

    # 加载任务配置
    TASK_NAME=""
    TASK_URL=""
    TASK_UA=""
    TASK_HEADERS=""
    TASK_GIST_ID=""
    TASK_GIST_FILENAME=""
    if ! load_conf "$conf_file"; then
        log "ERROR" "加载任务配置失败：$task_id"
        return 1
    fi

    if [ -z "$TASK_NAME" ] || [ -z "$TASK_URL" ]; then
        log "ERROR" "任务配置不完整：$task_id（TASK_NAME 和 TASK_URL 必填）"
        return 1
    fi

    # 默认值
    [ -z "$TASK_GIST_FILENAME" ] && TASK_GIST_FILENAME="${task_id}.txt"

    # 加载状态
    get_state "$task_id"

    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')
    local cache_file="$CACHE_DIR/${task_id}.cache"
    local tmp_file
    tmp_file=$(mktemp 2>/dev/null || echo "/tmp/sub_to_gist_fetch.$$")

    log "INFO" "开始处理任务：$task_id（$TASK_NAME）"

    # 1. 拉取源内容
    if ! fetch_subscription "$TASK_URL" "$TASK_UA" "$TASK_HEADERS" "$tmp_file"; then
        log "ERROR" "任务 $task_id 拉取内容失败"
        rm -f "$tmp_file"

        # 更新失败计数
        local new_failures=$((CONSECUTIVE_FAILURES + 1))
        local desc_prefix="[FAIL x${new_failures}]"
        if [ "$new_failures" -ge "$CRITICAL_THRESHOLD" ]; then
            desc_prefix="[CRITICAL x${new_failures}]"
        fi
        local desc="${desc_prefix} ${TASK_NAME} ${now}"

        # 如果有 gist_id，只更新 description（不改内容）
        if [ -n "$TASK_GIST_ID" ]; then
            local http_code
            http_code=$(gist_update_description "$GIST_TOKEN" "$TASK_GIST_ID" "$desc")
            case "$http_code" in
                200) log "INFO" "已更新 gist description：$desc" ;;
                404)
                    log "WARN" "gist 已被删除（404），清空 TASK_GIST_ID 等待下次成功后重建"
                    TASK_GIST_ID=""
                    save_conf "$conf_file" \
                        TASK_NAME "$TASK_NAME" \
                        TASK_URL "$TASK_URL" \
                        TASK_UA "$TASK_UA" \
                        TASK_HEADERS "$TASK_HEADERS" \
                        TASK_GIST_ID "$TASK_GIST_ID" \
                        TASK_GIST_FILENAME "$TASK_GIST_FILENAME"
                    ;;
                *) log "WARN" "更新 gist description 失败（HTTP $http_code）" ;;
            esac
        fi

        # 更新状态
        set_state "$task_id" "FAIL" "$now" "$new_failures" "$LAST_GIST_URL"
        log "WARN" "任务 $task_id 失败（连续 $new_failures 次）"
        return 1
    fi

    log "INFO" "任务 $task_id 拉取内容成功"

    # 2. 推送到 gist
    local desc="[OK] ${TASK_NAME} ${now}"
    local gist_raw_url=""

    if [ -z "$TASK_GIST_ID" ]; then
        # 创建新 gist
        log "INFO" "任务 $task_id 无 gist_id，创建新 gist"
        local new_gist_id
        new_gist_id=$(gist_create "$GIST_TOKEN" "$TASK_GIST_FILENAME" "$tmp_file" "$desc")
        if [ -z "$new_gist_id" ]; then
            log "ERROR" "任务 $task_id 创建 gist 失败"
            rm -f "$tmp_file"
            set_state "$task_id" "FAIL" "$now" $((CONSECUTIVE_FAILURES + 1)) "$LAST_GIST_URL"
            return 1
        fi
        TASK_GIST_ID="$new_gist_id"
        log "INFO" "任务 $task_id 创建 gist 成功：$TASK_GIST_ID"

        # 写回 gist_id 到任务配置
        save_conf "$conf_file" \
            TASK_NAME "$TASK_NAME" \
            TASK_URL "$TASK_URL" \
            TASK_UA "$TASK_UA" \
            TASK_HEADERS "$TASK_HEADERS" \
            TASK_GIST_ID "$TASK_GIST_ID" \
            TASK_GIST_FILENAME "$TASK_GIST_FILENAME"

        gist_raw_url="https://gist.githubusercontent.com/$TASK_GIST_ID/raw/$TASK_GIST_FILENAME"
    else
        # 更新已有 gist
        log "INFO" "任务 $task_id 更新 gist：$TASK_GIST_ID"
        local http_code
        http_code=$(gist_update_content "$GIST_TOKEN" "$TASK_GIST_ID" "$TASK_GIST_FILENAME" "$tmp_file")
        case "$http_code" in
            200)
                log "INFO" "任务 $task_id 更新 gist 内容成功"
                # 更新 description 为 OK 状态
                gist_update_description "$GIST_TOKEN" "$TASK_GIST_ID" "$desc" >/dev/null
                ;;
            404)
                log "WARN" "任务 $task_id 的 gist 已被删除（404），清空 TASK_GIST_ID 并重建"
                TASK_GIST_ID=""
                save_conf "$conf_file" \
                    TASK_NAME "$TASK_NAME" \
                    TASK_URL "$TASK_URL" \
                    TASK_UA "$TASK_UA" \
                    TASK_HEADERS "$TASK_HEADERS" \
                    TASK_GIST_ID "$TASK_GIST_ID" \
                    TASK_GIST_FILENAME "$TASK_GIST_FILENAME"
                # 递归调用自身重建 gist
                rm -f "$tmp_file"
                return push_task "$task_id"
                ;;
            *)
                log "ERROR" "任务 $task_id 更新 gist 失败（HTTP $http_code）"
                rm -f "$tmp_file"
                # 只更新 description 为失败状态
                local fail_desc="[FAIL x$((CONSECUTIVE_FAILURES + 1))] ${TASK_NAME} ${now}"
                gist_update_description "$GIST_TOKEN" "$TASK_GIST_ID" "$fail_desc" >/dev/null 2>&1
                set_state "$task_id" "FAIL" "$now" $((CONSECUTIVE_FAILURES + 1)) "$LAST_GIST_URL"
                return 1
                ;;
        esac
        gist_raw_url="https://gist.githubusercontent.com/$TASK_GIST_ID/raw/$TASK_GIST_FILENAME"
    fi

    # 3. 更新缓存（原子写）
    mkdir -p "$CACHE_DIR" 2>/dev/null
    mv -f "$tmp_file" "$cache_file" 2>/dev/null || cp "$tmp_file" "$cache_file"
    rm -f "$tmp_file"

    # 4. 更新状态
    set_state "$task_id" "OK" "$now" 0 "$gist_raw_url"
    log "INFO" "任务 $task_id 推送成功（gist_url=$gist_raw_url）"
    return 0
}

# 运行所有任务
run_all_tasks() {
    if ! acquire_lock; then
        log "WARN" "run-all 无法获取锁，退出"
        return 1
    fi

    # 加载全局配置
    if ! load_conf "$CONFIG_FILE"; then
        log "ERROR" "加载全局配置失败：$CONFIG_FILE"
        release_lock
        return 1
    fi

    if [ -z "${GIST_TOKEN:-}" ]; then
        log "ERROR" "GIST_TOKEN 未配置"
        release_lock
        return 1
    fi

    # 验证 token
    if ! gist_check_token "$GIST_TOKEN"; then
        release_lock
        return 1
    fi

    local task_count=0
    local success_count=0
    local fail_count=0

    # 遍历任务配置文件
    if [ ! -d "$TASKS_DIR" ]; then
        log "WARN" "任务目录不存在：$TASKS_DIR"
        release_lock
        return 0
    fi

    ls "$TASKS_DIR"/*.conf 2>/dev/null | while IFS= read -r conf_file; do
        [ -z "$conf_file" ] && continue
        local task_id
        task_id=$(basename "$conf_file" .conf)
        task_count=$((task_count + 1))
        if push_task "$task_id"; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
    done

    log "INFO" "run-all 完成（总计 $task_count / 成功 $success_count / 失败 $fail_count）"
    release_lock
    return 0
}

# ============ cron 管理 ============

# 验证 hh:mm 格式
validate_hhmm() {
    local hhmm="$1"
    case "$hhmm" in
        [0-9][0-9]:[0-9][0-9])
            local hh=${hhmm%:*}
            local mm=${hhmm#*:}
            if [ "$hh" -ge 0 ] && [ "$hh" -le 23 ] && [ "$mm" -ge 0 ] && [ "$mm" -le 59 ]; then
                return 0
            fi
            ;;
    esac
    log "ERROR" "时间格式非法：$hhmm（应为 HH:MM，如 06:00）"
    return 1
}

# 安装 cron 定时
# $1 = hh:mm（可选，默认 06:00）
install_cron() {
    local hhmm="${1:-06:00}"
    if ! validate_hhmm "$hhmm"; then
        return 1
    fi

    local hh=${hhmm%:*}
    local mm=${hhmm#*:}

    local cron_file
    cron_file=$(get_cron_file)
    local mark_begin="# BEGIN sub_to_gist (auto-managed, do not edit)"
    local mark_end="# END sub_to_gist"
    local cmd="$SCRIPT_PATH run-all >> $LOGS_DIR/cron.log 2>&1"
    local cron_line
    cron_line=$(build_cron_line "$mm" "$hh" "$cmd")

    # 准备 cron 目录
    case "$(detect_env)" in
        openwrt) mkdir -p /etc/crontabs ;;
        *)       mkdir -p /etc/cron.d ;;
    esac

    # 原子替换：临时文件 → mv
    local tmp
    tmp=$(mktemp 2>/dev/null || echo "/tmp/sub_to_gist_cron.$$")

    # 复制现有内容（去除旧的 sub_to_gist 块）
    if [ -f "$cron_file" ]; then
        cat "$cron_file" > "$tmp"
        # 删除旧的 BEGIN/END 块
        sed -i "/^${mark_begin}\$/,/^${mark_end}\$/d" "$tmp" 2>/dev/null
    fi

    # 追加新的 BEGIN/END 块
    {
        echo ""
        echo "$mark_begin"
        echo "$cron_line"
        echo "$mark_end"
    } >> "$tmp"

    # 确保文件末尾有换行
    [ -n "$(tail -c1 "$tmp")" ] && echo >> "$tmp"

    # 原子替换
    mv -f "$tmp" "$cron_file" 2>/dev/null || cat "$tmp" > "$cron_file"
    rm -f "$tmp"
    chmod 600 "$cron_file" 2>/dev/null

    # 重载 cron
    reload_cron

    log "INFO" "cron 定时已安装：$hhmm → $cron_file"
    echo "cron 定时已安装：每日 $hhmm 执行"
    echo "配置文件：$cron_file"
    return 0
}

# 卸载 cron 定时
uninstall_cron() {
    local cron_file
    cron_file=$(get_cron_file)
    local mark_begin="# BEGIN sub_to_gist (auto-managed, do not edit)"
    local mark_end="# END sub_to_gist"

    if [ ! -f "$cron_file" ]; then
        echo "cron 配置文件不存在：$cron_file"
        return 0
    fi

    local tmp
    tmp=$(mktemp 2>/dev/null || echo "/tmp/sub_to_gist_cron.$$")
    cat "$cron_file" > "$tmp"
    sed -i "/^${mark_begin}\$/,/^${mark_end}\$/d" "$tmp" 2>/dev/null

    # 如果是 /etc/cron.d/sub_to_gist 专用文件，直接删除
    case "$cron_file" in
        /etc/cron.d/sub_to_gist)
            rm -f "$cron_file"
            log "INFO" "已删除 cron 专用文件：$cron_file"
            ;;
        *)
            mv -f "$tmp" "$cron_file" 2>/dev/null || cat "$tmp" > "$cron_file"
            rm -f "$tmp"
            ;;
    esac

    reload_cron
    log "INFO" "cron 定时已卸载"
    echo "cron 定时已卸载"
    return 0
}

# ============ 菜单功能 ============

# 列出所有任务（CLI 表格）
action_list_tasks() {
    echo ""
    echo "=== 当前推送任务列表 ==="
    echo ""

    if [ ! -d "$TASKS_DIR" ] || [ -z "$(ls "$TASKS_DIR"/*.conf 2>/dev/null)" ]; then
        echo "暂无任务。请选择菜单 1 添加。"
        return 0
    fi

    # 表头
    printf '%-15s %-20s %-10s %-12s %-40s\n' "任务ID" "任务名称" "上次结果" "连续失败" "Gist URL"
    printf '%s\n' "-----------------------------------------------------------------------------------------"

    ls "$TASKS_DIR"/*.conf 2>/dev/null | while IFS= read -r conf_file; do
        [ -z "$conf_file" ] && continue
        local task_id
        task_id=$(basename "$conf_file" .conf)

        # 加载任务配置
        TASK_NAME=""
        TASK_GIST_ID=""
        load_conf "$conf_file" 2>/dev/null

        # 加载状态
        get_state "$task_id" 2>/dev/null

        local result="${LAST_RESULT:-N/A}"
        local failures="${CONSECUTIVE_FAILURES:-0}"
        local url="${LAST_GIST_URL:-（未推送）}"

        # 结果状态标识
        case "$result" in
            OK)    result="✓ OK" ;;
            FAIL)  result="✗ FAIL" ;;
            *)     result="- N/A" ;;
        esac

        # 连续失败告警
        if [ "$failures" -ge "$CRITICAL_THRESHOLD" ]; then
            failures="⚠ ${failures}!"
        fi

        printf '%-15s %-20s %-10s %-12s %-40s\n' "$task_id" "${TASK_NAME:-（未命名）}" "$result" "$failures" "$url"
    done
    echo ""
}

# 添加任务
action_add_task() {
    echo ""
    echo "=== 添加内容推送任务 ==="
    echo ""

    local task_id task_name task_url task_ua task_headers

    printf '请输入任务 ID（小写字母/数字/下划线，以字母开头，≤32 字符）：'
    if ! read -r task_id; then
        echo "输入取消"
        return 1
    fi
    if ! validate_task_id "$task_id"; then
        return 1
    fi
    if [ -f "$TASKS_DIR/${task_id}.conf" ]; then
        printf '任务 ID 已存在：%s，是否覆盖？[y/N] ' "$task_id"
        local confirm
        read -r confirm
        case "$confirm" in
            y|Y) ;;
            *) echo "已取消"; return 1 ;;
        esac
    fi

    printf '请输入任务显示名称：'
    if ! read -r task_name; then
        echo "输入取消"
        return 1
    fi
    [ -z "$task_name" ] && task_name="$task_id"

    printf '请输入源 URL（必须以 https:// 开头）：'
    if ! read -r task_url; then
        echo "输入取消"
        return 1
    fi
    case "$task_url" in
        https://*) ;;
        http://*)
            printf 'URL 使用不安全的 HTTP，确认继续？[y/N] '
            local confirm_http
            read -r confirm_http
            case "$confirm_http" in
                y|Y) ;;
                *) echo "已取消"; return 1 ;;
            esac
            ;;
        *) echo "URL 必须以 http:// 或 https:// 开头"; return 1 ;;
    esac

    printf '请输入自定义 User-Agent（留空使用默认 curl UA）：'
    read -r task_ua

    printf '请输入额外请求头（格式：Key: Value|Key2: Value2，留空跳过）：'
    read -r task_headers

    # 生成默认 gist 文件名
    local gist_filename="${task_id}.txt"

    # 保存配置
    mkdir -p "$TASKS_DIR" 2>/dev/null
    save_conf "$TASKS_DIR/${task_id}.conf" \
        TASK_NAME "$task_name" \
        TASK_URL "$task_url" \
        TASK_UA "$task_ua" \
        TASK_HEADERS "$task_headers" \
        TASK_GIST_ID "" \
        TASK_GIST_FILENAME "$gist_filename"
    chmod 600 "$TASKS_DIR/${task_id}.conf" 2>/dev/null

    echo ""
    echo "任务已添加："
    echo "  任务 ID：$task_id"
    echo "  任务名称：$task_name"
    echo "  源 URL：$task_url"
    echo "  User-Agent：${task_ua:-（默认）}"
    echo "  额外请求头：${task_headers:-（无）}"
    echo "  Gist 文件名：$gist_filename"
    echo ""
    echo "配置文件：$TASKS_DIR/${task_id}.conf"
    return 0
}

# 删除任务
action_delete_task() {
    echo ""
    echo "=== 删除推送任务 ==="
    action_list_tasks

    if [ ! -d "$TASKS_DIR" ] || [ -z "$(ls "$TASKS_DIR"/*.conf 2>/dev/null)" ]; then
        return 0
    fi

    printf '请输入要删除的任务 ID：'
    local task_id
    if ! read -r task_id; then
        echo "输入取消"
        return 1
    fi
    if ! validate_task_id "$task_id"; then
        return 1
    fi

    local conf_file="$TASKS_DIR/${task_id}.conf"
    if [ ! -f "$conf_file" ]; then
        echo "任务不存在：$task_id"
        return 1
    fi

    printf '确认删除任务 %s？[y/N] ' "$task_id"
    local confirm
    read -r confirm
    case "$confirm" in
        y|Y) ;;
        *) echo "已取消"; return 1 ;;
    esac

    # 询问是否同时删除 gist
    TASK_GIST_ID=""
    load_conf "$conf_file" 2>/dev/null
    if [ -n "$TASK_GIST_ID" ]; then
        printf '是否同时删除 GitHub Gist（%s）？[y/N] ' "$TASK_GIST_ID"
        local delete_gist
        read -r delete_gist
        case "$delete_gist" in
            y|Y)
                # 加载全局配置获取 token
                if load_conf "$CONFIG_FILE" 2>/dev/null && [ -n "$GIST_TOKEN" ]; then
                    local http_code
                    http_code=$(gist_delete "$GIST_TOKEN" "$TASK_GIST_ID")
                    case "$http_code" in
                        204) echo "Gist 已删除：$TASK_GIST_ID" ;;
                        404) echo "Gist 已不存在（404）" ;;
                        *)   echo "Gist 删除失败（HTTP $http_code）" ;;
                    esac
                else
                    echo "无法加载 GIST_TOKEN，跳过 Gist 删除"
                fi
                ;;
        esac
    fi

    rm -f "$conf_file"
    rm -f "$STATE_DIR/${task_id}.state"
    rm -f "$CACHE_DIR/${task_id}.cache"
    echo "任务已删除：$task_id"
    return 0
}

# 立即运行所有任务
action_run_all() {
    echo ""
    echo "=== 立即运行所有任务 ==="
    if ! acquire_lock; then
        echo "已有进程在运行，请稍后再试"
        return 1
    fi
    run_all_tasks
    release_lock
}

# 管理 cron
action_manage_cron() {
    echo ""
    echo "=== cron 定时管理 ==="
    echo "当前环境：$(detect_env)"
    echo "cron 配置文件：$(get_cron_file)"
    echo ""
    echo "  1) 安装 cron（默认每日 06:00）"
    echo "  2) 安装 cron（自定义时间）"
    echo "  3) 卸载 cron"
    echo "  0) 返回主菜单"
    printf '请选择 [0-3]: '
    local choice
    if ! read -r choice; then
        return 1
    fi
    case "$choice" in
        1) install_cron "06:00" ;;
        2)
            printf '请输入时间（HH:MM，如 06:00）：'
            local hhmm
            read -r hhmm
            install_cron "$hhmm"
            ;;
        3) uninstall_cron ;;
        0) return 0 ;;
        *) echo "无效选项：$choice" ;;
    esac
}

# 卸载工具
action_uninstall() {
    echo ""
    echo "=== 卸载 sub_to_gist ==="
    echo ""
    echo "将执行以下操作："
    echo "  1. 卸载 cron 定时"
    echo "  2. 删除本地文件（配置/状态/缓存/日志）"
    echo "  3. （可选）删除所有 GitHub Gist"
    echo "  4. 提示撤销 GitHub PAT"
    echo ""
    printf '确认卸载？此操作不可逆 [y/N] '
    local confirm
    read -r confirm
    case "$confirm" in
        y|Y) ;;
        *) echo "已取消"; return 1 ;;
    esac

    # 1. 卸载 cron
    echo "[1/4] 卸载 cron..."
    uninstall_cron

    # 2. 询问是否删除 gist
    echo "[2/4] 处理 GitHub Gist..."
    if [ -d "$TASKS_DIR" ] && [ -n "$(ls "$TASKS_DIR"/*.conf 2>/dev/null)" ]; then
        printf '是否删除所有任务的 GitHub Gist？[y/N] '
        local delete_gists
        read -r delete_gists
        case "$delete_gists" in
            y|Y)
                if load_conf "$CONFIG_FILE" 2>/dev/null && [ -n "$GIST_TOKEN" ]; then
                    ls "$TASKS_DIR"/*.conf 2>/dev/null | while IFS= read -r conf_file; do
                        [ -z "$conf_file" ] && continue
                        TASK_GIST_ID=""
                        load_conf "$conf_file" 2>/dev/null
                        if [ -n "$TASK_GIST_ID" ]; then
                            local http_code
                            http_code=$(gist_delete "$GIST_TOKEN" "$TASK_GIST_ID")
                            case "$http_code" in
                                204) echo "  已删除 Gist：$TASK_GIST_ID" ;;
                                404) echo "  Gist 已不存在：$TASK_GIST_ID" ;;
                                *)   echo "  删除失败（HTTP $http_code）：$TASK_GIST_ID" ;;
                            esac
                        fi
                    done
                else
                    echo "  无法加载 GIST_TOKEN，跳过 Gist 删除"
                fi
                ;;
            *) echo "  保留 Gist（URL 仍可访问，直到 token 撤销或手动删除）" ;;
        esac
    fi

    # 3. 删除本地文件
    echo "[3/4] 删除本地文件..."
    rm -rf "$INSTALL_DIR"
    echo "  已删除：$INSTALL_DIR"

    # 4. 提示撤销 PAT
    echo "[4/4] 请撤销 GitHub PAT："
    echo "  1. 访问 https://github.com/settings/tokens"
    echo "  2. 删除 sub_to_gist 使用的 PAT"
    echo ""
    echo "卸载完成。"
    return 0
}

# ============ 配置 Gist Token ============

action_configure_token() {
    echo ""
    echo "=== 配置 Gist Token ==="
    echo ""

    # 显示当前 token（脱敏）
    local current_token=""
    local desc_prefix="sub_to_gist"
    if load_conf "$CONFIG_FILE" 2>/dev/null; then
        current_token="${GIST_TOKEN:-}"
        desc_prefix="${GIST_DESCRIPTION_PREFIX:-sub_to_gist}"
    fi

    if [ -n "$current_token" ]; then
        # 脱敏显示：前 4 位 + *** + 后 4 位
        local token_len=${#current_token}
        if [ "$token_len" -gt 12 ]; then
            local prefix="${current_token%${current_token#????}}"
            local suffix="${current_token##${current_token%????}}"
            echo "当前 Token：${prefix}***${suffix}（长度 ${token_len}）"
        else
            echo "当前 Token：***（长度 ${token_len}，过短）"
        fi
    else
        echo "当前 Token：（未配置）"
    fi
    echo "  GIST_DESCRIPTION_PREFIX：${desc_prefix}"
    echo ""

    # 提示输入新 token
    printf '请输入 GitHub Personal Access Token（留空取消）：'
    local new_token
    if ! read -r new_token; then
        echo "输入取消"
        return 1
    fi

    if [ -z "$new_token" ]; then
        echo "已取消"
        return 1
    fi

    # 验证 token 格式（ghp_ classic PAT 或 github_pat_ fine-grained PAT）
    case "$new_token" in
        ghp_*|github_pat_*) ;;
        *)
            printf 'Token 格式异常（应以 ghp_ 或 github_pat_ 开头），确认继续？[y/N] '
            local confirm_format
            read -r confirm_format
            case "$confirm_format" in
                y|Y) ;;
                *) echo "已取消"; return 1 ;;
            esac
            ;;
    esac

    # 验证 token 有效性
    echo "正在验证 Token 有效性（调用 GitHub API）..."
    if ! gist_check_token "$new_token"; then
        echo "Token 验证失败，未保存"
        return 1
    fi
    echo "[OK] Token 验证通过"

    # 保存到 config.conf（保留 GIST_DESCRIPTION_PREFIX）
    save_conf "$CONFIG_FILE" \
        GIST_TOKEN "$new_token" \
        GIST_DESCRIPTION_PREFIX "$desc_prefix"
    chmod 600 "$CONFIG_FILE" 2>/dev/null

    echo ""
    echo "Token 已保存到：$CONFIG_FILE"
    echo "  GIST_TOKEN：已更新"
    echo "  GIST_DESCRIPTION_PREFIX：$desc_prefix"
    echo "  文件权限：600"
    echo ""
    echo "提示：现在可以选择「1) 添加内容推送到 Gist」创建任务"
    echo ""
}

# ============ 检查更新 ============

# 调用 install.sh --upgrade 检查并自主更新
action_check_update() {
    echo ""
    echo "=== 检查更新 ==="
    echo ""

    local install_script="$INSTALL_DIR/install.sh"

    # install.sh 不在 INSTALL_DIR 时，从 GitHub raw 下载到临时文件执行
    if [ ! -f "$install_script" ]; then
        echo "本地未找到 install.sh，从 GitHub 下载临时副本..."
        local tmp_script
        tmp_script=$(mktemp 2>/dev/null || echo "/tmp/sub_to_gist_install.$$")
        if ! curl -sSL --fail --connect-timeout 10 --max-time 60 \
            "https://raw.githubusercontent.com/ciskonc/sub_to_gist/main/src/install.sh" \
            -o "$tmp_script" 2>/dev/null || [ ! -s "$tmp_script" ]; then
            echo "[ERROR] 下载 install.sh 失败（网络错误或 GitHub 不可达）"
            rm -f "$tmp_script" 2>/dev/null
            return 1
        fi
        chmod 755 "$tmp_script"
        sh "$tmp_script" --upgrade
        local rc=$?
        rm -f "$tmp_script" 2>/dev/null
        return $rc
    fi

    # 本地有 install.sh，直接调用
    sh "$install_script" --upgrade
    return $?
}

# 主菜单
main_menu() {
    # 检查依赖
    if ! check_deps; then
        printf '是否立即安装依赖？[y/N] '
        local confirm
        read -r confirm
        case "$confirm" in
            y|Y) install_deps ;;
            *) return 1 ;;
        esac
    fi

    # 检查全局配置：config.conf 不存在时自动创建空配置，引导用户选择 7) 配置 Token
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "全局配置文件不存在，正在创建空配置：$CONFIG_FILE"
        mkdir -p "$(dirname "$CONFIG_FILE")" 2>/dev/null
        save_conf "$CONFIG_FILE" \
            GIST_TOKEN "" \
            GIST_DESCRIPTION_PREFIX "sub_to_gist"
        chmod 600 "$CONFIG_FILE" 2>/dev/null
        echo "[OK] 配置文件已创建（权限 600）"
        echo ""
        echo "请选择「7) 配置 Gist Token」填入 GitHub PAT 后再添加任务"
        echo ""
    fi

    while :; do
        local task_count=0
        if [ -d "$TASKS_DIR" ]; then
            task_count=$(ls "$TASKS_DIR"/*.conf 2>/dev/null | wc -l)
        fi

        # 检查 token 配置状态（用于菜单提示）
        local token_status="未配置"
        if load_conf "$CONFIG_FILE" 2>/dev/null && [ -n "${GIST_TOKEN:-}" ]; then
            token_status="已配置"
        fi

        echo ""
        echo "=== Gist 内容推送器 v$VERSION ==="
        echo "运行环境：$(detect_env)"
        echo "Token 状态：$token_status"
        echo "当前已有 ${task_count} 个推送任务"
        echo ""
        echo "  1) 添加内容推送到 Gist"
        echo "  2) 查看现在已有推送"
        echo "  3) 删除任务"
        echo "  4) 立即运行所有任务"
        echo "  5) 安装/管理 cron 定时"
        echo "  6) 卸载本工具和清理 cron"
        echo "  7) 配置 Gist Token"
        echo "  8) 检查更新"
        echo "  0) 退出"
        printf '请选择 [0-8]: '

        local choice
        if ! read -r choice; then
            echo
            echo "EOF，退出"
            exit 0
        fi

        case "$choice" in
            1) action_add_task ;;
            2) action_list_tasks ;;
            3) action_delete_task ;;
            4) action_run_all ;;
            5) action_manage_cron ;;
            6) action_uninstall ;;
            7) action_configure_token ;;
            8) action_check_update ;;
            0) echo "再见"; exit 0 ;;
            '') echo "输入不能为空" ;;
            *) echo "无效选项：'$choice'" ;;
        esac

        echo ""
        printf '按回车返回主菜单...'
        read -r _
    done
}

# ============ 入口 ============

case "${1:-menu}" in
    menu|"")
        main_menu
        ;;
    run-all)
        run_all_tasks
        ;;
    run)
        if [ -z "${2:-}" ]; then
            echo "用法：$0 run <task_id>"
            exit 1
        fi
        if ! acquire_lock; then
            echo "已有进程在运行，请稍后再试"
            exit 1
        fi
        if ! load_conf "$CONFIG_FILE"; then
            echo "加载全局配置失败"
            release_lock
            exit 1
        fi
        push_task "$2"
        rc=$?
        release_lock
        exit $rc
        ;;
    rotate-gist)
        if [ -z "${2:-}" ]; then
            echo "用法：$0 rotate-gist <task_id>"
            exit 1
        fi
        if ! acquire_lock; then
            echo "已有进程在运行，请稍后再试"
            exit 1
        fi
        if ! load_conf "$CONFIG_FILE"; then
            echo "加载全局配置失败"
            release_lock
            exit 1
        fi
        task_id="$2"
        conf_file="$TASKS_DIR/${task_id}.conf"
        if [ ! -f "$conf_file" ]; then
            echo "任务不存在：$task_id"
            release_lock
            exit 1
        fi
        TASK_GIST_ID=""
        load_conf "$conf_file"
        if [ -n "$TASK_GIST_ID" ]; then
            echo "删除旧 gist：$TASK_GIST_ID"
            http_code=$(gist_delete "$GIST_TOKEN" "$TASK_GIST_ID")
            echo "删除结果：HTTP $http_code"
        fi
        # 清空 gist_id 并重新推送
        save_conf "$conf_file" \
            TASK_NAME "$TASK_NAME" \
            TASK_URL "$TASK_URL" \
            TASK_UA "$TASK_UA" \
            TASK_HEADERS "$TASK_HEADERS" \
            TASK_GIST_ID "" \
            TASK_GIST_FILENAME "$TASK_GIST_FILENAME"
        echo "重新推送任务：$task_id"
        push_task "$task_id"
        rc=$?
        release_lock
        exit $rc
        ;;
    cron-install)
        install_cron "${2:-06:00}"
        ;;
    cron-uninstall)
        uninstall_cron
        ;;
    check-deps)
        check_deps
        ;;
    install-deps)
        install_deps
        ;;
    version|-v|--version)
        echo "sub_to_gist v$VERSION"
        ;;
    help|-h|--help)
        cat <<EOF
sub_to_gist v$VERSION — 网页内容中转推送器

用法：
  $0                          启动交互菜单
  $0 run-all                  运行所有任务（cron 调用）
  $0 run <task_id>            运行单个任务
  $0 rotate-gist <task_id>    删除并重建 gist（token 轮换时使用）
  $0 cron-install [hh:mm]     安装 cron 定时（默认 06:00）
  $0 cron-uninstall           卸载 cron 定时
  $0 check-deps               检查依赖
  $0 install-deps             安装依赖（自适应环境）
  $0 version                  显示版本
  $0 help                     显示帮助

环境：$(detect_env)
配置：$CONFIG_FILE
EOF
        ;;
    *)
        echo "未知命令：$1"
        echo "运行 '$0 help' 查看用法"
        exit 1
        ;;
esac
