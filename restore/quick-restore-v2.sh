#!/bin/bash
set -Eeo pipefail

# =============================================================================
# Kubernetes PostgreSQL 快速还原脚本 v2.0 (简化版)
# =============================================================================
# 改进点:
# 1. 模块化设计，拆分为多个辅助脚本
# 2. 支持增量备份还原
# 3. 自动验证还原结果
# 4. 简化配置生成
# 5. 优化远程S3操作
# =============================================================================

VERSION="2.0.0"

# 脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载辅助模块
source_if_exists() {
    [ -f "$1" ] && source "$1"
}

# 默认配置
DEFAULT_NAMESPACE="postgres"
DEFAULT_STATEFULSET_NAME="postgres"
DEFAULT_JOB_FILE="${SCRIPT_DIR}/postgres-restore-job.yaml"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 全局变量
NAMESPACE=""
STATEFULSET_NAME=""
BACKUP_DATE=""
FORCE_RESTORE="false"
LIST_ONLY="false"
VERIFY_AFTER_RESTORE="true"
INCLUDE_INCREMENTAL="false"
S3_BUCKET="backups"
BACKUP_PREFIX="postgres"
REMOTE_S3_MODE="false"
S3_ENDPOINT_URL=""
S3_ACCESS_KEY=""
S3_SECRET_KEY=""

# 日志函数
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 显示横幅
show_banner() {
    cat << "EOF"
 ____           _                  __     ____  
|  _ \ ___  ___| |_ ___  _ __ ___  \ \   / /_ | 
| |_) / _ \/ __| __/ _ \| '__/ _ \  \ \ / / | | 
|  _ <  __/\__ \ || (_) | | |  __/   \ V /  | | 
|_| \_\___||___/\__\___/|_|  \___|    \_/   |_| 
                                      Simplified
EOF
    echo "Version: $VERSION"
    echo ""
}

# 检查依赖
check_dependencies() {
    log_info "检查依赖..."
    
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl未安装"
        exit 1
    fi
    
    if ! kubectl cluster-info &> /dev/null; then
        log_error "无法连接到Kubernetes集群"
        exit 1
    fi
    
    if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
        log_error "命名空间'$NAMESPACE'不存在"
        exit 1
    fi
    
    log_success "依赖检查通过"
}

# 使用S3辅助脚本列出远程备份
list_remote_backups() {
    log_info "列出远程S3备份..."
    
    # 使用s3-helper.sh
    if [ -f "$SCRIPT_DIR/s3-helper.sh" ]; then
        source "$SCRIPT_DIR/s3-helper.sh"
        
        # 安装mc
        install_mc || {
            log_error "无法安装mc客户端"
            exit 1
        }
        
        # 配置S3
        configure_s3 "$S3_ENDPOINT_URL" "$S3_ACCESS_KEY" "$S3_SECRET_KEY" || {
            log_error "S3配置失败"
            exit 1
        }
        
        # 列出备份
        local backups=$(list_backups "$S3_BUCKET" "$BACKUP_PREFIX")
        
        if [ -z "$backups" ]; then
            log_warning "未找到任何备份"
            return 0
        fi
        
        echo ""
        echo "可用备份列表:"
        echo "=============="
        local count=1
        echo "$backups" | while read -r backup; do
            echo "$count. $backup"
            count=$((count + 1))
        done
        echo ""
    else
        log_error "找不到s3-helper.sh脚本"
        exit 1
    fi
}

