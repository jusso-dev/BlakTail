# Admin API versioning

The public automation contract is `/api/v1`. It is distinct from node protocol
routes and from console HMAC assertions.

## Compatibility

- Additive fields, endpoints, and optional headers stay inside `/api/v1`.
- Breaking changes get a new major path (`/api/v2`) and a documented deprecation
  window on the previous version.
- OpenAPI lives at [openapi/admin-v1.yaml](openapi/admin-v1.yaml).

## Credentials

Owners mint `bta_` tokens in Settings. Secrets are shown once and stored as
SHA-256 hashes. Send `Authorization: Bearer bta_…` and
`X-BlakTail-Organisation`. Node tokens, join keys, and anonymous callers are
rejected.

## Writes

- Policy PUT requires the current `etag`.
- `POST /api/v1/keys` honours `Idempotency-Key` (8–128 characters). Reusing a
  key with a different body returns `409`.
- Request bodies are rejected above 64 KiB (`413`).
- Each `bta_` client is limited to 120 requests per 60-second window (`429`).
- Errors use `{ error, code, message, request_id }`.
- CI runs `scripts/admin-openapi-drift.sh` so `docs/openapi/admin-v1.yaml`
  stays aligned with `api_routes()` in `blaktail-coord`.

A disposable smoke against a running coordinator:

```sh
scripts/admin-api-smoke.sh https://coord.example ORG_UUID bta_token
```
