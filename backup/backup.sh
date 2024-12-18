#!/usr/bin/env bash
set -Eeo pipefail

if [ -n "$POSTGRES_PASSWORD" ]; then
    export PGPASSWORD="$POSTGRES_PASSWORD"
fi

# 加载环境变量
source "$(dirname "$0")/env.sh"

# 获取当前时间戳
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
TODAY=$(date +%Y%m%d)

# 创建必要的目录
mkdir -p "$BACKUP_DIR/manifest"
mkdir -p "$BACKUP_DIR/files"
BACKUP_FILES_DIR="$BACKUP_DIR/files"
LAST_TIMESTAMP_FILE="$BACKUP_DIR/manifest/last_timestamp"

# 检查PostgreSQL服务是否运行
check_postgres_running() {
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if pg_isready -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" >/dev/null 2>&1; then
            echo "PostgreSQL is running"
            return 0
        fi
        echo "Waiting for PostgreSQL to start... (attempt $attempt/$max_attempts)"
        sleep 1
        attempt=$((attempt + 1))
    done
    
    echo "PostgreSQL did not start within $max_attempts seconds"
    exit 1
}

# 检查是否需要执行全量备份
need_full_backup() {
    # 如果时间戳文件不存在，需要执行全量备份
    if [ ! -f "$LAST_TIMESTAMP_FILE" ]; then
        echo "No last full backup timestamp found, performing full backup..."
        return 0
    fi
    
    # 读取上次全量备份的时间戳
    local last_backup_date=$(cat "$LAST_TIMESTAMP_FILE")
    
    # 计算距离上次全量备份的天数
    local last_date_seconds=$(date -d "${last_backup_date}" +%s)
    local today_seconds=$(date -d "${TODAY}" +%s)
    local days_diff=$(( (today_seconds - last_date_seconds) / 86400 ))
    
    echo "Days since last full backup: $days_diff"
    
    # 如果超过配置的间隔天数，需要执行全量备份
    if [ "$days_diff" -ge "${FULL_BACKUP_INTERVAL}" ]; then
        echo "Last full backup is older than ${FULL_BACKUP_INTERVAL} days, performing full backup..."
        return 0
    fi
    
    return 1
}

# 验证备份函数
verify_backup() {
    local BACKUP_PATH=$1
    local BACKUP_TYPE=$2

    echo "Verifying $BACKUP_TYPE backup: $(basename $BACKUP_PATH)"

    pg_verifybackup \
        --manifest-path="$BACKUP_PATH/backup_manifest" \
        "$BACKUP_PATH"

    if [ $? -eq 0 ]; then
        echo "Backup verification successful"
        return 0
    else
        echo "Backup verification failed"
        return 1
    fi
}

# 执行全量备份
full_backup() {
    echo "Performing full backup..."
    local backup_name="${BACKUP_PREFIX}-full-${TIMESTAMP}"
    local backup_path="$BACKUP_FILES_DIR/$TODAY"
    # 使用pg_basebackup执行全量备份
    pg_basebackup \
        -h $POSTGRES_HOST \
        -U $POSTGRES_USER \
        -D "$backup_path/$backup_name" \
        -X stream \
        --manifest-checksums=sha256 \
        --manifest-force-encode \
        -v \
        -P \
        -l "full_backup_$TIMESTAMP"
    
    # 检查备份是否成功
    if [ $? -eq 0 ]; then
        cp "$backup_path/$backup_name/backup_manifest" "$BACKUP_DIR/manifest/last_manifest"
        verify_backup "$backup_path/$backup_name" "full"
        echo "Full backup completed successfully"
        cd $backup_path 
        tar cf - "$backup_name" | zstd > "${backup_name}.tar.zst" 
        rm -rf "$backup_name"
        # 更新最后一次全量备份的时间戳
        echo "$TODAY" > "$LAST_TIMESTAMP_FILE"
    else
        echo "Full backup failed"
        rm -rf "$backup_path"
        exit 1
    fi
}

# 执行增量备份
incremental_backup() {
    echo "Performing incremental backup..."
    # 获取最近的全量备份WAL位置
    local last_manifest=$(ls -t "$BACKUP_DIR/manifest"/last_manifest 2>/dev/null | head -n 1)
    if [ -z "$last_manifest" ]; then
        echo "No full backup found, performing full backup instead..."
        full_backup
        return
    fi
    local last_backup_date=$(cat "$LAST_TIMESTAMP_FILE")

    local backup_path="$BACKUP_FILES_DIR/$last_backup_date/incremental"
    local backup_name="${BACKUP_PREFIX}-incremental-${TIMESTAMP}"
    mkdir -p "$backup_path"
    
    # 使用pg_basebackup的增量备份功能
    pg_basebackup \
        -h $POSTGRES_HOST \
        -U $POSTGRES_USER \
        -D "$backup_path/$backup_name" \
        -X stream \
        -i "$last_manifest" \
        --manifest-checksums=sha256 \
        --manifest-force-encode \
        -v \
        -P \
        -l "incremental_backup_$TIMESTAMP"
    
    # 检查备份是否成功
    if [ $? -eq 0 ]; then
        cp "$backup_path/$backup_name/backup_manifest" "$BACKUP_DIR/manifest/last_manifest"
        verify_backup "$backup_path/$backup_name" "incremental"
        echo "Incremental backup completed successfully"
        cd  $backup_path
        tar cf - "$backup_name" | zstd > "${backup_name}.tar.zst" 
        rm -rf "$backup_name"
    else
        echo "Incremental backup failed"
        rm -rf "$backup_path"
        exit 1
    fi
}

# 上传备份到对象存储
upload_backups() {
    if [ "${STORAGE_TYPE}" = "s3" ]; then
        mc alias set remote_storage "${S3_ENDPOINT}" "${S3_ACCESS_KEY}" "${S3_SECRET_KEY}"
        echo "Uploading backup to S3..."
        # 使用mc命令上传到MinIO
        mc cp --recursive $BACKUP_FILES_DIR/* remote_storage/$S3_BUCKET/$BACKUP_PREFIX/
        if [ $? -eq 0 ]; then
            echo "Backup upload successful, cleaning up local files..."
            # 删除已同步的备份文件
            rm -rf "$BACKUP_FILES_DIR"/*
            echo "Local backup files cleaned up"
        else
            echo "Backup upload failed, keeping local files"
            exit 1
        fi
    fi
}

main() {
    check_postgres_running
    
    # 根据时间戳判断是否需要执行全量备份
    if need_full_backup; then
        full_backup
    else
        incremental_backup
    fi
    
    upload_backups
}

# 执行主逻辑
main
