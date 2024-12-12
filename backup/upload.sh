#!/bin/bash
set -e

# Source environment variables
source /env.sh

# Function to upload file to S3
upload_to_s3() {
    local file="$1"
    
    if [ "${STORAGE_TYPE}" != "s3" ]; then
        echo "Storage type is not s3, skipping upload"
        return 0
    fi
    
    # 获取备份类型
    local backup_type="incremental"
    if [[ "$file" == *"-full-"* ]]; then
        backup_type="full"
    fi
    
    # 确定使用哪个时间戳作为目录名
    local dir_timestamp
    if [ "$backup_type" = "full" ]; then
        # 如果是全量备份，使用自己的时间戳
        dir_timestamp=$(basename "$file" | grep -o '[0-9]\{8\}-[0-9]\{6\}')
    else
        # 如果是增量备份，使用其基于的全量备份时间戳
        # 读取备份开始时最近的全量备份时间戳
        if [ -f "$BACKUP_DIR/latest_full_backup_timestamp" ]; then
            dir_timestamp=$(cat "$BACKUP_DIR/latest_full_backup_timestamp")
        else
            # 如果找不到全量备份时间戳文件，这是一个错误状态
            echo "Error: Cannot find latest full backup timestamp file. A full backup is required."
            exit 1
        fi
    fi
    
    # 构建S3路径
    # 根据备份类型确定最终的S3路径
    if [ "$backup_type" = "full" ]; then
        # 全量备份使用自己的时间戳作为目录
        local s3_path="backup/${S3_BUCKET}/${BACKUP_PREFIX}/${dir_timestamp}/$(basename "$file")"
    else
        # 增量备份放在对应全量备份目录下的incremental子目录中
        local s3_path="backup/${S3_BUCKET}/${BACKUP_PREFIX}/${dir_timestamp}/incremental/$(basename "$file")"
    fi
    
    # Upload file to S3
    echo "Uploading ${file} to ${s3_path}"
    mc cp "${file}" "${s3_path}"

    if [ $? -eq 0 ]; then
        echo "Successfully uploaded ${file} to ${s3_path}"
        # Remove local file after successful upload if needed
        # rm "${file}"
    else
        echo "Failed to upload ${file} to ${s3_path}"
        exit 1
    fi
}

# Check if file argument is provided
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <backup-file>"
    exit 1
fi

BACKUP_FILE="$1"

# Check if file exists
if [ ! -f "${BACKUP_FILE}" ]; then
    echo "Backup file ${BACKUP_FILE} does not exist"
    exit 1
fi

# Upload the file
upload_to_s3 "${BACKUP_FILE}"