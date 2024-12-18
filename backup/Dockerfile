ARG BASETAG=17
FROM postgres:$BASETAG

ARG TARGETOS
ARG TARGETARCH

RUN set -x \
    && apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && curl https://dl.min.io/client/mc/release/linux-$TARGETARCH/mc -o /usr/local/bin/mc \
    && chmod +x /usr/local/bin/mc

ENV POSTGRES_USER="**None**" \
    POSTGRES_PASSWORD="**None**" \
    BACKUP_DIR="/backups" \
    BACKUP_PREFIX="postgres" \
    STORAGE_TYPE="local" \
    S3_ENDPOINT="**None**" \
    S3_BUCKET="**None**" \
    S3_ACCESS_KEY="**None**" \
    S3_SECRET_KEY="**None**" \
    FULL_BACKUP_INTERVAL="7" 

COPY backup.sh env.sh /

RUN chmod +x /backup.sh /env.sh

VOLUME ["/backups"]

CMD ["/backup.sh"]
