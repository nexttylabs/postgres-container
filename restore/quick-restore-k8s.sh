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
RESTORE_IMAGE="postgres:17"

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
INCREMENTAL_BACKUP=""
APPLY_INCREMENTALS="false"
LIST_INCREMENTALS="false"
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
JOB_CREATED="false"

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

# 清理 Job
cleanup_job() {
    if [ "$JOB_CREATED" = "true" ]; then
        log_info "清理还原 Job..."
        kubectl delete job "$RESTORE_JOB_NAME" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
        JOB_CREATED="false"
    fi
}

trap cleanup_job EXIT

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

# 列出指定日期的增量备份
list_incremental_backups() {
    local backup_date=$1
    
    if [ -z "$backup_date" ]; then
        log_error "必须指定备份日期 (-d 参数)"
        exit 1
    fi
    
    log_info "列出 ${backup_date} 的增量备份..."
    
    if [ "$REMOTE_S3_MODE" = "true" ]; then
        # 远程 S3 模式 - 创建临时 Pod
        local temp_pod="s3-list-inc-$(date +%s)"
        
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
      apk add --no-cache wget grep sed gawk coreutils ca-certificates > /dev/null 2>&1
      ARCH=\$(uname -m)
      case \$ARCH in
        x86_64) MC_ARCH="amd64" ;;
        aarch64|arm64) MC_ARCH="arm64" ;;
        *) exit 1 ;;
      esac
      wget -q https://dl.min.io/client/mc/release/linux-\${MC_ARCH}/mc -O /usr/local/bin/mc 2>&1
      chmod +x /usr/local/bin/mc
      /usr/local/bin/mc --version > /dev/null 2>&1 || exit 1
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
    - name: BACKUP_DATE
      value: "${backup_date}"
EOF
        
        log_info "等待 S3 客户端 Pod 就绪..."
        if ! kubectl wait --for=condition=ready pod/"${temp_pod}" \
            -n "${NAMESPACE}" --timeout=120s 2>/dev/null; then
            kubectl delete pod "${temp_pod}" -n "${NAMESPACE}" --wait=false 2>/dev/null
            log_error "Pod 启动失败"
            return 1
        fi
        
        sleep 10
        
        local incrementals=$(kubectl exec -n "${NAMESPACE}" "${temp_pod}" -- sh -c '
            mc alias set remote "$S3_ENDPOINT" "$S3_ACCESS_KEY" "$S3_SECRET_KEY" --api S3v4 > /dev/null 2>&1
            mc ls remote/$S3_BUCKET/$BACKUP_PREFIX/$BACKUP_DATE/incremental/ 2>/dev/null | awk "NF>=5{print \$5, \$NF}" | grep -E "incremental.*\.tar\.zst"
        ' 2>&1)
        
        kubectl delete pod "${temp_pod}" -n "${NAMESPACE}" --wait=false 2>/dev/null
        
    else
        # 本地 MinIO 模式
        local minio_pod=$(kubectl get pods -l "$MINIO_LABEL" \
            -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}')
        
        if [ -z "$minio_pod" ]; then
            log_error "未找到 MinIO Pod"
            return 1
        fi
        
        local incrementals=$(kubectl exec -n "$NAMESPACE" "$minio_pod" -- \
            mc ls "${S3_BUCKET}/${BACKUP_PREFIX}/${backup_date}/incremental/" 2>/dev/null | \
            awk 'NF>=5{print $5, $NF}' | grep -E "incremental.*\.tar\.zst")
    fi
    
    if [ -z "$incrementals" ]; then
        log_warning "未找到增量备份"
        echo ""
        echo "提示: 增量备份路径应为: ${S3_BUCKET}/${BACKUP_PREFIX}/${backup_date}/incremental/"
        return 0
    fi
    
    echo ""
    echo "📦 增量备份列表 (日期: ${backup_date})"
    echo "==========================================="
    echo ""
    
    local count=1
    echo "$incrementals" | while read -r size filename; do
        if [ -n "$filename" ]; then
            # 提取时间戳
            local timestamp=$(echo "$filename" | grep -oE "[0-9]{8}-[0-9]{6}")
            echo "$count. $filename"
            if [ -n "$timestamp" ]; then
                echo "   时间: ${timestamp:0:4}-${timestamp:4:2}-${timestamp:6:2} ${timestamp:9:2}:${timestamp:11:2}:${timestamp:13:2}"
            fi
            if [ -n "$size" ]; then
                echo "   大小: $size"
            fi
            echo ""
            count=$((count + 1))
        fi
    done
    
    echo "==========================================="
    echo "总计: $(echo "$incrementals" | grep -c "incremental") 个增量备份"
    echo ""
}

