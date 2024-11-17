#!/usr/bin/env bash
set -Eeo pipefail

source /env.sh
if [ "${STORAGE_TYPE}" = "s3" ]; then
  mc alias set backup "${S3_ENDPOINT}" "${S3_ACCESS_KEY}" "${S3_SECRET_KEY}"
fi

# Configure MinIO client

EXTRA_ARGS=""
# Initial background backup
if [ "${BACKUP_ON_START}" = "TRUE" ]; then
  EXTRA_ARGS="-i"
fi

exec /usr/local/bin/go-cron -s "$SCHEDULE" -p "$HEALTHCHECK_PORT" $EXTRA_ARGS -- /backup.sh