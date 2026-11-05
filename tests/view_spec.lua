-- End-to-end: a real headless browser renders a document into a page buffer.
-- Skipped when no Chromium-based browser is installed.

local browser = require("pageview.browser")
local config = require("pageview.config")
local terminal = require("pageview.terminal")
local view = require("pageview.view")

local has_browser = browser.find() ~= nil
local it_browser = has_browser and it or pending

---@param path string
---@return integer width, integer height
local function png_size(path)
  local f = assert(io.open(path, "rb"))
  local h = f:read(24)
  f:close()
  local function u32(i)
    local a, b, c, d = h:byte(i, i + 3)
    return a * 16777216 + b * 65536 + c * 256 + d
  end
  return u32(17), u32(21)
end

local function wait(ms, cond)
  return vim.wait(ms, cond, 10)
end

describe("page view", function()
  local written ---@type string[]
  local raw ---@type integer
  local file ---@type string

  setup(function()
    vim.env.PAGEVIEW_TERMINAL = "kitty"
    vim.o.termguicolors = true
    config.setup({ browser_args = vim.fn.has("linux") == 1 and { "--no-sandbox" } or {} })
    -- Headless Neovim keeps an 80x24 grid; cropping is covered by render_spec.
    terminal._size = { cols = 80, rows = 24, width = 1280, height = 768, cell_width = 16, cell_height = 32 }
    terminal._writer = function(data)
      written[#written + 1] = data
    end
    local lines = { "# Title", "" }
    for i = 1, 150 do
      vim.list_extend(
        lines,
        { ("## Section %d"):format(i), "", ("Paragraph %d with **bold** and `code`."):format(i), "" }
      )
    end
    file = vim.fn.tempname() .. ".md"
    vim.fn.writefile(lines, file)
  end)

  teardown(function()
    vim.cmd("silent! %bwipeout!")
    browser.shutdown(true)
    terminal._writer = nil
    terminal._size = nil
    os.remove(file)
  end)

  before_each(function()
    written = {}
    vim.cmd("silent! only")
    vim.cmd.edit(file)
    raw = vim.api.nvim_get_current_buf()
    vim.bo[raw].filetype = "markdown"
  end)

  it_browser("renders and shows the slices around the cursor", function()
    require("pageview").open()
    local page = assert(view.get(vim.api.nvim_get_current_buf()))
    assert.is_true(
      wait(30000, function()
        return page.layout ~= nil and next(page.shown) ~= nil
      end),
      "page did not render: " .. tostring(page.failed)
    )

    local layout = page.layout
    assert.is_true(layout.total_rows > 100)
    assert.are.equal(layout.total_rows, vim.api.nvim_buf_line_count(page.buf))
    -- the image stays inside the window
    assert.is_true(layout.col0 + layout.ncols <= vim.api.nvim_win_get_width(0))

    -- slice files match the cell grid exactly
    local index = next(page.shown)
    local _, rows = require("pageview.render").slice_rows(layout, index)
    local w, h = png_size(require("pageview.cache").slice_path(page.key, index))
    assert.are.equal(layout.ncols * 16, w)
    assert.are.equal(rows * 32, h)

    local all = table.concat(written)
    assert.matches("a=T", all, 1, true)
    assert.matches("U=1", all, 1, true)

    -- placeholders are drawn as overlays on the empty lines
    local marks = vim.api.nvim_buf_get_extmarks(page.buf, vim.api.nvim_create_namespace("pageview"), 0, -1, {})
    assert.is_true(#marks > 0)
  end)

  it_browser("captures more while scrolling and frees what is far away", function()
    require("pageview").open()
    local page = assert(view.get(vim.api.nvim_get_current_buf()))
    assert.is_true(wait(30000, function()
      return page.layout ~= nil and page.shown[1] ~= nil
    end))
    local last = page.layout.slices
    vim.cmd("normal! G")
    view.refresh(page, vim.api.nvim_get_current_win())
    assert.is_true(
      wait(30000, function()
        return page.shown[last] ~= nil
      end),
      "last slice not shown"
    )
    assert.is_nil(page.shown[1], "first slice should be freed")
    assert.matches("d=I", table.concat(written), 1, true)
  end)

  it_browser("goes back to the raw buffer and frees the images", function()
    require("pageview").open()
    local page = assert(view.get(vim.api.nvim_get_current_buf()))
    assert.is_true(wait(30000, function()
      return next(page.shown) ~= nil
    end))
    written = {}
    require("pageview").close()
    assert.are.equal(raw, vim.api.nvim_get_current_buf())
    assert.is_nil(next(page.shown))
    assert.matches("d=I", table.concat(written), 1, true)
  end)

  it_browser("reuses the cached layout when nothing changed", function()
    require("pageview").open()
    local page = assert(view.get(vim.api.nvim_get_current_buf()))
    assert.is_true(wait(30000, function()
      return page.layout ~= nil
    end))
    local key = page.key
    require("pageview").close()
    require("pageview").open()
    assert.are.equal(key, page.key)
    assert.is_not_nil(page.layout) -- available right away
  end)

  it_browser("lays the page out again when the width changes", function()
    require("pageview").open()
    local page = assert(view.get(vim.api.nvim_get_current_buf()))
    assert.is_true(wait(30000, function()
      return page.layout ~= nil
    end))
    local key = page.key
    vim.cmd("vsplit")
    view.refresh(page, vim.api.nvim_get_current_win())
    assert.is_true(wait(30000, function()
      return page.layout ~= nil and page.key ~= key
    end))
    assert.is_true(page.layout.ncols <= vim.api.nvim_win_get_width(0))
  end)

  it("refuses non-markdown buffers", function()
    vim.bo[raw].filetype = "lua"
    require("pageview").open()
    assert.are.equal(raw, vim.api.nvim_get_current_buf())
  end)
end)
