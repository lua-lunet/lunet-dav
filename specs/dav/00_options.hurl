# OPTIONS advertises class-1 WebDAV and the MVP method set.
OPTIONS {{host}}/remote.php/dav/files/{{user}}/
Authorization: Basic dGVzdDp4
HTTP 200
[Asserts]
header "DAV" contains "1"
header "Allow" contains "PROPFIND"
header "Allow" contains "MKCOL"
header "Allow" contains "MOVE"
header "Allow" contains "PUT"
