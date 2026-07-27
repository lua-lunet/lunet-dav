# PROPFIND — 207 multistatus. XPath asserts use local-name() to avoid namespace binding.

MKCOL {{host}}/remote.php/dav/files/{{user}}/pf_{{uid}}
Authorization: Basic dGVzdDp4
HTTP 201

PUT {{host}}/remote.php/dav/files/{{user}}/pf_{{uid}}/a.txt
Authorization: Basic dGVzdDp4
Content-Type: text/plain
```
hello
```
HTTP 201

# Depth 0 on a file -> one response with the requested props.
PROPFIND {{host}}/remote.php/dav/files/{{user}}/pf_{{uid}}/a.txt
Authorization: Basic dGVzdDp4
Depth: 0
Content-Type: application/xml
```xml
<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
  <d:prop>
    <d:getcontentlength/>
    <d:getcontenttype/>
    <d:getetag/>
    <d:resourcetype/>
    <oc:id/>
    <oc:fileid/>
    <oc:checksums/>
  </d:prop>
</d:propfind>
```
HTTP 207
[Asserts]
header "Content-Type" contains "xml"
xpath "count(//*[local-name()='response'])" == 1
xpath "string(//*[local-name()='href'])" == "/remote.php/dav/files/{{user}}/pf_{{uid}}/a.txt"
xpath "string(//*[local-name()='getcontentlength'])" == "6"
xpath "string(//*[local-name()='getcontenttype'])" contains "text/plain"
xpath "string(//*[local-name()='id'])" matches /^[0-9]{8}.+/
xpath "string(//*[local-name()='fileid'])" matches /^[0-9]+$/
xpath "string(//*[local-name()='checksums'])" contains "SHA-256:5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"

# Depth 1 on the collection -> the collection plus its one child = 2 responses.
PROPFIND {{host}}/remote.php/dav/files/{{user}}/pf_{{uid}}
Authorization: Basic dGVzdDp4
Depth: 1
Content-Type: application/xml
```xml
<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:resourcetype/>
    <d:displayname/>
    <d:quota-available-bytes/>
  </d:prop>
</d:propfind>
```
HTTP 207
[Asserts]
xpath "count(//*[local-name()='response'])" == 2
xpath "string((//*[local-name()='href'])[1])" == "/remote.php/dav/files/{{user}}/pf_{{uid}}/"
xpath "string((//*[local-name()='href'])[2])" == "/remote.php/dav/files/{{user}}/pf_{{uid}}/a.txt"
xpath "boolean(//*[local-name()='collection'])" == true
xpath "string((//*[local-name()='quota-available-bytes'])[1])" == "-3"

# getlastmodified is an HTTP-date (RFC 7231) on files.
PROPFIND {{host}}/remote.php/dav/files/{{user}}/pf_{{uid}}/a.txt
Authorization: Basic dGVzdDp4
Depth: 0
Content-Type: application/xml
```xml
<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:getlastmodified/>
    <d:creationdate/>
    <d:getetag/>
  </d:prop>
</d:propfind>
```
HTTP 207
[Asserts]
xpath "string(//*[local-name()='getlastmodified'])" matches /^[A-Z][a-z]{2}, [0-9]{2} [A-Z][a-z]{2} [0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2} GMT$/
xpath "string(//*[local-name()='creationdate'])" matches /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/

# Unknown prop -> 404 propstat echoing the prop.
PROPFIND {{host}}/remote.php/dav/files/{{user}}/pf_{{uid}}/a.txt
Authorization: Basic dGVzdDp4
Depth: 0
Content-Type: application/xml
```xml
<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:" xmlns:custom="http://example.com/ns">
  <d:prop>
    <d:getetag/>
    <custom:made-up/>
  </d:prop>
</d:propfind>
```
HTTP 207
[Asserts]
xpath "string(//*[local-name()='getetag'])" != ""
xpath "count(//d:propstat[d:status='HTTP/1.1 404 Not Found'])" >= 1

# Two unknown namespace URIs -> both echoed in 404 propstat with declared xmlns:xN.
PROPFIND {{host}}/remote.php/dav/files/{{user}}/pf_{{uid}}/a.txt
Authorization: Basic dGVzdDp4
Depth: 0
Content-Type: application/xml
```xml
<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:" xmlns:ua="http://example.test/a" xmlns:ub="http://example.test/b">
  <d:prop>
    <d:getetag/>
    <ua:alpha-prop/>
    <ub:beta-prop/>
  </d:prop>
</d:propfind>
```
HTTP 207
[Asserts]
xpath "string(//*[local-name()='getetag'])" != ""
xpath "count(//d:propstat[d:status='HTTP/1.1 404 Not Found'])" >= 1
xpath "count(//*[local-name()='alpha-prop'])" >= 1
xpath "count(//*[local-name()='beta-prop'])" >= 1

# Depth: infinity is rejected in the flat namespace -> 403.
PROPFIND {{host}}/remote.php/dav/files/{{user}}/pf_{{uid}}
Authorization: Basic dGVzdDp4
Depth: infinity
HTTP 403

# PROPFIND on a missing resource -> 404.
PROPFIND {{host}}/remote.php/dav/files/{{user}}/pf_{{uid}}/missing.txt
Authorization: Basic dGVzdDp4
Depth: 0
HTTP 404
