# Syntax=docker/dockerfile:1
FROM macro-local-rust-services:dev AS rust-bundle
FROM alpine:3.20

RUN apk add --no-cache bash curl jq aws-cli postgresql-client

WORKDIR /app
COPY --from=rust-bundle /app/out/macro_db_migrator /app/macro_db_migrator
COPY docker/init/bootstrap.sh /app/bootstrap.sh

RUN chmod +x /app/macro_db_migrator /app/bootstrap.sh

ENTRYPOINT ["/app/bootstrap.sh"]
