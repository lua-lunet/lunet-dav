local dav_xml = {}

local DAV_NS = "DAV:"
local OC_NS = "http://owncloud.org/ns"

local function scoped_ns_map(node, parent_map)
    local attrs = node.attr
    if not attrs then
        return parent_map
    end
    local added
    for k, v in pairs(attrs) do
        if type(k) == "string" then
            if k == "xmlns" then
                added = added or {}
                added[""] = v
            elseif k:sub(1, 6) == "xmlns:" then
                added = added or {}
                added[k:sub(7)] = v
            end
        end
    end
    if not added then
        return parent_map
    end
    local ns = {}
    for k, v in pairs(parent_map) do
        ns[k] = v
    end
    for k, v in pairs(added) do
        ns[k] = v
    end
    return ns
end

local function resolve(tag, ns_map)
    local colon = tag:find(":", 1, true)
    if colon then
        local prefix = tag:sub(1, colon - 1)
        local uri = ns_map[prefix]
        if not uri then
            return nil, nil, "undeclared namespace prefix: " .. prefix
        end
        return uri, tag:sub(colon + 1)
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

local function resolve_root(tree, expected_name)
    local ns_map = scoped_ns_map(tree, {})
    local ns, name, err = resolve(tree.tag, ns_map)
    if not ns then
        return nil, nil, err
    end
    if ns ~= DAV_NS or name ~= expected_name then
        return nil, nil, "unexpected document root"
    end
    return ns_map, ns, name
end

function dav_xml.parse_propfind(body)
    if not body or body:match("^%s*$") then
        return { allprop = true, props = {} }
    end
    local tree, err = parse_body(body)
    if not tree then
        return nil, err
    end
    local root_map, _, rerr = resolve_root(tree, "propfind")
    if not root_map then
        return nil, rerr
    end
    local result = { allprop = false, props = {} }
    for _, child in ipairs(child_elements(tree)) do
        local child_map = scoped_ns_map(child, root_map)
        local ns, name, cerr = resolve(child.tag, child_map)
        if not ns then
            return nil, cerr
        end
        if ns == DAV_NS and name == "allprop" then
            result.allprop = true
            return result
        end
        if ns == DAV_NS and name == "prop" then
            for _, prop_elem in ipairs(child_elements(child)) do
                local elem_map = scoped_ns_map(prop_elem, child_map)
                local pns, pname, perr = resolve(prop_elem.tag, elem_map)
                if not pns then
                    return nil, perr
                end
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
    local root_map, _, rerr = resolve_root(tree, "propertyupdate")
    if not root_map then
        return nil, rerr
    end
    local result = { set = {}, remove = {}, ops = {} }
    for _, child in ipairs(child_elements(tree)) do
        local child_map = scoped_ns_map(child, root_map)
        local ns, name, cerr = resolve(child.tag, child_map)
        if not ns then
            return nil, cerr
        end
        if ns == DAV_NS and (name == "set" or name == "remove") then
            local target = (name == "set") and result.set or result.remove
            for _, prop_container in ipairs(child_elements(child)) do
                local container_map = scoped_ns_map(prop_container, child_map)
                local pns, pname_container, pcerr = resolve(prop_container.tag, container_map)
                if not pns then
                    return nil, pcerr
                end
                if pns == DAV_NS and pname_container == "prop" then
                    for _, prop_elem in ipairs(child_elements(prop_container)) do
                        local elem_map = scoped_ns_map(prop_elem, container_map)
                        local ens, ename, eerr = resolve(prop_elem.tag, elem_map)
                        if not ens then
                            return nil, eerr
                        end
                        local entry
                        if ens == OC_NS and ename == "tags" then
                            local tags = {}
                            for _, tag_child in ipairs(child_elements(prop_elem)) do
                                local tag_map = scoped_ns_map(tag_child, elem_map)
                                local tns, tname, terr = resolve(tag_child.tag, tag_map)
                                if not tns then
                                    return nil, terr
                                end
                                if tns == OC_NS and tname == "tag" then
                                    tags[#tags + 1] = inner_text(tag_child)
                                end
                            end
                            entry = { ns = ens, name = ename, tags = tags }
                        else
                            entry = { ns = ens, name = ename, text = inner_text(prop_elem) }
                        end
                        entry.action = name
                        target[#target + 1] = entry
                        result.ops[#result.ops + 1] = entry
                    end
                end
            end
        end
    end
    return result
end

return dav_xml
