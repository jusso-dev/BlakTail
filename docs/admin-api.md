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

`POST /oauth/token` accepts the OAuth 2.0 `client_credentials` grant. The
client id is the automation client UUID; the client secret is the shown-once
`bta_` token. Credentials may be sent as HTTP Basic or form fields. The
response access token is that same hashed secret, plus `organisation_id` so
callers can set `X-BlakTail-Organisation`. Requested `scope` must be empty or
a subset of the registered scopes; the token still carries the registered
set. Distinct short-lived access tokens remain later.

## Writes

- Policy PUT requires the current `etag`.
- `GET`/`PUT /api/v1/dns` publishes organisation DNS settings. Writes need
  `dns:write` and the current `etag`. `{"rollback": true}` restores the previous
  revision.
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

CI also runs an in-process Terraform/provider-style contract
(`admin_api_provider_contract_manages_device_lifecycle`) that mints a `bta_`
client, enrols a device from a minted key, renames it without changing the
WireGuard identity, publishes policy and DNS with etags, tombstones the device,
and proves a read-only token cannot write. `POST /oauth/token` issues the
same `bta_` secret for the `client_credentials` grant. Distinct short-lived
access tokens remain on #37.
