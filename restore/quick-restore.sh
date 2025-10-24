#!/bin/bash
set -Eeo pipefail

# =============================================================================
# Kubernetes PostgreSQL 快速还原脚本
# =============================================================================
# 使用方法:
#   ./quick-restore.sh [选项]
#
# 选项:
#   -d, --date DATE        指定备份日期 (YYYYMMDD)
#   -f, --force            强制还原，跳过确认
#   -n, --namespace NAMESPACE  指定命名空间 (默认: postgres)
#   -l, --list             列出可用备份
#   -h, --help             显示帮助信息
#
# 示例:
#   ./quick-restore.sh -l                    # 列出可用备份
#   ./quick-restore.sh -d 20241218           # 还原指定日期备份
#   ./quick-restore.sh -d 20241218 -f        # 强制还原指定备份
# =============================================================================

# 脚本版本
VERSION="1.0.0"

# 脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 默认配置
DEFAULT_NAMESPACE="postgres"
DEFAULT_STATEFULSET_NAME="postgres"
DEFAULT_JOB_NAME="postgres-restore"
DEFAULT_JOB_FILE="${SCRIPT_DIR}/postgres-restore-job.yaml"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 全局变量
NAMESPACE=""
STATEFULSET_NAME=""
POSTGRES_HOST=""
POSTGRES_PORT=""
POSTGRES_USER=""
POSTGRES_POD_LABEL=""
MINIO_LABEL=""
POSTGRES_DATA_DIR=""
RESTORE_TEMP_DIR=""
POSTGRES_UID=""
POSTGRES_GID=""
POSTGRES_INIT_WAIT_TIME=""
POD_TERMINATION_TIMEOUT=""
POD_READY_TIMEOUT=""
BACKUP_DATE=""
FORCE_RESTORE="false"
LIST_ONLY="false"
JOB_NAME=""
JOB_FILE=""
S3_BUCKET="backups"
BACKUP_PREFIX="postgres"
AUTO_CREATE_MINIO="false"
STORAGE_CLASS=""
REMOTE_S3_MODE="false"
S3_ENDPOINT_URL=""
S3_ACCESS_KEY=""
S3_SECRET_KEY=""

