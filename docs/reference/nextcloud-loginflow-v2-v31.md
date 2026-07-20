# NextCloud Enterprise 31 — Login Flow v2 (reference notes)

> Source: <https://docs.nextcloud.com/server/31/developer_manual/client_apis/LoginFlow/index.html>
> Captured 2026-07-20. Reference capture of upstream behaviour; our subset is in
> [`../SPEC-v0.1.0.md`](../SPEC-v0.1.0.md). `NOT IN v0.1.0` markers flag what we skip.

## Purpose
Lets a native app (iOS / Android / desktop) obtain an **app password** by having the user
authenticate in their **real system browser**, instead of the app handling the password.

## 1. Initiate
`POST /index.php/login/v2` — anonymous, no auth. `User-Agent` becomes the app-password name.
Response JSON:
```json
{
  "poll": { "token": "<poll-token>", "endpoint": "https://cloud.example/login/v2/poll" },
  "login": "https://cloud.example/login/v2/flow?token=<login-token>"
}
```
- `poll.token` — opaque token used when polling. ~20 minute validity.
- `poll.endpoint` — absolute URL the client POSTs to while polling.
- `login` — absolute URL the client opens in the **system browser** for the user.

## 2. User authenticates in browser
Client opens `login` in the native browser. The user enters their real credentials and
grants access. The server mints an **app password** bound to that user.

## 3. Poll for completion
`POST <poll.endpoint>` with body `token=<poll.token>` (form-encoded).
- **404 Not Found** — not completed yet (keep polling).
- **200 OK** — completed. Body returned **once**:
```json
{ "server": "https://cloud.example", "loginName": "<user>", "appPassword": "<app-password>" }
```
After a successful 200 the token is consumed; subsequent polls fail.

## 4. Use the credentials
All later requests use HTTP Basic auth: `Authorization: Basic base64(loginName:appPassword)`.
The app password can be revoked by the user later (independently of their real password).

## Login Flow v1 (legacy) — `NOT IN v0.1.0`
Opens `<server>/index.php/login/flow` in a webview with header `OCS-APIREQUEST: true`;
server redirects to a `nc://login/server:...&user:...&password:...` custom-scheme URL.
