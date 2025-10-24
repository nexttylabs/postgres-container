#!/bin/bash
set -Eeo pipefail

# =============================================================================
# 增量备份还原辅助脚本
# 用于配合 quick-restore.sh 处理增量备份链
# =============================================================================

# 日志函数
log_info() {
    echo -e "\033[0;34m[INFO]\033[0m $1"
}

log_error() {
    echo -e "\033[0;31m[ERROR]\033[0m $1"
}

log_success() {
    echo -e "\033[0;32m[SUCCESS]\033[0m $1"
}

# 获取增量备份链
get_incremental_chain() {
    local base_date=$1
    local namespace=$2
    local minio_pod=$3
    local s3_bucket=${4:-backups}
    local backup_prefix=${5:-postgres}
    
    log_info "获取日期 ${base_date} 的增量备份链..."
    
    # 获取增量备份列表（按时间排序）
    local incremental_path="${s3_bucket}/${backup_prefix}/files/${base_date}/incremental"
    
    kubectl exec -n "$namespace" "$minio_pod" -- \
        mc ls "$incremental_path/" 2>/dev/null | \
        awk 'NF>=5{print $5}' | \
        sed 's:/$::' | \
        grep "postgres-incremental-" | \
        sort
}

# 显示增量备份链信息
show_incremental_info() {
    local base_date=$1
    local namespace=$2
    local minio_label=${3:-app.kubernetes.io/name=minio}
    
    # 获取MinIO Pod
    local minio_pod=$(kubectl get pods -l "$minio_label" -n "$namespace" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$minio_pod" ]; then
        log_error "未找到MinIO Pod"
        return 1
    fi
    
    # 检查全量备份
    local full_backup=$(kubectl exec -n "$namespace" "$minio_pod" -- \
        mc ls "backups/postgres/files/${base_date}/" 2>/dev/null | \
        grep "postgres-full-" | head -n1)
    
    if [ -z "$full_backup" ]; then
        log_error "未找到日期 ${base_date} 的全量备份"
        return 1
    fi
    
    log_success "找到全量备份: $full_backup"
    
    # 获取增量备份链
    local incremental_backups=$(get_incremental_chain "$base_date" "$namespace" "$minio_pod")
    
    if [ -n "$incremental_backups" ]; then
        echo ""
        echo "增量备份链:"
        echo "============"
        local count=1
        echo "$incremental_backups" | while read -r backup; do
            echo "$count. $backup"
            count=$((count + 1))
        done
        echo ""
        log_info "总计: 1个全量备份 + $(echo "$incremental_backups" | wc -l | tr -d ' ')个增量备份"
    else
        log_info "没有增量备份，仅需还原全量备份"
    fi
}

# 生成还原脚本使用说明
show_usage() {
    cat << 'EOF'
增量备份还原辅助脚本

用法:
    ./restore-incremental.sh info <DATE> <NAMESPACE>
    ./restore-incremental.sh list <DATE> <NAMESPACE>

命令:
    info    显示指定日期的备份链信息
    list    列出增量备份（用于脚本集成）

示例:
    ./restore-incremental.sh info 20241218 postgres
    ./restore-incremental.sh list 20241218 postgres

注意:
    增量备份必须按顺序应用，还原流程为：
    1. 还原全量备份
    2. 按时间顺序应用所有增量备份
    3. 验证数据完整性

EOF
}

# 主函数
main() {
    local command=$1
    local date=$2
    local namespace=${3:-postgres}
    
    case $command in
        info)
            if [ -z "$date" ]; then
                log_error "请指定日期"
                show_usage
                exit 1
            fi
            show_incremental_info "$date" "$namespace"
            ;;
        list)
            if [ -z "$date" ]; then
                log_error "请指定日期"
                exit 1
            fi
            local minio_pod=$(kubectl get pods -l "app.kubernetes.io/name=minio" -n "$namespace" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
            get_incremental_chain "$date" "$namespace" "$minio_pod"
            ;;
        *)
            show_usage
            exit 0
            ;;
    esac
}

main "$@"
