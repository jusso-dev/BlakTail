# Observability live proof

- UTC: 2026-08-25T04:22:41Z
- Git: 751e90ab76aa12c6615110f56cfc8f1a77c9586d
- Coordinator /metrics: scraped on 127.0.0.1:19701 with diagnostics bearer; unauthenticated 401
- Relay /metrics: scraped on 127.0.0.1:19702 with diagnostics bearer; unauthenticated 401
- Public TLS listener /metrics: 404
- Public /livez and /readyz: status only
- Metric labels: no org/node/user/DNS/IP identifiers

Coordinator sample:

```
# HELP blaktail_coord_requests_total Coordinator API requests by operation and result.
# TYPE blaktail_coord_requests_total counter
# HELP blaktail_coord_request_duration_seconds Coordinator API request latency.
# TYPE blaktail_coord_request_duration_seconds histogram
blaktail_coord_requests_total{operation="register",result="success"} 0
blaktail_coord_requests_total{operation="register",result="error"} 0
blaktail_coord_request_duration_seconds_bucket{operation="register",le="0.005"} 0
blaktail_coord_request_duration_seconds_bucket{operation="register",le="0.01"} 0
blaktail_coord_request_duration_seconds_bucket{operation="register",le="0.025"} 0
blaktail_coord_request_duration_seconds_bucket{operation="register",le="0.05"} 0
blaktail_coord_request_duration_seconds_bucket{operation="register",le="0.1"} 0
blaktail_coord_request_duration_seconds_bucket{operation="register",le="0.25"} 0
blaktail_coord_request_duration_seconds_bucket{operation="register",le="0.5"} 0
blaktail_coord_request_duration_seconds_bucket{operation="register",le="1"} 0
blaktail_coord_request_duration_seconds_bucket{operation="register",le="2.5"} 0
blaktail_coord_request_duration_seconds_bucket{operation="register",le="5"} 0
blaktail_coord_request_duration_seconds_bucket{operation="register",le="+Inf"} 0
blaktail_coord_request_duration_seconds_sum{operation="register"} 0.000000
blaktail_coord_request_duration_seconds_count{operation="register"} 0
blaktail_coord_requests_total{operation="peers",result="success"} 0
```

Relay sample:

```
# TYPE blaktail_relay_registers_total counter
blaktail_relay_registers_total{result="ok"} 0
blaktail_relay_registers_total{result="rejected"} 0
# TYPE blaktail_relay_forwards_total counter
blaktail_relay_forwards_total 0
# TYPE blaktail_relay_bytes_total counter
blaktail_relay_bytes_total 0
# TYPE blaktail_relay_dropped_total counter
blaktail_relay_dropped_total{reason="unknown_destination"} 0
blaktail_relay_dropped_total{reason="rate_limited"} 0
blaktail_relay_dropped_total{reason="oversized"} 0
```
