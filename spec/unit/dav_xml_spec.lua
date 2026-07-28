---@diagnostic disable: undefined-global, undefined-field, need-check-nil

local dav_xml = require("dav_xml")

describe("dav_xml.parse_propfind", function()
    it("parses standard prefixes", function()
        local xml = [[<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
  <d:prop>
    <d:getcontentlength/>
    <oc:tags/>
    <nc:share-types/>
  </d:prop>
</d:propfind>]]
        local result = dav_xml.parse_propfind(xml)
        assert.is_table(result)
        assert.is_false(result.allprop)
        assert.equal(3, #result.props)
        local found = {}
        for _, p in ipairs(result.props) do
            found[p.ns .. ":" .. p.name] = true
        end
        assert.is_true(found["DAV::getcontentlength"])
        assert.is_true(found["http://owncloud.org/ns:tags"])
        assert.is_true(found["http://nextcloud.org/ns:share-types"])
    end)

    it("resolves renamed prefixes by URI", function()
        local xml = [[<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:" xmlns:oc2="http://owncloud.org/ns" xmlns:nc2="http://nextcloud.org/ns">
  <d:prop>
    <d:getcontentlength/>
    <oc2:tags/>
    <nc2:share-types/>
  </d:prop>
</d:propfind>]]
        local result = dav_xml.parse_propfind(xml)
        assert.is_table(result)
        assert.is_false(result.allprop)
        assert.equal(3, #result.props)
        local found = {}
        for _, p in ipairs(result.props) do
            found[p.ns .. ":" .. p.name] = true
        end
        assert.is_true(found["DAV::getcontentlength"])
        assert.is_true(found["http://owncloud.org/ns:tags"])
        assert.is_true(found["http://nextcloud.org/ns:share-types"])
    end)

    it("handles allprop form", function()
        local xml = [[<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:"><d:allprop/></d:propfind>]]
        local result = dav_xml.parse_propfind(xml)
        assert.is_table(result)
        assert.is_true(result.allprop)
    end)

    it("treats empty body as allprop", function()
        local result = dav_xml.parse_propfind("")
        assert.is_table(result)
        assert.is_true(result.allprop)
    end)

    it("treats whitespace-only body as allprop", function()
        local result = dav_xml.parse_propfind("   \n  ")
        assert.is_table(result)
        assert.is_true(result.allprop)
    end)

    it("preserves unknown-namespace props", function()
        local xml = [[<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:" xmlns:custom="http://example.com/ns">
  <d:prop>
    <custom:myprop/>
  </d:prop>
</d:propfind>]]
        local result = dav_xml.parse_propfind(xml)
        assert.is_table(result)
        assert.equal(1, #result.props)
        assert.equal("http://example.com/ns", result.props[1].ns)
        assert.equal("myprop", result.props[1].name)
    end)

    it("returns nil+err for malformed XML", function()
        local result, err = dav_xml.parse_propfind("not xml at all")
        assert.is_nil(result)
        assert.is_string(err)
    end)
end)

describe("dav_xml.parse_propertyupdate", function()
    it("parses set oc:tags with two tags", function()
        local xml = [[<?xml version="1.0" encoding="utf-8"?>
<d:propertyupdate xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:set>
    <d:prop>
      <oc:tags>
        <oc:tag>alpha</oc:tag>
        <oc:tag>beta</oc:tag>
      </oc:tags>
    </d:prop>
  </d:set>
</d:propertyupdate>]]
        local result = dav_xml.parse_propertyupdate(xml)
        assert.is_table(result)
        assert.equal(1, #result.set)
        assert.equal("http://owncloud.org/ns", result.set[1].ns)
        assert.equal("tags", result.set[1].name)
        assert.is_table(result.set[1].tags)
        assert.equal(2, #result.set[1].tags)
        assert.equal("alpha", result.set[1].tags[1])
        assert.equal("beta", result.set[1].tags[2])
    end)

    it("parses remove oc:tags", function()
        local xml = [[<?xml version="1.0" encoding="utf-8"?>
<d:propertyupdate xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:remove>
    <d:prop>
      <oc:tags/>
    </d:prop>
  </d:remove>
</d:propertyupdate>]]
        local result = dav_xml.parse_propertyupdate(xml)
        assert.is_table(result)
        assert.equal(1, #result.remove)
        assert.equal("http://owncloud.org/ns", result.remove[1].ns)
        assert.equal("tags", result.remove[1].name)
    end)

    it("parses set oc:favorite", function()
        local xml = [[<?xml version="1.0" encoding="utf-8"?>
<d:propertyupdate xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:set>
    <d:prop>
      <oc:favorite>1</oc:favorite>
    </d:prop>
  </d:set>
</d:propertyupdate>]]
        local result = dav_xml.parse_propertyupdate(xml)
        assert.is_table(result)
        assert.equal(1, #result.set)
        assert.equal("http://owncloud.org/ns", result.set[1].ns)
        assert.equal("favorite", result.set[1].name)
        assert.equal("1", result.set[1].text)
    end)

    it("parses set a d: prop", function()
        local xml = [[<?xml version="1.0" encoding="utf-8"?>
<d:propertyupdate xmlns:d="DAV:">
  <d:set>
    <d:prop>
      <d:displayname>hello</d:displayname>
    </d:prop>
  </d:set>
</d:propertyupdate>]]
        local result = dav_xml.parse_propertyupdate(xml)
        assert.is_table(result)
        assert.equal(1, #result.set)
        assert.equal("DAV:", result.set[1].ns)
        assert.equal("displayname", result.set[1].name)
        assert.equal("hello", result.set[1].text)
    end)

    it("parses mixed set+remove in one document", function()
        local xml = [[<?xml version="1.0" encoding="utf-8"?>
<d:propertyupdate xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:set>
    <d:prop>
      <oc:tags>
        <oc:tag>one</oc:tag>
      </oc:tags>
    </d:prop>
  </d:set>
  <d:remove>
    <d:prop>
      <oc:favorite/>
    </d:prop>
  </d:remove>
</d:propertyupdate>]]
        local result = dav_xml.parse_propertyupdate(xml)
        assert.is_table(result)
        assert.equal(1, #result.set)
        assert.equal("tags", result.set[1].name)
        assert.equal(1, #result.remove)
        assert.equal("favorite", result.remove[1].name)
    end)

    it("records document order across set and remove in ops", function()
        local xml = [[<?xml version="1.0" encoding="utf-8"?>
<d:propertyupdate xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:set>
    <d:prop><oc:tags><oc:tag>one</oc:tag></oc:tags></d:prop>
  </d:set>
  <d:remove>
    <d:prop><oc:favorite/></d:prop>
  </d:remove>
  <d:remove>
    <d:prop><oc:tags/></d:prop>
  </d:remove>
</d:propertyupdate>]]
        local result = dav_xml.parse_propertyupdate(xml)
        assert.is_table(result.ops)
        assert.equal(3, #result.ops)
        assert.equal("set", result.ops[1].action)
        assert.equal("tags", result.ops[1].name)
        assert.equal("remove", result.ops[2].action)
        assert.equal("favorite", result.ops[2].name)
        assert.equal("remove", result.ops[3].action)
        assert.equal("tags", result.ops[3].name)
        assert.equal(1, #result.set)
        assert.equal(2, #result.remove)
    end)

    it("preserves unknown-namespace props", function()
        local xml = [[<?xml version="1.0" encoding="utf-8"?>
<d:propertyupdate xmlns:d="DAV:" xmlns:custom="http://example.com/ns">
  <d:set>
    <d:prop>
      <custom:myprop>value</custom:myprop>
    </d:prop>
  </d:set>
</d:propertyupdate>]]
        local result = dav_xml.parse_propertyupdate(xml)
        assert.is_table(result)
        assert.equal(1, #result.set)
        assert.equal("http://example.com/ns", result.set[1].ns)
        assert.equal("myprop", result.set[1].name)
        assert.equal("value", result.set[1].text)
    end)

    it("returns nil+err for malformed XML", function()
        local result, err = dav_xml.parse_propertyupdate("<broken")
        assert.is_nil(result)
        assert.is_string(err)
    end)
end)
