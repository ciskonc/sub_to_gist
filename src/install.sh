#!/bin/sh
# =============================================================================
# sub_to_gist — 部署脚本
#
# 功能：检测环境 → 安装依赖 → 创建目录 → 部署脚本 → 设置权限 → 提示配置
# 支持：本地安装（clone 仓库后执行）+ 网络一键安装（sh -c "$(curl ...)"）
# 支持：版本检测 + 自主更新（--upgrade）
#
# 用法：
#   sh install.sh              # 交互式部署（本地或网络模式自动检测）
#   sh install.sh --auto       # 静默部署（使用默认值）
#   sh install.sh --upgrade    # 检查远程版本，有更新则自主更新
#   sh install.sh --help       # 显示帮助
#
# 一键安装：
#   sh -c "$(curl -sSL https://raw.githubusercontent.com/ciskonc/sub_to_gist/main/src/install.sh)"
#
# 自主更新：
#   sh /etc/sub_to_gist/pusher.sh  # 菜单选择 8) 检查更新
#   sh -c "$(curl -sSL https://raw.githubusercontent.com/ciskonc/sub_to_gist/main/src/install.sh)" -- --upgrade
# =============================================================================

set -u

# ============ 常量 ============
VERSION="1.0.3"
INSTALL_DIR="/etc/sub_to_gist"
SCRIPT_NAME="pusher.sh"
CONFIG_NAME="config.conf"
CONFIG_TEMPLATE="config.example"
DIRS_TO_CREATE="tasks.d cache.d state.d logs"
GITHUB_RAW_BASE="https://raw.githubusercontent.com/ciskonc/sub_to_gist/main/src"

# 网络安装模式临时目录（用于 trap 清理）
DEPLOY_TMP_DIR=""

