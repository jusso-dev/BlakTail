# Observability and audit

BlakTail exposes operational counters without putting node secrets or payloads
in metrics or logs. Metrics use Prometheus's text format on dedicated plain-HTTP
listeners. Both listeners default to loopback and should remain private.

## Local Compose scrape

`compose.yaml` binds only the host loopback interface:

```sh
docker compose up -d --build
curl --fail --silent -H "Authorization: Bearer $BLAKTAIL_DIAGNOSTICS_TOKEN" \
  http://127.0.0.1:9701/metrics
curl --fail --silent -H "Authorization: Bearer $BLAKTAIL_DIAGNOSTICS_TOKEN" \
  http://127.0.0.1:9702/metrics
```

The container listeners bind `0.0.0.0` so Docker port forwarding can reach them;
that explicit exposure requires a separate 32-byte diagnostics token. Published
host ports remain `127.0.0.1` only. A same-network Prometheus must send the same
bearer token and the ports must not be published externally.

Coordinator metrics:

- `blaktail_coord_requests_total{operation,result}` — register, peer-list, and
  revoke outcomes
- `blaktail_coord_request_duration_seconds` — cumulative latency histogram for
  those operations
- `blaktail_coord_active_nodes` — unrevoked nodes whose credentials have not
  expired, calculated from the configured coordinator database at scrape time

Relay metrics:

- `blaktail_relay_registers_total{result}` — accepted/rejected registrations
- `blaktail_relay_forwards_total` — forwarded encrypted WireGuard packets
- `blaktail_relay_bytes_total` — encrypted payload bytes forwarded
- `blaktail_relay_dropped_total{reason}` — unknown destinations, rate limits,
  and oversized packets

Coordinator public `/livez`, `/readyz`, and `/health` responses contain status
only; readiness probes the configured store and exact schema version. Relay `/livez` and `/readyz`
are status-only on its private HTTP listener. `/metrics` and
`/diagnostics/readiness` require bearer authentication whenever a non-loopback
metrics bind is enabled. Network isolation remains mandatory.

## Audit trail

The coordinator's `audit_events` table is append-only through the application.
Each event records organisation, signed actor id/name/email/role, action, target,
non-secret JSON details, and a UTC Unix timestamp. The event is inserted in the
same database transaction as its mutation, so a change cannot commit without its
audit record.

Audited actions are:

- `join_key.minted` (manual and browser enrollment)
- `device_authorization.approved`
- `node.routes_updated`
- `node.revoked` (console administration)
- `node.friendly_name_updated`
- `acl.updated`
- `security.updated`

Organisation members can inspect the latest 100 events in Console → Audit log.
The coordinator API supports `GET /v1/orgs/{org_id}/audit?limit=200`; it enforces
the signed organisation boundary. Secret join keys, node tokens, raw device
codes, and ACL bodies are omitted. ACL events store only rule count and SHA-256.
Database administrators can still alter the underlying store directly, so ship database
audit records and process logs to separately controlled backup/log storage when tamper evidence
is required.

## Alert baseline

Tune thresholds after observing normal traffic. A practical starting point:

```yaml
groups:
  - name: blaktail
    rules:
      - alert: BlakTailMetricsTargetDown
        expr: up{job=~"blaktail-(coord|relay)"} == 0
        for: 5m
      - alert: BlakTailCoordinatorErrors
        expr: sum(rate(blaktail_coord_requests_total{result="error"}[10m])) by (operation) > 0.05
        for: 10m
      - alert: BlakTailCoordinatorP95Latency
        expr: histogram_quantile(0.95, sum(rate(blaktail_coord_request_duration_seconds_bucket[10m])) by (le, operation)) > 1
        for: 10m
      - alert: BlakTailRelayRegistrationRejects
        expr: rate(blaktail_relay_registers_total{result="rejected"}[10m]) > 0.1
        for: 10m
      - alert: BlakTailRelayRateLimiting
        expr: rate(blaktail_relay_dropped_total{reason="rate_limited"}[5m]) > 1
        for: 5m
```

Also alert from infrastructure telemetry on coordinator or relay task restarts,
disk/EFS saturation, memory above 85%, and no healthy load-balancer targets. The
AWS Terraform deployment enables ECS Container Insights and retains service logs
in CloudWatch for 30 days. Application Prometheus metrics still require a private
collector or sidecar; they are intentionally not exposed by the public load
balancers.
