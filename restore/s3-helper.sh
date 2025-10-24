#!/bin/bash
set -Eeo pipefail

# =============================================================================
# S3辅助工具脚本
# 简化远程S3备份操作，复用mc客户端
# =============================================================================

# 全局变量
MC_INSTALL_DIR="${MC_INSTALL_DIR:-/tmp}"
MC_CMD="${MC_INSTALL_DIR}/mc"
ALIAS_NAME="remote_storage"

log_info() {
    echo -e "\033[0;34m[INFO]\033[0m $1" >&2
}

log_error() {
    echo -e "\033[0;31m[ERROR]\033[0m $1" >&2
}

# 安装MinIO Client（如果需要）
install_mc() {
    if command -v mc &> /dev/null; then
        MC_CMD="mc"
        log_info "使用系统已安装的mc客户端"
        return 0
    fi
    
    if [ -f "$MC_CMD" ]; then
        log_info "使用已下载的mc客户端: $MC_CMD"
        return 0
    fi
    
    log_info "下载MinIO Client..."
    
    # 检测操作系统和架构
    local os=$(uname -s | tr '[:upper:]' '[:lower:]')
    local arch=$(uname -m)
    
    case "$arch" in
        x86_64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) 
            log_error "不支持的架构: $arch"
            return 1
            ;;
    esac
    
    local mc_url="https://dl.min.io/client/mc/release/${os}-${arch}/mc"
    
    if ! curl -fsSL "$mc_url" -o "$MC_CMD"; then
        log_error "下载mc失败"
        return 1
    fi
    
    chmod +x "$MC_CMD"
    log_info "mc客户端已安装到: $MC_CMD"
}

# 配置S3连接
configure_s3() {
    local endpoint=$1
    local access_key=$2
    local secret_key=$3
    
    if [ -z "$endpoint" ] || [ -z "$access_key" ] || [ -z "$secret_key" ]; then
        log_error "缺少S3配置参数"
        return 1
    fi
    
    # 移除已存在的别名
    $MC_CMD alias remove "$ALIAS_NAME" 2>/dev/null || true
    
    # 添加新别名
    if $MC_CMD alias set "$ALIAS_NAME" "$endpoint" "$access_key" "$secret_key" --api S3v4 >/dev/null 2>&1; then
        log_info "S3连接已配置: $endpoint"
        return 0
    else
        log_error "S3连接配置失败"
        return 1
    fi
}

# 列出备份
list_backups() {
    local bucket=$1
    local prefix=$2
    
    # 列出备份目录
    $MC_CMD ls "${ALIAS_NAME}/${bucket}/${prefix}/files/" 2>/dev/null | \
        awk 'NF>=5{print $5}' | \
        sed 's:/$::' | \
        grep -E '^[0-9]{8}$' | \
        sort -r
}

# 检查备份是否存在
check_backup_exists() {
    local bucket=$1
    local prefix=$2
    local date=$3
    
    $MC_CMD ls "${ALIAS_NAME}/${bucket}/${prefix}/files/${date}/" >/dev/null 2>&1
}

# 获取备份大小
get_backup_size() {
    local bucket=$1
    local prefix=$2
    local date=$3
    
    $MC_CMD du "${ALIAS_NAME}/${bucket}/${prefix}/files/${date}/" 2>/dev/null | \
        awk '{print $1}'
}

# 显示备份详情
show_backup_details() {
    local bucket=$1
    local prefix=$2
    local date=$3
    
    log_info "备份详情 - $date"
    $MC_CMD ls "${ALIAS_NAME}/${bucket}/${prefix}/files/${date}/" 2>/dev/null
}

# 主函数
main() {
    local command=$1
    shift
    
    case "$command" in
        install)
            install_mc
            ;;
        configure)
            configure_s3"$@"
            ;;
        list)
            list_backups "$@"
            ;;
        check)
            check_backup_exists "$@"
            ;;
        size)
            get_backup_size "$@"
            ;;
        details)
            show_backup_details "$@"
            ;;
        *)
            cat << EOF
S3辅助工具

用法:
    $0 install
    $0 configure <endpoint> <access_key> <secret_key>
    $0 list <bucket> <prefix>
    $0 check <bucket> <prefix> <date>
    $0 size <bucket> <prefix> <date>
    $0 details <bucket> <prefix> <date>

环境变量:
    MC_INSTALL_DIR   mc客户端安装目录 (默认: /tmp)

示例:
    # 安装mc客户端
    $0 install
    
    # 配置S3连接
    $0 configure https://s3.amazonaws.com AKIAIOSFODNN7EXAMPLE wJalrXU...
    
    # 列出备份
    $0 list backups postgres
    
    # 检查备份是否存在
    $0 check backups postgres 20241218
    
    # 获取备份大小
    $0 size backups postgres 20241218
    
    # 显示备份详情
    $0 details backups postgres 20241218

EOF
            ;;
    esac
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
