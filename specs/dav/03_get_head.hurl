# GET / HEAD — download bytes and metadata.

MKCOL {{host}}/remote.php/dav/files/{{user}}/get_{{uid}}
Authorization: Basic dGVzdDp4
HTTP 201

PUT {{host}}/remote.php/dav/files/{{user}}/get_{{uid}}/note.txt
Authorization: Basic dGVzdDp4
Content-Type: text/plain
```
hello
```
HTTP 201

# GET returns the exact bytes with content headers and OC-FileId.
GET {{host}}/remote.php/dav/files/{{user}}/get_{{uid}}/note.txt
Authorization: Basic dGVzdDp4
HTTP 200
[Asserts]
body == "hello\n"
header "Content-Type" contains "text/plain"
header "Content-Length" == "6"
header "OC-FileId" matches /^[0-9]{8}.+/
header "ETag" matches /^".*"$/

# HEAD is identical minus the body.
HEAD {{host}}/remote.php/dav/files/{{user}}/get_{{uid}}/note.txt
Authorization: Basic dGVzdDp4
HTTP 200
[Asserts]
header "Content-Length" == "6"

# Missing file -> 404.
GET {{host}}/remote.php/dav/files/{{user}}/get_{{uid}}/missing.txt
Authorization: Basic dGVzdDp4
HTTP 404

# Folder download (zip/tar) is out of scope for v0.1.0 -> 501.
GET {{host}}/remote.php/dav/files/{{user}}/get_{{uid}}
Authorization: Basic dGVzdDp4
Accept: application/zip
HTTP 501
