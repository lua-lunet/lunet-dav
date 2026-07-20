-- Route registration: requiring each module registers its routes with the router

require("auth_routes")
require("profile_routes")
require("store_routes") -- TEST-ONLY shim for the store mock (lunet#103); remove for real deploys
