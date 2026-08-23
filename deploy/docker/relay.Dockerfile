# Australia-pinned UDP relay. Stateless; scale horizontally behind a UDP NLB.
FROM rust:1.95-slim AS build
WORKDIR /src
COPY Cargo.toml Cargo.lock rust-toolchain.toml ./
COPY blaktail-coord ./blaktail-coord
COPY blaktail-relay ./blaktail-relay
COPY blaktaild ./blaktaild
RUN cargo build --release -p blaktail-relay

FROM debian:12-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 blaktail
COPY --from=build /src/target/release/blaktail-relay /usr/local/bin/blaktail-relay
USER blaktail
EXPOSE 3478/udp
ENTRYPOINT ["/usr/local/bin/blaktail-relay"]
