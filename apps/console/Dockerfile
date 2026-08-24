# BlakTail console (Next.js + Better Auth + Drizzle). Migrations are an explicit gate.
FROM rust:1.95-slim-bookworm AS config-build
WORKDIR /src
COPY Cargo.toml Cargo.lock rust-toolchain.toml ./
COPY config ./config
COPY blaktail-config ./blaktail-config
COPY blaktail-coord ./blaktail-coord
COPY blaktail-relay ./blaktail-relay
COPY blaktaild ./blaktaild
RUN cargo build --release -p blaktail-config

FROM node:22-bookworm-slim AS deps
WORKDIR /app
COPY apps/console/package.json apps/console/package-lock.json ./
RUN npm ci

FROM node:22-bookworm-slim AS build
WORKDIR /app
ENV NEXT_TELEMETRY_DISABLED=1
COPY --from=deps /app/node_modules ./node_modules
COPY apps/console ./
# Build-time placeholders exist only for static compilation; real values are
# injected at runtime and must not persist in image metadata.
RUN DATABASE_URL=postgres://placeholder:placeholder@127.0.0.1:5432/placeholder \
    BETTER_AUTH_SECRET=build-time-placeholder-secret-32-chars-min \
    BETTER_AUTH_URL=http://localhost:3000 \
    COORD_BASE_URL=https://coord.example.internal \
    BLAKTAIL_AUTH_HMAC_SECRET=build-time-placeholder-secret-32-chars-min \
    npm run build

FROM node:22-bookworm-slim
WORKDIR /app
ENV NODE_ENV=production NEXT_TELEMETRY_DISABLED=1 PORT=3000 HOME=/tmp
RUN apt-get update \
    && apt-get install --yes --no-install-recommends awscli ca-certificates curl postgresql-client \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system blaktail \
    && useradd --system --gid blaktail --home-dir /nonexistent --shell /usr/sbin/nologin blaktail
COPY --chown=blaktail:blaktail --from=deps /app/node_modules ./node_modules
COPY --chown=blaktail:blaktail --from=build /app/.next ./.next
COPY --chown=blaktail:blaktail --from=build /app/public ./public
COPY --chown=blaktail:blaktail --from=build /app/scripts ./scripts
COPY --chown=blaktail:blaktail apps/console/package.json apps/console/drizzle.config.ts ./
COPY --chown=blaktail:blaktail apps/console/drizzle ./drizzle
COPY --from=config-build /src/target/release/blaktail-config /usr/local/bin/blaktail-config
COPY --chown=blaktail:blaktail --chmod=0755 deploy/docker/console-entrypoint.sh /usr/local/bin/console-entrypoint
USER blaktail
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s \
  CMD curl --fail --silent http://127.0.0.1:3000/sign-in >/dev/null || exit 1
ENTRYPOINT ["console-entrypoint"]
CMD ["./node_modules/.bin/next", "start"]
