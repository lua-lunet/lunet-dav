# Cross-cutting error contract (status codes summarised in docs/SPEC-v0.1.0.md).

# GET on a path with no resource -> 404.
GET {{host}}/remote.php/dav/files/{{user}}/err_{{uid}}/ghost.txt
Authorization: Basic dGVzdDp4
HTTP 404

# PROPFIND on a missing collection -> 404.
PROPFIND {{host}}/remote.php/dav/files/{{user}}/err_{{uid}}
Authorization: Basic dGVzdDp4
Depth: 1
HTTP 404

# Nested MKCOL -> 409.
MKCOL {{host}}/remote.php/dav/files/{{user}}/err_a_{{uid}}/err_b
Authorization: Basic dGVzdDp4
HTTP 409

# COPY anywhere -> 409 (unsupported by design).
MKCOL {{host}}/remote.php/dav/files/{{user}}/err_{{uid}}
Authorization: Basic dGVzdDp4
HTTP 201

PUT {{host}}/remote.php/dav/files/{{user}}/err_{{uid}}/a.txt
Authorization: Basic dGVzdDp4
```
hello
```
HTTP 201

COPY {{host}}/remote.php/dav/files/{{user}}/err_{{uid}}/a.txt
Authorization: Basic dGVzdDp4
Destination: {{host}}/remote.php/dav/files/{{user}}/err_{{uid}}/b.txt
HTTP 409

# Reserved-prefix MKCOL -> 403.
MKCOL {{host}}/remote.php/dav/files/{{user}}/_reserved_{{uid}}
Authorization: Basic dGVzdDp4
HTTP 403
