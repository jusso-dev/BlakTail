# ADR 0002 — First transport for resumable control updates

- Status: accepted for the first slice of #43
- Date: 2026-08-27

## Decision

The first control-update transport is a **bounded HTTPS long-poll** on a new
authenticated node route. Agents send the last applied organisation revision
and wait a short, documented interval. The coordinator returns either a full
snapshot or ordered deltas, then the client reconnects.

`--poll-seconds` full snapshot polling stays as the recovery and version-skew
path. It is not removed by this record.

## Why this transport first

Agents already speak HTTPS GET to `/v1/nodes/:id/peers`. The binding
constraint is the isolated AWS topology, not the persistent NLB:

| Path | HTTP idle / timeout | Effect on a waiting GET |
| --- | --- | --- |
| Homelab Caddy → coord TLS | operator-set; no 30s cloud cap | Long-poll or SSE both work |
| Persistent AWS TCP NLB :443 (TLS pass-through) | TCP, not HTTP | Long-poll or SSE both work |
| Isolated AWS HTTP API Gateway → VPC link → internal ALB → coord :8080 | API Gateway **30s**; ALB idle **60s** default | A wait longer than ~29s is cut. SSE/HTTP streaming dies the same way |

API Gateway HTTP API in `deploy/aws/e2e` sets `timeout_milliseconds = 30000`.
That is the first topology the conformance lab actually runs. A first
transport that needs idle timeouts above 30s, WebSocket integrations, or
sticky sessions would make that lab lie.

| Option | Propagation | ALB / API Gateway | Client change | Failure isolation |
| --- | --- | --- | --- | --- |
| Current `--poll-seconds` snapshot | Worst case one full interval | Safe | None | Unchanged state is resent every tick |
| Bounded long-poll (`wait` ≤ 25s, `since` revision) | Wake on change or on wait expiry | Fits 30s API Gateway and 60s ALB idle | Same GET stack; add wait/since | Slow client just reconnects; no open stream to buffer |
| SSE / HTTP streaming | Immediate on an open stream | Needs timeout/idle raises and a non-Gateway path | New reader, heartbeat, proxy buffering rules | One stuck stream holds coordinator memory until bounded |
| WebSocket | Same as SSE | API Gateway needs a different integration; NLB is fine | New protocol in every agent | Same backpressure problem plus a second TLS profile |

Long-poll reuses the existing rustls client, works through the lab Gateway
without Terraform changes, and still lets connected agents learn a revoke on
the next wait instead of waiting a full poll interval. SSE remains the later
upgrade once organisation revisions, coalescing, and a measured NLB-only (or
raised-timeout) path exist.

## Protocol shape this record locks

- New route, not a silent change to today's peers GET. Capability-advertise
  the stream; old agents keep polling snapshots for the documented skew
  window.
- Request carries node identity (existing bearer), last applied organisation
  revision, and protocol version. Empty/zero revision means "send a snapshot".
- Response is one JSON body: snapshot or contiguous deltas, each with the
  organisation revision and enough data to apply add/remove, policy/tag,
  route, relay, DNS, and credential changes idempotently.
- Wait is capped at **25 seconds** so Gateway/ALB cannot 504 a quiet org.
  Immediate return when a newer revision exists.
- Heartbeats stay out of band: a timed-out wait with no change is not a
  configuration update.
- Coalescing, replay window, and per-connection queue bounds belong in the
  implementation slices. Revoke and other terminal security state must not be
  coalesced away.
- No extra payload-encryption layer over TLS.

## Limits that stay explicit

- This record does not implement the stream, deltas, or metrics.
- Coordinator HA and store topology stay on #27. The stream must not invent
  a second source of truth.
- Cross-tenant cache keys remain forbidden. A revision is scoped to one
  organisation.
- Full snapshot recovery stays. Missing, gapped, or corrupt history falls
  back to one snapshot.
- Existing poll clients stay supported until an upgrade signal is shipped.

## Follow-up

Agents wait on `GET /v1/nodes/:id/updates` with the last applied revision
and reconnect after a 204 heartbeat. Protocol `version=2` may receive a
coalesced `{kind: delta, added, removed}` body when the coordinator still
has the node's last sent peer set; gapped, missing, or `version=1` history
falls back to one snapshot. `--poll-seconds` remains the recovery path.
In-memory views are capped at 10k nodes so a storm resynchronises with
snapshots rather than growing unbounded. 1k/10k CPU/latency baselines live
in [control-update-baselines.md](../control-update-baselines.md) and
`scripts/control-update-baseline.sh`. Keep the 25-second wait cap unless the
AWS lab path is changed and re-proven.
