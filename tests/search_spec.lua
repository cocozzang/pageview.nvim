-- Search from the page, end to end: keys are typed into a page buffer and the
-- source is searched in a real headless browser's layout.
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

describe("search in the page", function()
  local file ---@type string
  local lines ---@type string[]
  local echoed ---@type string[]
  local orig_echo = vim.api.nvim_echo

  --- 1-based line and 0-based column of the n-th `word` in the document.
  local function where(word, n)
    for lnum, text in ipairs(lines) do
      local init = 1
      while true do
        local s = text:find(word, init, true)
        if not s then
          break
        end
        n = n - 1
        if n == 0 then
          return lnum, s - 1
        end
        init = s + 1
      end
    end
  end

  setup(function()
    vim.env.PAGEVIEW_TERMINAL = "kitty"
    vim.o.termguicolors = true
    config.setup({ browser_args = vim.fn.has("linux") == 1 and { "--no-sandbox" } or {} })
    terminal._size = { cols = 80, rows = 24, width = 1280, height = 768, cell_width = 16, cell_height = 32 }
    terminal._writer = function() end
    lines = { "# Search", "", "First paragraph mentions beta and beta again.", "", "```lua" }
    for i = 1, 60 do
      lines[#lines + 1] = i == 35 and "local target = 35" or ("local x%d = %d"):format(i, i)
    end
    vim.list_extend(lines, { "```", "", "Last paragraph has the target too." })
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

  local page ---@type pageview.Page

  before_each(function()
    vim.cmd("silent! only")
    vim.cmd.edit(file)
    vim.bo.filetype = "markdown"
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.fn.setreg("/", "")
    vim.o.ignorecase, vim.o.smartcase, vim.o.wrapscan = false, false, true
    echoed = {}
    vim.api.nvim_echo = function(chunks, history, opts)
      for _, c in ipairs(chunks) do
        echoed[#echoed + 1] = c[1]
      end
      return orig_echo(chunks, history, opts)
    end
    require("pageview").open()
    page = assert(view.get(vim.api.nvim_get_current_buf()))
    assert.is_true(wait(30000, function()
      return page.layout ~= nil
    end))
  end)

  after_each(function()
    vim.api.nvim_echo = orig_echo
    if view.get(vim.api.nvim_get_current_buf()) then
      require("pageview").close()
    end
  end)

  --- Type keys that search in the page, and wait until the search ran: it
  --- always reports something (the pattern, a warning or an error).
  local function search(keys)
    echoed = {}
    type_keys(keys)
    assert.is_true(
      wait(2000, function()
        return #echoed > 0
      end),
      "no search for " .. keys
    )
  end

  --- The last search put the cursor on this source position.
  local function at(lnum, col)
    assert.are.same({ lnum, col }, { page.placed.line, page.placed.col })
    -- the page cursor is on the row where that line is drawn
    local row = vim.fn.line(".")
    assert.are.equal(lnum, position.line(page.layout.blocks, row - 0.5) + 1)
  end

  it_browser("finds a pattern in the source with /", function()
    search("/target<CR>")
    at(where("target", 1))
    assert.are.equal("target", vim.fn.getreg("/"))
    assert.are.equal("target", vim.fn.histget("/", -1))
    assert.are.equal(1, vim.v.searchforward)
    -- the pattern, and which match of how many at the right
    assert.matches("^/target +%[1/2%]$", echoed[1])
    assert.are.equal(vim.v.echospace, vim.fn.strdisplaywidth(echoed[1]))
  end)

  it_browser("goes through the matches with n and N, also inside one line", function()
    search("/beta<CR>")
    at(where("beta", 1))
    local row = vim.fn.line(".")
    search("n")
    at(where("beta", 2))
    assert.are.equal(row, vim.fn.line(".")) -- same paragraph, same row
    search("N")
    at(where("beta", 1))
  end)

  it_browser("wraps around the end of the document", function()
    search("/target<CR>")
    at(where("target", 1))
    search("n")
    at(where("target", 2))
    search("n")
    at(where("target", 1))
    assert.matches("^/target +W %[1/2%]$", echoed[1])
    -- without the count, Vim's warning
    vim.opt.shortmess:append("S")
    search("N")
    search("n")
    assert.are.same({ "search hit BOTTOM, continuing at TOP" }, echoed)
    search("N")
    assert.are.same({ "search hit TOP, continuing at BOTTOM" }, echoed)
    vim.opt.shortmess:remove("S")
  end)

  it_browser("searches backward with ?", function()
    search("?target<CR>")
    at(where("target", 2)) -- from the top, backward wraps to the last one
    assert.are.equal(0, vim.v.searchforward)
    search("N")
    at(where("target", 1)) -- N is forward after ?
  end)

  it_browser("leaves the page alone when the search is cancelled", function()
    local row = vim.fn.line(".")
    type_keys("/target<Esc>")
    vim.wait(50)
    assert.are.equal(row, vim.fn.line("."))
    assert.are.equal("", vim.fn.getreg("/"))
  end)

  it_browser("reports a pattern that is not in the source", function()
    search("/nowhere<CR>")
    assert.are.same({ "E486: Pattern not found: nowhere" }, echoed)
    vim.o.wrapscan = false
    search("?nowhere<CR>")
    assert.are.same({ "E384: Search hit TOP without match for: nowhere" }, echoed)
  end)

  it_browser("follows 'ignorecase' and 'smartcase'", function()
    vim.o.ignorecase, vim.o.smartcase = true, true
    search("/TARGET<CR>")
    assert.are.same({ "E486: Pattern not found: TARGET" }, echoed)
    search("/LAST\\c<CR>")
    at(where("Last", 1))
  end)

  it_browser("continues a search started in the raw buffer", function()
    require("pageview").close()
    type_keys("/target<CR>") -- Neovim's own search
    assert.are.same({ where("target", 1) }, { vim.fn.line("."), vim.fn.col(".") - 1 })
    require("pageview").open()
    search("n")
    at(where("target", 2))
  end)

  it_browser("maps n and N only in page buffers, unless keymaps = false", function()
    assert.are.equal(1, vim.fn.maparg("n", "n", false, true).buffer)
    require("pageview").close()
    assert.are.same({}, vim.fn.maparg("n", "n", false, true))

    local other = vim.fn.tempname() .. ".md"
    vim.fn.writefile({ "# Other" }, other)
    config.setup({ keymaps = false, browser_args = vim.fn.has("linux") == 1 and { "--no-sandbox" } or {} })
    vim.cmd.edit(other)
    vim.bo.filetype = "markdown"
    require("pageview").open()
    assert.is_not_nil(view.get(vim.api.nvim_get_current_buf()))
    assert.are.same({}, vim.fn.maparg("n", "n", false, true))
    config.setup({ browser_args = vim.fn.has("linux") == 1 and { "--no-sandbox" } or {} })
    require("pageview").close()
    vim.cmd("bwipeout! " .. vim.fn.fnameescape(other))
    os.remove(other)
  end)

  describe("mark", function()
    local ns = vim.api.nvim_create_namespace("pageview.match")

    ---@return integer[] rows (1-based) with a mark
    local function marked()
      local rows = {}
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(page.buf, ns, 0, -1, { details = true })) do
        assert.are.equal(page.layout.mark_col, m[4].virt_text_win_col)
        rows[#rows + 1] = m[2] + 1
      end
      return rows
    end

    it_browser("is drawn beside the matched code line", function()
      search("/target<CR>")
      at(where("target", 1))
      local rows = marked()
      assert.is_true(#rows >= 1 and #rows <= 2, vim.inspect(rows)) -- one code line
      assert.is_true(vim.tbl_contains(rows, vim.fn.line(".")))
    end)

    it_browser("covers the matched paragraph", function()
      search("/again<CR>")
      at(where("again", 1))
      assert.is_true(#marked() >= 2) -- a paragraph is taller than a row
    end)

    it_browser("goes away when leaving the page or after :nohlsearch", function()
      search("/target<CR>")
      at(where("target", 1))
      require("pageview").close()
      assert.are.same({}, marked())

      vim.o.hlsearch = true
      require("pageview").open()
      search("/target<CR>") -- from the first match, where the raw cursor is
      at(where("target", 2))
      assert.are_not.same({}, marked())
      vim.v.hlsearch = 0
      type_keys("k")
      -- typed keys run without the main loop here, which is what fires CursorMoved
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = page.buf })
      assert.are.same({}, marked())
    end)
  end)

  describe("while typing", function()
    local seen ---@type integer[]

    before_each(function()
      seen = {}
      _G.pageview_probe = function()
        seen[#seen + 1] = vim.fn.line(".")
      end
    end)

    after_each(function()
      _G.pageview_probe = nil
      vim.o.incsearch = true
    end)

    local probe = "<Cmd>lua pageview_probe()<CR>"

    ---@param lnum integer source line
    local function row_of(lnum)
      return math.floor(position.row(page.layout.blocks, lnum - 1) + 0.5) + 1
    end

    it_browser("the page follows the pattern, and goes back on <Esc>", function()
      local start = vim.fn.line(".")
      local target = row_of((where("target", 1)))
      type_keys("/targ" .. probe .. "<C-u>" .. probe .. "target" .. probe .. "<Esc>")
      assert.are.same({ target, start, target }, seen)
      assert.are.equal(start, vim.fn.line("."))
      assert.is_true(vim.o.incsearch) -- Neovim's own is turned back on
    end)

    it_browser("the search then starts where typing started, as one jump", function()
      local start = vim.fn.line(".")
      search("/target<CR>")
      at(where("target", 1))
      type_keys("<C-o>")
      assert.are.equal(start, vim.fn.line("."))
    end)

    it_browser("the page stays put without 'incsearch'", function()
      vim.o.incsearch = false
      local start = vim.fn.line(".")
      type_keys("/target" .. probe .. "<Esc>")
      assert.are.same({ start }, seen)
      assert.is_false(vim.o.incsearch)
    end)
  end)

  it_browser("lands on the match when switching to raw", function()
    search("/target<CR>")
    at(where("target", 1))
    require("pageview").close()
    assert.are.same({ where("target", 1) }, { vim.fn.line("."), vim.fn.col(".") - 1 })
  end)
end)