# 创建还原 Job（所有操作在 Pod 中完成）
create_restore_job() {
    local backup_date=$1
    
    log_info "创建还原 Job: $RESTORE_JOB_NAME"
    
    log_info "解析 PostgreSQL PVC..."
    local pvc_name=""
    pvc_name=$(kubectl get pvc -n "$NAMESPACE" -l "$POSTGRES_POD_LABEL" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    
    if [ -z "$pvc_name" ]; then
        local volume_name=""
        volume_name=$(kubectl get statefulset "$STATEFULSET_NAME" -n "$NAMESPACE" \
            -o jsonpath='{.spec.volumeClaimTemplates[0].metadata.name}' 2>/dev/null || true)
        
        if [ -z "$volume_name" ]; then
            volume_name="data"
        fi
        
        pvc_name="${volume_name}-${STATEFULSET_NAME}-0"
        
        if ! kubectl get pvc "$pvc_name" -n "$NAMESPACE" >/dev/null 2>&1; then
            log_error "找不到 PVC $pvc_name"
            log_info "可用的 PVC 列表:"
            kubectl get pvc -n "$NAMESPACE"
            exit 1
        fi
    fi
    
    log_info "使用 PVC: $pvc_name"
    
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
        - name: INCREMENTAL_BACKUP
          value: "${INCREMENTAL_BACKUP}"
        - name: APPLY_INCREMENTALS
          value: "${APPLY_INCREMENTALS}"
        - name: PVC_NAME
          value: "${pvc_name}"
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
          echo "PVC: \${PVC_NAME}"
          echo "========================================="
          
          # 安装必要工具（仅在容器内）
          echo "安装工具..."
          apt-get update -qq
          apt-get install -y -qq kubectl curl zstd > /dev/null
          
          # 如果是远程 S3 模式，安装 mc
          if [ "\${REMOTE_S3_MODE}" = "true" ]; then
            echo "安装 MinIO Client..."
            ARCH=\$(uname -m)
            case \$ARCH in
              x86_64) MC_ARCH="amd64" ;;
              aarch64|arm64) MC_ARCH="arm64" ;;
              *) echo "ERROR: Unsupported architecture: \$ARCH"; exit 1 ;;
            esac
            echo "架构: \$ARCH, 下载 mc for linux-\${MC_ARCH}"
            curl -sSL https://dl.min.io/client/mc/release/linux-\${MC_ARCH}/mc -o /usr/local/bin/mc
            chmod +x /usr/local/bin/mc
            
            mc alias set remote "\${S3_ENDPOINT_URL}" "\${S3_ACCESS_KEY}" "\${S3_SECRET_KEY}" --api S3v4
            S3_ALIAS="remote"
          else
            MINIO_POD=\$(kubectl get pods -l "\${MINIO_LABEL}" -n "\${KUBECTL_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}')
            echo "MinIO Pod: \$MINIO_POD"
          fi
          
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
          
          echo "停止 PostgreSQL StatefulSet..."
          kubectl scale statefulset "\${POSTGRES_STATEFULSET_NAME}" \
            -n "\${KUBECTL_NAMESPACE}" --replicas=0
          
          echo "等待 Pod 终止..."
          kubectl wait --for=delete pod \
            -l "\${POSTGRES_POD_LABEL}" \
            -n "\${KUBECTL_NAMESPACE}" \
            --timeout=300s || true
          
          echo "准备还原工作目录..."
          RESTORE_WORK_DIR="/tmp/restore"
          TARGET_DIR="/restore/target"
          rm -rf "\${RESTORE_WORK_DIR}"
          mkdir -p "\${RESTORE_WORK_DIR}"
          mkdir -p "\${TARGET_DIR}"
          
          if [ "\${REMOTE_S3_MODE}" = "true" ]; then
            FULL_BACKUP=\$(mc ls "\${S3_ALIAS}/\${BACKUP_PATH}/" | grep "full-.*\\.tar\\.zst" | awk '{print \$NF}' | head -n1)
            
            if [ -z "\$FULL_BACKUP" ]; then
              echo "错误: 未找到全量备份文件"
              mc ls "\${S3_ALIAS}/\${BACKUP_PATH}/"
              exit 1
            fi
            
            echo "下载: \$FULL_BACKUP"
            mc cat "\${S3_ALIAS}/\${BACKUP_PATH}/\${FULL_BACKUP}" | zstd -dc --threads=0 | tar -xC "\${RESTORE_WORK_DIR}"
          else
            FULL_BACKUP=\$(kubectl exec -n "\${KUBECTL_NAMESPACE}" "\$MINIO_POD" -- \
              mc ls "\${BACKUP_PATH}/" | grep "full-.*\\.tar\\.zst" | awk '{print \$NF}' | head -n1)
            
            if [ -z "\$FULL_BACKUP" ]; then
              echo "错误: 未找到全量备份文件"
              kubectl exec -n "\${KUBECTL_NAMESPACE}" "\$MINIO_POD" -- mc ls "\${BACKUP_PATH}/"
              exit 1
            fi
            
            echo "下载: \$FULL_BACKUP"
            kubectl exec -n "\${KUBECTL_NAMESPACE}" "\$MINIO_POD" -- \
              mc cat "\${BACKUP_PATH}/\${FULL_BACKUP}" | zstd -dc --threads=0 | tar -xC "\${RESTORE_WORK_DIR}"
          fi
          
          BACKUP_DIR=\$(find "\${RESTORE_WORK_DIR}" -mindepth 1 -maxdepth 1 -type d -name "*-full-*" | head -n1)
          if [ -z "\${BACKUP_DIR}" ]; then
            echo "错误: 未找到解压后的备份目录"
            ls -la "\${RESTORE_WORK_DIR}"
            exit 1
          fi
          echo "全量备份目录: \${BACKUP_DIR}"
          
          declare -a COMBINE_DIRS
          COMBINE_DIRS=( "\${BACKUP_DIR}" )
          
          if [ -n "\${INCREMENTAL_BACKUP}" ] || [ "\${APPLY_INCREMENTALS}" = "true" ]; then
            echo ""
            echo "========================================="
            echo "应用增量备份"
            echo "========================================="
            
            INCREMENTAL_PATH="\${BACKUP_PATH}/incremental"
            INCREMENTALS_TO_APPLY=""
            
            if [ "\${APPLY_INCREMENTALS}" = "true" ]; then
              echo "获取所有增量备份列表..."
              if [ "\${REMOTE_S3_MODE}" = "true" ]; then
                INCREMENTALS_TO_APPLY=\$(mc ls "\${S3_ALIAS}/\${INCREMENTAL_PATH}/" 2>/dev/null | \
                  grep "incremental.*\\.tar\\.zst" | awk '{print \$NF}' | sort)
              else
                INCREMENTALS_TO_APPLY=\$(kubectl exec -n "\${KUBECTL_NAMESPACE}" "\$MINIO_POD" -- \
                  mc ls "\${INCREMENTAL_PATH}/" 2>/dev/null | \
                  grep "incremental.*\\.tar\\.zst" | awk '{print \$NF}' | sort)
              fi
            else
              INCREMENTALS_TO_APPLY="\${INCREMENTAL_BACKUP}"
            fi
            
            if [ -z "\${INCREMENTALS_TO_APPLY}" ]; then
              echo "警告: 未找到增量备份"
            else
              echo "将按以下顺序应用增量备份:"
              printf '%s\n' "\${INCREMENTALS_TO_APPLY}" | nl
              echo "========================================="
              echo ""
              
              idx=1
              while IFS= read -r inc_backup; do
                [ -z "\${inc_backup}" ] && continue
                echo "处理增量备份: \${inc_backup}"
                
                INC_WORK_DIR="\${RESTORE_WORK_DIR}/incremental_\${idx}"
                mkdir -p "\${INC_WORK_DIR}"
                
                if [ "\${REMOTE_S3_MODE}" = "true" ]; then
                  mc cat "\${S3_ALIAS}/\${INCREMENTAL_PATH}/\${inc_backup}" | zstd -dc --threads=0 | tar -xC "\${INC_WORK_DIR}"
                else
                  kubectl exec -n "\${KUBECTL_NAMESPACE}" "\$MINIO_POD" -- \
                    mc cat "\${INCREMENTAL_PATH}/\${inc_backup}" | zstd -dc --threads=0 | tar -xC "\${INC_WORK_DIR}"
                fi
                
                INC_DIR=\$(find "\${INC_WORK_DIR}" -mindepth 1 -maxdepth 1 -type d | head -n1)
                if [ -z "\${INC_DIR}" ]; then
                  echo "错误: 找不到增量备份目录"
                  exit 1
                fi
                
                COMBINE_DIRS+=( "\${INC_DIR}" )
                echo "✓ 增量备份 \${inc_backup} 已准备"
                idx=\$((idx + 1))
              done <<< "\${INCREMENTALS_TO_APPLY}"
              
              echo "========================================="
              echo "所有增量备份准备完成"
              echo "========================================="
              echo ""
            fi
          fi
          
          echo "清空目标数据目录..."
          rm -rf "\${TARGET_DIR:?}/"*
          
          if ! command -v pg_combinebackup >/dev/null 2>&1; then
            echo "错误: 找不到 pg_combinebackup"
            exit 1
          fi
          
          echo "使用 pg_combinebackup 合并备份..."
          pg_combinebackup -o "\${TARGET_DIR}" "\${COMBINE_DIRS[@]}"
          
          sync
          chmod 700 "\${TARGET_DIR}" || true
          chown -R 999:999 "\${TARGET_DIR}" || true
          
          echo "恢复数据已写入 PVC"
          
          rm -rf "\${RESTORE_WORK_DIR}"
          
          echo "启动 PostgreSQL..."
          kubectl scale statefulset "\${POSTGRES_STATEFULSET_NAME}" \
            -n "\${KUBECTL_NAMESPACE}" --replicas=1
          
          echo "等待 PostgreSQL 就绪..."
          if ! kubectl rollout status statefulset/"\${POSTGRES_STATEFULSET_NAME}" \
            -n "\${KUBECTL_NAMESPACE}" --timeout=600s; then
            log_warning "StatefulSet 未在超时时间内完成，改为等待 Pod 就绪"
            kubectl wait --for=condition=ready pod \
              -l "\${POSTGRES_POD_LABEL}" \
              -n "\${KUBECTL_NAMESPACE}" \
              --timeout=300s || true
          fi
          
          echo "验证 PostgreSQL..."
          sleep 30
          kubectl exec -n "\${KUBECTL_NAMESPACE}" \
            statefulset/"\${POSTGRES_STATEFULSET_NAME}" -- \
            pg_isready -U postgres
          
          echo "========================================="
          echo "还原成功完成！"
          echo "========================================="
        volumeMounts:
        - name: postgres-data
          mountPath: /restore/target
        resources:
          requests:
            memory: "512Mi"
            cpu: "200m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
      volumes:
      - name: postgres-data
        persistentVolumeClaim:
          claimName: ${pvc_name}
EOF

    log_success "还原 Job 已创建"
    JOB_CREATED="true"
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

增量备份选项:
    --list-incrementals       列出指定日期的增量备份
    --incremental FILE        指定要应用的增量备份文件名
    --apply-all-incrementals  自动应用该日期下的所有增量备份

远程S3选项:
    --remote-s3               启用远程S3模式
    --s3-endpoint URL         S3端点URL
    --s3-access-key KEY       S3访问密钥
    --s3-secret-key KEY       S3私密密钥
    --s3-bucket BUCKET        S3存储桶 (默认: backups)
    --backup-prefix PREFIX    备份文件前缀 (默认: postgres)

高级选项:
    --no-verify               跳过还原后验证
    --image IMAGE             还原容器镜像 (默认: postgres:17)

特性:
    ✅ 零本地依赖（仅需kubectl）
    ✅ 所有操作在 Kubernetes 集群中完成
    ✅ 不污染本地环境
    ✅ 支持远程S3
    ✅ 自动验证

示例:
    # 列出备份（在 MinIO Pod 中执行）
    $0 -l -n postgres
    
    # 列出指定日期的增量备份
    $0 -d 20241218 --list-incrementals -n postgres
    
    # 还原全量备份（所有操作在集群中）
    $0 -d 20241218 -n postgres
    
    # 还原全量 + 指定增量备份
    $0 -d 20241218 -n postgres \\
       --incremental postgres-incremental-20241218-120001.tar.zst
    
    # 还原全量 + 所有增量备份
    $0 -d 20241218 -n postgres --apply-all-incrementals
    
    # 从远程S3还原增量备份
    $0 -d 20251017 -n batsystem \\
       --remote-s3 \\
       --s3-endpoint https://xxx.r2.cloudflarestorage.com \\
       --s3-bucket backup \\
       --backup-prefix batsystem \\
       --s3-access-key xxx \\
       --s3-secret-key xxx \\
       --incremental batsystem-incremental-20251018-010001.tar.zst

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
            --list-incrementals) LIST_INCREMENTALS="true"; shift ;;
            --incremental) INCREMENTAL_BACKUP="$2"; shift 2 ;;
            --apply-all-incrementals) APPLY_INCREMENTALS="true"; shift ;;
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
    
    # 列出增量备份
    if [ "$LIST_INCREMENTALS" = "true" ]; then
        list_incremental_backups "$BACKUP_DATE"
        exit 0
    fi
    
    # 验证参数
    if [ -z "$BACKUP_DATE" ]; then
        log_error "请指定备份日期 (-d) 或使用 -l 查看可用备份"
        exit 1
    fi
    
    # 验证增量备份参数
    if [ -n "$INCREMENTAL_BACKUP" ] && [ "$APPLY_INCREMENTALS" = "true" ]; then
        log_error "不能同时使用 --incremental 和 --apply-all-incrementals"
        exit 1
    fi
    
    # 执行还原
    log_info "开始还原流程（Kubernetes 原生模式）"
    log_info "命名空间: $NAMESPACE"
    log_info "StatefulSet: $STATEFULSET_NAME"
    log_info "备份日期: $BACKUP_DATE"
    
    if [ -n "$INCREMENTAL_BACKUP" ]; then
        log_info "增量备份: $INCREMENTAL_BACKUP"
    elif [ "$APPLY_INCREMENTALS" = "true" ]; then
        log_info "增量备份: 应用所有增量备份"
    else
        log_info "增量备份: 否"
    fi
    
    log_info "本地依赖: 仅 kubectl ✓"
    echo ""
    
    perform_restore
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
