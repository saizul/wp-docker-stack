# PHP-FPM image for WordPress: official wordpress fpm-alpine image (bcmath, exif,
# gd, intl, mysqli, zip, imagick, opcache) plus the redis extension, wp-cli,
# tuned php.ini / opcache / FPM pool and healthcheck helpers.
ARG WORDPRESS_BASE_IMAGE=wordpress:7.1-php8.4-fpm-alpine
FROM ${WORDPRESS_BASE_IMAGE}

ARG PHPREDIS_VERSION=6.3.0
ARG WP_CLI_VERSION=2.12.0
ARG WP_CLI_SHA512=be928f6b8ca1e8dfb9d2f4b75a13aa4aee0896f8a9a0a1c45cd5d2c98605e6172e6d014dda2e27f88c98befc16c040cbb2bd1bfa121510ea5cdf5f6a30fe8832

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

# hadolint ignore=SC2086
RUN apk add --no-cache fcgi less mariadb-client \
    && apk add --no-cache --virtual .build-deps $PHPIZE_DEPS \
    && pecl install "redis-${PHPREDIS_VERSION}" \
    && docker-php-ext-enable redis \
    && apk del --no-network .build-deps \
    && rm -rf /tmp/pear \
    && php -m | grep -qx redis

RUN curl -fsSL -o /usr/local/bin/wp \
        "https://github.com/wp-cli/wp-cli/releases/download/v${WP_CLI_VERSION}/wp-cli-${WP_CLI_VERSION}.phar" \
    && echo "${WP_CLI_SHA512}  /usr/local/bin/wp" | sha512sum -c - \
    && chmod 0755 /usr/local/bin/wp \
    && wp --allow-root --version

# Defaults for the ${VAR} placeholders in the ini and pool files below.
ENV PHP_MEMORY_LIMIT=256M \
    PHP_UPLOAD_MAX=64M \
    PHP_MAX_EXECUTION_TIME=120 \
    PHP_OPCACHE_MEMORY=192 \
    PHP_FPM_MAX_CHILDREN=10 \
    PHP_FPM_START_SERVERS=3 \
    PHP_FPM_MIN_SPARE=2 \
    PHP_FPM_MAX_SPARE=5 \
    PHP_FPM_MAX_REQUESTS=500 \
    HOME=/tmp \
    WP_CLI_CACHE_DIR=/tmp/wp-cli-cache

COPY conf/php.ini "$PHP_INI_DIR/conf.d/zz-wpstack.ini"
COPY conf/opcache.ini "$PHP_INI_DIR/conf.d/zz-wpstack-opcache.ini"
COPY conf/www.conf /usr/local/etc/php-fpm.d/zz-wpstack.conf
COPY --chmod=0755 bin/php-fpm-healthcheck bin/wp-cron-loop /usr/local/bin/

USER www-data
