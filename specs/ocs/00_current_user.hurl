# OCS: a user reads their own metadata. Self-contained: register -> Login Flow v2 to mint
# an app password -> OCS with Basic auth (loginName:appPassword).

POST {{host}}/api/users
{
  "user": {
    "username": "ocs_{{uid}}",
    "email": "ocs_{{uid}}@test.com",
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
loginName: ocs_{{uid}}
password: password123
HTTP 200

POST {{host}}/login/v2/poll
[FormParams]
token: {{poll_token}}
HTTP 200
[Captures]
login_name: jsonpath "$.loginName"
app_password: jsonpath "$.appPassword"

# Current user's own details via app-password Basic auth.
GET {{host}}/ocs/v2.php/cloud/user?format=json
OCS-APIRequest: true
[BasicAuth]
{{login_name}}: {{app_password}}
HTTP 200
[Asserts]
jsonpath "$.ocs.meta.status" == "ok"
jsonpath "$.ocs.meta.statuscode" == 200
jsonpath "$.ocs.data.id" == "ocs_{{uid}}"
jsonpath "$.ocs.data['display-name']" == "ocs_{{uid}}"
jsonpath "$.ocs.data.email" == "ocs_{{uid}}@test.com"
jsonpath "$.ocs.data.enabled" == true
jsonpath "$.ocs.data.quota.quota" == -3

# Fetching self by explicit userid is allowed.
GET {{host}}/ocs/v2.php/cloud/users/ocs_{{uid}}?format=json
OCS-APIRequest: true
[BasicAuth]
{{login_name}}: {{app_password}}
HTTP 200
[Asserts]
jsonpath "$.ocs.data.id" == "ocs_{{uid}}"
