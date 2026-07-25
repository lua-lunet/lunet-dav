# PUT — upload creates content-addressed objects and returns nc headers.

# Parent collection for these uploads.
MKCOL {{host}}/remote.php/dav/files/{{user}}/put_{{uid}}
Authorization: Basic dGVzdDp4
HTTP 201

# New file -> 201 Created, with OC-FileId (<8-digit><instance-id>) and OC-Etag.
# X-Hash: sha256 request -> X-Hash-SHA256 echoed. Body "hello\n" has a known sha256.
PUT {{host}}/remote.php/dav/files/{{user}}/put_{{uid}}/hello.txt
Authorization: Basic dGVzdDp4
X-Hash: sha256
X-OC-MTime: 1675789581
Content-Type: text/plain
```
hello
```
HTTP 201
[Asserts]
header "OC-FileId" matches /^[0-9]{8}.+/
header "OC-Etag" matches /^".*"$/
header "X-Hash-SHA256" == "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"
header "X-OC-MTime" == "accepted"
[Captures]
first_fileid: header "OC-FileId"

# Overwrite the same path with new content -> 204, SAME OC-FileId (inode semantics).
PUT {{host}}/remote.php/dav/files/{{user}}/put_{{uid}}/hello.txt
Authorization: Basic dGVzdDp4
Content-Type: text/plain
```
goodbye
```
HTTP 204
[Asserts]
header "OC-FileId" == "{{first_fileid}}"

# PUT identical bytes to a SECOND path in the same collection -> 201 (content reuse).
PUT {{host}}/remote.php/dav/files/{{user}}/put_{{uid}}/hello2.txt
Authorization: Basic dGVzdDp4
Content-Type: text/plain
```
goodbye
```
HTTP 201

# The second path must carry a non-empty S3 version id (locator preserved on reuse).
PROPFIND {{host}}/remote.php/dav/files/{{user}}/put_{{uid}}/hello2.txt
Authorization: Basic dGVzdDp4
Depth: 0
Content-Type: application/xml
```xml
<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:" xmlns:lnt="http://lunet.stenographer.cloud/ns">
  <d:prop>
    <lnt:s3-version-id/>
  </d:prop>
</d:propfind>
```
HTTP 207
[Asserts]
xpath "string(//*[local-name()='s3-version-id'])" != ""

# Re-PUT same bytes to the SAME first path again -> 204 (overwrite with reused content).
PUT {{host}}/remote.php/dav/files/{{user}}/put_{{uid}}/hello.txt
Authorization: Basic dGVzdDp4
Content-Type: text/plain
```
goodbye
```
HTTP 204

# The first path must STILL carry a non-empty S3 version id (no clobber on same-path re-PUT).
PROPFIND {{host}}/remote.php/dav/files/{{user}}/put_{{uid}}/hello.txt
Authorization: Basic dGVzdDp4
Depth: 0
Content-Type: application/xml
```xml
<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:" xmlns:lnt="http://lunet.stenographer.cloud/ns">
  <d:prop>
    <lnt:s3-version-id/>
  </d:prop>
</d:propfind>
```
HTTP 207
[Asserts]
xpath "string(//*[local-name()='s3-version-id'])" != ""

# PUT into a non-existent collection -> 409 Conflict.
PUT {{host}}/remote.php/dav/files/{{user}}/nope_{{uid}}/x.txt
Authorization: Basic dGVzdDp4
```
x
```
HTTP 409

# PUT nested more than one level deep -> 409 Conflict.
PUT {{host}}/remote.php/dav/files/{{user}}/put_{{uid}}/sub/x.txt
Authorization: Basic dGVzdDp4
```
x
```
HTTP 409
