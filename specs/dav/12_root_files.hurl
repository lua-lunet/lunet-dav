# Root-level files, percent-decoded paths, Last-Modified, X-OC-CTime.

# PUT a root-level file with a percent-encoded name -> 201.
PUT {{host}}/remote.php/dav/files/{{user}}/My%20File.txt
Authorization: Basic dGVzdDp4
Content-Type: text/plain
```
root-bytes
```
HTTP 201
[Asserts]
header "OC-FileId" matches /^[0-9]{8}.+/
header "OC-Etag" matches /^".*"$/

# GET the same root file -> 200 with exact bytes and Last-Modified.
GET {{host}}/remote.php/dav/files/{{user}}/My%20File.txt
Authorization: Basic dGVzdDp4
HTTP 200
[Asserts]
body == "root-bytes\n"
header "Content-Length" == "11"
header "Last-Modified" matches /^[A-Z][a-z]{2}, [0-9]{2} [A-Z][a-z]{2} [0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2} GMT$/

# HEAD same -> Last-Modified present, no body.
HEAD {{host}}/remote.php/dav/files/{{user}}/My%20File.txt
Authorization: Basic dGVzdDp4
HTTP 200
[Asserts]
header "Content-Length" == "11"
header "Last-Modified" matches /^[A-Z][a-z]{2}, [0-9]{2} [A-Z][a-z]{2} [0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2} GMT$/

# PROPFIND Depth 0 on root file -> displayname is decoded name, href is percent-encoded.
PROPFIND {{host}}/remote.php/dav/files/{{user}}/My%20File.txt
Authorization: Basic dGVzdDp4
Depth: 0
Content-Type: application/xml
```xml
<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:displayname/>
    <d:getcontentlength/>
    <d:resourcetype/>
  </d:prop>
</d:propfind>
```
HTTP 207
[Asserts]
xpath "count(//*[local-name()='response'])" == 1
xpath "string(//*[local-name()='href'])" == "/remote.php/dav/files/{{user}}/My%20File.txt"
xpath "string(//*[local-name()='displayname'])" == "My File.txt"
xpath "string(//*[local-name()='getcontentlength'])" == "11"

# PROPFIND root Depth 1 -> lists the root file among root entries.
PROPFIND {{host}}/remote.php/dav/files/{{user}}/
Authorization: Basic dGVzdDp4
Depth: 1
Content-Type: application/xml
```xml
<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:displayname/>
    <d:resourcetype/>
  </d:prop>
</d:propfind>
```
HTTP 207
[Asserts]
xpath "count(//*[local-name()='response'])" >= 2

# Root file + root collection coexistence: create collection "docs_{{uid}}" and file "note_{{uid}}.txt".
MKCOL {{host}}/remote.php/dav/files/{{user}}/docs_{{uid}}
Authorization: Basic dGVzdDp4
HTTP 201

PUT {{host}}/remote.php/dav/files/{{user}}/note_{{uid}}.txt
Authorization: Basic dGVzdDp4
Content-Type: text/plain
```
note
```
HTTP 201

# PROPFIND root Depth 1 -> both the collection and the file appear.
PROPFIND {{host}}/remote.php/dav/files/{{user}}/
Authorization: Basic dGVzdDp4
Depth: 1
Content-Type: application/xml
```xml
<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:displayname/>
    <d:resourcetype/>
  </d:prop>
</d:propfind>
```
HTTP 207
[Asserts]
xpath "count(//*[local-name()='response'])" >= 3

# MKCOL with same name as existing root file -> 405 (file occupies the name).
MKCOL {{host}}/remote.php/dav/files/{{user}}/My%20File.txt
Authorization: Basic dGVzdDp4
HTTP 405

# PUT with X-OC-CTime -> echoed as accepted.
PUT {{host}}/remote.php/dav/files/{{user}}/note_{{uid}}.txt
Authorization: Basic dGVzdDp4
X-OC-CTime: 1675789581
Content-Type: text/plain
```
updated-note
```
HTTP 204
[Asserts]
header "X-OC-CTime" == "accepted"

# DELETE root file -> 204.
DELETE {{host}}/remote.php/dav/files/{{user}}/My%20File.txt
Authorization: Basic dGVzdDp4
HTTP 204

# It is gone.
GET {{host}}/remote.php/dav/files/{{user}}/My%20File.txt
Authorization: Basic dGVzdDp4
HTTP 404

# Cleanup.
DELETE {{host}}/remote.php/dav/files/{{user}}/docs_{{uid}}
Authorization: Basic dGVzdDp4
HTTP 204

DELETE {{host}}/remote.php/dav/files/{{user}}/note_{{uid}}.txt
Authorization: Basic dGVzdDp4
HTTP 204
