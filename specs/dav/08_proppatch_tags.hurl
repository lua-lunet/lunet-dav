# PROPPATCH — tags only (set folding into info.tags). Favourite is out of scope -> 403 propstat.

MKCOL {{host}}/remote.php/dav/files/{{user}}/tag_{{uid}}
Authorization: Basic dGVzdDp4
HTTP 201

PUT {{host}}/remote.php/dav/files/{{user}}/tag_{{uid}}/a.txt
Authorization: Basic dGVzdDp4
```
hello
```
HTTP 201

# Set two tags -> appends set-label ops, 200 propstat.
PROPPATCH {{host}}/remote.php/dav/files/{{user}}/tag_{{uid}}/a.txt
Authorization: Basic dGVzdDp4
Content-Type: application/xml
```xml
<?xml version="1.0"?>
<d:propertyupdate xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:set><d:prop>
    <oc:tags><oc:tag>red</oc:tag><oc:tag>urgent</oc:tag></oc:tags>
  </d:prop></d:set>
</d:propertyupdate>
```
HTTP 207
[Asserts]
xpath "string(//*[local-name()='status'])" contains "200"

# PROPFIND reads the materialized tag set (order-independent membership).
PROPFIND {{host}}/remote.php/dav/files/{{user}}/tag_{{uid}}/a.txt
Authorization: Basic dGVzdDp4
Depth: 0
Content-Type: application/xml
```xml
<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:prop><oc:tags/></d:prop></d:propfind>
```
HTTP 207
[Asserts]
xpath "string(//*[local-name()='tags'])" contains "red"
xpath "string(//*[local-name()='tags'])" contains "urgent"

# Removing a tag appends unset-label and drops it from the stored set.
PROPPATCH {{host}}/remote.php/dav/files/{{user}}/tag_{{uid}}/a.txt
Authorization: Basic dGVzdDp4
Content-Type: application/xml
```xml
<?xml version="1.0"?>
<d:propertyupdate xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:set><d:prop><oc:tags><oc:tag>red</oc:tag></oc:tags></d:prop></d:set>
</d:propertyupdate>
```
HTTP 207

PROPFIND {{host}}/remote.php/dav/files/{{user}}/tag_{{uid}}/a.txt
Authorization: Basic dGVzdDp4
Depth: 0
Content-Type: application/xml
```xml
<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:prop><oc:tags/></d:prop></d:propfind>
```
HTTP 207
[Asserts]
xpath "string(//*[local-name()='tags'])" contains "red"
xpath "string(//*[local-name()='tags'])" not contains "urgent"

# Favourite requires a user table -> forbidden propstat (403).
PROPPATCH {{host}}/remote.php/dav/files/{{user}}/tag_{{uid}}/a.txt
Authorization: Basic dGVzdDp4
Content-Type: application/xml
```xml
<?xml version="1.0"?>
<d:propertyupdate xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:set><d:prop><oc:favorite>1</oc:favorite></d:prop></d:set>
</d:propertyupdate>
```
HTTP 207
[Asserts]
xpath "string(//*[local-name()='status'])" contains "403"

# Tags still present after the forbidden favorite attempt.
PROPFIND {{host}}/remote.php/dav/files/{{user}}/tag_{{uid}}/a.txt
Authorization: Basic dGVzdDp4
Depth: 0
Content-Type: application/xml
```xml
<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:prop><oc:tags/></d:prop></d:propfind>
```
HTTP 207
[Asserts]
xpath "string(//*[local-name()='tags'])" contains "red"

# Renamed prefix (oc2) — same namespace — must set tags correctly (not erase).
PROPPATCH {{host}}/remote.php/dav/files/{{user}}/tag_{{uid}}/a.txt
Authorization: Basic dGVzdDp4
Content-Type: application/xml
```xml
<?xml version="1.0"?>
<d:propertyupdate xmlns:d="DAV:" xmlns:oc2="http://owncloud.org/ns">
  <d:set><d:prop>
    <oc2:tags><oc2:tag>blue</oc2:tag><oc2:tag>green</oc2:tag></oc2:tags>
  </d:prop></d:set>
</d:propertyupdate>
```
HTTP 207
[Asserts]
xpath "string(//*[local-name()='status'])" contains "200"

PROPFIND {{host}}/remote.php/dav/files/{{user}}/tag_{{uid}}/a.txt
Authorization: Basic dGVzdDp4
Depth: 0
Content-Type: application/xml
```xml
<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:prop><oc:tags/></d:prop></d:propfind>
```
HTTP 207
[Asserts]
xpath "string(//*[local-name()='tags'])" contains "blue"
xpath "string(//*[local-name()='tags'])" contains "green"

# Unsupported prop in <d:set> → 403 propstat; prior tags untouched.
PROPPATCH {{host}}/remote.php/dav/files/{{user}}/tag_{{uid}}/a.txt
Authorization: Basic dGVzdDp4
Content-Type: application/xml
```xml
<?xml version="1.0"?>
<d:propertyupdate xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:set><d:prop><d:getcontenttype>text/plain</d:getcontenttype></d:prop></d:set>
</d:propertyupdate>
```
HTTP 207
[Asserts]
xpath "string(//*[local-name()='status'])" contains "403"

PROPFIND {{host}}/remote.php/dav/files/{{user}}/tag_{{uid}}/a.txt
Authorization: Basic dGVzdDp4
Depth: 0
Content-Type: application/xml
```xml
<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:prop><oc:tags/></d:prop></d:propfind>
```
HTTP 207
[Asserts]
xpath "string(//*[local-name()='tags'])" contains "blue"
xpath "string(//*[local-name()='tags'])" contains "green"

# <d:remove> of oc:tags clears all tags → 200 propstat.
PROPPATCH {{host}}/remote.php/dav/files/{{user}}/tag_{{uid}}/a.txt
Authorization: Basic dGVzdDp4
Content-Type: application/xml
```xml
<?xml version="1.0"?>
<d:propertyupdate xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:remove><d:prop><oc:tags/></d:prop></d:remove>
</d:propertyupdate>
```
HTTP 207
[Asserts]
xpath "string(//*[local-name()='status'])" contains "200"

PROPFIND {{host}}/remote.php/dav/files/{{user}}/tag_{{uid}}/a.txt
Authorization: Basic dGVzdDp4
Depth: 0
Content-Type: application/xml
```xml
<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:prop><oc:tags/></d:prop></d:propfind>
```
HTTP 207
[Asserts]
xpath "count(//*[local-name()='tag'])" == 0

# Renamed-prefix favorite → 403 propstat.
PROPPATCH {{host}}/remote.php/dav/files/{{user}}/tag_{{uid}}/a.txt
Authorization: Basic dGVzdDp4
Content-Type: application/xml
```xml
<?xml version="1.0"?>
<d:propertyupdate xmlns:d="DAV:" xmlns:oc3="http://owncloud.org/ns">
  <d:set><d:prop><oc3:favorite>1</oc3:favorite></d:prop></d:set>
</d:propertyupdate>
```
HTTP 207
[Asserts]
xpath "string(//*[local-name()='status'])" contains "403"
