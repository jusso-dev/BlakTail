# BlakTail console (Next.js + Better Auth + Drizzle). Migrations run at start.
FROM node:22-alpine AS deps
WORKDIR /app
COPY apps/console/package.json apps/console/package-lock.json ./
RUN npm ci

FROM node:22-alpine AS build
WORKDIR /app
ENV NEXT_TELEMETRY_DISABLED=1
COPY --from=deps /app/node_modules ./node_modules
COPY apps/console ./
# Build-time placeholders; real values are injected at runtime.
ENV DATABASE_URL=postgres://placeholder:placeholder@127.0.0.1:5432/placeholder \
    BETTER_AUTH_SECRET=build-time-placeholder-secret-32-chars-min \
    BETTER_AUTH_URL=http://localhost:3000 \
    COORD_BASE_URL=https://coord.example.internal \
    BLAKTAIL_AUTH_HMAC_SECRET=build-time-placeholder-secret-32-chars-min
RUN npm run build

FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production NEXT_TELEMETRY_DISABLED=1 PORT=3000
RUN apk add --no-cache postgresql-client && addgroup -S blaktail && adduser -S blaktail -G blaktail
COPY --from=deps /app/node_modules ./node_modules
COPY --from=build /app/.next ./.next
COPY --from=build /app/public ./public
COPY apps/console/package.json apps/console/drizzle.config.ts ./ 
COPY apps/console/drizzle ./drizzle
USER blaktail
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s \
  CMD wget -qO- http://127.0.0.1:3000/sign-in || exit 1
CMD ["sh", "-c", "npx drizzle-kit migrate --config drizzle.config.ts && npx next start -p $PORT"]
