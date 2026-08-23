# ARM64/multi-arch coordinator HTTP bridge and ephemeral certificate generator.
FROM caddy:2.10.2-alpine

RUN apk add --no-cache openssl
COPY deploy/docker/e2e-coord-proxy.Caddyfile /etc/caddy/Caddyfile

EXPOSE 8080
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
