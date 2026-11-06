-- `gx` in the page, end to end with a real headless browser's layout.
-- Skipped when no Chromium-based browser is installed.

local browser = require("pageview.browser")
local config = require("pageview.config")
local position = require("pageview.position")
local terminal = require("pageview.terminal")
local view = require("pageview.view")

local it_browser = browser.find() and it or pending

local function wait(ms, cond)
  return vim.wait(ms, cond, 10)
end

---@param keys string
local function type_keys(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
end

describe("links in the page", function()
  local dir, doc ---@type string, string
  local lines = {
    "# Links", -- 1
    "",
    "See [one](https://example.com/one) here.", -- 3
    "",
    "[a](https://example.com/a) and [other](./other.md) on one line.", -- 5
    "",
    "Plain text without links.", -- 7
    "",
    "[picture](pic.png) and [missing](gone.md)", -- 9
  }
  local page ---@type pageview.Page
  local opened ---@type string[]
  local notified ---@type string[]
  local orig = { open = vim.ui.open, select = vim.ui.select, notify = vim.notify }

  setup(function()
    vim.env.PAGEVIEW_TERMINAL = "kitty"
    vim.o.termguicolors = true
    config.setup({ browser_args = vim.fn.has("linux") == 1 and { "--no-sandbox" } or {} })
    terminal._size = { cols = 80, rows = 24, width = 1280, height = 768, cell_width = 16, cell_height = 32 }
    terminal._writer = function() end
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    dir = assert((vim.uv or vim.loop).fs_realpath(dir)) -- macOS: /var is /private/var
    doc = dir .. "/doc.md"
    vim.fn.writefile(lines, doc)
    vim.fn.writefile({ "# Other" }, dir .. "/other.md")
    vim.fn.writefile({}, dir .. "/pic.png")
  end)

  teardown(function()
    vim.cmd("silent! %bwipeout!")
    browser.shutdown(true)
    terminal._writer = nil
    terminal._size = nil
    vim.fn.delete(dir, "rf")
  end)

  before_each(function()
    opened, notified = {}, {}
    vim.ui.open = function(path)
      opened[#opened + 1] = path
      return nil, nil
    end
    vim.notify = function(msg)
      notified[#notified + 1] = msg
    end
    vim.cmd("silent! only")
    vim.cmd.edit(doc)
    vim.bo.filetype = "markdown"
    require("pageview").open()
    page = assert(view.get(vim.api.nvim_get_current_buf()))
    assert.is_true(wait(30000, function()
      return page.layout ~= nil
    end))
  end)

  after_each(function()
    vim.ui.open, vim.ui.select, vim.notify = orig.open, orig.select, orig.notify
    if view.get(vim.api.nvim_get_current_buf()) then
      require("pageview").close()
    end
  end)

  --- Put the page cursor on the row of a link and press gx.
  ---@param href string
  local function gx_on(href)
    for _, link in ipairs(page.layout.links) do
      if link.href == href then
        local r = link.rows[1]
        vim.api.nvim_win_set_cursor(0, { math.floor((r[1] + r[2]) / 2) + 1, 0 })
        type_keys("gx")
        return
      end
    end
    error("no link " .. href)
  end

  it_browser("knows where every link is drawn", function()
    local hrefs = vim.tbl_map(function(l)
      return l.href
    end, page.layout.links)
    assert.are.same({ "https://example.com/one", "https://example.com/a", "./other.md", "pic.png", "gone.md" }, hrefs)
    assert.are.equal("one", page.layout.links[1].text)
    assert.are.equal(vim.uri_from_fname(dir) .. "/other.md", page.layout.links[3].url)
  end)

  it_browser("opens the only link on the row", function()
    gx_on("https://example.com/one")
    assert.are.same({ "https://example.com/one" }, opened)
  end)

  it_browser("offers the links when the row has several, and opens files in Neovim", function()
    local offered
    vim.ui.select = function(items, opts, choose)
      offered = vim.tbl_map(opts.format_item, items)
      choose(items[2])
    end
    gx_on("./other.md")
    assert.are.same({ "a  https://example.com/a", "other  ./other.md" }, offered)
    assert.are.equal(vim.fs.normalize(dir .. "/other.md"), vim.fs.normalize(vim.api.nvim_buf_get_name(0)))
    assert.are.same({}, opened)
  end)

  it_browser("opens pictures with the system viewer and reports missing files", function()
    local choices = {}
    vim.ui.select = function(items, _, choose)
      choose(items[#choices + 1])
      choices[#choices + 1] = true
    end
    gx_on("pic.png")
    assert.are.equal(1, #opened)
    assert.matches("pic%.png$", opened[1])
    gx_on("gone.md")
    assert.matches("no such file", notified[1])
  end)

  it_browser("switches to raw at the line when the row has no link", function()
    local row
    for r = 1, page.layout.total_rows do
      if position.line(page.layout.blocks, r - 0.5) + 1 == 7 then
        row = r
        break
      end
    end
    vim.api.nvim_win_set_cursor(0, { assert(row), 0 })
    type_keys("gx")
    assert.is_nil(view.get(vim.api.nvim_get_current_buf()))
    assert.are.equal(7, vim.fn.line("."))
    assert.are.same({}, opened)
  end)
end)
