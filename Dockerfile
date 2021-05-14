ARG crystal_version=1.0.0
FROM crystallang/crystal:${crystal_version}-alpine

WORKDIR /app

# Set the commit through a build arg
ARG PLACE_COMMIT="DEV"

# Install the latest version of LibSSH2, ping
RUN apk add --no-cache libssh2 libssh2-dev libssh2-static tzdata ca-certificates bash
RUN apk add --no-cache -X http://dl-cdn.alpinelinux.org/alpine/edge/testing watchexec

# Add trusted CAs for communicating with external services
RUN update-ca-certificates

COPY shard.yml /app
COPY shard.yml /app

RUN shards install --ignore-crystal-version

COPY scripts /app/scripts
COPY spec /app/spec
COPY src /app/src

# These provide certificate chain validation where communicating with external services over TLS
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

CMD /app/scripts/entrypoint.sh
