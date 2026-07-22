# OCS: self-only rule, required header, and format handling.

POST {{host}}/api/users
{
  "user": {
    "username": "ocsf_{{uid}}",
    "email": "ocsf_{{uid}}@test.com",
    "password": "password123"
  }
}
HTTP 201

POST {{host}}/index.php/login/v2
User-Agent: lunet-test-client/0.1
HTTP 200
[Captures]
poll_token: jsonpath "$.poll.token"
login_token: jsonpath "$.login" regex "token=(.+)"

POST {{host}}/login/v2/grant
[FormParams]
token: {{login_token}}
loginName: ocsf_{{uid}}
password: password123
HTTP 200

POST {{host}}/login/v2/poll
[FormParams]
token: {{poll_token}}
HTTP 200
[Captures]
login_name: jsonpath "$.loginName"
app_password: jsonpath "$.appPassword"

# Another user's details -> 403 (no admin role; default user is self-only).
GET {{host}}/ocs/v2.php/cloud/users/someone_else_{{uid}}?format=json
OCS-APIRequest: true
[BasicAuth]
{{login_name}}: {{app_password}}
HTTP 403
[Asserts]
jsonpath "$.ocs.meta.statuscode" == 403

# Missing OCS-APIRequest header -> 401 / 997.
GET {{host}}/ocs/v2.php/cloud/user?format=json
[BasicAuth]
{{login_name}}: {{app_password}}
HTTP 401
[Asserts]
jsonpath "$.ocs.meta.statuscode" == 997

# Unsupported format (xml is not in v0.1.0) -> 400 / 998.
GET {{host}}/ocs/v2.php/cloud/user?format=xml
OCS-APIRequest: true
[BasicAuth]
{{login_name}}: {{app_password}}
HTTP 400
[Asserts]
jsonpath "$.ocs.meta.statuscode" == 998
