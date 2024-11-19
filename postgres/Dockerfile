ARG BASETAG=latest
FROM postgres:$BASETAG

ARG TARGETOS
ARG TARGETARCH
ARG PGVECTOR_VERSION=v0.8.0

# Install build dependencies and pgvector
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    postgresql-server-dev-all \
    && git clone --branch ${PGVECTOR_VERSION} https://github.com/pgvector/pgvector.git \
    && cd pgvector \
    && make \
    && make install \
    && cd .. \
    && rm -rf pgvector \
    && apt-get remove -y build-essential git postgresql-server-dev-all \
    && apt-get autoremove -y \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

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
    && mkdir -p /etc/postgresql \
    && mkdir -p /etc/postgresql/ssl

COPY postgresql.conf pg_hba.conf /etc/postgresql/
COPY create_backup_user.sh init-pgvector.sh /docker-entrypoint-initdb.d/

# Support for Docker secrets and ensure proper permissions
RUN set -x \
    && mkdir -p /run/secrets \
    && chown -R postgres:postgres /run/secrets \
    && chown postgres:postgres /docker-entrypoint-initdb.d/create_backup_user.sh \
    && chmod 755 /docker-entrypoint-initdb.d/create_backup_user.sh \
    && chown postgres:postgres /docker-entrypoint-initdb.d/init-pgvector.sh \
    && chmod 755 /docker-entrypoint-initdb.d/init-pgvector.sh

RUN set -x \
    && chown -R postgres:postgres /etc/postgresql \
    && chmod 600 /etc/postgresql/postgresql.conf \
    && chmod 600 /etc/postgresql/pg_hba.conf

CMD ["postgres", "-c", "config_file=/etc/postgresql/postgresql.conf"]
