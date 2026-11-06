local cdp = require("pageview.cdp")

describe("cdp decoder", function()
  it("splits messages on NUL bytes", function()
    local d = cdp.Decoder.new()
    assert.are.same({ "a", "b" }, d:feed("a\0b\0"))
  end)

  it("joins messages split across reads", function()
    local d = cdp.Decoder.new()
    assert.are.same({}, d:feed('{"id"'))
    assert.are.same({}, d:feed(":1"))
    assert.are.same({ '{"id":1}' }, d:feed("}\0{"))
    assert.are.same({ "{}" }, d:feed("}\0"))
  end)

  it("handles large messages", function()
    local d = cdp.Decoder.new()
    local big = string.rep("x", 100000)
    local out = {}
    for i = 1, #big, 4096 do
      vim.list_extend(out, d:feed(big:sub(i, i + 4095)))
    end
    vim.list_extend(out, d:feed("\0"))
    assert.are.equal(1, #out)
    assert.are.equal(100000, #out[1])
  end)
end)
