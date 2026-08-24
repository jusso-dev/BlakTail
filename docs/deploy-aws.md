# Deploying BlakTail to AWS

Two supported paths:

| Path | Shape | Scales | Best for |
| --- | --- | --- | --- |
| **Single host (EC2)** | `compose.yaml` + Docker on one box | Vertical only | Pilots, self-hosted demos |
| **AWS ECS (this directory)** | Fargate services + RDS + EFS + ALB/NLB | Horizontal | Production |

Everything is pinned to Sydney (`ap-southeast-2`); the relay binary refuses other regions by design (onshore data rule).

## Architecture (ECS path)

| Component | Runs as | Scaling | Data store |
| --- | --- | --- | --- |
| Console (Next.js + Better Auth) | Fargate service behind an ALB | 2–6 tasks, CPU target tracking | RDS Postgres (`db.t4g.medium`, Multi-AZ optional) |
| Coordinator (`blaktail-coord`) | Fargate service behind a TCP pass-through NLB :443 | **1 task** (SQLite single-writer) | SQLite on EFS access point |
| Relay (`blaktail-relay`) | Fargate service behind a UDP NLB :3478 | **1 task** until relay sharding lands | In-memory registration map |

Notes:

* The coord NLB is pass-through, so the Rust binary keeps terminating TLS itself; its certificate and key travel through Secrets Manager into env vars and are materialised at `/tmp` by the container entrypoint.
* Coordinator and relay are intentionally pinned at one task. SQLite keeps coordinator single-writer; relay registrations currently live in one process.
* Secrets (`DATABASE_URL`, `BETTER_AUTH_SECRET`, `BLAKTAIL_AUTH_HMAC_SECRET`, dedicated `BLAKTAIL_RELAY_AUTH_SECRET`, coord TLS material) live in Secrets Manager and are injected by ECS; nothing lands in the image or task definition.
* Logs go to CloudWatch (`/ecs/blaktail/{console,coord,relay}`, 30-day retention).
* ECS Container Insights is enabled by Terraform for task-level CPU, memory,
  network, storage, and restart visibility.

## Path 1: single EC2 host

```sh
# Ubuntu/Amazon Linux 2023 with Docker + Compose plugin installed
git clone https://github.com/jusso-dev/BlakTail && cd BlakTail
scripts/dev-certs.sh                      # throwaway local CA + coord cert
POSTGRES_PASSWORD="$(openssl rand -hex 24)"
BETTER_AUTH_SECRET="$(openssl rand -hex 32)"
BLAKTAIL_AUTH_HMAC_SECRET="$(openssl rand -hex 32)"
BLAKTAIL_RELAY_AUTH_SECRET="$(openssl rand -hex 32)"
cat > .env <<EOF
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
BETTER_AUTH_SECRET=$BETTER_AUTH_SECRET
BLAKTAIL_AUTH_HMAC_SECRET=$BLAKTAIL_AUTH_HMAC_SECRET
BLAKTAIL_RELAY_AUTH_SECRET=$BLAKTAIL_RELAY_AUTH_SECRET
BLAKTAIL_RELAY_ENDPOINT=relay.example.org.au:3478
BETTER_AUTH_URL=https://console.example.org.au
EOF
docker compose build
docker compose up -d postgres coord relay
docker compose run --rm console npm run db:migrate

umask 077
openssl rand -base64 32 > owner-password
chmod 600 owner-password
docker compose run --rm \
  -v "$PWD/owner-password:/run/secrets/owner-password:ro" \
  console sh -ceu '
    node scripts/bootstrap.mjs init --token-file /tmp/bootstrap-token
    node scripts/bootstrap.mjs claim \
      --token-file /tmp/bootstrap-token \
      --password-file /run/secrets/owner-password \
      --email owner@example.org.au \
      --name "First Owner" \
      --organisation-name "Example Organisation"
  '
docker compose up -d console
```

Open `http://<ec2-ip>:3000` and sign in with the example email plus the protected
`owner-password` file (put a TLS proxy such as Caddy/nginx in front for
production). Public sign-up is disabled; create later users with owner invitations
from `/settings`. Security group needs inbound 3000/tcp, 8443/tcp, 3478/udp. Coord
state lives in the `coorddata` volume; Postgres in `pgdata`. Compose binds
coordinator and relay metrics to host loopback at `127.0.0.1:9701` and
`127.0.0.1:9702`; scrape them from the host or a host-networked collector. See
[console.md](console.md#first-owner-and-invitations) and
[observability.md](observability.md).

## Path 2: ECS via Terraform

```sh
cd deploy/aws
terraform init
terraform apply \
  -var="coord_tls_cert_pem=$(cat coord.crt)" \
  -var="coord_tls_key_pem=$(cat coord.key)"
```

Then build and push images and force new deployments:

```sh
ACCOUNT=123456789012
scripts/publish-images.sh "$ACCOUNT" ap-southeast-2 latest
aws ecs update-service --cluster blaktail --service console  --force-new-deployment
aws ecs update-service --cluster blaktail --service coord    --force-new-deployment
aws ecs update-service --cluster blaktail --service relay    --force-new-deployment
terraform output console_url     # set BETTER_AUTH_URL / your DNS here
terraform output coord_endpoint  # agents' --coord value
terraform output relay_endpoint
```

Run console migrations once, then execute the same supported `bootstrap.mjs
init`/`claim` ceremony in a one-off console task or ECS Exec session. Transfer the
password through a protected operator channel, never task arguments, Terraform
variables/state, or CloudWatch output. The disposable isolated harness implements
this as `scripts/aws-e2e/bootstrap-owner.sh`: it uses a short-lived encrypted S3
object readable only by the console task role, deletes it on exit, keeps the
bootstrap token inside the task, and writes a credential-free evidence marker.
`scripts/aws-e2e/verify-auth.sh` then proves that public signup is disabled and
that the generated owner can reach the authenticated Devices page without writing
the password, session body, or cookie jar to evidence. Successful teardown removes
the local password, cookie, enrollment URLs, Terraform state and state backup after
AWS absence checks pass.

Production additions:

* `terraform apply -var="db_multi_az=true" -var="db_instance_class=db.t4g.large"`.
* ACM certificate for the console: `-var="console_acm_certificate_arn=arn:aws:acm:..."` plus a Route53 alias; then set `-var="better_auth_url=https://your-domain"`.
* Replace the default VPC with a dedicated VPC, private subnets, and NAT gateways.
* Coordinate certificate: a publicly trusted cert (e.g. Let's Encrypt DNS-01 for your coord hostname) works best; agents must trust whatever chain coord presents.
* Complete [privacy.md](privacy.md) with the operating organisation's real contact,
  locations, retention, subprocessors, and rights-request process. Confirm `/privacy`
  is reachable without signing in before publishing the console URL.
* Run the pinned published-package [two-node drill](two-node-drill.md). A successful
  image push or health check alone does not prove enrollment or tunnel traffic.

## Scaling limits and next steps

* Coordinator: SQLite is single-writer. Porting `blaktail-coord` to Postgres unlocks multi-task coord behind the existing NLB target group — tracked separately.
* Relay: one task per advertised endpoint. Horizontal scale needs explicit relay sharding/discovery so communicating nodes select the same registration map.
* Console: stateless; scale-out is bounded only by RDS capacity.
