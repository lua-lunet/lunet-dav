# MOVE — rename / move keeps the same OC-FileId (inode semantics).

MKCOL {{host}}/remote.php/dav/files/{{user}}/mv_{{uid}}
Authorization: Basic dGVzdDp4
HTTP 201

MKCOL {{host}}/remote.php/dav/files/{{user}}/mv2_{{uid}}
Authorization: Basic dGVzdDp4
HTTP 201

PUT {{host}}/remote.php/dav/files/{{user}}/mv_{{uid}}/orig.txt
Authorization: Basic dGVzdDp4
```
hello
```
HTTP 201
[Captures]
orig_fileid: header "OC-FileId"

# Rename within the same collection -> 201, same OC-FileId.
MOVE {{host}}/remote.php/dav/files/{{user}}/mv_{{uid}}/orig.txt
Authorization: Basic dGVzdDp4
Destination: {{host}}/remote.php/dav/files/{{user}}/mv_{{uid}}/renamed.txt
HTTP 201
[Asserts]
header "OC-FileId" == "{{orig_fileid}}"

# Move to another collection -> 201, still the same OC-FileId.
MOVE {{host}}/remote.php/dav/files/{{user}}/mv_{{uid}}/renamed.txt
Authorization: Basic dGVzdDp4
Destination: {{host}}/remote.php/dav/files/{{user}}/mv2_{{uid}}/renamed.txt
HTTP 201
[Asserts]
header "OC-FileId" == "{{orig_fileid}}"

# The source no longer exists.
GET {{host}}/remote.php/dav/files/{{user}}/mv_{{uid}}/renamed.txt
Authorization: Basic dGVzdDp4
HTTP 404

# Set up an overwrite-target collision.
PUT {{host}}/remote.php/dav/files/{{user}}/mv2_{{uid}}/target.txt
Authorization: Basic dGVzdDp4
```
existing
```
HTTP 201

PUT {{host}}/remote.php/dav/files/{{user}}/mv_{{uid}}/src.txt
Authorization: Basic dGVzdDp4
```
newer
```
HTTP 201

# Overwrite: F onto an existing destination -> 412 Precondition Failed.
MOVE {{host}}/remote.php/dav/files/{{user}}/mv_{{uid}}/src.txt
Authorization: Basic dGVzdDp4
Destination: {{host}}/remote.php/dav/files/{{user}}/mv2_{{uid}}/target.txt
Overwrite: F
HTTP 412

# Overwrite (default T) onto the existing destination -> 204.
MOVE {{host}}/remote.php/dav/files/{{user}}/mv_{{uid}}/src.txt
Authorization: Basic dGVzdDp4
Destination: {{host}}/remote.php/dav/files/{{user}}/mv2_{{uid}}/target.txt
Overwrite: T
HTTP 204

# Move into a reserved collection -> 403.
PUT {{host}}/remote.php/dav/files/{{user}}/mv_{{uid}}/reserve.txt
Authorization: Basic dGVzdDp4
```
z
```
HTTP 201

MOVE {{host}}/remote.php/dav/files/{{user}}/mv_{{uid}}/reserve.txt
Authorization: Basic dGVzdDp4
Destination: {{host}}/remote.php/dav/files/{{user}}/_sys_{{uid}}/reserve.txt
HTTP 403

# Self-MOVE with default Overwrite (T) -> 409, file must remain intact.
PUT {{host}}/remote.php/dav/files/{{user}}/mv_{{uid}}/selftest.txt
Authorization: Basic dGVzdDp4
```
selfmove-bytes
```
HTTP 201

MOVE {{host}}/remote.php/dav/files/{{user}}/mv_{{uid}}/selftest.txt
Authorization: Basic dGVzdDp4
Destination: {{host}}/remote.php/dav/files/{{user}}/mv_{{uid}}/selftest.txt
HTTP 409

GET {{host}}/remote.php/dav/files/{{user}}/mv_{{uid}}/selftest.txt
Authorization: Basic dGVzdDp4
HTTP 200
[Asserts]
body == "selfmove-bytes\n"

# Self-MOVE with Overwrite: F -> 412, file intact.
MOVE {{host}}/remote.php/dav/files/{{user}}/mv_{{uid}}/selftest.txt
Authorization: Basic dGVzdDp4
Destination: {{host}}/remote.php/dav/files/{{user}}/mv_{{uid}}/selftest.txt
Overwrite: F
HTTP 412

GET {{host}}/remote.php/dav/files/{{user}}/mv_{{uid}}/selftest.txt
Authorization: Basic dGVzdDp4
HTTP 200
[Asserts]
body == "selfmove-bytes\n"
