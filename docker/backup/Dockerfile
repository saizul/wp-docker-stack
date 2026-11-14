# Backup sidecar: mariadb-dump + tar to a local volume, optional rclone copy
# to Cloudflare R2 / S3-compatible storage.
ARG BACKUP_BASE_IMAGE=alpine:3.24
FROM ${BACKUP_BASE_IMAGE}

RUN apk add --no-cache bash coreutils findutils gzip tar mariadb-client rclone tzdata \
    && (getent group www-data >/dev/null || addgroup -S -g 82 www-data) \
    && (getent passwd www-data >/dev/null || adduser -S -D -H -u 82 -G www-data -s /sbin/nologin www-data) \
    && mkdir -p /backups \
    && chown www-data:www-data /backups \
    && chmod 0750 /backups

COPY --chmod=0755 backup.sh /usr/local/bin/backup.sh

ENV BACKUP_DIR=/backups \
    WP_DIR=/var/www/html \
    BACKUP_SELF=/usr/local/bin/backup.sh

VOLUME ["/backups"]
USER www-data
WORKDIR /backups
ENTRYPOINT ["/usr/local/bin/backup.sh"]
CMD ["daemon"]
