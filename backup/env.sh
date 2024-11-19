#!/usr/bin/env bash


if [ "${POSTGRES_USER}" = "**None**" ]; then
  echo "You need to set the POSTGRES_USER environment variable."
  exit 1
fi

if [ "${POSTGRES_PASSWORD}" = "**None**" ]; then
  echo "You need to set the POSTGRES_PASSWORD environment variable."
  exit 1
fi

#Process vars

export PGPORT="${POSTGRES_PORT}"

# Validate backup dir
if [ '!' -d "${BACKUP_DIR}" -o '!' -w "${BACKUP_DIR}" -o '!' -x "${BACKUP_DIR}" ]; then
  echo "BACKUP_DIR points to a file or folder with insufficient permissions."
  exit 1
fi

# Validate object store
if [ "${STORAGE_TYPE}" = "s3" ]; then
if [ "${S3_BUCKET}" = "**None**" ]; then
  echo "You need to set the S3_BUCKET environment variable."
  exit 1
fi
if [ "${S3_ENDPOINT}" = "**None**"  ]; then
  echo "You need to set the S3_ENDPOINT environment variable."
  exit 1
fi

if [ "${S3_ACCESS_KEY}" = "**None**" ]; then
  echo "You need to set the S3_ACCESS_KEY environment variable."
  exit 1
fi

if [ "${S3_SECRET_KEY}" = "**None**" ]; then
  echo "You need to set the S3_SECRET_KEY environment variable."
  exit 1
fi

fi
