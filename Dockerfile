ARG ENABLE_INFLUX1_CLIENT=false
ARG ENABLE_MYSQL_SOURCE_CLIENT=false
ARG ENABLE_BLOBXFER=false
ARG ENABLE_MSSQL_CLIENT=false

FROM alpine:3.23.3
LABEL maintainer="Dave Conroy (github.com/tiredofit)"

ARG ENABLE_INFLUX1_CLIENT
ARG ENABLE_MYSQL_SOURCE_CLIENT
ARG ENABLE_BLOBXFER
ARG ENABLE_MSSQL_CLIENT

RUN apk add --no-cache bash ca-certificates curl

COPY install/assets/functions/01-dbbackup-build /usr/local/share/dbbackup/01-dbbackup-build

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV INFLUX1_CLIENT_VERSION=1.8.0 \
    INFLUX2_CLIENT_VERSION=2.7.5 \
    MSODBC_VERSION=18.4.1.1-1 \
    MSSQL_VERSION=18.4.1.1-1 \
    MYSQL_VERSION=mysql-8.4.4 \
    MYSQL_REPO_URL=https://github.com/mysql/mysql-server \
    AWS_CLI_VERSION=1.36.40 \
    CONTAINER_ENABLE_MESSAGING=TRUE \
    CONTAINER_ENABLE_MONITORING=FALSE \
    IMAGE_NAME="a75g/docker-db-backup" \
    IMAGE_VERSION="dev" \
    IMAGE_REPO_URL="https://github.com/A75G/docker-db-backup/"

RUN source /usr/local/share/dbbackup/01-dbbackup-build && \
    set -ex && \
    addgroup -S -g 10000 dbbackup && \
    adduser -S -D -H -u 10000 -G dbbackup -g "Tired of I.T! DB Backup" dbbackup && \
    mkdir -p /usr/src /tmp/.container /backup /logs /tmp/backups /assets/cron /assets/logrotate && \
    package update && \
    package upgrade && \
    echo '@edge_main https://dl-cdn.alpinelinux.org/alpine/edge/main' >> /etc/apk/repositories && \
    echo '@edge_community https://dl-cdn.alpinelinux.org/alpine/edge/community' >> /etc/apk/repositories && \
    package update && \
    package install .db-backup-build-deps \
                    build-base \
                    bzip2-dev \
                    cargo \
                    cmake \
                    git \
                    go \
                    libarchive-dev \
                    libtirpc-dev \
                    openssl-dev \
                    libffi-dev \
                    ncurses-dev \
                    python3-dev \
                    py3-pip \
                    xz-dev \
                    && \
    package install .db-backup-run-deps \
                    bzip2 \
                    coreutils \
                    gpg \
                    gpg-agent \
                    grep \
                    groff \
                    libarchive \
                    libtirpc \
                    mariadb-client \
                    mariadb-connector-c \
                    ncurses \
                    openssl \
                    pigz \
                    pixz \
                    pv \
                    py3-botocore \
                    py3-colorama \
                    py3-cryptography \
                    py3-docutils \
                    py3-jmespath \
                    py3-rsa \
                    py3-setuptools \
                    py3-s3transfer \
                    py3-yaml \
                    python3 \
                    msmtp \
                    sqlite \
                    sudo \
                    tzdata \
                    xz \
                    zip \
                    zstd \
                    && \
    apk add --no-cache --upgrade \
            --repository=https://dl-cdn.alpinelinux.org/alpine/edge/main \
            libcrypto3 libssl3 openssl pcre2 zlib && \
    apk add --no-cache --upgrade \
            --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community \
            mongodb-tools redis && \
    apk add --no-cache postgresql18-client --repository=https://dl-cdn.alpinelinux.org/alpine/edge/main

