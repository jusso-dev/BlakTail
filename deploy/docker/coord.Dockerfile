# BlakTail coordination server. TLS terminates inside the binary (rustls),
# so a load balancer can pass traffic through untouched.
FROM rust:1.95-slim AS build
WORKDIR /src
COPY Cargo.toml Cargo.lock rust-toolchain.toml ./
COPY blaktail-coord ./blaktail-coord
COPY blaktail-relay ./blaktail-relay
COPY blaktaild ./blaktaild
RUN cargo build --release -p blaktail-coord

FROM debian:12-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 blaktail \
 && mkdir -p /data && chown blaktail:blaktail /data
COPY --from=build /src/target/release/blaktail-coord /usr/local/bin/blaktail-coord
COPY --chown=blaktail:blaktail --chmod=0755 deploy/docker/coord-entrypoint.sh /usr/local/bin/coord-entrypoint
USER blaktail
WORKDIR /data
VOLUME ["/data"]
EXPOSE 8443
ENTRYPOINT ["coord-entrypoint"]
