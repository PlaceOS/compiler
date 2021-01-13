FROM crystallang/crystal:0.35.1-alpine

WORKDIR /app

# Set the commit through a build arg
ARG PLACE_COMMIT="DEV"

# Install the latest version of LibSSH2, ping
RUN apk add --no-cache libssh2 libssh2-dev libssh2-static

# Add trusted CAs for communicating with external services
RUN apk update && apk add --no-cache ca-certificates tzdata && update-ca-certificates

RUN apk add --no-cache -X http://dl-cdn.alpinelinux.org/alpine/edge/testing watchexec

RUN apk add --no-cache bash

COPY shard.yml /app

RUN shards install

COPY entrypoint.sh /app/entrypoint.sh
COPY spec /app/spec
COPY src /app/src

# These provide certificate chain validation where communicating with external services over TLS
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

ENTRYPOINT /app/entrypoint.sh
