#!/usr/bin/env bash
set -Eeo pipefail

if [ -n "$POSTGRES_PASSWORD" ]; then
    export PGPASSWORD="$POSTGRES_PASSWORD"
fi

HOOKS_DIR="/hooks"
if [ -d "${HOOKS_DIR}" ]; then
  on_error(){
    run-parts -a "error" "${HOOKS_DIR}"
  }
  trap 'on_error' ERR
fi

source "$(dirname "$0")/env.sh"

# 获取当前时间戳
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
TODAY=$(date +%u)  # 获取星期几 (1-7)

# 检查是否需要执行全量备份
need_full_backup() {
    # 检查是否是周日
    if [ "$TODAY" -eq 7 ]; then
        return 0
    fi
    
    # 检查是否存在全量备份
    if ! compgen -G "$BACKUP_DIR/manifest/*full*" > /dev/null; then
        return 0
    fi
    
    # 检查最近的全量备份是否超过7天
    local latest_full=$(ls -t "$BACKUP_DIR/manifest"/*full* 2>/dev/null | head -n 1)
    if [ -n "$latest_full" ]; then
        local backup_date=$(basename "$latest_full" | grep -o '[0-9]\{8\}')
        local today_date=$(date +%Y%m%d)
        local backup_formatted="${backup_date:0:4}-${backup_date:4:2}-${backup_date:6:2}"
        local today_formatted="${today_date:0:4}-${today_date:4:2}-${today_date:6:2}"
        local days_diff=$(( ($(date +%s -d "$today_formatted") - $(date +%s -d "$backup_formatted")) / 86400 ))
        if [ "$days_diff" -ge 7 ]; then
            return 0
        fi
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

# 完整备份函数
full_backup() {
    BACKUP_NAME="${BACKUP_PREFIX}-full-${TIMESTAMP}"
    echo "Starting full backup: $BACKUP_NAME"

    # 记录当前全量备份的时间戳到文件
    echo "${TIMESTAMP}" > "$BACKUP_DIR/latest_full_backup_timestamp"

    # 使用pg_basebackup的内置zstd压缩
    pg_basebackup \
        -h $POSTGRES_HOST \
        -U $POSTGRES_USER \
        -D "$BACKUP_DIR/full/$BACKUP_NAME" \
        -X stream \
        --manifest-checksums=sha256 \
        --manifest-force-encode \
        -v \
        -P \
        -l "full_backup_$TIMESTAMP"

    BACKUP_STATUS=$?

    if [ $BACKUP_STATUS -eq 0 ]; then
        # 保存manifest文件
        cp "$BACKUP_DIR/full/$BACKUP_NAME/backup_manifest" "$BACKUP_DIR/manifest/${BACKUP_NAME}_manifest"
        verify_backup "$BACKUP_DIR/full/$BACKUP_NAME" "full"
        echo "Full backup completed successfully"
        cd  $BACKUP_DIR/full
        tar cf - "$BACKUP_NAME" | zstd > "${BACKUP_NAME}.tar.zst" 
        rm -rf "$BACKUP_NAME"
    else
        echo "Full backup failed with status $BACKUP_STATUS"
        exit 1
    fi
}

# 增量备份函数
incremental_backup() {
    BACKUP_NAME="${BACKUP_PREFIX}-incremental-${TIMESTAMP}"
    echo "Starting incremental backup: $BACKUP_NAME"

    # 检查manifest目录是否为空
    if [ ! -d "$BACKUP_DIR/manifest" ] || [ -z "$(ls -A $BACKUP_DIR/manifest 2>/dev/null)" ]; then
        echo "No manifest directory or empty manifest directory. Performing full backup instead."
        full_backup
        return
    fi

    # 安全地获取最近的全量备份WAL位置
    LATEST_FULL_MANIFEST=""
    if compgen -G "$BACKUP_DIR/manifest/*full*" > /dev/null; then
        LATEST_FULL_MANIFEST=$(ls -t "$BACKUP_DIR/manifest"/*full* 2>/dev/null | head -n 1)
    fi

    if [ -z "$LATEST_FULL_MANIFEST" ]; then
        echo "No full backup manifest found. Performing full backup instead."
        full_backup
        return
    fi

    # 使用pg_basebackup的增量备份功能
    pg_basebackup \
        -h $POSTGRES_HOST \
        -U $POSTGRES_USER \
        -D "$BACKUP_DIR/incremental/$BACKUP_NAME" \
        -X stream \
        -i "$LATEST_FULL_MANIFEST" \
        --manifest-checksums=sha256 \
        --manifest-force-encode \
        -v \
        -P \
        -l "incremental_backup_$TIMESTAMP"

    BACKUP_STATUS=$?

    if [ $BACKUP_STATUS -eq 0 ]; then
        # 保存manifest文件
        cp "$BACKUP_DIR/incremental/$BACKUP_NAME/backup_manifest" "$BACKUP_DIR/manifest/${BACKUP_NAME}_manifest"
        verify_backup "$BACKUP_DIR/incremental/$BACKUP_NAME" "incremental"
        echo "Incremental backup completed successfully"
        cd  $BACKUP_DIR/incremental
        tar cf - "$BACKUP_NAME" | zstd > "${BACKUP_NAME}.tar.zst" 
        rm -rf "$BACKUP_NAME"

    else
        echo "Incremental backup failed with status $BACKUP_STATUS"
        exit 1
    fi
}

# 检查PostgreSQL服务是否运行（最多等待30秒）
check_postgres_running() {
    local max_attempts=30  # 最大尝试次数（60次，每次1秒）
    local attempt=1

    echo "Waiting for PostgreSQL to start..."

    while [ $attempt -le $max_attempts ]; do
        if PGPASSWORD=$POSTGRES_PASSWORD pg_isready -h $POSTGRES_HOST -U $POSTGRES_USER -d postgres -q; then
            echo "PostgreSQL is running and accepting connections"
            return 0
        fi

        echo "Attempt $attempt/$max_attempts: PostgreSQL is not ready yet..."
        sleep 1
        attempt=$((attempt + 1))
    done

    echo "ERROR: PostgreSQL did not start within 30 seconds"
    exit 1
}

# 上传备份文件到S3
upload_backups() {
    local backup_type=$1
    echo "Uploading ${backup_type} backups to S3..."
    
    if [ "$backup_type" = "full" ]; then
        # 处理全量备份
        find "$BACKUP_DIR/full" -name "*.tar.zst" -type f | while read file; do
            if [ -f "$file" ]; then
                # 从文件名中提取时间戳
                local timestamp=$(basename "$file" | grep -o '[0-9]\{8\}-[0-9]\{6\}')
                local s3_dir="backups/${timestamp}"
                
                echo "Uploading full backup $file to S3 directory: $s3_dir"
                S3_PREFIX="$s3_dir" /upload.sh "$file"
                
                if [ $? -eq 0 ]; then
                    echo "Successfully uploaded $file, removing local copy..."
                    rm "$file"
                else
                    echo "Failed to upload $file, keeping local copy"
                fi
            fi
        done
    else
        # 处理增量备份
        find "$BACKUP_DIR/incremental" -name "*.tar.zst" -type f | while read file; do
            if [ -f "$file" ]; then
                # 获取最近的全量备份时间戳
                local latest_full=$(ls -t "$BACKUP_DIR/manifest"/*full* 2>/dev/null | head -n 1)
                if [ -n "$latest_full" ]; then
                    local full_timestamp=$(basename "$latest_full" | grep -o '[0-9]\{8\}-[0-9]\{6\}')
                    local s3_dir="backups/${full_timestamp}"
                    
                    echo "Uploading incremental backup $file to S3 directory: $s3_dir"
                    S3_PREFIX="$s3_dir" /upload.sh "$file"
                    
                    if [ $? -eq 0 ]; then
                        echo "Successfully uploaded $file, removing local copy..."
                        rm "$file"
                    else
                        echo "Failed to upload $file, keeping local copy"
                    fi
                else
                    echo "No full backup found for reference, skipping upload of $file"
                fi
            fi
        done
    fi
}

main() {
    # Pre-backup hook
    if [ -d "${HOOKS_DIR}" ]; then
      run-parts -a "pre-backup" --exit-on-error "${HOOKS_DIR}"
    fi

    #Initialize dirs
    mkdir -p "$BACKUP_DIR"/{full,incremental,manifest}

    check_postgres_running

    # 使用新的备份策略判断函数
    if need_full_backup; then
        full_backup
        upload_backups "full"
    else
        incremental_backup
        upload_backups "incremental"
    fi

    # Post-backup hook
    if [ -d "${HOOKS_DIR}" ]; then
      run-parts -a "post-backup" --reverse --exit-on-error "${HOOKS_DIR}"
    fi
}


# 执行主逻辑
main