RUN source /usr/local/share/dbbackup/01-dbbackup-build && \
    set -ex && \
    case "$(uname -m)" in \
        "x86_64" ) mssql_arch=amd64; influx2=true ; influx_arch=amd64; ;; \
        "arm64" | "aarch64" ) mssql_arch=arm64; influx2=true ; influx_arch=arm64 ;; \
        *) mssql_arch=none; influx2=false ;; \
    esac && \
    if [ "${ENABLE_MSSQL_CLIENT,,}" = "true" ] && [ "${mssql_arch}" != "none" ]; then \
        curl -sSLO https://download.microsoft.com/download/7/6/d/76de322a-d860-4894-9945-f0cc5d6a45f8/msodbcsql18_${MSODBC_VERSION}_${mssql_arch}.apk ; \
        curl -sSLO https://download.microsoft.com/download/7/6/d/76de322a-d860-4894-9945-f0cc5d6a45f8/mssql-tools18_${MSSQL_VERSION}_${mssql_arch}.apk ; \
        echo y | apk add --allow-untrusted msodbcsql18_${MSODBC_VERSION}_${mssql_arch}.apk mssql-tools18_${MSSQL_VERSION}_${mssql_arch}.apk ; \
    else \
        echo "Skipping optional MSSQL client installation" ; \
    fi && \
    if [ "${influx2,,}" = "true" ] ; then \
        curl -sSL https://dl.influxdata.com/influxdb/releases/influxdb2-client-${INFLUX2_CLIENT_VERSION}-linux-${influx_arch}.tar.gz | tar xvfz - --strip=1 -C /usr/src/ ; \
        chmod +x /usr/src/influx ; \
        mv /usr/src/influx /usr/sbin/ ; \
    else \
        echo "Skipping optional InfluxDB v2 client install on this architecture" ; \
    fi && \
    if [ "${ENABLE_INFLUX1_CLIENT,,}" = "true" ] ; then \
        clone_git_repo https://github.com/influxdata/influxdb "${INFLUX1_CLIENT_VERSION}" && \
        go build -o /usr/sbin/influxd ./cmd/influxd && \
        strip /usr/sbin/influxd ; \
    else \
        echo "Skipping optional InfluxDB v1 client build" ; \
    fi && \
    if [ "${ENABLE_MYSQL_SOURCE_CLIENT,,}" = "true" ] ; then \
        clone_git_repo "${MYSQL_REPO_URL}" "${MYSQL_VERSION}" && \
        cmake \
            -DCMAKE_BUILD_TYPE=MinSizeRel \
            -DCMAKE_INSTALL_PREFIX=/opt/mysql \
            -DFORCE_INSOURCE_BUILD=1 \
            -DWITHOUT_SERVER:BOOL=ON \
            && \
        make -j$(nproc) install ; \
    else \
        echo "Skipping optional MySQL source client build (using mariadb-client)" ; \
    fi

RUN source /usr/local/share/dbbackup/01-dbbackup-build && \
    set -ex && \
    # Keep awscli pinned for deterministic S3 CLI behavior across architectures.
    pip3 install --break-system-packages awscli==${AWS_CLI_VERSION} && \
    if [ "${ENABLE_BLOBXFER,,}" = "true" ] ; then \
        pip3 install --break-system-packages blobxfer ; \
    else \
        echo "Skipping optional blobxfer installation" ; \
    fi && \
    mkdir -p /usr/src/pbzip2 && \
    curl -sSL https://launchpad.net/pbzip2/1.1/1.1.13/+download/pbzip2-1.1.13.tar.gz | tar xvfz - --strip=1 -C /usr/src/pbzip2 && \
    cd /usr/src/pbzip2 && \
    make && \
    make install && \
    command -v pg_dump >/dev/null 2>&1 && \
    command -v psql >/dev/null 2>&1 && \
    command -v mysqldump >/dev/null 2>&1 && \
    command -v mongodump >/dev/null 2>&1 && \
    command -v redis-cli >/dev/null 2>&1 && \
    command -v sqlite3 >/dev/null 2>&1 && \
    package remove .db-backup-build-deps && \
    package cleanup && \
    rm -rf \
            /*.apk \
            /etc/logrotate.d/* \
            /root/.cache \
            /root/go \
            /tmp/* \
            /usr/src/*

COPY install  /

RUN find /assets /usr/local/bin -type f -exec sed -i 's/\r$//' {} + && \
    chmod +x /usr/local/bin/dbbackup-entrypoint /usr/local/bin/dbbackup-job /usr/local/bin/restore /usr/local/bin/logrotate_dbbackup

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD sh -ec 'for b in bash pg_dump psql mysqldump mongodump redis-cli sqlite3; do command -v "$b" >/dev/null || exit 1; done'

ENTRYPOINT ["/usr/local/bin/dbbackup-entrypoint"]
