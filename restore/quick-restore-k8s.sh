#!/bin/bash
set -Eeo pipefail

# =============================================================================
# Kubernetes 原生 PostgreSQL 还原脚本
# =============================================================================
# 设计理念: 零本地依赖，所有操作在 Kubernetes 集群中执行
# 
# 本地仅需:
# - kubectl (必需)
# - bash (系统自带)
# 
# 所有重型操作(下载、解压、验证)都在 Kubernetes Pod 中完成
# =============================================================================

VERSION="2.1.0-k8s"

# 脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 默认配置
DEFAULT_NAMESPACE="postgres"
DEFAULT_STATEFULSET_NAME="postgres"
RESTORE_JOB_NAME="postgres-restore-$(date +%s)"
RESTORE_IMAGE="bitnami/postgresql:16"

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
S3_BUCKET="backups"
BACKUP_PREFIX="postgres"
MINIO_LABEL="app.kubernetes.io/name=minio"
POSTGRES_POD_LABEL="app.kubernetes.io/name=postgres"
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
 _  _____ ____   ____            _                  
| |/ ( _ ) ___|  |  _ \ ___  ___| |_ ___  _ __ ___ 
| ' // _ \\___ \  | |_) / _ \/ __| __/ _ \| '__/ _ \
| . \ (_) |__) | |  _ <  __/\__ \ || (_) | | |  __/
|_|\_\___/____/  |_| \_\___||___/\__\___/|_|  \___|
                                     Kubernetes Native
EOF
    echo "Version: $VERSION - 零本地依赖"
    echo ""
}

# 检查依赖（仅检查kubectl）
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
    
    log_success "依赖检查通过 (仅需kubectl)"
}

# 在 MinIO Pod 中列出备份
list_backups_in_pod() {
    log_info "在 MinIO Pod 中列出备份..."
    
    local minio_pod=$(kubectl get pods -l "$MINIO_LABEL" \
        -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$minio_pod" ]; then
        log_error "未找到 MinIO Pod"
        return 1
    fi
    
    log_info "MinIO Pod: $minio_pod"
    
    # 在 Pod 中执行列表命令
    local backups=$(kubectl exec -n "$NAMESPACE" "$minio_pod" -- \
        mc ls "${S3_BUCKET}/${BACKUP_PREFIX}/" 2>/dev/null | \
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
        
        # 检查是否有增量备份（在 Pod 中）
        local inc_count=$(kubectl exec -n "$NAMESPACE" "$minio_pod" -- \
            mc ls "${S3_BUCKET}/${BACKUP_PREFIX}/${backup}/incremental/" 2>/dev/null | \
            grep -c "postgres-incremental-" || echo 0)
        
        if [ "$inc_count" -gt 0 ]; then
            echo "   └─ 包含 ${inc_count} 个增量备份"
        fi
        
        count=$((count + 1))
    done
    echo ""
}

# 使用远程 S3 列出备份（在临时 Pod 中）
list_remote_s3_backups_in_pod() {
    log_info "在 Kubernetes Pod 中列出远程 S3 备份..."
    
    # 创建临时 Pod 执行 S3 列表操作
    local temp_pod="s3-list-$(date +%s)"
    
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${temp_pod}
  namespace: ${NAMESPACE}
spec:
  restartPolicy: Never
  containers:
  - name: s3-client
    image: alpine:latest
    command: ['/bin/sh', '-c']
    args:
    - |
      set -e
      # 安装必要工具（静默安装）
      apk add --no-cache wget grep sed gawk coreutils ca-certificates > /dev/null 2>&1
      
      # 检测架构并下载对应的 mc
      ARCH=\$(uname -m)
      case \$ARCH in
        x86_64) MC_ARCH="amd64" ;;
        aarch64|arm64) MC_ARCH="arm64" ;;
        *) exit 1 ;;
      esac
      
      # 下载 mc 客户端（静默）
      wget -q https://dl.min.io/client/mc/release/linux-\${MC_ARCH}/mc -O /usr/local/bin/mc 2>&1
      chmod +x /usr/local/bin/mc
      
      # 验证 mc 可执行
      /usr/local/bin/mc --version > /dev/null 2>&1 || exit 1
      
      # 保持容器运行
      sleep 300
    env:
    - name: S3_ENDPOINT
      value: "${S3_ENDPOINT_URL}"
    - name: S3_ACCESS_KEY
      value: "${S3_ACCESS_KEY}"
    - name: S3_SECRET_KEY
      value: "${S3_SECRET_KEY}"
    - name: S3_BUCKET
      value: "${S3_BUCKET}"
    - name: BACKUP_PREFIX
      value: "${BACKUP_PREFIX}"
