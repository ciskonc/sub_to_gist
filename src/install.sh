#!/bin/sh
# =============================================================================
# sub_to_gist — 部署脚本
#
# 功能：检测环境 → 安装依赖 → 创建目录 → 部署脚本 → 设置权限 → 提示配置
#
# 用法：
#   sh install.sh              # 交互式部署
#   sh install.sh --auto       # 静默部署（使用默认值）
# =============================================================================

set -u

# ============ 常量 ============
VERSION="1.0.0"
INSTALL_DIR="/etc/sub_to_gist"
SCRIPT_NAME="pusher.sh"
CONFIG_NAME="config.conf"
CONFIG_TEMPLATE="config.example"
DIRS_TO_CREATE="tasks.d cache.d state.d logs"

# 获取脚本所在目录（源文件目录）
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
    local src_script="$SCRIPT_DIR/$SCRIPT_NAME"
    local src_config="$SCRIPT_DIR/$CONFIG_TEMPLATE"
    local dst_script="$INSTALL_DIR/$SCRIPT_NAME"
    local dst_config="$INSTALL_DIR/$CONFIG_NAME"

    # 检查源文件
    if [ ! -f "$src_script" ]; then
        echo_error "源脚本不存在：$src_script"
        return 1
    fi
    if [ ! -f "$src_config" ]; then
        echo_error "源配置模板不存在：$src_config"
        return 1
    fi

    # 复制主脚本
    echo_info "部署主脚本：$src_script → $dst_script"
    cp "$src_script" "$dst_script"
    chmod 755 "$dst_script"

    # 复制配置文件（如果目标已存在则备份）
    if [ -f "$dst_config" ]; then
        local backup="${dst_config}.bak.$(date '+%Y%m%d%H%M%S')"
        echo_warn "配置文件已存在，备份至：$backup"
        cp "$dst_config" "$backup"
        chmod 600 "$backup"
    else
        echo_info "部署配置模板：$src_config → $dst_config"
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

  3. 在菜单中选择「1) 添加订阅推送到 Gist」添加任务

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
        --help|-h)
            cat <<EOF
sub_to_gist 部署脚本 v$VERSION

用法：
  sh install.sh              交互式部署
  sh install.sh --auto       静默部署（使用默认值）
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
