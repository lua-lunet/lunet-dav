# PUT response header policy (docs/DESIGN.md §8).
# Runs ONLY against a server started with:
#   S3_API_PROFILE=minio
#   DAV_EMIT_HASH_HEADER=always
#   DAV_PUT_PASSTHROUGH_HEADERS=x-amz-version-id,x-amz-checksum-sha256
# (the e2e second pass — see e2e/run-e2e.sh). It is NOT part of the default
# compat glob: under default behavior these assertions fail by design.
#
# Bodies embed {{uid}} so every first upload is a guaranteed-fresh PutObject:
# content stored by an earlier lcd-profile run has no upstream checksum to
# harvest, so exact assertions are made via captures within this file.

MKCOL {{host}}/remote.php/dav/files/{{user}}/hdr_{{uid}}
Authorization: Basic dGVzdDp4
HTTP 201

# Fresh upload: hash header emitted without being asked (mode=always); the
# upstream checksum + version id harvested from the real MinIO exchange are
# passed through verbatim.
PUT {{host}}/remote.php/dav/files/{{user}}/hdr_{{uid}}/hello.txt
Authorization: Basic dGVzdDp4
Content-Type: text/plain
```
cfg-{{uid}}-hello
```
HTTP 201
[Asserts]
header "OC-FileId" matches /^[0-9]{8}.+/
header "X-Hash-SHA256" matches /^[0-9a-f]{64}$/
header "x-amz-version-id" exists
header "x-amz-checksum-sha256" matches /^[A-Za-z0-9+\/]+={0,2}$/
[Captures]
first_fileid: header "OC-FileId"
sum1: header "x-amz-checksum-sha256"
hash1: header "X-Hash-SHA256"

# Overwrite with new content -> 204, same OC-FileId; the fresh PutObject
# harvests the new content's checksum (which differs from the first).
PUT {{host}}/remote.php/dav/files/{{user}}/hdr_{{uid}}/hello.txt
Authorization: Basic dGVzdDp4
Content-Type: text/plain
```
cfg-{{uid}}-goodbye
```
HTTP 204
[Asserts]
header "OC-FileId" == "{{first_fileid}}"
header "X-Hash-SHA256" matches /^[0-9a-f]{64}$/
header "X-Hash-SHA256" != "{{hash1}}"
header "x-amz-version-id" exists
header "x-amz-checksum-sha256" matches /^[A-Za-z0-9+\/]+={0,2}$/
header "x-amz-checksum-sha256" != "{{sum1}}"
[Captures]
sum2: header "x-amz-checksum-sha256"

# Same bytes as the first upload at a different path -> content reuse (no
# PutObject). The persisted upstream checksum rides the reused locator, so
# passthrough is identical to the fresh harvest.
MKCOL {{host}}/remote.php/dav/files/{{user}}/hdr2_{{uid}}
Authorization: Basic dGVzdDp4
HTTP 201

PUT {{host}}/remote.php/dav/files/{{user}}/hdr2_{{uid}}/copy.txt
Authorization: Basic dGVzdDp4
Content-Type: text/plain
```
cfg-{{uid}}-hello
```
HTTP 201
[Asserts]
header "X-Hash-SHA256" == "{{hash1}}"
header "x-amz-version-id" exists
header "x-amz-checksum-sha256" == "{{sum1}}"

# The harvested checksum is also visible in PROPFIND via the lnt debug prop
# (here: the overwritten file's second checksum).
PROPFIND {{host}}/remote.php/dav/files/{{user}}/hdr_{{uid}}/hello.txt
Authorization: Basic dGVzdDp4
Depth: 0
Content-Type: application/xml
```xml
<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:" xmlns:lnt="http://lunet.stenographer.cloud/ns"><d:prop><lnt:upstream-checksum/></d:prop></d:propfind>
```
HTTP 207
[Asserts]
xpath "string(//*[local-name()='upstream-checksum'])" == "{{sum2}}"
