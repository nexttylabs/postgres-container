#!/usr/bin/env bash

# 检查必要的环境变量
required_vars=(
    "POSTGRES_USER"
    "POSTGRES_PASSWORD"
    "POSTGRES_HOST"
    "POSTGRES_PORT"
    "BACKUP_DIR"
    "FULL_BACKUP_INTERVAL"
)

for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo "Error: Required environment variable $var is not set"
        exit 1
    fi
done

# 如果启用了S3存储，检查S3相关的环境变量
if [ "${STORAGE_TYPE}" = "s3" ]; then
    s3_vars=(
        "S3_BUCKET"
        "S3_ENDPOINT"
        "S3_ACCESS_KEY"
        "S3_SECRET_KEY"
    )
    
    for var in "${s3_vars[@]}"; do
        if [ -z "${!var}" ]; then
            echo "Error: S3 storage is enabled but $var is not set"
            exit 1
        fi
    done
fi

# 设置PostgreSQL端口
export PGPORT="${POSTGRES_PORT}"

# 验证备份目录权限
if [ ! -d "${BACKUP_DIR}" ]; then
    mkdir -p "${BACKUP_DIR}"
fi

if [ ! -w "${BACKUP_DIR}" ] || [ ! -x "${BACKUP_DIR}" ]; then
    echo "Error: BACKUP_DIR is not writable or accessible"
    exit 1
fi

# 验证全量备份间隔是否为有效数字
if ! [[ "$FULL_BACKUP_INTERVAL" =~ ^[0-9]+$ ]]; then
    echo "Error: FULL_BACKUP_INTERVAL must be a positive integer"
    exit 1
fi
