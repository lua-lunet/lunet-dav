# NextCloud Enterprise 31 — OCS API (user metadata) (reference notes)

> Sources:
> <https://docs.nextcloud.com/server/31/developer_manual/client_apis/OCS/ocs-api-overview.html>
> and the Provisioning API user pages.
> Captured 2026-07-20. Reference capture; our subset is in [`../SPEC-v0.1.0.md`](../SPEC-v0.1.0.md).

## Base paths & required header
- Base: `/ocs/v1.php/...` or `/ocs/v2.php/...`. We target **v2**.
- **Every** request must send header `OCS-APIRequest: true`.
- `?format=json` selects JSON (default is XML).
- Auth: HTTP Basic (username + password, or app password).

## Response envelope
```json
{ "ocs": {
    "meta": { "status": "ok", "statuscode": 200, "message": "OK" },
    "data": { ... }
} }
```
- v1 success `statuscode` = `100`; v2 success `statuscode` = `200`.
- Common failures: `997` not authenticated, `998` not found, `403` forbidden.
- In **v2** the HTTP status mirrors the OCS statuscode; in v1 the HTTP status is always 200.

## User endpoints
- `GET /ocs/v2.php/cloud/user` — the **authenticated user's own** metadata (no id in path).
- `GET /ocs/v2.php/cloud/users/{userid}` — a specific user. "Admin users can see the
  information of all users, while a default user only can access their own metadata."

## User fields (upstream, full set)
`id`, `enabled`, `displayname` / `display-name`, `email`, `phone`, `address`, `website`,
`twitter`, `groups`, `language`, `locale`, `storageLocation`, `lastLogin`, `backend`,
`quota` (nested `free`/`used`/`total`/`relative`/`quota`), `backendCapabilities`.
Most are `NOT IN v0.1.0` — see SPEC for the subset we can actually source from our
residual `users` table.