EOF
    
    # 等待 Pod 就绪
    log_info "等待 S3 客户端 Pod 就绪（安装工具中...）"
    if ! kubectl wait --for=condition=ready pod/"${temp_pod}" \
        -n "${NAMESPACE}" --timeout=120s 2>/dev/null; then
        log_error "Pod 启动超时或失败"
        echo ""
        echo "Pod 日志："
        kubectl logs -n "${NAMESPACE}" "${temp_pod}" --tail=30 2>/dev/null || echo "无法获取日志"
        kubectl delete pod "${temp_pod}" -n "${NAMESPACE}" --wait=false 2>/dev/null
        return 1
    fi
    
    # 检查 Pod 状态
    local pod_phase=$(kubectl get pod "${temp_pod}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}')
    if [ "$pod_phase" = "Failed" ]; then
        log_error "Pod 启动失败"
        echo ""
        echo "Pod 日志："
        kubectl logs -n "${NAMESPACE}" "${temp_pod}" --tail=30 2>/dev/null || echo "无法获取日志"
        kubectl delete pod "${temp_pod}" -n "${NAMESPACE}" --wait=false 2>/dev/null
        return 1
    fi
    
    # 等待工具安装完成（给足够时间下载和验证 mc）
    log_info "等待工具安装完成..."
    sleep 15
    
    # 配置 S3 并列出备份
    local backups=$(kubectl exec -n "${NAMESPACE}" "${temp_pod}" -- sh -c '
        mc alias set remote "$S3_ENDPOINT" "$S3_ACCESS_KEY" "$S3_SECRET_KEY" --api S3v4 > /dev/null 2>&1
        mc ls remote/$S3_BUCKET/$BACKUP_PREFIX/ 2>/dev/null | awk "NF>=5{print \$5}" | sed "s:/$::" | grep -E "^[0-9]{8}$" | sort -r
    ' 2>&1)
    
    local exec_status=$?
    
    # 清理临时 Pod
    kubectl delete pod "${temp_pod}" -n "${NAMESPACE}" --wait=false 2>/dev/null
    
    # 检查执行是否成功
    if [ $exec_status -ne 0 ]; then
        log_error "执行 S3 列表命令失败"
        echo "错误输出: $backups"
        return 1
    fi
    
    # 显示结果
    if [ -z "$backups" ]; then
        log_warning "未找到任何备份"
        return 0
    fi
    
    echo ""
    echo "可用备份列表:"
    echo "=============="
    
    local count=1
    echo "$backups" | while read -r backup; do
        [ -n "$backup" ] && echo "$count. $backup"
        count=$((count + 1))
    done
    echo ""
}

# 统一列出备份入口
list_backups() {
    if [ "$REMOTE_S3_MODE" = "true" ]; then
        list_remote_s3_backups_in_pod
    else
        list_backups_in_pod
    fi
}

# 创建还原 Job（所有操作在 Pod 中完成）
create_restore_job() {
    local backup_date=$1
    
    log_info "创建还原 Job: $RESTORE_JOB_NAME"
    
    # 准备 S3 配置
    local s3_config=""
    if [ "$REMOTE_S3_MODE" = "true" ]; then
        s3_config=$(cat <<-END
        - name: REMOTE_S3_MODE
          value: "true"
        - name: S3_ENDPOINT_URL
          value: "${S3_ENDPOINT_URL}"
        - name: S3_ACCESS_KEY
          value: "${S3_ACCESS_KEY}"
        - name: S3_SECRET_KEY
          value: "${S3_SECRET_KEY}"
END
)
    else
        s3_config=$(cat <<-END
        - name: REMOTE_S3_MODE
          value: "false"
        - name: MINIO_LABEL
          value: "${MINIO_LABEL}"
END
)
    fi
    
    # 创建 Job
    cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${RESTORE_JOB_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: postgres-restore
    app.kubernetes.io/component: restore
spec:
  ttlSecondsAfterFinished: 3600
  backoffLimit: 2
  template:
    metadata:
      labels:
        app.kubernetes.io/name: postgres-restore
    spec:
      restartPolicy: Never
      serviceAccountName: postgres-restore
      containers:
      - name: restore
        image: ${RESTORE_IMAGE}
        env:
        - name: BACKUP_DATE
          value: "${backup_date}"
        - name: POSTGRES_STATEFULSET_NAME
          value: "${STATEFULSET_NAME}"
        - name: KUBECTL_NAMESPACE
          value: "${NAMESPACE}"
        - name: POSTGRES_POD_LABEL
          value: "${POSTGRES_POD_LABEL}"
        - name: S3_BUCKET
          value: "${S3_BUCKET}"
        - name: BACKUP_PREFIX
          value: "${BACKUP_PREFIX}"
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: postgres-secret
              key: postgres-password
${s3_config}
        command:
        - /bin/bash
        - -c
        - |
          set -Eeo pipefail
          
          echo "========================================="
          echo "PostgreSQL 还原任务（Kubernetes 原生）"
          echo "========================================="
          echo "备份日期: \${BACKUP_DATE}"
          echo "命名空间: \${KUBECTL_NAMESPACE}"
          echo "StatefulSet: \${POSTGRES_STATEFULSET_NAME}"
          echo "========================================="
          
          # 安装必要工具（仅在容器内）
          echo "安装工具..."
          apt-get update -qq
          apt-get install -y -qq kubectl curl zstd > /dev/null
          
          # 如果是远程 S3 模式，安装 mc
          if [ "\${REMOTE_S3_MODE}" = "true" ]; then
            echo "安装 MinIO Client..."
            curl -sSL https://dl.min.io/client/mc/release/linux-amd64/mc -o /usr/local/bin/mc
            chmod +x /usr/local/bin/mc
            
            # 配置远程 S3
            mc alias set remote "\${S3_ENDPOINT_URL}" "\${S3_ACCESS_KEY}" "\${S3_SECRET_KEY}" --api S3v4
            S3_ALIAS="remote"
          else
            # 获取 MinIO Pod
            MINIO_POD=\$(kubectl get pods -l "\${MINIO_LABEL}" -n "\${KUBECTL_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}')
            echo "MinIO Pod: \$MINIO_POD"
          fi
          
          # 检查备份存在性
          echo "检查备份: \${BACKUP_DATE}"
          BACKUP_PATH="\${S3_BUCKET}/\${BACKUP_PREFIX}/\${BACKUP_DATE}"
          
          if [ "\${REMOTE_S3_MODE}" = "true" ]; then
            mc ls "\${S3_ALIAS}/\${BACKUP_PATH}/" > /dev/null || {
              echo "错误: 备份不存在"
              exit 1
            }
          else
            kubectl exec -n "\${KUBECTL_NAMESPACE}" "\$MINIO_POD" -- \
              mc ls "\${BACKUP_PATH}/" > /dev/null || {
              echo "错误: 备份不存在"
              exit 1
            }
          fi
          
          echo "备份验证通过"
          
          # 停止 PostgreSQL
          echo "停止 PostgreSQL StatefulSet..."
          kubectl scale statefulset "\${POSTGRES_STATEFULSET_NAME}" \
            -n "\${KUBECTL_NAMESPACE}" --replicas=0
          
          # 等待 Pod 终止
          echo "等待 Pod 终止..."
          kubectl wait --for=delete pod \
            -l "\${POSTGRES_POD_LABEL}" \
            -n "\${KUBECTL_NAMESPACE}" \
            --timeout=300s || true
          
          # 下载并解压备份（在容器内）
          echo "下载备份到容器..."
          RESTORE_DIR="/tmp/restore"
          rm -rf "\${RESTORE_DIR}"
          mkdir -p "\${RESTORE_DIR}"
          
          # 获取全量备份文件名
          if [ "\${REMOTE_S3_MODE}" = "true" ]; then
            FULL_BACKUP=\$(mc ls "\${S3_ALIAS}/\${BACKUP_PATH}/" | grep "postgres-full-" | awk '{print \$5}' | head -n1)
            
            echo "下载: \$FULL_BACKUP"
            mc cp "\${S3_ALIAS}/\${BACKUP_PATH}/\${FULL_BACKUP}" "\${RESTORE_DIR}/\${FULL_BACKUP}"
          else
            FULL_BACKUP=\$(kubectl exec -n "\${KUBECTL_NAMESPACE}" "\$MINIO_POD" -- \
              mc ls "\${BACKUP_PATH}/" | grep "postgres-full-" | awk '{print \$5}' | head -n1)
            
            echo "下载: \$FULL_BACKUP"
            kubectl exec -n "\${KUBECTL_NAMESPACE}" "\$MINIO_POD" -- \
              mc cat "\${BACKUP_PATH}/\${FULL_BACKUP}" > "\${RESTORE_DIR}/\${FULL_BACKUP}"
          fi
          
          # 解压
          echo "解压备份..."
          cd "\${RESTORE_DIR}"
          zstd -d "\${FULL_BACKUP}" -o backup.tar
          tar -xf backup.tar
          
          BACKUP_DIR=\$(find . -maxdepth 1 -type d -name "postgres-full-*" | head -n1)
          echo "备份已解压: \$BACKUP_DIR"
          
          # 获取 PVC
          echo "获取 PostgreSQL PVC..."
          PVC_NAME=\$(kubectl get pvc -n "\${KUBECTL_NAMESPACE}" \
            -l "\${POSTGRES_POD_LABEL}" \
            -o jsonpath='{.items[0].metadata.name}')
          
          echo "PVC: \$PVC_NAME"
          
          # 创建临时 Pod 复制数据
          echo "创建数据复制 Pod..."
          cat <<EEOF | kubectl apply -f -
          apiVersion: v1
          kind: Pod
          metadata:
            name: postgres-restore-copy
            namespace: \${KUBECTL_NAMESPACE}
          spec:
            restartPolicy: Never
            containers:
            - name: copy
              image: busybox
              command: ['sleep', '3600']
              volumeMounts:
              - name: data
                mountPath: /data
            volumes:
            - name: data
              persistentVolumeClaim:
                claimName: \${PVC_NAME}
EEOF
          
          # 等待 Pod 就绪
          kubectl wait --for=condition=ready pod/postgres-restore-copy \
            -n "\${KUBECTL_NAMESPACE}" --timeout=60s
          
          # 清空并复制数据
          echo "清空现有数据..."
          kubectl exec -n "\${KUBECTL_NAMESPACE}" postgres-restore-copy -- \
            sh -c "rm -rf /data/*"
          
          echo "复制还原数据..."
          kubectl cp "\${RESTORE_DIR}/\${BACKUP_DIR}/." \
            "\${KUBECTL_NAMESPACE}/postgres-restore-copy:/data/"
          
          # 设置权限
          echo "设置权限..."
          kubectl exec -n "\${KUBECTL_NAMESPACE}" postgres-restore-copy -- \
            sh -c "chmod 700 /data && chown -R 999:999 /data"
          
          # 清理临时 Pod
          kubectl delete pod postgres-restore-copy -n "\${KUBECTL_NAMESPACE}"
          
          # 启动 PostgreSQL
          echo "启动 PostgreSQL..."
          kubectl scale statefulset "\${POSTGRES_STATEFULSET_NAME}" \
            -n "\${KUBECTL_NAMESPACE}" --replicas=1
          
          # 等待就绪
          echo "等待 PostgreSQL 就绪..."
          kubectl wait --for=condition=ready pod \
            -l "\${POSTGRES_POD_LABEL}" \
            -n "\${KUBECTL_NAMESPACE}" \
            --timeout=600s
          
          # 验证
          echo "验证 PostgreSQL..."
          sleep 30
          kubectl exec -n "\${KUBECTL_NAMESPACE}" \
            statefulset/"\${POSTGRES_STATEFULSET_NAME}" -- \
            pg_isready -U postgres
          
          echo "========================================="
          echo "还原成功完成！"
          echo "========================================="
          
          # 清理临时文件
          rm -rf "\${RESTORE_DIR}"
          
        resources:
          requests:
            memory: "512Mi"
            cpu: "200m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
EOF
    
    log_success "还原 Job 已创建"
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
        log_warning "所有操作将在 Kubernetes 集群中完成"
        log_warning "这将覆盖现有数据"
        echo ""
        read -p "确认继续? (输入'yes'确认): " confirm
        if [ "$confirm" != "yes" ]; then
            log_info "已取消"
            exit 0
        fi
    fi
    
    # 清理旧 Job
    if kubectl get job "$RESTORE_JOB_NAME" -n "$NAMESPACE" &> /dev/null; then
        log_info "清理现有 Job..."
        kubectl delete job "$RESTORE_JOB_NAME" -n "$NAMESPACE"
        sleep 5
    fi
    
    # 创建 Job
    create_restore_job "$BACKUP_DATE"
    
    # 监控执行
    monitor_job
    
    # 验证
    if [ "$VERIFY_AFTER_RESTORE" = "true" ]; then
        verify_restore
    fi
}

# 监控 Job
monitor_job() {
    log_info "监控 Job 执行..."
    
    local timeout=3600
    local elapsed=0
    
    while [ $elapsed -lt $timeout ]; do
        local status=$(kubectl get job "$RESTORE_JOB_NAME" -n "$NAMESPACE" \
            -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null)
        local failed=$(kubectl get job "$RESTORE_JOB_NAME" -n "$NAMESPACE" \
            -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null)
        
        if [ "$status" = "True" ]; then
            echo ""
            log_success "还原完成!"
            show_job_logs
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

# 显示 Job 日志
show_job_logs() {
    local pod=$(kubectl get pods -l app.kubernetes.io/name=postgres-restore \
        -n "$NAMESPACE" --field-selector=status.phase!=Pending \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -n "$pod" ]; then
        echo ""
        echo "=== Job 日志（最后50行） ==="
        kubectl logs -n "$NAMESPACE" "$pod" --tail=50
    fi
}

# 验证还原
verify_restore() {
    echo ""
    log_info "执行还原验证..."
    
    if [ -f "$SCRIPT_DIR/restore-verify.sh" ]; then
        "$SCRIPT_DIR/restore-verify.sh" "$NAMESPACE" "$STATEFULSET_NAME"
    else
        log_warning "验证脚本不存在，跳过"
    fi
}

# 显示帮助
show_help() {
    cat << EOF
Kubernetes 原生 PostgreSQL 还原脚本 v${VERSION}

零本地依赖 - 所有操作在 Kubernetes 集群中执行

用法:
    $0 [选项]

基本选项:
    -d, --date DATE           备份日期 (YYYYMMDD)
    -f, --force               强制还原，跳过确认
    -n, --namespace NS        命名空间 (默认: postgres)
    -s, --statefulset NAME    StatefulSet名称 (默认: postgres)
    -l, --list                列出可用备份
    -h, --help                显示帮助

远程S3选项:
    --remote-s3               启用远程S3模式
    --s3-endpoint URL         S3端点URL
    --s3-access-key KEY       S3访问密钥
    --s3-secret-key KEY       S3私密密钥
    --s3-bucket BUCKET        S3存储桶 (默认: backups)
    --backup-prefix PREFIX    备份文件前缀 (默认: postgres)

高级选项:
    --no-verify               跳过还原后验证
    --image IMAGE             还原容器镜像 (默认: bitnami/postgresql:16)

特性:
    ✅ 零本地依赖（仅需kubectl）
    ✅ 所有操作在 Kubernetes 集群中完成
    ✅ 不污染本地环境
    ✅ 支持远程S3
    ✅ 自动验证

示例:
    # 列出备份（在 MinIO Pod 中执行）
    $0 -l -n postgres
    
    # 还原指定日期（所有操作在集群中）
    $0 -d 20241218 -n postgres
    
    # 从远程S3还原（在临时Pod中执行）
    $0 -d 20241218 --remote-s3 \\
       --s3-endpoint https://s3.amazonaws.com \\
       --s3-access-key AKIAIO... \\
       --s3-secret-key wJalrXU... \\
       --s3-bucket my-backups \\
       --backup-prefix batsystem
    
    # Cloudflare R2 示例
    $0 -l -n batsystem --remote-s3 \\
       --s3-endpoint https://xxx.r2.cloudflarestorage.com \\
       --s3-access-key xxx \\
       --s3-secret-key xxx \\
       --s3-bucket backup \\
       --backup-prefix batsystem

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
            --s3-bucket) S3_BUCKET="$2"; shift 2 ;;
            --remote-s3) REMOTE_S3_MODE="true"; shift ;;
            --s3-endpoint) S3_ENDPOINT_URL="$2"; shift 2 ;;
            --s3-access-key) S3_ACCESS_KEY="$2"; shift 2 ;;
            --s3-secret-key) S3_SECRET_KEY="$2"; shift 2 ;;
            --backup-prefix) BACKUP_PREFIX="$2"; shift 2 ;;
            --image) RESTORE_IMAGE="$2"; shift 2 ;;
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
    log_info "开始还原流程（Kubernetes 原生模式）"
    log_info "命名空间: $NAMESPACE"
    log_info "StatefulSet: $STATEFULSET_NAME"
    log_info "备份日期: $BACKUP_DATE"
    log_info "本地依赖: 仅 kubectl ✓"
    echo ""
    
    perform_restore
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
