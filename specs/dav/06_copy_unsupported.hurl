# COPY — not implemented in v0.1.0.

MKCOL {{host}}/remote.php/dav/files/{{user}}/cp_{{uid}}
Authorization: Basic dGVzdDp4
HTTP 201

PUT {{host}}/remote.php/dav/files/{{user}}/cp_{{uid}}/a.txt
Authorization: Basic dGVzdDp4
```
hello
```
HTTP 201

# COPY -> 409 Conflict with a DAV error document explaining the refusal.
COPY {{host}}/remote.php/dav/files/{{user}}/cp_{{uid}}/a.txt
Authorization: Basic dGVzdDp4
Destination: {{host}}/remote.php/dav/files/{{user}}/cp_{{uid}}/b.txt
HTTP 409
[Asserts]
xpath "boolean(//*[local-name()='error'])" == true
xpath "string(//*[local-name()='message'])" contains "not implemented"