# 显示帮助信息
show_help() {
    cat << EOF
Kubernetes PostgreSQL 快速还原脚本 v${VERSION}

使用方法:
    $0 [选项]

选项:
    -d, --date DATE            指定备份日期 (YYYYMMDD格式)
    -f, --force                强制还原，跳过确认提示
    -n, --namespace NAMESPACE  指定命名空间 (默认: ${DEFAULT_NAMESPACE})
    -s, --statefulset NAME     指定PostgreSQL StatefulSet名称 (默认: postgres)
    -H, --host HOST            指定PostgreSQL主机地址 (默认: postgres)
    -p, --port PORT            指定PostgreSQL端口 (默认: 5432)
    -u, --user USER            指定PostgreSQL用户名 (默认: postgres)
    -l, --list                 仅列出可用备份，不执行还原
    -h, --help                 显示此帮助信息

高级选项:
    --pod-label LABEL          指定PostgreSQL Pod标签 (默认: app.kubernetes.io/name=postgres)
    --minio-label LABEL        指定MinIO Pod标签 (默认: app.kubernetes.io/name=minio)
    --data-dir DIR             指定PostgreSQL数据目录 (默认: /data)
    --temp-dir DIR             指定临时还原目录 (默认: /tmp/restore_data)
    --uid UID                  指定PostgreSQL用户ID (默认: 999)
    --gid GID                  指定PostgreSQL组ID (默认: 999)
    --init-wait SECONDS        PostgreSQL初始化等待时间 (默认: 30)
    --termination-timeout TIME Pod终止超时时间 (默认: 300s)
    --ready-timeout TIME       Pod就绪超时时间 (默认: 600s)
    --s3-bucket BUCKET         指定S3存储桶名称 (默认: backups)
    --backup-prefix PREFIX     指定备份文件前缀 (默认: postgres)
    --auto-create-minio        自动创建MinIO部署 (如果不存在)
    --storage-class CLASS      指定存储类 (默认: standard)

远程S3选项:
    --remote-s3               启用远程S3模式 (跳过本地MinIO检查)
    --s3-endpoint URL         指定S3端点URL (如: https://s3.amazonaws.com)
    --s3-access-key KEY       指定S3访问密钥ID (必需)
    --s3-secret-key KEY       指定S3访问密钥Secret (必需)

示例:
    $0 -l                                    # 列出可用备份
    $0 -d 20241218                           # 还原指定日期备份
    $0 -d 20241218 -f                        # 强制还原指定备份
    $0 -n production -d 20241218             # 在指定命名空间还原
    $0 -s postgres-prod -d 20241218          # 指定StatefulSet名称还原
    $0 -H postgres-db -p 5433 -d 20241218    # 指定主机和端口还原
    $0 --pod-label app=database -d 20241218  # 使用自定义Pod标签还原
    $0 --uid 1000 --gid 1000 -d 20241218     # 使用自定义用户/组ID还原

远程S3还原示例 (使用MinIO Client兼容所有S3存储):
    # AWS S3
    $0 -l --remote-s3 --s3-endpoint https://s3.amazonaws.com --s3-access-key AKIAIOSFODNN7EXAMPLE --s3-secret-key wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY --s3-bucket my-backups

    # 阿里云OSS
    $0 -l --remote-s3 --s3-endpoint https://oss-cn-hangzhou.aliyuncs.com --s3-access-key LTAI5txxxxxx --s3-secret-key xxxxxxxxxx --s3-bucket aliyun-backups

    # 腾讯云COS
    $0 -l --remote-s3 --s3-endpoint https://cos.ap-beijing.myqcloud.com --s3-access-key AKIDxxxxxx --s3-secret-key xxxxxxxxx --s3-bucket tencent-backups

    # 还原指定日期备份
    $0 -d 20241218 --remote-s3 --s3-endpoint https://s3.amazonaws.com --s3-access-key AKIAIOSFODNN7EXAMPLE --s3-secret-key wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY --s3-bucket production-backups

注意事项:
    1. 确保kubectl已正确配置且可访问目标集群
    2. 确保有足够的权限操作StatefulSet和Job
    3. 还原操作会覆盖现有数据，请谨慎操作
    4. 建议在执行还原前备份当前数据

EOF
}

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 显示横幅
show_banner() {
    cat << "EOF"
 ____  _                          _     _____                      _
/ ___|| |_ _ __ ___  __ _ _ __   __| |   | ____|_  ____ _ _ __ ___| |
\___ \| __| '__/ _ \/ _` | '_ \ / _` |   |  _| \ \/ / _` | '__/ _ \ |
 ___) | |_| | |  __/ (_| | | | | (_| |   | |___ >  < (_| | | |  __/ |
|____/ \__|_|  \___|\__,_|_| |_|\__,_|   |_____/_/\_\__,_|_|  \___|_|
                                                                    RESTORE
EOF
}

# 检查依赖
check_dependencies() {
    log_info "检查依赖..."

    # 检查kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl 未安装或不在PATH中"
        exit 1
    fi

    # 检查集群连接
    if ! kubectl cluster-info &> /dev/null; then
        log_error "无法连接到Kubernetes集群"
        exit 1
    fi

    # 检查命名空间
    if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
        log_error "命名空间 '$NAMESPACE' 不存在"
        exit 1
    fi

    # 检查Job文件
    if [ ! -f "$JOB_FILE" ]; then
        log_error "Job配置文件 '$JOB_FILE' 不存在"
        exit 1
    fi

    log_success "依赖检查通过"
}

# 检查环境状态
check_environment() {
    log_info "检查环境状态..."

    # 检查PostgreSQL StatefulSet
    if kubectl get statefulset "$STATEFULSET_NAME" -n "$NAMESPACE" &> /dev/null; then
        local replicas=$(kubectl get statefulset "$STATEFULSET_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')
        log_info "PostgreSQL StatefulSet '$STATEFULSET_NAME' 状态: $replicas 个副本"

        # 检查Pod状态 - 使用StatefulSet的Pod命名模式查找
        local ready_pods=$(kubectl get pods -n "$NAMESPACE" --field-selector=status.phase=Running --no-headers | grep "${STATEFULSET_NAME}-" | wc -l)
        log_info "运行中的 PostgreSQL Pod: $ready_pods 个"
    else
        log_warning "PostgreSQL StatefulSet '$STATEFULSET_NAME' 未找到"
    fi

    # 检查MinIO (远程S3模式下跳过)
    if [ "$REMOTE_S3_MODE" = "true" ]; then
        log_info "远程S3模式: 跳过本地MinIO检查"
        log_info "S3端点: ${S3_ENDPOINT_URL:-未指定}"
        log_info "S3存储桶: $S3_BUCKET"
        log_info "S3区域: ${S3_REGION:-default}"
    else
        if kubectl get deployment -l "$MINIO_LABEL" -n "$NAMESPACE" &> /dev/null; then
            local minio_deployment=$(kubectl get deployment -l "$MINIO_LABEL" -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
            local minio_status=$(kubectl get deployment "$minio_deployment" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
            log_info "MinIO Deployment 状态: ${minio_status:-0} 个就绪副本"
        else
            log_warning "MinIO Deployment 未找到，可使用 --auto-create-minio 自动创建"
        fi
    fi

    # 检查存储
    local pvc_count=$(kubectl get pvc -n "$NAMESPACE" --no-headers | wc -l)
    log_info "PVC 数量: $pvc_count 个"

    log_success "环境状态检查完成"
}

# 自动创建MinIO部署
create_minio_deployment() {
    log_info "开始自动创建MinIO部署..."

    # 创建临时配置文件
    local temp_secret_file="temp-minio-secret-${NAMESPACE}.yaml"
    local temp_deployment_file="temp-minio-deployment-${NAMESPACE}.yaml"

    # 生成Secret配置
    sed "s/\${NAMESPACE}/$NAMESPACE/g" minio-secret.yaml > "$temp_secret_file"

    # 生成部署配置
    sed "s/\${NAMESPACE}/$NAMESPACE/g" minio-auto-deployment.yaml | \
    sed "s/\${STORAGE_CLASS:-standard}/$STORAGE_CLASS/g" > "$temp_deployment_file"

    log_info "创建MinIO Secret..."
    kubectl apply -f "$temp_secret_file"

    log_info "创建MinIO PVC和Deployment..."
    kubectl apply -f "$temp_deployment_file"

    # 清理临时文件
    rm -f "$temp_secret_file" "$temp_deployment_file"

    log_info "等待MinIO部署完成..."
    local max_wait=300  # 5分钟超时
    local wait_time=0

    while [ $wait_time -lt $max_wait ]; do
        local minio_pod=$(kubectl get pods -l "$MINIO_LABEL" -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

        if [ -n "$minio_pod" ]; then
            local pod_status=$(kubectl get pod "$minio_pod" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)
            if [ "$pod_status" = "Running" ]; then
                local ready_status=$(kubectl get pod "$minio_pod" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)
                if [ "$ready_status" = "true" ]; then
                    log_success "MinIO部署创建成功并已就绪"

                    # 创建存储桶
                    log_info "创建备份存储桶..."
                    sleep 10  # 等待MinIO完全启动
                    kubectl exec -n "$NAMESPACE" "$minio_pod" -- mc alias set local http://localhost:9000 minioadmin minioadmin >/dev/null 2>&1
                    kubectl exec -n "$NAMESPACE" "$minio_pod" -- mc mb local/${S3_BUCKET} >/dev/null 2>&1 || true
                    kubectl exec -n "$NAMESPACE" "$minio_pod" -- mc mb local/${S3_BUCKET}/${BACKUP_PREFIX} >/dev/null 2>&1 || true
                    kubectl exec -n "$NAMESPACE" "$minio_pod" -- mc mb local/${S3_BUCKET}/${BACKUP_PREFIX}/files >/dev/null 2>&1 || true

                    log_success "MinIO存储桶创建完成"
                    return 0
                fi
            fi
        fi

        echo -n "."
        sleep 5
        wait_time=$((wait_time + 5))
    done

    echo ""
    log_error "MinIO部署超时，请手动检查"
    return 1
}

# 列出远程S3备份
list_remote_s3_backups() {
    log_info "获取远程S3可用备份列表..."

    # 检查必要参数
    if [ -z "$S3_ENDPOINT_URL" ]; then
        log_error "远程S3模式需要指定 --s3-endpoint 参数"
        exit 1
    fi

    # 检查认证方式 (mc仅支持Access Key方式)
    if [ -z "$S3_ACCESS_KEY" ] || [ -z "$S3_SECRET_KEY" ]; then
        log_error "MinIO Client (mc) 需要提供 Access Key 和 Secret Key"
        log_error "请使用 --s3-access-key 和 --s3-secret-key 参数"
        exit 1
    fi
    log_info "使用MinIO Client (mc) 和 Access Key认证方式"

    # 创建临时脚本文件
    local temp_s3_script="temp-s3-ls-${NAMESPACE}.sh"
    local temp_mc_dir="temp-mc-${NAMESPACE}"

    # 创建临时目录
    mkdir -p "$temp_mc_dir"

    # 创建S3列表脚本
    cat > "$temp_s3_script" << EOF
#!/bin/bash
set -Eeo pipefail

# 设置临时mc路径
MC_CMD="$temp_mc_dir/mc"

# 下载并安装MinIO Client到临时目录
if [ ! -f "\$MC_CMD" ]; then
    echo "Downloading MinIO Client to temporary directory..." >&2
    curl https://dl.min.io/client/mc/release/linux-amd64/mc -o "\$MC_CMD" >&2
    chmod +x "\$MC_CMD"
fi

# 配置MinIO Client
if [ -n "$S3_ENDPOINT_URL" ]; then
    MC_ENDPOINT="$S3_ENDPOINT_URL"
else
    echo "Error: S3 endpoint URL is required for mc"
    exit 1
fi

# 设置别名
ALIAS_NAME="remote_storage"

# 移除已存在的别名
mc alias remove \$ALIAS_NAME 2>/dev/null || true

# 添加新的S3兼容存储别名
mc alias set \$ALIAS_NAME "\$MC_ENDPOINT" "$S3_ACCESS_KEY" "$S3_SECRET_KEY" 2>/dev/null

if [ \$? -ne 0 ]; then
    echo "Failed to configure MinIO client with provided credentials" >&2
    exit 1
fi

# 列出备份 (只输出备份目录名)
\$MC_CMD ls \$ALIAS_NAME/$S3_BUCKET/$BACKUP_PREFIX/files/ 2>/dev/null | awk 'NF>=5{print $5}' | sed 's:/$::' | grep -E '^[0-9]{8}$' | sort -r
EOF

    chmod +x "$temp_s3_script"

    # 导出变量给子脚本使用
    export S3_ACCESS_KEY S3_SECRET_KEY S3_ENDPOINT_URL S3_BUCKET BACKUP_PREFIX

    # 执行S3列表并捕获输出
    echo "执行远程备份列表查询..."
    local backups=$("./$temp_s3_script" 2>&1)
    local exit_code=$?

    # 显示调试信息
    echo "脚本输出: $backups"
    echo "脚本退出码: $exit_code"

    # 如果脚本执行失败
    if [ $exit_code -ne 0 ]; then
        log_error "远程S3查询失败，错误信息:"
        echo "$backups"
        # 清理临时文件和目录
        rm -f "$temp_s3_script"
        rm -rf "$temp_mc_dir"
        exit 1
    fi

    # 过滤出有效的备份日期
    # 只保留8位数字格式的日期
    local valid_backups=$(echo "$backups" | grep -E '^[0-9]{8}$' | sort -r)

    echo "过滤后的备份列表: $valid_backups"

    if [ -z "$valid_backups" ]; then
        log_warning "未找到任何远程备份文件"
        echo "调试信息: 原始输出: $backups"
        # 清理临时文件和目录
        rm -f "$temp_s3_script"
        rm -rf "$temp_mc_dir"
        exit 0
    fi

    echo ""
    echo "可用远程备份列表:"
    echo "=================="

    local count=1
    for backup in $valid_backups; do
        echo "$count. $backup"
        count=$((count + 1))
    done

    echo ""
    log_info "从远程S3获取了 $(($count - 1)) 个备份"

    # 清理临时文件和目录
    rm -f "$temp_s3_script"
    rm -rf "$temp_mc_dir"
}

# 列出可用备份
list_backups() {
    log_info "获取可用备份列表..."

    # 检查是否为远程S3模式
    if [ "$REMOTE_S3_MODE" = "true" ]; then
        list_remote_s3_backups
        return 0
    fi

    # 获取MinIO Pod
    local minio_pod=$(kubectl get pods -l "$MINIO_LABEL" -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [ -z "$minio_pod" ]; then
        log_warning "未找到MinIO Pod"

        if [ "$AUTO_CREATE_MINIO" = "true" ]; then
            log_info "启用自动创建MinIO部署..."
            if create_minio_deployment; then
                # 重新获取MinIO Pod
                minio_pod=$(kubectl get pods -l "$MINIO_LABEL" -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
                if [ -z "$minio_pod" ]; then
                    log_error "MinIO部署创建后仍无法找到Pod"
                    exit 1
                fi
                log_success "MinIO Pod创建成功: $minio_pod"
            else
                log_error "MinIO自动部署失败"
                exit 1
            fi
        else
            log_error "未找到MinIO Pod，请使用 --auto-create-minio 选项自动创建，或手动部署MinIO"
            exit 1
        fi
    fi

    # 获取备份列表
    local backups=$(kubectl exec -n "$NAMESPACE" "$minio_pod" -- mc ls ${S3_BUCKET:-backups}/${BACKUP_PREFIX:-postgres}/files/ 2>/dev/null | awk 'NF>=5{print $5}' | sed 's:/$::' | sed '/^$/d' | sort -r)

    if [ -z "$backups" ]; then
        log_warning "未找到任何备份文件"
        exit 0
    fi

    echo ""
    echo "可用备份列表:"
    echo "=============="

    local count=1
    for backup in $backups; do
        echo "$count. $backup"
        count=$((count + 1))
    done

    echo ""

    # 显示最新备份的详细信息
    local latest_backup=$(echo "$backups" | head -n 1)
    if [ -n "$latest_backup" ]; then
        log_info "最新备份: $latest_backup"

        # 显示备份文件详情
        local backup_files=$(kubectl exec -n "$NAMESPACE" "$minio_pod" -- mc ls ${S3_BUCKET:-backups}/${BACKUP_PREFIX:-postgres}/files/"$latest_backup"/ 2>/dev/null)
        if [ -n "$backup_files" ]; then
            echo "备份文件:"
            echo "$backup_files" | while read -r line; do
                echo "  - $line"
            done
        fi
    fi
}

# 执行还原
perform_restore() {
    log_info "准备执行数据库还原..."

    # 验证备份日期格式
    if ! [[ "$BACKUP_DATE" =~ ^[0-9]{8}$ ]]; then
        log_error "备份日期格式错误，应为 YYYYMMDD 格式"
        exit 1
    fi

    # 确认还原操作
    if [ "$FORCE_RESTORE" != "true" ]; then
        echo ""
        log_warning "即将执行数据库还原操作!"
        log_warning "这将覆盖现有的PostgreSQL数据"
        echo ""
        read -p "确认继续还原? (输入 'yes' 确认): " confirm
        if [ "$confirm" != "yes" ]; then
            log_info "还原操作已取消"
            exit 0
        fi
    fi

    # 清理现有的还原Job
    if kubectl get job "$JOB_NAME" -n "$NAMESPACE" &> /dev/null; then
        log_info "清理现有的还原Job..."
        kubectl delete job "$JOB_NAME" -n "$NAMESPACE"
        sleep 5
    fi

    # 创建临时的Job配置
    local temp_job_file="temp-${JOB_NAME}.yaml"
    log_info "创建还原Job配置..."

    # 根据参数修改Job配置
    sed "s/BACKUP_DATE: \"interactive\"/BACKUP_DATE: \"$BACKUP_DATE\"/" "$JOB_FILE" | \
    sed "s/FORCE_RESTORE: \"false\"/FORCE_RESTORE: \"$FORCE_RESTORE\"/" | \
    sed "s/POSTGRES_STATEFULSET_NAME: \"postgres\"/POSTGRES_STATEFULSET_NAME: \"$STATEFULSET_NAME\"/" | \
    sed "s/POSTGRES_HOST: \"postgres\"/POSTGRES_HOST: \"$POSTGRES_HOST\"/" | \
    sed "s/POSTGRES_PORT: \"5432\"/POSTGRES_PORT: \"$POSTGRES_PORT\"/" | \
    sed "s/POSTGRES_USER: \"postgres\"/POSTGRES_USER: \"$POSTGRES_USER\"/" | \
    sed "s/KUBECTL_NAMESPACE: \"postgres\"/KUBECTL_NAMESPACE: \"$NAMESPACE\"/" | \
    sed "s/POSTGRES_POD_LABEL: \"app.kubernetes.io\/name=postgres\"/POSTGRES_POD_LABEL: \"$POSTGRES_POD_LABEL\"/" | \
    sed "s/MINIO_LABEL: \"app.kubernetes.io\/name=minio\"/MINIO_LABEL: \"$MINIO_LABEL\"/" | \
    sed "s/POSTGRES_DATA_DIR: \"\/data\"/POSTGRES_DATA_DIR: \"$POSTGRES_DATA_DIR\"/" | \
    sed "s/RESTORE_TEMP_DIR: \"\/tmp\/restore_data\"/RESTORE_TEMP_DIR: \"$RESTORE_TEMP_DIR\"/" | \
    sed "s/POSTGRES_UID: \"999\"/POSTGRES_UID: \"$POSTGRES_UID\"/" | \
    sed "s/POSTGRES_GID: \"999\"/POSTGRES_GID: \"$POSTGRES_GID\"/" | \
    sed "s/POSTGRES_INIT_WAIT_TIME: \"30\"/POSTGRES_INIT_WAIT_TIME: \"$POSTGRES_INIT_WAIT_TIME\"/" | \
    sed "s/POD_TERMINATION_TIMEOUT: \"300s\"/POD_TERMINATION_TIMEOUT: \"$POD_TERMINATION_TIMEOUT\"/" | \
    sed "s/POD_READY_TIMEOUT: \"600s\"/POD_READY_TIMEOUT: \"$POD_READY_TIMEOUT\"/" | \
    sed "s/S3_BUCKET: \"backups\"/S3_BUCKET: \"$S3_BUCKET\"/" | \
    sed "s/BACKUP_PREFIX: \"postgres\"/BACKUP_PREFIX: \"$BACKUP_PREFIX\"/" | \
    sed "s/REMOTE_S3_MODE: \"false\"/REMOTE_S3_MODE: \"$REMOTE_S3_MODE\"/" | \
    sed "s/S3_ENDPOINT_URL: \"\"/S3_ENDPOINT_URL: \"$S3_ENDPOINT_URL\"/" | \
    sed "s/S3_ACCESS_KEY: \"\"/S3_ACCESS_KEY: \"$S3_ACCESS_KEY\"/" | \
    sed "s/S3_SECRET_KEY: \"\"/S3_SECRET_KEY: \"$S3_SECRET_KEY\"/" > "$temp_job_file"

    # 部署还原Job
    log_info "部署还原Job..."
    kubectl apply -f "$temp_job_file"

    # 清理临时文件
    rm -f "$temp_job_file"

    log_success "还原Job已部署，开始监控执行状态..."

    # 监控Job执行
    monitor_restore_job
}

# 监控还原Job
monitor_restore_job() {
    log_info "监控还原Job执行状态..."

    local job_start_time=$(date +%s)
    local timeout_duration=3600  # 1小时超时

    while true; do
        local current_time=$(date +%s)
        local elapsed_time=$((current_time - job_start_time))

        # 检查超时
        if [ $elapsed_time -gt $timeout_duration ]; then
            log_error "还原Job执行超时"
            break
        fi

        # 获取Job状态
        local job_status=$(kubectl get job "$JOB_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null)
        local job_failed=$(kubectl get job "$JOB_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null)
        local job_active=$(kubectl get job "$JOB_NAME" -n "$NAMESPACE" -o jsonpath='{.status.active}' 2>/dev/null)

        # 显示进度
        echo -ne "\r已执行时间: ${elapsed_time}s | 状态: "

        if [ "$job_status" = "True" ]; then
            echo -e "${GREEN}完成${NC}"
            log_success "还原Job执行完成!"
            show_restore_completion
            break
        elif [ "$job_failed" = "True" ]; then
            echo -e "${RED}失败${NC}"
            log_error "还原Job执行失败!"
            show_job_logs
            break
        elif [ "$job_active" = "1" ]; then
            echo -e "${YELLOW}执行中${NC}"
        else
            echo -e "${BLUE}准备中${NC}"
        fi

        sleep 10
    done
}

# 显示Job日志
show_job_logs() {
    log_info "显示Job执行日志..."

    local pod_name=$(kubectl get pods -l app.kubernetes.io/name=postgres-restore -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [ -n "$pod_name" ]; then
        echo ""
        echo "=== Job日志 ==="
        kubectl logs -n "$NAMESPACE" "$pod_name" --tail=50
        echo ""
    fi
}

# 显示还原完成信息
show_restore_completion() {
    echo ""
    log_success "数据库还原操作已完成!"
    echo ""
    echo "后续操作建议:"
    echo "1. 检查PostgreSQL Pod状态:"
    echo "   kubectl get pods -n $NAMESPACE | grep ${STATEFULSET_NAME}-"
    echo ""
    echo "2. 查看PostgreSQL日志:"
    echo "   kubectl logs -n $NAMESPACE statefulset/$STATEFULSET_NAME --tail=100"
    echo ""
    echo "3. 验证数据库连接:"
    echo "   kubectl exec -it -n $NAMESPACE statefulset/$STATEFULSET_NAME -- psql -U postgres -c 'SELECT version();'"
    echo ""
    echo "4. 检查数据完整性:"
    echo "   kubectl exec -it -n $NAMESPACE statefulset/$STATEFULSET_NAME -- psql -U postgres -c '\\l'"
    echo ""
    echo "5. 监控系统资源:"
    echo "   kubectl top pods -n $NAMESPACE"
    echo ""
}

# 清理函数
cleanup() {
    # 清理临时文件
    rm -f temp-*.yaml 2>/dev/null || true
}

# 主函数
main() {
    # 设置清理陷阱
    trap cleanup EXIT

    # 显示横幅
    show_banner

    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--date)
                BACKUP_DATE="$2"
                shift 2
                ;;
            -f|--force)
                FORCE_RESTORE="true"
                shift
                ;;
            -n|--namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            -s|--statefulset)
                STATEFULSET_NAME="$2"
                shift 2
                ;;
            -H|--host)
                POSTGRES_HOST="$2"
                shift 2
                ;;
            -p|--port)
                POSTGRES_PORT="$2"
                shift 2
                ;;
            -u|--user)
                POSTGRES_USER="$2"
                shift 2
                ;;
            -l|--list)
                LIST_ONLY="true"
                shift
                ;;
            --pod-label)
                POSTGRES_POD_LABEL="$2"
                shift 2
                ;;
            --minio-label)
                MINIO_LABEL="$2"
                shift 2
                ;;
            --data-dir)
                POSTGRES_DATA_DIR="$2"
                shift 2
                ;;
            --temp-dir)
                RESTORE_TEMP_DIR="$2"
                shift 2
                ;;
            --uid)
                POSTGRES_UID="$2"
                shift 2
                ;;
            --gid)
                POSTGRES_GID="$2"
                shift 2
                ;;
            --init-wait)
                POSTGRES_INIT_WAIT_TIME="$2"
                shift 2
                ;;
            --termination-timeout)
                POD_TERMINATION_TIMEOUT="$2"
                shift 2
                ;;
            --ready-timeout)
                POD_READY_TIMEOUT="$2"
                shift 2
                ;;
            --s3-bucket)
                S3_BUCKET="$2"
                shift 2
                ;;
            --backup-prefix)
                BACKUP_PREFIX="$2"
                shift 2
                ;;
            --auto-create-minio)
                AUTO_CREATE_MINIO="true"
                shift
                ;;
            --storage-class)
                STORAGE_CLASS="$2"
                shift 2
                ;;
            --remote-s3)
                REMOTE_S3_MODE="true"
                shift
                ;;
            --s3-endpoint)
                S3_ENDPOINT_URL="$2"
                shift 2
                ;;
            --s3-access-key)
                S3_ACCESS_KEY="$2"
                shift 2
                ;;
            --s3-secret-key)
                S3_SECRET_KEY="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "未知选项: $1"
                show_help
                exit 1
                ;;
        esac
    done

    # 设置默认值
    NAMESPACE="${NAMESPACE:-$DEFAULT_NAMESPACE}"
    STATEFULSET_NAME="${STATEFULSET_NAME:-$DEFAULT_STATEFULSET_NAME}"
    POSTGRES_HOST="${POSTGRES_HOST:-postgres}"
    POSTGRES_PORT="${POSTGRES_PORT:-5432}"
    POSTGRES_USER="${POSTGRES_USER:-postgres}"
    POSTGRES_POD_LABEL="${POSTGRES_POD_LABEL:-app.kubernetes.io/name=postgres}"
    MINIO_LABEL="${MINIO_LABEL:-app.kubernetes.io/name=minio}"
    POSTGRES_DATA_DIR="${POSTGRES_DATA_DIR:-/data}"
    RESTORE_TEMP_DIR="${RESTORE_TEMP_DIR:-/tmp/restore_data}"
    POSTGRES_UID="${POSTGRES_UID:-999}"
    POSTGRES_GID="${POSTGRES_GID:-999}"
    POSTGRES_INIT_WAIT_TIME="${POSTGRES_INIT_WAIT_TIME:-30}"
    POD_TERMINATION_TIMEOUT="${POD_TERMINATION_TIMEOUT:-300s}"
    POD_READY_TIMEOUT="${POD_READY_TIMEOUT:-600s}"
    JOB_NAME="${DEFAULT_JOB_NAME}"
    JOB_FILE="$DEFAULT_JOB_FILE"

    # 验证参数
    if [ "$LIST_ONLY" = "true" ]; then
        # 仅列出备份
        check_dependencies
        check_environment
        list_backups
        exit 0
    fi

    if [ -z "$BACKUP_DATE" ]; then
        log_error "请指定备份日期 (-d) 或使用 -l 查看可用备份"
        show_help
        exit 1
    fi

    # 执行还原流程
    log_info "开始Kubernetes PostgreSQL还原流程"
    log_info "命名空间: $NAMESPACE"
    log_info "StatefulSet名称: $STATEFULSET_NAME"
    log_info "PostgreSQL主机: $POSTGRES_HOST"
    log_info "PostgreSQL端口: $POSTGRES_PORT"
    log_info "PostgreSQL用户: $POSTGRES_USER"
    log_info "Pod标签: $POSTGRES_POD_LABEL"
    log_info "备份日期: $BACKUP_DATE"
    log_info "强制还原: $FORCE_RESTORE"
    echo ""

    check_dependencies
    check_environment
    perform_restore
}

# 脚本入口点
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi