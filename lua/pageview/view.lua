-- Page buffers: one per source buffer, one buffer line per terminal row.
--
-- Image slices are drawn over the empty lines with unicode placeholders, so
-- normal motions (j/k, Ctrl-d/u, gg/G) scroll the page row by row. Only the
-- slices near the visible rows are captured and sent to the terminal; slices
-- that scroll far away are freed again.

local async = require("pageview.async")
local browser = require("pageview.browser")
local cache = require("pageview.cache")
local config = require("pageview.config")
local kitty = require("pageview.backend.kitty")
local position = require("pageview.position")
local render = require("pageview.render")
local terminal = require("pageview.terminal")

local api = vim.api

local M = {}

local ns = api.nvim_create_namespace("pageview")
local ns_status = api.nvim_create_namespace("pageview.status")

---@class pageview.Anchor
---@field line integer source line (1-based)
---@field col? integer source column (0-based), when known exactly
---@field offset integer screen rows between the window top and the cursor
---@field row? integer page line (1-based) for `line`, when known exactly...
---@field key? string ...in the layout with this key

--- The last switch between raw and page: where the cursor was put on each
--- side. While the cursor stays there, switching back returns to exactly the
--- same place, instead of going through the approximate line <-> row mapping.
---@class pageview.Placed
---@field key string layout key
---@field row integer page line (1-based)
---@field line integer source line (1-based)
---@field col? integer source column (0-based)

---@class pageview.Page
---@field buf integer page buffer
---@field raw integer source buffer
---@field gen integer bumped on every new layout; stale async work checks it
---@field key? string
---@field params? pageview.RenderParams
---@field layout? pageview.Layout
---@field anchor? pageview.Anchor where to scroll once the layout is ready
---@field placed? pageview.Placed
---@field shown table<integer, pageview.kitty.Image> slice index -> image in the terminal
---@field queue integer[] slices waiting to be captured
---@field queued table<integer, boolean>
---@field worker boolean
---@field failed? string

---@type table<integer, pageview.Page>
local pages = {}
---@type table<integer, integer>
local by_raw = {}

local WIN_OPTS = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  statuscolumn = "",
  list = false,
  wrap = false,
  cursorline = false,
  cursorcolumn = false,
  spell = false,
  colorcolumn = "",
  conceallevel = 0,
  foldenable = false,
}

---@param buf integer
---@return pageview.Page?
function M.get(buf)
  return pages[buf]
end

---@param buf integer
---@return integer? page buffer for a source buffer
function M.page_of(buf)
  return by_raw[buf]
end

---@param msg string
---@param level? integer
local function notify(msg, level)
  vim.notify("pageview: " .. msg, level or vim.log.levels.ERROR)
end

--- A window in the current tab showing the page, preferring the current one.
---@param page pageview.Page
---@return integer?
local function find_win(page)
  local cur = api.nvim_get_current_win()
  if api.nvim_win_get_buf(cur) == page.buf then
    return cur
  end
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_buf(win) == page.buf then
      return win
    end
  end
end

--- Show a short message on the first visible row (nil clears it).
---@param page pageview.Page
---@param text? string
local function set_status(page, text)
  if not api.nvim_buf_is_valid(page.buf) then
    return
  end
  api.nvim_buf_clear_namespace(page.buf, ns_status, 0, -1)
  if text then
    local win = find_win(page)
    local row = win and (vim.fn.line("w0", win) - 1) or 0
    row = math.min(row, api.nvim_buf_line_count(page.buf) - 1)
    api.nvim_buf_set_extmark(page.buf, ns_status, row, 0, {
      virt_text = { { text, "Comment" } },
      virt_text_win_col = 2,
      priority = 1,
    })
  end
end

---@param page pageview.Page
---@param count integer
local function set_line_count(page, count)
  local lines = {}
  for i = 1, count do
    lines[i] = ""
  end
  vim.bo[page.buf].modifiable = true
  api.nvim_buf_set_lines(page.buf, 0, -1, false, lines)
  vim.bo[page.buf].modifiable = false
end

--- Remove one slice from the screen and from the terminal's memory.
---@param page pageview.Page
---@param index integer
local function hide_slice(page, index)
  local img = page.shown[index]
  if not img then
    return
  end
  page.shown[index] = nil
  kitty.free(img)
  if page.layout and api.nvim_buf_is_valid(page.buf) then
    local row0, rows = render.slice_rows(page.layout, index)
    api.nvim_buf_clear_namespace(page.buf, ns, row0, row0 + rows)
  end
end

---@param page pageview.Page
local function hide_all(page)
  for index in pairs(page.shown) do
    hide_slice(page, index)
  end
end

---@param page pageview.Page
---@param index integer
---@param path string
local function show_slice(page, index, path)
  local layout = assert(page.layout)
  local row0, rows = render.slice_rows(layout, index)
  local img = kitty.show(path, layout.ncols, rows)
  page.shown[index] = img
  for r = 1, rows do
    api.nvim_buf_set_extmark(page.buf, ns, row0 + r - 1, 0, {
      virt_text = { { kitty.placeholder_row(r, layout.ncols), img.hl } },
      virt_text_win_col = layout.col0,
      hl_mode = "replace",
    })
  end
  set_status(page, nil)
end

--- Rows (1-based) that should have images: the visible rows plus one screen
--- above and below. `keep` is wider so small scrolls do not resend images.
---@param page pageview.Page
---@param win integer
---@return integer want0, integer want1, integer keep0, integer keep1
local function ranges(page, win)
  local total = page.layout.total_rows
  local top = vim.fn.line("w0", win)
  local bot = vim.fn.line("w$", win)
  local h = api.nvim_win_get_height(win)
  return math.max(1, top - h), math.min(total, bot + h), math.max(1, top - 2 * h), math.min(total, bot + 2 * h)
end

---@param layout pageview.Layout
---@param line integer 1-based buffer line
local function slice_of(layout, line)
  return math.floor((line - 1) / layout.slice_rows) + 1
end

---@param page pageview.Page
---@param index integer
---@return boolean
local function wanted(page, index)
  local win = page.layout and find_win(page)
  if not win then
    return false
  end
  local want0, want1 = ranges(page, win)
  return index >= slice_of(page.layout, want0) and index <= slice_of(page.layout, want1)
end

local start_worker

