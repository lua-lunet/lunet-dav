# lnt: private debug namespace (UNSTABLE) — surfaces internal table state.
# http://lunet.stenographer.cloud/ns. Not a stable API; for debugging only.

MKCOL {{host}}/remote.php/dav/files/{{user}}/lnt_{{uid}}
Authorization: Basic dGVzdDp4
HTTP 201

PUT {{host}}/remote.php/dav/files/{{user}}/lnt_{{uid}}/a.txt
Authorization: Basic dGVzdDp4
Content-Type: text/plain
```
hello
```
HTTP 201

# Debug props expose sha256, S3 version id, CAS version, and the full op-log JSON.
PROPFIND {{host}}/remote.php/dav/files/{{user}}/lnt_{{uid}}/a.txt
Authorization: Basic dGVzdDp4
Depth: 0
Content-Type: application/xml
```xml
<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:" xmlns:lnt="http://lunet.stenographer.cloud/ns">
  <d:prop>
    <lnt:sha256/>
    <lnt:s3-version-id/>
    <lnt:cas-version/>
    <lnt:oplog/>
  </d:prop>
</d:propfind>
```
HTTP 207
[Asserts]
xpath "string(//*[local-name()='sha256'])" == "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"
xpath "string(//*[local-name()='cas-version'])" matches /^[0-9]+$/
xpath "string(//*[local-name()='oplog'])" contains "put"
