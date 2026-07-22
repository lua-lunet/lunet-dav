# Login Flow v2 error contract.

POST {{host}}/api/users
{
  "user": {
    "username": "flowerr_{{uid}}",
    "email": "flowerr_{{uid}}@test.com",
    "password": "password123"
  }
}
HTTP 201

POST {{host}}/index.php/login/v2
User-Agent: lunet-test-client/0.1
HTTP 200
[Captures]
login_token: jsonpath "$.login" regex "token=(.+)"

# Grant with wrong password -> 403.
POST {{host}}/login/v2/grant
[FormParams]
token: {{login_token}}
loginName: flowerr_{{uid}}
password: wrong-password
HTTP 403

# Grant with an unknown login token -> 404.
POST {{host}}/login/v2/grant
[FormParams]
token: nonexistent-login-token
loginName: flowerr_{{uid}}
password: password123
HTTP 404

# Poll with an unknown token -> 404.
POST {{host}}/login/v2/poll
[FormParams]
token: nonexistent-poll-token
HTTP 404