--- Show what is near the visible rows, free what scrolled far away.
---@param page pageview.Page
---@param win integer
local function update_visible(page, win)
  local layout = page.layout
  if not layout or not page.key then
    return
  end
  local want0, want1, keep0, keep1 = ranges(page, win)
  local keep_first, keep_last = slice_of(layout, keep0), slice_of(layout, keep1)
  for index in pairs(page.shown) do
    if index < keep_first or index > keep_last then
      hide_slice(page, index)
    end
  end
  local top, bot = vim.fn.line("w0", win), vim.fn.line("w$", win)
  local order = {}
  for i = slice_of(layout, top), slice_of(layout, bot) do
    order[#order + 1] = i
  end
  for i = slice_of(layout, want0), slice_of(layout, want1) do
    if i < slice_of(layout, top) or i > slice_of(layout, bot) then
      order[#order + 1] = i
    end
  end
  for _, i in ipairs(order) do
    if not page.shown[i] then
      local path = cache.slice_path(page.key, i)
      if cache.exists(path) then
        show_slice(page, i, path)
      elseif not page.queued[i] then
        page.queued[i] = true
        page.queue[#page.queue + 1] = i
      end
    end
  end
  start_worker(page)
end

--- Capture queued slices one at a time.
---@param page pageview.Page
function start_worker(page)
  if page.worker or #page.queue == 0 or page.failed or not (page.key and page.params and page.layout) then
    return
  end
  page.worker = true
  local gen = page.gen
  local key = page.key --[[@as string]]
  local params = page.params --[[@as pageview.RenderParams]]
  local layout = page.layout --[[@as pageview.Layout]]
  async.run(function()
    while page.gen == gen and #page.queue > 0 do
      local index = table.remove(page.queue, 1)
      page.queued[index] = nil
      if not page.shown[index] and wanted(page, index) then
        local path = cache.slice_path(key, index)
        if not cache.exists(path) then
          browser.with(function(b)
            render.capture(b, params, key, layout, index, path)
          end)
        end
        if page.gen == gen and not page.shown[index] and wanted(page, index) then
          show_slice(page, index, path)
        end
      end
    end
  end, function(err)
    page.worker = false
    if err and page.gen == gen then
      page.failed = err
      notify("capture failed: " .. err)
      return
    end
    if #page.queue > 0 then
      start_worker(page)
    end
  end)
end

--- Page line (1-based) where a source line (1-based) is drawn: the row that
--- holds most of the line's first row.
---@param layout pageview.Layout
---@param line integer
---@return integer
local function page_line(layout, line)
  local lnum = math.floor(position.row(layout.blocks, line - 1) + 0.5) + 1
  return math.max(1, math.min(layout.total_rows, lnum))
end

--- Where the cursor is, in source lines.
---@param page pageview.Page
---@param win integer
---@return pageview.Anchor?
local function anchor_from_page(page, win)
  local layout = page.layout
  if not layout then
    return page.anchor
  end
  local view = api.nvim_win_call(win, vim.fn.winsaveview)
  local anchor = { offset = view.lnum - view.topline, row = view.lnum, key = page.key }
  local placed = page.placed
  if placed and placed.key == page.key and placed.row == view.lnum then
    anchor.line, anchor.col = placed.line, placed.col
  else
    -- the middle of the cursor row
    anchor.line = position.line(layout.blocks, view.lnum - 0.5) + 1
  end
  return anchor
end

--- Scroll the page so the anchor's source line sits at the same screen offset.
---@param page pageview.Page
---@param win integer
---@param anchor pageview.Anchor
local function goto_anchor(page, win, anchor)
  local layout = page.layout
  if not layout then
    return
  end
  local lnum = anchor.row
  if not (lnum and anchor.key == page.key) then
    lnum = page_line(layout, anchor.line)
  end
  lnum = math.max(1, math.min(layout.total_rows, lnum))
  api.nvim_win_call(win, function()
    vim.fn.winrestview({ lnum = lnum, col = 0, topline = math.max(1, lnum - anchor.offset), leftcol = 0 })
  end)
  page.placed = { key = page.key, row = lnum, line = anchor.line, col = anchor.col }
end

--- The source position at the page cursor: exact while the cursor stays where
--- the last switch or search put it, else the start of the line drawn there.
---@param page pageview.Page
---@param win integer
---@return { line: integer, col: integer } pos 1-based line, 0-based column
---@return boolean exact
function M.cursor_source(page, win)
  local lnum = api.nvim_win_get_cursor(win)[1]
  local placed = page.placed
  if placed and placed.key == page.key and placed.row == lnum then
    return { line = placed.line, col = placed.col or 0 }, placed.col ~= nil
  end
  local line = page.layout and (position.line(page.layout.blocks, lnum - 0.5) + 1) or 1
  return { line = line, col = 0 }, false
end

--- Move the page cursor to where a source position is drawn, as a jump (so
--- `''` and Ctrl-O come back). Switching to raw from there lands on it.
---@param page pageview.Page
---@param win integer
---@param line integer 1-based
---@param col integer 0-based
function M.jump(page, win, line, col)
  local lnum = page_line(assert(page.layout), line)
  api.nvim_win_call(win, function()
    vim.cmd("normal! m'")
    api.nvim_win_set_cursor(win, { lnum, 0 })
  end)
  page.placed = { key = page.key, row = lnum, line = line, col = col }
end

---@param page pageview.Page
---@param layout pageview.Layout
local function apply_layout(page, layout)
  page.layout = layout
  page.failed = nil
  api.nvim_buf_clear_namespace(page.buf, ns, 0, -1)
  set_line_count(page, layout.total_rows)
  local win = find_win(page)
  if not win then
    return
  end
  if page.anchor then
    goto_anchor(page, win, page.anchor)
  end
  set_status(page, "rendering…")
  update_visible(page, win)
end

--- Everything the browser needs to draw this page in this window.
---@param page pageview.Page
---@param win integer
---@return pageview.RenderParams?, string? err
local function params_for(page, win)
  local size = terminal.size()
  if not size then
    return nil, "the terminal did not report its size in pixels"
  end
  local cfg = config.get()
  local name = api.nvim_buf_get_name(page.raw)
  local css
  if cfg.css then
    local f = io.open(vim.fn.expand(cfg.css), "r")
    if f then
      css = f:read("*a")
      f:close()
    end
  end
  return {
    src = table.concat(api.nvim_buf_get_lines(page.raw, 0, -1, false), "\n"),
    base_href = name ~= "" and (vim.uri_from_fname(vim.fs.dirname(name)) .. "/") or nil,
    cols = api.nvim_win_get_width(win),
    win_rows = api.nvim_win_get_height(win),
    cell_width = size.cell_width,
    cell_height = size.cell_height,
    zoom = cfg.zoom,
    theme = config.theme(),
    background = cfg.background,
    body_font = cfg.font.body,
    code_font = cfg.font.code or render.terminal_font(),
    css = css,
  }
end

local pruned = false

--- Lay the page out for this window if anything changed, then show it.
---@param page pageview.Page
---@param win integer
---@param anchor? pageview.Anchor where to scroll; default keeps the current position
function M.refresh(page, win, anchor)
  local params, perr = params_for(page, win)
  if not params then
    notify(perr --[[@as string]])
    return
  end
  local key = render.key(params, render.assets_fingerprint())
  if key == page.key and not page.failed then
    -- Same document and size: reuse the layout (or the one being made).
    if page.layout then
      update_visible(page, win)
    end
    return
  end

  page.anchor = anchor or (page.layout and anchor_from_page(page, win)) or page.anchor
  hide_all(page)
  page.gen = page.gen + 1
  page.key, page.params, page.layout = key, params, nil
  page.queue, page.queued, page.failed = {}, {}, nil

  if not pruned then
    pruned = true
    vim.schedule(function()
      cache.prune(config.get().cache_max_size, { [key] = true })
    end)
  end

  local meta = cache.load_meta(key)
  if meta and meta.version == render.VERSION then
    apply_layout(page, meta)
    return
  end

  set_status(page, "rendering…")
  local gen = page.gen
  async.run(function()
    return browser.with(function(b)
      return render.layout(b, params, key)
    end)
  end, function(err, layout)
    if page.gen ~= gen or not api.nvim_buf_is_valid(page.buf) then
      return
    end
    if err then
      page.failed = err
      set_status(page, "pageview: " .. vim.split(err, "\n")[1])
      notify(err)
      return
    end
    cache.save_meta(key, layout)
    apply_layout(page, layout)
  end)
end

---@param page pageview.Page
local function destroy(page)
  hide_all(page)
  page.gen = page.gen + 1
  pages[page.buf] = nil
  if by_raw[page.raw] == page.buf then
    by_raw[page.raw] = nil
  end
end

---@param raw integer
---@return pageview.Page
local function create(raw)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].undolevels = -1
  local name = api.nvim_buf_get_name(raw)
  pcall(api.nvim_buf_set_name, buf, "pageview://" .. (name ~= "" and name or tostring(raw)))
  vim.bo[buf].filetype = "pageview"
  vim.bo[buf].modifiable = false
  vim.b[buf].pageview_raw = raw

  ---@type pageview.Page
  local page = { buf = buf, raw = raw, gen = 0, shown = {}, queue = {}, queued = {}, worker = false }
  pages[buf] = page
  by_raw[raw] = buf

  local group = api.nvim_create_augroup("pageview.page." .. buf, { clear = true })
  api.nvim_create_autocmd("BufWinLeave", {
    group = group,
    buffer = buf,
    callback = function()
      hide_all(page)
    end,
  })
  api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    buffer = buf,
    callback = function()
      vim.schedule(function()
        local win = find_win(page)
        if win then
          M.refresh(page, win)
        end
      end)
    end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    callback = function()
      destroy(page)
      pcall(api.nvim_del_augroup_by_id, group)
    end,
  })
  if config.get().keymaps then
    local function map(lhs, reverse, desc)
      vim.keymap.set("n", lhs, function()
        require("pageview.search").next(page, api.nvim_get_current_win(), reverse, vim.v.count1)
      end, { buffer = buf, desc = desc })
    end
    map("n", false, "Next match in the source")
    map("N", true, "Previous match in the source")
  end

  api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = raw,
    callback = function()
      vim.schedule(function()
        if api.nvim_buf_is_valid(buf) then
          api.nvim_buf_delete(buf, { force = true })
        end
      end)
    end,
  })
  return page
end

--- Check that pages can be shown here. Returns an error message if not.
---@return string?
function M.unsupported()
  local info = terminal.detect()
  if not info.graphics then
    return ("this terminal (%s) cannot show images. Supported: kitty, Ghostty. See :checkhealth pageview"):format(
      info.name
    )
  end
  if not vim.o.termguicolors then
    return "'termguicolors' must be on (image ids travel as colors)"
  end
  if not terminal.size() then
    return "the terminal did not report its size in pixels"
  end
end

--- Show the page for the source buffer in `win`.
---@param win? integer
function M.open(win)
  win = win or api.nvim_get_current_win()
  local raw = api.nvim_win_get_buf(win)
  if pages[raw] then
    return
  end
  if not vim.tbl_contains(config.get().filetypes, vim.bo[raw].filetype) then
    notify(("filetype '%s' is not in `filetypes`"):format(vim.bo[raw].filetype), vim.log.levels.WARN)
    return
  end
  local err = M.unsupported()
  if err then
    notify(err)
    return
  end
  local page = by_raw[raw] and pages[by_raw[raw]] or create(raw)
  local view = api.nvim_win_call(win, vim.fn.winsaveview)
  local anchor = { line = view.lnum, col = view.col, offset = view.lnum - view.topline }
  local placed = page.placed
  if placed and placed.line == view.lnum then
    -- not moved since the last switch: back to the same page line
    anchor.row, anchor.key = placed.row, placed.key
  end
  page.anchor = anchor
  api.nvim_win_set_buf(win, page.buf)
  for k, v in pairs(WIN_OPTS) do
    vim.wo[win][0][k] = v
  end
  -- Same content and size as last time: scroll now, the layout is reused.
  if page.layout then
    goto_anchor(page, win, page.anchor)
  end
  M.refresh(page, win, page.anchor)
