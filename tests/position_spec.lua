local position = require("pageview.position")

-- { first line, end line, top row, bottom row }
local blocks = {
  { 0, 1, 0, 3 }, -- heading
  { 2, 6, 4, 8 }, -- paragraph: 4 lines on 4 rows
  { 7, 40, 9, 50 }, -- code box with its fences
  { 8, 39, 10, 48, 1 }, -- its 31 code lines on 38 rows, evenly spaced
  { 41, 50, 51, 60 }, -- list
  { 41, 45, 51, 55 }, -- item
  { 45, 50, 55, 60 }, -- item
}

describe("position", function()
  describe("row", function()
    it("spreads a block's lines over its rows", function()
      assert.are.equal(0, position.row(blocks, 0))
      assert.are.equal(5, position.row(blocks, 3))
      assert.are.equal(10 + 38 / 31, position.row(blocks, 9))
    end)

    it("uses the innermost block", function()
      assert.are.equal(9, position.row(blocks, 7)) -- the opening fence: the box
      assert.are.equal(10, position.row(blocks, 8)) -- the first code line
      assert.are.equal(52, position.row(blocks, 42)) -- in the first item
    end)

    it("sends lines between blocks to the next block", function()
      assert.are.equal(4, position.row(blocks, 1))
      assert.are.equal(51, position.row(blocks, 40))
    end)

    it("sends lines after the last block to its bottom", function()
      assert.are.equal(60, position.row(blocks, 100))
      assert.are.equal(0, position.row({}, 5))
    end)
  end)

  describe("extent", function()
    it("gives a code line its own rows", function()
      local per = 38 / 31
      local top, bottom = position.extent(blocks, 9)
      assert.is_true(math.abs(top - (10 + per)) < 1e-9)
      assert.is_true(math.abs(bottom - (10 + 2 * per)) < 1e-9)
    end)

    it("gives a line of text its whole block", function()
      assert.are.same({ 4, 8 }, { position.extent(blocks, 3) })
      assert.are.same({ 51, 55 }, { position.extent(blocks, 42) })
    end)

    it("leaves out nested blocks before and after the line", function()
      local nested = {
        { 0, 9, 0, 20 }, -- list item
        { 0, 1, 0, 2 }, -- its first paragraph
        { 2, 5, 3, 10 }, -- a sublist
        { 6, 9, 12, 20 }, -- a code block
      }
      assert.are.same({ 2, 3 }, { position.extent(nested, 1) }) -- between paragraph and sublist
      assert.are.same({ 10, 12 }, { position.extent(nested, 5) }) -- between sublist and code
    end)

    it("gives a line outside any block one row", function()
      assert.are.same({ 4, 5 }, { position.extent(blocks, 1) })
    end)
  end)

  describe("line", function()
    it("finds the line drawn at a row", function()
      assert.are.equal(0, position.line(blocks, 0.5))
      assert.are.equal(3, position.line(blocks, 5.5))
      assert.are.equal(8, position.line(blocks, 10.5))
      assert.are.equal(42, position.line(blocks, 52.5))
    end)

    it("sends margins to the next block", function()
      assert.are.equal(2, position.line(blocks, 3.5))
      assert.are.equal(41, position.line(blocks, 50.5))
    end)

    it("sends rows after the last block to its last line", function()
      assert.are.equal(49, position.line(blocks, 70))
      assert.are.equal(0, position.line({}, 5))
    end)

    it("finds every code line again from its row", function()
      for line = 8, 38 do
        local row = math.floor(position.row(blocks, line) + 0.5)
        assert.are.equal(line, position.line(blocks, row + 0.5))
      end
    end)
  end)
end)
