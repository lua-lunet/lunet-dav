---@diagnostic disable: undefined-global, undefined-field

describe("lxp.lom", function()
    local lom

    before_each(function()
        lom = require("lxp.lom")
    end)

    it("loads", function()
        assert.is_table(lom)
        assert.is_function(lom.parse)
    end)

    it("parses a small DAV document", function()
        local xml = [[<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/foo/bar</D:href>
    <D:propstat>
      <D:prop>
        <D:getcontentlength>42</D:getcontentlength>
      </D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>
</D:multistatus>]]

        local tree, err = lom.parse(xml)
        assert.is_nil(err)
        assert.is_table(tree)
        assert.equal("D:multistatus", tree.tag)
        assert.equal("DAV:", tree.attr["xmlns:D"])

        local response = lom.find_elem(tree, "D:response")
        assert.is_table(response)

        local href = lom.find_elem(response, "D:href")
        assert.is_table(href)
        assert.equal("/foo/bar", href[1])

        local prop = lom.find_elem(response, "D:prop")
        assert.is_table(prop)

        local length = lom.find_elem(prop, "D:getcontentlength")
        assert.is_table(length)
        assert.equal("42", length[1])
    end)
end)
