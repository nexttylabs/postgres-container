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

    # Configure MinIO client
    mc alias set backup "${S3_ENDPOINT}" "${S3_ACCESS_KEY}" "${S3_SECRET_KEY}"

    # Upload file to S3
    echo "Uploading ${file} to s3://${S3_BUCKET}"
    mc cp "${file}" "backup/${S3_BUCKET}/${BACKUP_PREFIX}/"

    if [ $? -eq 0 ]; then
        echo "Successfully uploaded ${file} to s3://${S3_BUCKET}"
        # Remove local file after successful upload if needed
        # rm "${file}"
    else
        echo "Failed to upload ${file} to s3://${S3_BUCKET}"
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