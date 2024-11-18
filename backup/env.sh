#!/usr/bin/env bash


if [ "${POSTGRES_USER}" = "**None**" -a "${POSTGRES_USER_FILE}" = "**None**" ]; then
  echo "You need to set the POSTGRES_USER or POSTGRES_USER_FILE environment variable."
  exit 1
fi

if [ "${POSTGRES_PASSWORD}" = "**None**" -a "${POSTGRES_PASSWORD_FILE}" = "**None**" -a "${POSTGRES_PASSFILE_STORE}" = "**None**" ]; then
  echo "You need to set the POSTGRES_PASSWORD or POSTGRES_PASSWORD_FILE or POSTGRES_PASSFILE_STORE environment variable or link to a container named POSTGRES."
  exit 1
fi

#Process vars
if [ "${POSTGRES_USER_FILE}" = "**None**" ]; then
  export PGUSER="${POSTGRES_USER}"
elif [ -r "${POSTGRES_USER_FILE}" ]; then
  export PGUSER=$(cat "${POSTGRES_USER_FILE}")
else
  echo "Missing POSTGRES_USER_FILE file."
  exit 1
fi
if [ "${POSTGRES_PASSWORD_FILE}" = "**None**" ]; then
  export POSTGRES_PASSWORD="${POSTGRES_PASSWORD}"
elif [ "${POSTGRES_PASSWORD_FILE}" != "**None**" ]; then
  export POSTGRES_PASSWORD=$(cat "${POSTGRES_PASSWORD_FILE}")
else
  echo "Missing POSTGRES_PASSWORD_FILE or PGPASSWORD enviroment variable."
  exit 1
fi
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
if [ "${S3_ENDPOINT}" = "**None**" -a "${S3_ENDPOINT_FILE}" = "**None**"  ]; then
  echo "You need to set the S3_ENDPOINT environment variable."
  exit 1
fi

if [ "${S3_ENDPOINT_FILE}" != "**None**" ]; then
  export S3_ENDPOINT=$(cat "${S3_ENDPOINT_FILE}")
fi

if [ "${S3_ACCESS_KEY}" = "**None**" -a "${S3_ACCESS_KEY_FILE}" = "**None**" ]; then
  echo "You need to set the S3_ACCESS_KEY environment variable."
  exit 1
fi

if [ "${S3_ACCESS_KEY_FILE}" != "**None**" ]; then
  export S3_ACCESS_KEY=$(cat "${S3_ACCESS_KEY_FILE}")
fi

if [ "${S3_SECRET_KEY}" = "**None**" -a "${S3_SECRET_KEY_FILE}" = "**None**" ]; then
  echo "You need to set the S3_SECRET_KEY environment variable."
  exit 1
fi

if [ "${S3_SECRET_KEY_FILE}" != "**None**" ]; then
  export S3_SECRET_KEY=$(cat "${S3_SECRET_KEY_FILE}")
fi

fi
