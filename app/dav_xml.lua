local dav_xml = {}

local DAV_NS = "DAV:"
local OC_NS = "http://owncloud.org/ns"

local function build_ns_map(root)
    local ns = {}
    for k, v in pairs(root.attr or {}) do
        if type(k) == "string" and k:sub(1, 6) == "xmlns:" then
            ns[k:sub(7)] = v
        elseif k == "xmlns" then
            ns[""] = v
        end
    end
    return ns
end

local function resolve(tag, ns_map)
    local colon = tag:find(":", 1, true)
    if colon then
        local prefix = tag:sub(1, colon - 1)
        local local_name = tag:sub(colon + 1)
        return ns_map[prefix] or "", local_name
    end
    return ns_map[""] or "", tag
end

local function child_elements(node)
    local out = {}
    for _, c in ipairs(node) do
        if type(c) == "table" then
            out[#out + 1] = c
        end
    end
    return out
end

local function inner_text(node)
    local parts = {}
    for _, c in ipairs(node) do
        if type(c) == "string" then
            parts[#parts + 1] = c
        end
    end
    return table.concat(parts)
end

local function parse_body(body)
    if not body or body:match("^%s*$") then
        return nil, "empty"
    end
    local lom = require("lxp.lom")
    local tree, err = lom.parse(body)
    if not tree then
        return nil, err or "parse error"
    end
    return tree, nil
end

function dav_xml.parse_propfind(body)
    if not body or body:match("^%s*$") then
        return { allprop = true, props = {} }
    end
    local tree, err = parse_body(body)
    if not tree then
        return nil, err
    end
    local ns_map = build_ns_map(tree)
    local result = { allprop = false, props = {} }
    for _, child in ipairs(child_elements(tree)) do
        local ns, name = resolve(child.tag, ns_map)
        if ns == DAV_NS and name == "allprop" then
            result.allprop = true
            return result
        end
        if ns == DAV_NS and name == "prop" then
            for _, prop_elem in ipairs(child_elements(child)) do
                local pns, pname = resolve(prop_elem.tag, ns_map)
                result.props[#result.props + 1] = { ns = pns, name = pname }
            end
        end
    end
    return result
end

function dav_xml.parse_propertyupdate(body)
    local tree, err = parse_body(body)
    if not tree then
        return nil, err
    end
    local ns_map = build_ns_map(tree)
    local result = { set = {}, remove = {} }
    for _, child in ipairs(child_elements(tree)) do
        local ns, name = resolve(child.tag, ns_map)
        if ns == DAV_NS and (name == "set" or name == "remove") then
            local target = (name == "set") and result.set or result.remove
            for _, prop_container in ipairs(child_elements(child)) do
                local pns, pname_container = resolve(prop_container.tag, ns_map)
                if pns == DAV_NS and pname_container == "prop" then
                    for _, prop_elem in ipairs(child_elements(prop_container)) do
                        local ens, ename = resolve(prop_elem.tag, ns_map)
                        if ens == OC_NS and ename == "tags" then
                            local tags = {}
                            for _, tag_child in ipairs(child_elements(prop_elem)) do
                                local tns, tname = resolve(tag_child.tag, ns_map)
                                if tns == OC_NS and tname == "tag" then
                                    tags[#tags + 1] = inner_text(tag_child)
                                end
                            end
                            target[#target + 1] = { ns = ens, name = ename, tags = tags }
                        else
                            target[#target + 1] = { ns = ens, name = ename, text = inner_text(prop_elem) }
                        end
                    end
                end
            end
        end
    end
    return result
end

return dav_xml
