local render = require("pageview.render")

---@return pageview.RenderParams
local function params(over)
  return vim.tbl_extend("force", {
    src = "# hi",
    cols = 100,
    win_rows = 40,
    cell_width = 16,
    cell_height = 32,
    zoom = 1,
    theme = "github-dark",
    background = "page",
  }, over or {})
end

describe("render", function()
  it("follows the terminal font scale", function()
    assert.are.equal(2, render.scale(16, 1))
    assert.are.equal(2.5, render.scale(20, 1))
    assert.are.equal(1, render.scale(7, 1))
    assert.are.equal(3, render.scale(16, 1.5))
  end)

  it("crops to the article columns", function()
    -- 100 cols * 16 px / scale 2 = 800 CSS px wide window, one cell = 8 CSS px.
    -- Article from 200 to 760 CSS px = columns 25 to 95.
    local l = render.plan(params(), { height = 640, left = 200, articleWidth = 560, lines = {} })
    assert.are.equal(25, l.col0)
    assert.are.equal(70, l.ncols)
    assert.are.equal(40, l.total_rows) -- 640 CSS px * 2 / 32 px
  end)

  it("uses the whole window with background = full", function()
    local l = render.plan(params({ background = "full" }), { height = 10, left = 100, articleWidth = 600, lines = {} })
    assert.are.equal(0, l.col0)
    assert.are.equal(100, l.ncols)
  end)

  it("rounds partial cells outward", function()
    -- article from 201 to 761 CSS px: starts inside column 25, ends inside column 95
    local l = render.plan(params(), { height = 641, left = 201, articleWidth = 560, lines = {} })
    assert.are.equal(25, l.col0)
    assert.are.equal(71, l.ncols)
    assert.are.equal(41, l.total_rows)
  end)

  it("never goes past the window", function()
    local l = render.plan(params(), { height = 10, left = 0, articleWidth = 900, lines = {} })
    assert.are.equal(0, l.col0)
    assert.are.equal(100, l.ncols)
  end)

  it("maps source lines to rows", function()
    local l = render.plan(params(), { height = 640, left = 0, articleWidth = 800, lines = { { 0, 32 }, { 4, 100 } } })
    assert.are.same({ { 0, 2 }, { 4, 6 } }, l.lines)
  end)

  it("splits rows into slices", function()
    local l = render.plan(params(), { height = 1600, left = 0, articleWidth = 800, lines = {} })
    assert.are.equal(100, l.total_rows)
    assert.are.equal(math.ceil(100 / render.SLICE_ROWS), l.slices)
    local row0, rows = render.slice_rows(l, l.slices)
    assert.are.equal(100, row0 + rows)
  end)

  it("fingerprints every page asset, and vendored libraries by VERSIONS", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/vendor/lib", "p")
    local function write(name, text)
      vim.fn.writefile({ text }, dir .. "/" .. name)
    end
    write("page.html", "<html>")
    write("page.js", "1")
    write("extra.css", "a {}")
    write("vendor/VERSIONS", "lib 1.0.0")
    write("vendor/lib/lib.js", "v1")
    local a = render.fingerprint(dir)
    write("extra.css", "b {}")
    local b = render.fingerprint(dir)
    assert.are_not.equal(a, b)
    write("vendor/lib/lib.js", "v2")
    assert.are.equal(b, render.fingerprint(dir))
    write("vendor/VERSIONS", "lib 2.0.0")
    assert.are_not.equal(b, render.fingerprint(dir))
    write("new.js", "")
    assert.are_not.equal(b, render.fingerprint(dir))
    vim.fn.delete(dir, "rf")
  end)

  it("keys change with anything that changes the pixels", function()
    local a = render.key(params(), "x")
    assert.are.equal(a, render.key(params(), "x"))
    assert.are_not.equal(a, render.key(params({ cols = 99 }), "x"))
    assert.are_not.equal(a, render.key(params({ src = "# bye" }), "x"))
    assert.are_not.equal(a, render.key(params({ theme = "github-light" }), "x"))
    assert.are_not.equal(a, render.key(params(), "y"))
    -- the window height does not change the pixels
    assert.are.equal(a, render.key(params({ win_rows = 10 }), "x"))
  end)
end)
