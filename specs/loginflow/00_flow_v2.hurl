# Login Flow v2 happy path: init -> poll(pending) -> grant -> poll(once) -> poll(gone).
# Tokens are minted by the server and captured; never hard-coded.

# Seed a real user via the residual chassis auth (gives us known credentials).
POST {{host}}/api/users
{
  "user": {
    "username": "flow_{{uid}}",
    "email": "flow_{{uid}}@test.com",
    "password": "password123"
  }
}
HTTP 201

# 1. Initiate. User-Agent becomes the app-password name.
POST {{host}}/index.php/login/v2
User-Agent: lunet-test-client/0.1
HTTP 200
[Asserts]
jsonpath "$.poll.token" isString
jsonpath "$.poll.endpoint" contains "/login/v2/poll"
jsonpath "$.login" contains "/login/v2/flow?token="
[Captures]
poll_token: jsonpath "$.poll.token"
poll_endpoint: jsonpath "$.poll.endpoint"
login_token: jsonpath "$.login" regex "token=(.+)"

# 2. Poll before grant -> 404 pending.
POST {{host}}/login/v2/poll
[FormParams]
token: {{poll_token}}
HTTP 404

# 3. Grant: the browser page submits real creds + the login token.
POST {{host}}/login/v2/grant
[FormParams]
token: {{login_token}}
loginName: flow_{{uid}}
password: password123
HTTP 200

# 4. Poll after grant -> 200 exactly once, returns the app password.
POST {{host}}/login/v2/poll
[FormParams]
token: {{poll_token}}
HTTP 200
[Asserts]
jsonpath "$.server" isString
jsonpath "$.loginName" == "flow_{{uid}}"
jsonpath "$.appPassword" isString
jsonpath "$.appPassword" not isEmpty

# 5. Poll again -> 404 (one-time semantics; token consumed).
POST {{host}}/login/v2/poll
[FormParams]
token: {{poll_token}}
HTTP 404
