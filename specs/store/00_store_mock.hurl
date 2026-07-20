# store MOCK contract (lunet#103 stand-in). Exercises the minimal surface lunet-dav uses:
# set/get/add/incr/delete + lazy TTL. Carries over as the scope contract when the native
# shared store replaces the Lua mock. Test-only endpoints under /api/_store/.

# set then get round-trips a JSON value.
POST {{host}}/api/_store/set
{ "key": "k_{{uid}}_a", "value": { "status": "pending", "id": 7 }, "ttl": 60 }
HTTP 200
[Asserts]
jsonpath "$.ok" == true

GET {{host}}/api/_store/get?key=k_{{uid}}_a
HTTP 200
[Asserts]
jsonpath "$.found" == true
jsonpath "$.value.status" == "pending"
jsonpath "$.value.id" == 7

# get on an absent key -> 404 found:false.
GET {{host}}/api/_store/get?key=k_{{uid}}_missing
HTTP 404
[Asserts]
jsonpath "$.found" == false

# add creates only when absent: first add wins, second is rejected (single-flight).
POST {{host}}/api/_store/add
{ "key": "k_{{uid}}_lock", "value": { "inflight": true }, "ttl": 60 }
HTTP 200
[Asserts]
jsonpath "$.added" == true

POST {{host}}/api/_store/add
{ "key": "k_{{uid}}_lock", "value": { "inflight": true }, "ttl": 60 }
HTTP 200
[Asserts]
jsonpath "$.added" == false

# incr creates with init+delta, then accumulates (throttle counter).
POST {{host}}/api/_store/incr
{ "key": "k_{{uid}}_ctr", "delta": 1, "init": 0, "ttl": 60 }
HTTP 200
[Asserts]
jsonpath "$.value" == 1

POST {{host}}/api/_store/incr
{ "key": "k_{{uid}}_ctr", "delta": 2, "init": 0, "ttl": 60 }
HTTP 200
[Asserts]
jsonpath "$.value" == 3

# delete removes the entry.
POST {{host}}/api/_store/delete
{ "key": "k_{{uid}}_a" }
HTTP 200

GET {{host}}/api/_store/get?key=k_{{uid}}_a
HTTP 404

# TTL expiry: set with a 1s TTL, then read after a 1.5s delay -> expired (404).
POST {{host}}/api/_store/set
{ "key": "k_{{uid}}_ttl", "value": { "v": 1 }, "ttl": 1 }
HTTP 200

GET {{host}}/api/_store/get?key=k_{{uid}}_ttl
[Options]
delay: 1500
HTTP 404
[Asserts]
jsonpath "$.found" == false
