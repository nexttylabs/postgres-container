#!/bin/bash
set -e

if [ -z "${BACKUP_USER_PASSWORD}" ]; then
    echo "BACKUP_USER_PASSWORD is not set"
    exit 1
fi

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_user WHERE usename = 'backup_user') THEN
            CREATE USER backup_user WITH PASSWORD '${BACKUP_USER_PASSWORD}' REPLICATION;
            GRANT pg_read_all_data TO backup_user;
            RAISE NOTICE 'Backup user created successfully';
        END IF;
    END
    \$\$;
EOSQL