# 列出本地MinIO备份
list_local_backups() {
    log_info "列出本地MinIO备份..."
    
    local minio_pod=$(kubectl get pods -l "app.kubernetes.io/name=minio" \
        -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$minio_pod" ]; then
        log_warning "未找到MinIO Pod"
        return 1
    fi
    
    local backups=$(kubectl exec -n "$NAMESPACE" "$minio_pod" -- \
        mc ls "${S3_BUCKET}/${BACKUP_PREFIX}/files/" 2>/dev/null | \
        awk 'NF>=5{print $5}' | sed 's:/$::' | grep -E '^[0-9]{8}$' | sort -r)
    
    if [ -z "$backups" ]; then
        log_warning "未找到任何备份"
        return 0
    fi
    
    echo ""
    echo "可用备份列表:"
    echo "=============="
    local count=1
    for backup in $backups; do
        echo "$count. $backup"
        
        # 检查是否有增量备份
        if [ -f "$SCRIPT_DIR/restore-incremental.sh" ]; then
            local inc_count=$(kubectl exec -n "$NAMESPACE" "$minio_pod" -- \
                mc ls "${S3_BUCKET}/${BACKUP_PREFIX}/files/${backup}/incremental/" 2>/dev/null | \
                grep "postgres-incremental-" | wc -l | tr -d ' ')
            
            if [ "$inc_count" -gt 0 ]; then
                echo "   └─ 包含 ${inc_count} 个增量备份"
            fi
        fi
        
        count=$((count + 1))
    done
    echo ""
}

# 列出备份（统一入口）
list_backups() {
    if [ "$REMOTE_S3_MODE" = "true" ]; then
        list_remote_backups
    else
        list_local_backups
    fi
}

# 执行还原
perform_restore() {
    log_info "准备执行还原..."
    
    # 验证日期格式
    if ! [[ "$BACKUP_DATE" =~ ^[0-9]{8}$ ]]; then
        log_error "日期格式错误，应为YYYYMMDD"
        exit 1
    fi
    
    # 确认操作
    if [ "$FORCE_RESTORE" != "true" ]; then
        echo ""
        log_warning "即将执行数据库还原!"
        log_warning "这将覆盖现有数据"
        echo ""
        read -p "确认继续? (输入'yes'确认): " confirm
        if [ "$confirm" != "yes" ]; then
            log_info "已取消"
            exit 0
        fi
    fi
    
    # 检查是否有增量备份
    if [ "$INCLUDE_INCREMENTAL" = "true" ] && [ -f "$SCRIPT_DIR/restore-incremental.sh" ]; then
        log_info "检查增量备份链..."
        "$SCRIPT_DIR/restore-incremental.sh" info "$BACKUP_DATE" "$NAMESPACE"
    fi
    
    # 清理现有Job
    if kubectl get job postgres-restore -n "$NAMESPACE" &> /dev/null; then
        log_info "清理现有还原Job..."
        kubectl delete job postgres-restore -n "$NAMESPACE"
        sleep 5
    fi
    
    # 生成Job配置
    local temp_job="temp-restore-job-${BACKUP_DATE}.yaml"
    
    if [ -f "$SCRIPT_DIR/restore-config-builder.sh" ]; then
        source "$SCRIPT_DIR/restore-config-builder.sh"
        
        # 设置环境变量
        export BACKUP_DATE FORCE_RESTORE NAMESPACE
        export POSTGRES_STATEFULSET_NAME="$STATEFULSET_NAME"
        export S3_BUCKET BACKUP_PREFIX
        export REMOTE_S3_MODE S3_ENDPOINT_URL S3_ACCESS_KEY S3_SECRET_KEY
        
        build_restore_job_config "$DEFAULT_JOB_FILE" "$temp_job"
    else
        # 回退到简单替换
        sed "s/BACKUP_DATE: \"interactive\"/BACKUP_DATE: \"$BACKUP_DATE\"/" "$DEFAULT_JOB_FILE" > "$temp_job"
    fi
    
    # 应用Job
    log_info "部署还原Job..."
    kubectl apply -f "$temp_job"
    rm -f "$temp_job"
    
    log_success "还原Job已部署"
    
    # 监控执行
    monitor_job
    
    # 验证还原
    if [ "$VERIFY_AFTER_RESTORE" = "true" ]; then
        verify_restore
    fi
}

# 监控Job（简化版）
monitor_job() {
    log_info "监控Job执行..."
    
    local timeout=3600
    local elapsed=0
    
    while [ $elapsed -lt $timeout ]; do
        local status=$(kubectl get job postgres-restore -n "$NAMESPACE" \
            -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null)
        local failed=$(kubectl get job postgres-restore -n "$NAMESPACE" \
            -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null)
        
        if [ "$status" = "True" ]; then
            echo ""
            log_success "还原完成!"
            return 0
        elif [ "$failed" = "True" ]; then
            echo ""
            log_error "还原失败!"
            show_job_logs
            return 1
        fi
        
        echo -ne "\r已执行: ${elapsed}s"
        sleep 10
        elapsed=$((elapsed + 10))
    done
    
    echo ""
    log_error "还原超时"
    return 1
}

# 显示Job日志
show_job_logs() {
    local pod=$(kubectl get pods -l app.kubernetes.io/name=postgres-restore \
        -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -n "$pod" ]; then
        echo ""
        echo "=== Job日志 ==="
        kubectl logs -n "$NAMESPACE" "$pod" --tail=50
    fi
}

# 验证还原结果
verify_restore() {
    echo ""
    log_info "执行还原验证..."
    
    if [ -f "$SCRIPT_DIR/restore-verify.sh" ]; then
        "$SCRIPT_DIR/restore-verify.sh" "$NAMESPACE" "$STATEFULSET_NAME"
    else
        log_warning "找不到验证脚本，跳过自动验证"
        show_manual_verify_commands
    fi
}

# 显示手动验证命令
show_manual_verify_commands() {
    cat << EOF

手动验证命令:
============
1. 检查Pod状态:
   kubectl get pods -n $NAMESPACE

2. 验证数据库:
   kubectl exec -n $NAMESPACE statefulset/$STATEFULSET_NAME -- psql -U postgres -c '\l'

3. 查看日志:
   kubectl logs -n $NAMESPACE statefulset/$STATEFULSET_NAME --tail=100

EOF
}

# 显示帮助
show_help() {
    cat << EOF
PostgreSQL快速还原脚本 v${VERSION} (简化版)

用法:
    $0 [选项]

基本选项:
    -d, --date DATE           备份日期 (YYYYMMDD)
    -f, --force               强制还原，跳过确认
    -n, --namespace NS        命名空间 (默认: postgres)
    -s, --statefulset NAME    StatefulSet名称 (默认: postgres)
    -l, --list                列出可用备份
    -h, --help                显示帮助

增强功能:
    --no-verify               跳过还原后验证
    --with-incremental        包含增量备份还原
    --s3-bucket BUCKET        S3存储桶 (默认: backups)
    --backup-prefix PREFIX    备份前缀 (默认: postgres)

远程S3:
    --remote-s3               启用远程S3模式
    --s3-endpoint URL         S3端点URL
    --s3-access-key KEY       S3访问密钥
    --s3-secret-key KEY       S3私密密钥

示例:
    # 列出备份
    $0 -l
    
    # 还原指定日期
    $0 -d 20241218
    
    # 强制还原并包含增量备份
    $0 -d 20241218 -f --with-incremental
    
    # 从远程S3还原
    $0 -d 20241218 --remote-s3 \\
       --s3-endpoint https://s3.amazonaws.com \\
       --s3-access-key AKIAIOSFODNN7EXAMPLE \\
       --s3-secret-key wJalrXU...

依赖脚本:
    - restore-verify.sh         还原后验证
    - restore-incremental.sh    增量备份支持
    - s3-helper.sh             S3操作辅助
    - restore-config-builder.sh Job配置生成

EOF
}

# 解析参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--date) BACKUP_DATE="$2"; shift 2 ;;
            -f|--force) FORCE_RESTORE="true"; shift ;;
            -n|--namespace) NAMESPACE="$2"; shift 2 ;;
            -s|--statefulset) STATEFULSET_NAME="$2"; shift 2 ;;
            -l|--list) LIST_ONLY="true"; shift ;;
            --no-verify) VERIFY_AFTER_RESTORE="false"; shift ;;
            --with-incremental) INCLUDE_INCREMENTAL="true"; shift ;;
            --s3-bucket) S3_BUCKET="$2"; shift 2 ;;
            --backup-prefix) BACKUP_PREFIX="$2"; shift 2 ;;
            --remote-s3) REMOTE_S3_MODE="true"; shift ;;
            --s3-endpoint) S3_ENDPOINT_URL="$2"; shift 2 ;;
            --s3-access-key) S3_ACCESS_KEY="$2"; shift 2 ;;
            --s3-secret-key) S3_SECRET_KEY="$2"; shift 2 ;;
            -h|--help) show_help; exit 0 ;;
            *)
                log_error "未知选项: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# 主函数
main() {
    show_banner
    parse_args "$@"
    
    # 设置默认值
    NAMESPACE="${NAMESPACE:-$DEFAULT_NAMESPACE}"
    STATEFULSET_NAME="${STATEFULSET_NAME:-$DEFAULT_STATEFULSET_NAME}"
    
    # 检查依赖
    check_dependencies
    
    # 仅列出备份
    if [ "$LIST_ONLY" = "true" ]; then
        list_backups
        exit 0
    fi
    
    # 验证参数
    if [ -z "$BACKUP_DATE" ]; then
        log_error "请指定备份日期 (-d) 或使用 -l 查看可用备份"
        exit 1
    fi
    
    # 执行还原
    log_info "开始还原流程"
    log_info "命名空间: $NAMESPACE"
    log_info "StatefulSet: $STATEFULSET_NAME"
    log_info "备份日期: $BACKUP_DATE"
    echo ""
    
    perform_restore
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
