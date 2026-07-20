# MKCOL — create a flat top-level team folder, plus the rejection rules.

# Create a new collection -> 201 with nc identity headers.
MKCOL {{host}}/remote.php/dav/files/{{user}}/team_{{uid}}
Authorization: Basic dGVzdDp4
HTTP 201
[Asserts]
header "OC-FileId" matches /^[0-9]{8}.+/
header "OC-Etag" exists

# Re-creating the same collection -> 405 Method Not Allowed.
MKCOL {{host}}/remote.php/dav/files/{{user}}/team_{{uid}}
Authorization: Basic dGVzdDp4
HTTP 405

# Reserved names (leading underscore) are forbidden -> 403.
MKCOL {{host}}/remote.php/dav/files/{{user}}/_system_{{uid}}
Authorization: Basic dGVzdDp4
HTTP 403

# Nested collection (flat namespace only) -> 409 Conflict.
MKCOL {{host}}/remote.php/dav/files/{{user}}/team_{{uid}}/nested
Authorization: Basic dGVzdDp4
HTTP 409
