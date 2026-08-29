# Control-update CPU and latency baselines

These numbers are the first published 1k / 10k baseline for #43. They measure
an in-process coordinator (`Store::memory`, SQLite) serving
`GET /v1/nodes/:id/updates?wait=0&version=2`. One authenticated observer
connection receives a full snapshot, then a one-peer add as a coalesced
delta. There is no high-cardinality label.

Run:

```sh
scripts/control-update-baseline.sh
```

Both cases run in CI. A storm that fills the 10k in-memory view cap drops
baselines so the next poll is a snapshot rather than an unbounded delta
history. Concurrent waiters on a quiet revision return 204 within the wait
cap. A laptop debug run on 2026-08-28 printed:

| Nodes | Snapshot ms | Snapshot bytes | Peers in snapshot | Delta ms | Delta bytes | Connections |
| --- | --- | --- | --- | --- | --- | --- |
| 1001 (1 observer + 1000 peers) | 38 | 260976 | 1000 | 22 | 684 | 1 |
| 10001 (1 observer + 10000 peers) | 185 | 2613807 | 10000 | 108 | 687 | 1 |

CPU and RSS are the `time` / `ps` samples printed by the script around the
10k case. Re-run on the target host before treating a later change as a
regression; these rows are a starting envelope, not a SLA.
