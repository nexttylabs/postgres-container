ARG BASETAG=latest
FROM postgres:$BASETAG

ARG GOCRONVER=v0.0.11
ARG TARGETOS
ARG TARGETARCH

# FIX Debian cross build
ARG DEBIAN_FRONTEND=noninteractive
RUN set -x \
    && ln -s /usr/bin/dpkg-split /usr/sbin/dpkg-split \
    && ln -s /usr/bin/dpkg-deb /usr/sbin/dpkg-deb \
    && ln -s /bin/tar /usr/sbin/tar \
    && ln -s /bin/rm /usr/sbin/rm \
    && ln -s /usr/bin/dpkg-split /usr/local/sbin/dpkg-split \
    && ln -s /usr/bin/dpkg-deb /usr/local/sbin/dpkg-deb \
    && ln -s /bin/tar /usr/local/sbin/tar \
    && ln -s /bin/rm /usr/local/sbin/rm

RUN set -x \
    && apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && curl --fail --retry 4 --retry-all-errors -o /usr/local/bin/go-cron.gz -L https://github.com/prodrigestivill/go-cron/releases/download/$GOCRONVER/go-cron-$TARGETOS-$TARGETARCH.gz \
    && gzip -vnd /usr/local/bin/go-cron.gz && chmod a+x /usr/local/bin/go-cron \
    && curl https://dl.min.io/client/mc/release/linux-$TARGETARCH/mc -o /usr/local/bin/mc \
    && chmod +x /usr/local/bin/mc


ENV POSTGRES_USER="**None**" \
    POSTGRES_USER_FILE="**None**" \
    POSTGRES_PASSWORD="**None**" \
    POSTGRES_PASSWORD_FILE="**None**" \
    SCHEDULE="@hourly" \
    BACKUP_ON_START="FALSE" \
    BACKUP_DIR="/backups" \
    BACKUP_PREFIX="postgres" \
    BACKUP_SUFFIX=".zst" \
    HEALTHCHECK_PORT=8080 \
    WEBHOOK_URL="**None**" \
    WEBHOOK_ERROR_URL="**None**" \
    WEBHOOK_PRE_BACKUP_URL="**None**" \
    WEBHOOK_POST_BACKUP_URL="**None**" \
    WEBHOOK_EXTRA_ARGS="" \
    STORAGE_TYPE="local" \
    S3_ENDPOINT="**None**" \
    S3_BUCKET="**None**" \
    S3_ACCESS_KEY="**None**" \
    S3_SECRET_KEY="**None**"

COPY hooks /hooks
COPY backup.sh env.sh init.sh upload.sh /

RUN set -x \
    && chmod +x /backup.sh /env.sh /init.sh /upload.sh

VOLUME ["/backups"]

ENTRYPOINT []
CMD ["/init.sh"]

HEALTHCHECK --interval=5m --timeout=3s \
    CMD curl -f "http://localhost:$HEALTHCHECK_PORT/" || exit 1
