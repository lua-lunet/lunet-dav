# DELETE — file and recursive collection delete.

MKCOL {{host}}/remote.php/dav/files/{{user}}/del_{{uid}}
Authorization: Basic dGVzdDp4
HTTP 201

PUT {{host}}/remote.php/dav/files/{{user}}/del_{{uid}}/a.txt
Authorization: Basic dGVzdDp4
```
hello
```
HTTP 201

# Delete a file -> 204.
DELETE {{host}}/remote.php/dav/files/{{user}}/del_{{uid}}/a.txt
Authorization: Basic dGVzdDp4
HTTP 204

# It is gone.
GET {{host}}/remote.php/dav/files/{{user}}/del_{{uid}}/a.txt
Authorization: Basic dGVzdDp4
HTTP 404

# Delete a missing resource -> 404.
DELETE {{host}}/remote.php/dav/files/{{user}}/del_{{uid}}/a.txt
Authorization: Basic dGVzdDp4
HTTP 404

# Recursive collection delete -> 204, then children are gone.
PUT {{host}}/remote.php/dav/files/{{user}}/del_{{uid}}/b.txt
Authorization: Basic dGVzdDp4
```
child
```
HTTP 201

DELETE {{host}}/remote.php/dav/files/{{user}}/del_{{uid}}
Authorization: Basic dGVzdDp4
HTTP 204

PROPFIND {{host}}/remote.php/dav/files/{{user}}/del_{{uid}}
Authorization: Basic dGVzdDp4
Depth: 0
HTTP 404
