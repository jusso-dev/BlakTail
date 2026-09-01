# Throwaway coordinator certificates for compose quickstarts.
FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends bash openssl \
 && rm -rf /var/lib/apt/lists/*
COPY scripts/dev-certs.sh /usr/local/bin/dev-certs
COPY deploy/docker/certs-entrypoint.sh /usr/local/bin/certs-entrypoint
RUN chmod 0755 /usr/local/bin/dev-certs /usr/local/bin/certs-entrypoint
VOLUME ["/certs"]
ENTRYPOINT ["/usr/local/bin/certs-entrypoint"]