# 获取脚本所在目录（源文件目录）
# 注意：sh -c "$(curl ...)" 模式下 $0 为 sh，SCRIPT_DIR 解析为当前目录，无源文件
SCRIPT_DIR=$(dirname "$0")
case "$SCRIPT_DIR" in
    /*) : ;;
    *)  SCRIPT_DIR=$(pwd)/$SCRIPT_DIR ;;
esac

# ============ 环境检测 ============

detect_env() {
    if [ -f /etc/openwrt_release ]; then
        echo "openwrt"
    elif [ -f /etc/fnos-release ] || grep -q '^ID=fnos' /etc/os-release 2>/dev/null; then
        echo "fnos"
    else
        echo "generic"
    fi
}

# ============ 安装模式检测 ============

# 检测安装模式：local（本地有源文件）/ remote（需从 GitHub 下载）
detect_install_mode() {
    if [ -f "$SCRIPT_DIR/$SCRIPT_NAME" ] && [ -f "$SCRIPT_DIR/$CONFIG_TEMPLATE" ]; then
        echo "local"
    else
        echo "remote"
    fi
}

# 下载文件（curl 兼容 OpenWrt BusyBox）
# $1 = URL, $2 = 目标路径
download_file() {
    local url="$1"
    local dst="$2"
    echo_info "下载：$url"
    if curl -sSL --fail --connect-timeout 10 --max-time 60 "$url" -o "$dst" 2>/dev/null; then
        if [ -s "$dst" ]; then
            echo_ok "下载完成：$dst"
            return 0
        else
            echo_error "下载内容为空：$url"
            return 1
        fi
    else
        echo_error "下载失败：$url"
        return 1
    fi
}

# 清理临时目录（trap 调用）
cleanup_tmp() {
    if [ -n "$DEPLOY_TMP_DIR" ] && [ -d "$DEPLOY_TMP_DIR" ]; then
        rm -rf "$DEPLOY_TMP_DIR" 2>/dev/null
    fi
}

# ============ 版本检测 ============

# 从已安装的 pusher.sh 提取版本号
get_local_version() {
    local installed_script="$INSTALL_DIR/$SCRIPT_NAME"
    if [ -f "$installed_script" ]; then
        grep '^VERSION="' "$installed_script" 2>/dev/null | head -1 | sed 's/^VERSION="//;s/"$//'
    fi
}

# 从文件提取版本号（通用，供 deploy_files 复用）
# $1 = 文件路径
extract_version() {
    if [ -f "$1" ]; then
        grep '^VERSION="' "$1" 2>/dev/null | head -1 | sed 's/^VERSION="//;s/"$//'
    fi
}

# 从 GitHub raw 下载 pusher.sh 到临时文件并返回版本号
# $1 = 临时文件路径（下载完成后可用于覆盖更新）
# 输出：版本号字符串（失败时输出空字符串）
get_remote_version() {
    local tmp_file="$1"
    if curl -sSL --fail --connect-timeout 10 --max-time 60 "$GITHUB_RAW_BASE/$SCRIPT_NAME" -o "$tmp_file" 2>/dev/null; then
        if [ -s "$tmp_file" ]; then
            extract_version "$tmp_file"
        fi
    fi
}

# 比较两个语义化版本号（格式：major.minor.patch）
# 参数：$1=v1  $2=v2
# 返回值：0=相等  1=v1>v2  2=v1<v2
compare_versions() {
    local v1="$1" v2="$2"
    # 移除可能的 v 前缀
    v1=${v1#v}
    v2=${v2#v}

    while [ -n "$v1" ] || [ -n "$v2" ]; do
        # 提取第一段（. 之前）
        local p1=${v1%%.*}
        local p2=${v2%%.*}
        # 处理空值
        p1=${p1:-0}
        p2=${p2:-0}

        # 数值比较
        if [ "$p1" -gt "$p2" ] 2>/dev/null; then
            return 1
        elif [ "$p1" -lt "$p2" ] 2>/dev/null; then
            return 2
        fi

        # 移除已比较的部分
        case "$v1" in *.*) v1=${v1#*.} ;; *) v1="" ;; esac
        case "$v2" in *.*) v2=${v2#*.} ;; *) v2="" ;; esac
    done
    return 0
}

# ============ 颜色输出 ============

echo_info() {
    printf '[INFO] %s\n' "$*"
}

echo_ok() {
    printf '[OK]   %s\n' "$*"
}

echo_warn() {
    printf '[WARN] %s\n' "$*"
}

echo_error() {
    printf '[ERROR] %s\n' "$*" >&2
}

echo_step() {
    printf '\n=== [步骤 %d/%d] %s ===\n' "$1" "$2" "$3"
}

# ============ 依赖检查与安装 ============

check_command() {
    command -v "$1" >/dev/null 2>&1
}

check_deps() {
    local missing=0
    local env_type
    env_type=$(detect_env)

    echo_info "运行环境：$env_type"

    if ! check_command curl; then
        echo_warn "缺失：curl"
        missing=1
    fi

    # 检查 CA 证书
    case "$env_type" in
        openwrt)
            if [ ! -d /etc/ssl/certs ] && [ ! -f /etc/ssl/certs/ca-certificates.crt ]; then
                echo_warn "缺失：CA 证书"
                missing=1
            fi
            ;;
        *)
            if [ ! -f /etc/ssl/certs/ca-certificates.crt ] && ! check_command update-ca-certificates; then
                echo_warn "缺失：CA 证书"
                missing=1
            fi
            ;;
    esac

    if [ "$missing" -eq 1 ]; then
        return 1
    fi
    return 0
}

install_deps() {
    local env_type
    env_type=$(detect_env)
    echo_info "安装依赖（环境：$env_type）"
    case "$env_type" in
        openwrt)
            opkg update && opkg install curl ca-bundle ca-certificates
            ;;
        *)
            apt-get update && apt-get install -y curl ca-certificates
            ;;
    esac
}

# ============ 目录创建 ============

create_dirs() {
    echo_info "创建目录：$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    local dir
    for dir in $DIRS_TO_CREATE; do
        mkdir -p "$INSTALL_DIR/$dir"
        echo_info "  创建：$INSTALL_DIR/$dir"
    done
    return 0
}

# ============ 文件部署 ============

deploy_files() {
    local install_mode
    install_mode=$(detect_install_mode)

    local src_script="$SCRIPT_DIR/$SCRIPT_NAME"
    local src_config="$SCRIPT_DIR/$CONFIG_TEMPLATE"
    local dst_script="$INSTALL_DIR/$SCRIPT_NAME"
    local dst_config="$INSTALL_DIR/$CONFIG_NAME"

    # 网络安装模式：从 GitHub raw 下载源文件到临时目录
    if [ "$install_mode" = "remote" ]; then
        echo_info "检测到网络安装模式，从 GitHub 下载源文件"
        DEPLOY_TMP_DIR=$(mktemp -d 2>/dev/null || echo "/tmp/sub_to_gist_install.$$")
        mkdir -p "$DEPLOY_TMP_DIR"
        trap cleanup_tmp EXIT INT TERM

        src_script="$DEPLOY_TMP_DIR/$SCRIPT_NAME"
        src_config="$DEPLOY_TMP_DIR/$CONFIG_TEMPLATE"

        if ! download_file "$GITHUB_RAW_BASE/$SCRIPT_NAME" "$src_script"; then
            return 1
        fi
        if ! download_file "$GITHUB_RAW_BASE/$CONFIG_TEMPLATE" "$src_config"; then
            return 1
        fi
    else
        # 本地模式：检查源文件
        if [ ! -f "$src_script" ]; then
            echo_error "源脚本不存在：$src_script"
            echo_error "若使用网络安装，请执行：sh -c \"\$(curl -sSL $GITHUB_RAW_BASE/install.sh)\""
            return 1
        fi
        if [ ! -f "$src_config" ]; then
            echo_error "源配置模板不存在：$src_config"
            return 1
        fi
    fi

    # 版本检测：如果本地已安装，对比版本决定是否更新主脚本
    local local_version=""
    local remote_version=""
    local skip_script=0

    if [ -f "$dst_script" ]; then
        local_version=$(extract_version "$dst_script")
        remote_version=$(extract_version "$src_script")

        if [ -n "$local_version" ] && [ -n "$remote_version" ]; then
            compare_versions "$remote_version" "$local_version"
            case $? in
                0)
                    echo_info "本地版本 v$local_version 已是最新，跳过主脚本更新"
                    skip_script=1
                    ;;
                2)
                    echo_warn "本地版本 v$local_version 比源版本 v$remote_version 更新，跳过主脚本更新"
                    skip_script=1
                    ;;
                1)
                    echo_info "发现新版本：v$local_version → v$remote_version，更新主脚本"
                    local backup="${dst_script}.bak.$(date '+%Y%m%d%H%M%S')"
                    cp "$dst_script" "$backup"
                    chmod 600 "$backup"
                    echo_info "已备份旧版本：$backup"
                    ;;
            esac
        fi
    fi

    # 复制主脚本（skip_script=0 时执行）
    if [ "$skip_script" -eq 0 ]; then
        echo_info "部署主脚本：→ $dst_script"
        cp "$src_script" "$dst_script"
        chmod 755 "$dst_script"
    fi

    # 复制配置文件（用户配置不覆盖，仅首次部署时写入）
    if [ -f "$dst_config" ]; then
        echo_info "配置文件已存在，保留用户配置：$dst_config"
    else
        echo_info "部署配置模板：→ $dst_config"
        cp "$src_config" "$dst_config"
    fi
    chmod 600 "$dst_config"

    return 0
}

# ============ 权限设置 ============

set_permissions() {
    echo_info "设置文件权限"
    chmod 755 "$INSTALL_DIR"
    chmod 700 "$INSTALL_DIR/tasks.d" 2>/dev/null
    chmod 700 "$INSTALL_DIR/cache.d" 2>/dev/null
    chmod 700 "$INSTALL_DIR/state.d" 2>/dev/null
    chmod 700 "$INSTALL_DIR/logs" 2>/dev/null
    chmod 600 "$INSTALL_DIR/$CONFIG_NAME" 2>/dev/null
    chmod 755 "$INSTALL_DIR/$SCRIPT_NAME" 2>/dev/null
    echo_ok "权限设置完成"
    return 0
}

# ============ 验证部署 ============

verify_deployment() {
    echo_info "验证部署"
    local errors=0

    if [ ! -f "$INSTALL_DIR/$SCRIPT_NAME" ]; then
        echo_error "主脚本未部署：$INSTALL_DIR/$SCRIPT_NAME"
        errors=1
    fi
    if [ ! -f "$INSTALL_DIR/$CONFIG_NAME" ]; then
        echo_error "配置文件未部署：$INSTALL_DIR/$CONFIG_NAME"
        errors=1
    fi
    local dir
    for dir in $DIRS_TO_CREATE; do
        if [ ! -d "$INSTALL_DIR/$dir" ]; then
            echo_error "目录未创建：$INSTALL_DIR/$dir"
            errors=1
        fi
    done

    if [ $errors -eq 1 ]; then
        echo_error "部署验证失败"
        return 1
    fi

    echo_ok "部署验证通过"
    return 0
}

# ============ 自主更新 ============

# 检查远程版本并自主更新
do_upgrade() {
    echo "============================================================"
    echo "  sub_to_gist 自主更新检查"
    echo "============================================================"
    echo ""

    local local_version
    local_version=$(get_local_version)

    if [ -z "$local_version" ]; then
        echo_warn "本地未安装 sub_to_gist（$INSTALL_DIR/$SCRIPT_NAME 不存在）"
        echo_info "请先执行安装：sh install.sh"
        return 1
    fi

    echo_info "本地版本：v$local_version"
    echo_info "正在检查远程版本（$GITHUB_RAW_BASE）..."

    local tmp_file
    tmp_file=$(mktemp 2>/dev/null || echo "/tmp/sub_to_gist_upgrade.$$")

    local remote_version
    remote_version=$(get_remote_version "$tmp_file")

    if [ -z "$remote_version" ]; then
        echo_error "无法获取远程版本（网络错误或 GitHub 不可达）"
        rm -f "$tmp_file" 2>/dev/null
        return 1
    fi

    echo_info "远程版本：v$remote_version"

    # 版本对比
    compare_versions "$remote_version" "$local_version"
    local cmp_result=$?

    case $cmp_result in
        0)
            echo_ok "已是最新版本（v$local_version），无需更新"
            rm -f "$tmp_file" 2>/dev/null
            return 0
            ;;
        2)
            echo_warn "本地版本更新（v$local_version > v$remote_version），跳过更新"
            rm -f "$tmp_file" 2>/dev/null
            return 0
            ;;
        1)
            echo_info "发现新版本：v$local_version → v$remote_version"
            ;;
    esac

    # 执行更新：备份 → 覆盖
    echo_info "备份当前版本..."
    local backup_file="$INSTALL_DIR/${SCRIPT_NAME}.bak.$(date '+%Y%m%d%H%M%S')"
    cp "$INSTALL_DIR/$SCRIPT_NAME" "$backup_file"
    chmod 600 "$backup_file"
    echo_ok "已备份至：$backup_file"

    echo_info "更新主脚本..."
    cp "$tmp_file" "$INSTALL_DIR/$SCRIPT_NAME"
    chmod 755 "$INSTALL_DIR/$SCRIPT_NAME"
    rm -f "$tmp_file" 2>/dev/null
    echo_ok "主脚本已更新至 v$remote_version"

    # 同步更新 config.example（仅当本地无 config.conf 时）
    if [ ! -f "$INSTALL_DIR/$CONFIG_NAME" ]; then
        local tmp_config
        tmp_config=$(mktemp 2>/dev/null || echo "/tmp/sub_to_gist_config.$$")
        if curl -sSL --fail --connect-timeout 10 --max-time 30 "$GITHUB_RAW_BASE/$CONFIG_TEMPLATE" -o "$tmp_config" 2>/dev/null && [ -s "$tmp_config" ]; then
            cp "$tmp_config" "$INSTALL_DIR/$CONFIG_NAME"
            chmod 600 "$INSTALL_DIR/$CONFIG_NAME"
            echo_ok "配置模板已更新"
        fi
        rm -f "$tmp_config" 2>/dev/null
    else
        echo_info "配置文件已存在，保留用户配置"
    fi

    echo ""
    echo_ok "更新完成：v$local_version → v$remote_version"
    echo_info "备份文件：$backup_file"
    echo_info "如需回滚：cp $backup_file $INSTALL_DIR/$SCRIPT_NAME"
    return 0
}

# ============ 完成提示 ============

print_completion() {
    local env_type
    env_type=$(detect_env)
    cat <<EOF

============================================================
  sub_to_gist v$VERSION 部署完成！
============================================================

运行环境：$env_type
安装路径：$INSTALL_DIR

下一步操作：

  1. 编辑配置文件，填入 GitHub Token：
     vi $INSTALL_DIR/$CONFIG_NAME
     （找到 GIST_TOKEN 行，替换为你的 PAT）

  2. 启动交互菜单：
     $INSTALL_DIR/$SCRIPT_NAME

  3. 在菜单中选择「1) 添加内容推送到 Gist」添加任务

  4. 在菜单中选择「5) 安装/管理 cron 定时」设置自动推送

依赖安装命令（如需手动安装）：
EOF
    case "$env_type" in
        openwrt)
            echo "     opkg update && opkg install curl ca-bundle ca-certificates"
            ;;
        *)
            echo "     apt-get update && apt-get install -y curl ca-certificates"
            ;;
    esac
    cat <<EOF

卸载命令：
  $INSTALL_DIR/$SCRIPT_NAME  （菜单选择 6 卸载）

============================================================
EOF
}

# ============ 主流程 ============

main() {
    local auto_mode=0
    case "${1:-}" in
        --auto|-a) auto_mode=1 ;;
        --upgrade|-u)
            do_upgrade
            exit $?
            ;;
        --help|-h)
            cat <<EOF
sub_to_gist 部署脚本 v$VERSION

用法：
  sh install.sh              交互式部署
  sh install.sh --auto       静默部署（使用默认值）
  sh install.sh --upgrade    检查远程版本，有更新则自主更新
  sh install.sh --help       显示帮助
EOF
            exit 0
            ;;
    esac

    echo "============================================================"
    echo "  sub_to_gist v$VERSION 部署脚本"
    echo "============================================================"

    local total_steps=5
    local current_step=1

    # 步骤 1：检查依赖
    echo_step $current_step $total_steps "检查依赖"
    current_step=$((current_step + 1))
    if ! check_deps; then
        if [ $auto_mode -eq 1 ]; then
            install_deps
        else
            printf '是否立即安装依赖？[y/N] '
            local confirm
            read -r confirm
            case "$confirm" in
                y|Y) install_deps ;;
                *)
                    echo_warn "跳过依赖安装，部分功能可能不可用"
                    echo_warn "请手动运行：$INSTALL_DIR/$SCRIPT_NAME install-deps"
                    ;;
            esac
        fi
    else
        echo_ok "依赖检查通过"
    fi

    # 步骤 2：创建目录
    echo_step $current_step $total_steps "创建目录结构"
    current_step=$((current_step + 1))
    create_dirs
    echo_ok "目录创建完成"

    # 步骤 3：部署文件
    echo_step $current_step $total_steps "部署脚本与配置"
    current_step=$((current_step + 1))
    if ! deploy_files; then
        echo_error "文件部署失败"
        exit 1
    fi
    echo_ok "文件部署完成"

    # 步骤 4：设置权限
    echo_step $current_step $total_steps "设置文件权限"
    current_step=$((current_step + 1))
    set_permissions

    # 步骤 5：验证部署
    echo_step $current_step $total_steps "验证部署"
    current_step=$((current_step + 1))
    if ! verify_deployment; then
        exit 1
    fi

    # 完成提示
    print_completion
}

main "$@"
