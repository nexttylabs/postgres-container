ARG BASETAG=latest
FROM postgres:$BASETAG

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
    && mkdir -p /etc/postgresql \
    && mkdir -p /etc/postgresql/ssl

COPY postgresql.conf pg_hba.conf /etc/postgresql/
COPY create_backup_user.sh /docker-entrypoint-initdb.d/

# Support for Docker secrets and ensure proper permissions
RUN set -x \
    && mkdir -p /run/secrets \
    && chown -R postgres:postgres /run/secrets \
    && chown postgres:postgres /docker-entrypoint-initdb.d/create_backup_user.sh \
    && chmod 755 /docker-entrypoint-initdb.d/create_backup_user.sh

RUN set -x \
    && chown -R postgres:postgres /etc/postgresql \
    && chmod 600 /etc/postgresql/postgresql.conf \
    && chmod 600 /etc/postgresql/pg_hba.conf

CMD ["postgres", "-c", "config_file=/etc/postgresql/postgresql.conf"]
