# OCS: no credentials at all -> 401 / 997.
GET {{host}}/ocs/v2.php/cloud/user?format=json
OCS-APIRequest: true
HTTP 401
[Asserts]
jsonpath "$.ocs.meta.statuscode" == 997

# Bad app password -> 401 / 997.
GET {{host}}/ocs/v2.php/cloud/user?format=json
OCS-APIRequest: true
[BasicAuth]
nobody: wrong-password
HTTP 401
[Asserts]
jsonpath "$.ocs.meta.statuscode" == 997