end

--- Go back to the source buffer, keeping the reading position.
---@param win? integer
function M.close(win)
  win = win or api.nvim_get_current_win()
  local page = pages[api.nvim_win_get_buf(win)]
  if not page then
    return
  end
  local anchor = anchor_from_page(page, win)
  if not api.nvim_buf_is_valid(page.raw) then
    return
  end
  api.nvim_win_set_buf(win, page.raw)
  if anchor then
    local last = api.nvim_buf_line_count(page.raw)
    local lnum = math.min(last, math.max(1, anchor.line))
    api.nvim_win_call(win, function()
      vim.fn.winrestview({ lnum = lnum, col = anchor.col, topline = math.max(1, lnum - anchor.offset) })
    end)
    if anchor.row and anchor.key then
      page.placed = { key = anchor.key, row = anchor.row, line = lnum, col = anchor.col }
    end
  end
end

---@param win? integer
function M.toggle(win)
  win = win or api.nvim_get_current_win()
  if pages[api.nvim_win_get_buf(win)] then
    M.close(win)
  else
    M.open(win)
  end
end

--- Pages visible in the current tab, with their windows.
---@return table<pageview.Page, integer>
local function visible_pages()
  local out = {}
  local cur = api.nvim_get_current_win()
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    local page = pages[api.nvim_win_get_buf(win)]
    if page and (not out[page] or win == cur) then
      out[page] = win
    end
  end
  return out
end

local resize_timer ---@type uv.uv_timer_t?

local function on_resize()
  resize_timer = resize_timer or assert((vim.uv or vim.loop).new_timer())
  resize_timer:stop()
  resize_timer:start(150, 0, function()
    vim.schedule(function()
      terminal.invalidate()
      for page, win in pairs(visible_pages()) do
        M.refresh(page, win)
      end
    end)
  end)
end

function M.setup_autocmds()
  local group = api.nvim_create_augroup("pageview", { clear = true })
  api.nvim_create_autocmd("WinScrolled", {
    group = group,
    callback = function()
      for id in pairs(vim.v.event) do
        local win = tonumber(id)
        if win and api.nvim_win_is_valid(win) then
          local page = pages[api.nvim_win_get_buf(win)]
          if page then
            update_visible(page, win)
          end
        end
      end
    end,
  })
  api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = group,
    callback = function(ev)
      if ev.event == "VimResized" then
        terminal.invalidate()
      end
      if next(pages) then
        on_resize()
      end
    end,
  })
  api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = "background",
    callback = function()
      if config.get().theme == nil and next(pages) then
        on_resize()
      end
    end,
  })
  api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      kitty.reapply()
      -- a colorscheme may also flip 'background'
      if config.get().theme == nil and next(pages) then
        on_resize()
      end
    end,
  })
  -- `/` and `?` in a page: cancel Neovim's search of the empty page lines and
  -- search the source instead (see search.lua).
  api.nvim_create_autocmd("CmdlineLeave", {
    group = group,
    pattern = { "/", "?" },
    callback = function()
      local win = api.nvim_get_current_win()
      local page = pages[api.nvim_win_get_buf(win)]
      if not page then
        return
      end
      local event = vim.v.event
      local text = vim.fn.getcmdline()
      vim.cmd("let v:event.abort = v:true")
      if event.abort then
        return -- <Esc> or Ctrl-C
      end
      vim.schedule(function()
        if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == page.buf then
          require("pageview.search").submit(page, win, text, event.cmdtype == "/")
        end
      end)
    end,
  })
  api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      for _, page in pairs(pages) do
        hide_all(page)
      end
      browser.shutdown(true)
    end,
  })
end

return M
