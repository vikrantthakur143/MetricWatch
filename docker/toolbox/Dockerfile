# Small helper image for the init and reload services.
#
#   openssl         self-signed certificate generation
#   apache2-utils   htpasswd, for the bcrypt hashes Prometheus and
#                   Alertmanager require in basic_auth_users
#   curl            reload endpoints
#
# Built once by compose and cached, so the init services do not need network
# access to install tooling on every run.
FROM alpine:3.21

RUN apk add --no-cache \
      openssl \
      apache2-utils \
      gettext \
      curl

WORKDIR /work
