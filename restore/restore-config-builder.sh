#!/bin/bash
set -Eeo pipefail

# =============================================================================
# 还原Job配置生成器
# 用环境变量替换模板，简化配置生成
# =============================================================================

build_restore_job_config() {
    local template_file=$1
    local output_file=$2
    
    # 导出所有配置变量
    export BACKUP_DATE
    export FORCE_RESTORE
    export POSTGRES_STATEFULSET_NAME
    export POSTGRES_HOST
    export POSTGRES_PORT
    export POSTGRES_USER
    export KUBECTL_NAMESPACE
    export POSTGRES_POD_LABEL
    export MINIO_LABEL
    export POSTGRES_DATA_DIR
    export RESTORE_TEMP_DIR
    export POSTGRES_UID
    export POSTGRES_GID
    export POSTGRES_INIT_WAIT_TIME
    export POD_TERMINATION_TIMEOUT
    export POD_READY_TIMEOUT
    export S3_BUCKET
    export BACKUP_PREFIX
    export REMOTE_S3_MODE
    export S3_ENDPOINT_URL
    export S3_ACCESS_KEY
    export S3_SECRET_KEY
    
    # 使用envsubst替换模板
    if command -v envsubst &> /dev/null; then
        envsubst < "$template_file" > "$output_file"
    else
        # 回退到sed（保持向后兼容）
        sed "s/\${BACKUP_DATE}/$BACKUP_DATE/g" "$template_file" | \
        sed "s/\${FORCE_RESTORE}/$FORCE_RESTORE/g" | \
        sed "s/\${POSTGRES_STATEFULSET_NAME}/$POSTGRES_STATEFULSET_NAME/g" | \
        sed "s/\${POSTGRES_HOST}/$POSTGRES_HOST/g" | \
        sed "s/\${POSTGRES_PORT}/$POSTGRES_PORT/g" | \
        sed "s/\${POSTGRES_USER}/$POSTGRES_USER/g" | \
        sed "s/\${KUBECTL_NAMESPACE}/$KUBECTL_NAMESPACE/g" | \
        sed "s/\${POSTGRES_POD_LABEL}/$POSTGRES_POD_LABEL/g" | \
        sed "s/\${MINIO_LABEL}/$MINIO_LABEL/g" | \
        sed "s/\${POSTGRES_DATA_DIR}/$POSTGRES_DATA_DIR/g" | \
        sed "s/\${RESTORE_TEMP_DIR}/$RESTORE_TEMP_DIR/g" | \
        sed "s/\${POSTGRES_UID}/$POSTGRES_UID/g" | \
        sed "s/\${POSTGRES_GID}/$POSTGRES_GID/g" | \
        sed "s/\${POSTGRES_INIT_WAIT_TIME}/$POSTGRES_INIT_WAIT_TIME/g" | \
        sed "s/\${POD_TERMINATION_TIMEOUT}/$POD_TERMINATION_TIMEOUT/g" | \
        sed "s/\${POD_READY_TIMEOUT}/$POD_READY_TIMEOUT/g" | \
        sed "s/\${S3_BUCKET}/$S3_BUCKET/g" | \
        sed "s/\${BACKUP_PREFIX}/$BACKUP_PREFIX/g" | \
        sed "s/\${REMOTE_S3_MODE}/$REMOTE_S3_MODE/g" | \
        sed "s/\${S3_ENDPOINT_URL}/$S3_ENDPOINT_URL/g" | \
        sed "s/\${S3_ACCESS_KEY}/$S3_ACCESS_KEY/g" | \
        sed "s/\${S3_SECRET_KEY}/$S3_SECRET_KEY/g" > "$output_file"
    fi
}

# 如果直接执行此脚本
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ $# -lt 2 ]; then
        echo "用法: $0 <template_file> <output_file>"
        exit 1
    fi
    
    build_restore_job_config "$1" "$2"
fi
