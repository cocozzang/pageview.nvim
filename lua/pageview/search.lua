-- Search in a page: the pattern is looked up in the source buffer, and the
-- page cursor goes to the row where the match is drawn.
--
-- `/` and `?` use Neovim's own search command line, so history and command
-- line plugins work as usual. When it is submitted in a page buffer, the
-- command is cancelled before Neovim searches the (empty) page lines, and the
-- source is searched instead. While typing, the page follows the pattern when
-- 'incsearch' is on. `n` and `N` are mapped in page buffers. The last
-- pattern and direction are shared with normal searches, so a search started
-- in the raw buffer continues in the page and back.

local api = vim.api

local M = {}

---@class pageview.Match
---@field line integer 1-based
---@field col integer 0-based
---@field wrapped boolean

---@param chunks [string, string?][]
---@param history? boolean
local function echo(chunks, history)
  api.nvim_echo(chunks, history or false, {})
end

---@param msg string
local function error_msg(msg)
  echo({ { msg, "ErrorMsg" } }, true)
end

--- 'smartcase' as for a typed pattern: search() alone does not apply it.
---@param pat string
---@return string
local function with_case(pat)
  if vim.o.ignorecase and vim.o.smartcase then
    local plain = pat:gsub("\\.", "")
    if vim.fn.tolower(plain) ~= plain then
      return "\\C" .. pat
    end
  end
  return pat
end

--- Search the source buffer from a position, with the user's 'wrapscan',
--- 'ignorecase' and 'smartcase'. A window already showing the buffer keeps
--- its view.
---@param raw integer
---@param pat string
---@param forward boolean
---@param from { line: integer, col: integer } 1-based line, 0-based column
---@param accept_at boolean a match right at `from` counts
---@return pageview.Match? match, string? err
function M.find(raw, pat, forward, from, accept_at)
  local res = api.nvim_buf_call(raw, function()
    local view = vim.fn.winsaveview()
    local last = api.nvim_buf_line_count(raw)
    pcall(api.nvim_win_set_cursor, 0, { math.min(from.line, last), from.col })
    local flags = (forward and "" or "b") .. (vim.o.wrapscan and "w" or "W") .. (accept_at and "c" or "")
    local ok, pos = pcall(vim.fn.searchpos, with_case(pat), flags)
    vim.fn.winrestview(view)
    if not ok then
      return { err = tostring(pos):gsub("^Vim:", "") }
    end
    if pos[1] == 0 then
      return {}
    end
    local line, col = pos[1], pos[2] - 1
    local before = line < from.line or (line == from.line and col < from.col)
    local after = line > from.line or (line == from.line and col > from.col)
    return { match = { line = line, col = col, wrapped = forward and before or (not forward and after) } }
  end)
  return res.match, res.err
end

--- Message for a failed search, as Vim words it.
---@param pat string
---@param forward boolean
---@return string
local function not_found(pat, forward)
  if vim.o.wrapscan then
    return "E486: Pattern not found: " .. pat
  end
  return forward and ("E385: Search hit BOTTOM without match for: " .. pat)
    or ("E384: Search hit TOP without match for: " .. pat)
end

--- Which match of how many, as Vim shows it: "[2/5]", "[2/>99]", "W [1/5]"
--- after wrapping around.
---@param raw integer
---@param pat string
---@param match pageview.Match
---@return string?
local function count_text(raw, pat, match)
  local ok, c = pcall(api.nvim_buf_call, raw, function()
    return vim.fn.searchcount({ pattern = with_case(pat), pos = { match.line, match.col + 1, 0 }, timeout = 500 })
  end)
  if not ok or not c.total then
    return nil
  end
  local s
  if c.incomplete == 1 then
    s = "[?/??]"
  elseif c.total > c.maxcount and c.current > c.maxcount then
    s = ("[>%d/>%d]"):format(c.maxcount, c.maxcount)
  elseif c.total > c.maxcount then
    s = ("[%d/>%d]"):format(c.current, c.maxcount)
  else
    s = ("[%d/%d]"):format(c.current, c.total)
  end
  return match.wrapped and ("W " .. s) or s
end

--- Show the pattern, with the match count at the right unless 'shortmess'
--- has "S". Without the count, wrapping around gets Vim's warning instead.
---@param raw integer
---@param pat string
---@param forward boolean
---@param match pageview.Match
local function report(raw, pat, forward, match)
  local text = (forward and "/" or "?") .. pat
  local count = not vim.o.shortmess:find("S", 1, true) and count_text(raw, pat, match)
  if count then
    local room = vim.v.echospace - #count - 1
    if vim.fn.strdisplaywidth(text) > room then
      text = vim.fn.strcharpart(text, 0, math.max(0, room - 1)) .. "…"
    end
    local gap = math.max(1, vim.v.echospace - vim.fn.strdisplaywidth(text) - #count)
    echo({ { text .. string.rep(" ", gap) .. count } })
  elseif match.wrapped and not vim.o.shortmess:find("s", 1, true) then
    echo({
      { forward and "search hit BOTTOM, continuing at TOP" or "search hit TOP, continuing at BOTTOM", "WarningMsg" },
    })
  else
    echo({ { text } })
  end
end

--- Search the source from the page cursor and move the cursor to the match.
---@param page pageview.Page
---@param win integer
---@param pat string
---@param forward boolean
---@param count? integer
function M.run(page, win, pat, forward, count)
  local view = require("pageview.view")
  if not page.layout then
    error_msg("pageview: the page is still being rendered")
    return
  end
  if not api.nvim_buf_is_valid(page.raw) then
    return
  end
  local from, exact = view.cursor_source(page, win)
  -- From a row, every match on the source line drawn there is ahead of a
  -- forward search; from an exact position, as in Vim, only those after it.
  local accept_at = forward and not exact
  local match, err
  for _ = 1, count or 1 do
    match, err = M.find(page.raw, pat, forward, from, accept_at)
    if not match then
      break
    end
    from, accept_at = match, false
  end
  if err then
    error_msg(err)
    return
  end
  if not match then
    error_msg(not_found(pat, forward))
    return
  end
  view.jump(page, win, match.line, match.col)
  view.set_match(page, { line = match.line, col = match.col })
  report(page.raw, pat, forward, match)
end

--- Remember a typed search like Neovim does: history, last pattern, direction.
---@param pat string
---@param forward boolean
local function remember(pat, forward)
  vim.fn.histadd("/", pat)
  vim.fn.setreg("/", pat)
  vim.v.searchforward = forward and 1 or 0
  if vim.o.hlsearch then
    vim.v.hlsearch = 1
  end
end

--- `/` or `?` submitted in a page buffer.
---@param page pageview.Page
---@param win integer
---@param text string what was typed
---@param forward boolean
function M.submit(page, win, text, forward)
  local pat = text
  if pat == "" then
    -- an empty pattern repeats the last one
    pat = vim.fn.getreg("/")
    if pat == "" then
      error_msg("E35: No previous regular expression")
      return
    end
  end
  remember(pat, forward)
  M.run(page, win, pat, forward)
end

---@class pageview.Typing a search being typed in a page
---@field page pageview.Page
---@field win integer
---@field forward boolean
---@field from { line: integer, col: integer }
---@field exact boolean
---@field view table page window view before typing
---@field match? { line: integer, col: integer } mark before typing
---@field incsearch boolean the user's 'incsearch'

---@type pageview.Typing?
local typing

--- `/` or `?` started in a page. Neovim's own 'incsearch' is turned off while
--- typing (it would search the empty page lines); with it on, the page
--- follows the pattern instead.
---@param page pageview.Page
---@param win integer
---@param forward boolean
function M.enter(page, win, forward)
  local view = require("pageview.view")
  local from, exact = view.cursor_source(page, win)
  typing = {
    page = page,
    win = win,
    forward = forward,
    from = from,
    exact = exact,
    view = api.nvim_win_call(win, vim.fn.winsaveview),
    match = page.match,
    incsearch = vim.o.incsearch,
  }
  vim.o.incsearch = false
end

---@param t pageview.Typing
local function restore(t)
  if api.nvim_win_is_valid(t.win) then
    api.nvim_win_call(t.win, function()
      vim.fn.winrestview(t.view)
    end)
  end
  require("pageview.view").set_match(t.page, t.match)
end

--- The search text changed: show where it would go, or where we started.
---@param text string
function M.changed(text)
  local t = typing
  if not (t and t.incsearch and t.page.layout and api.nvim_win_is_valid(t.win)) then
    return
  end
  -- a pattern that is not finished yet (an open "\(") is just not found
  local match = text ~= "" and M.find(t.page.raw, text, t.forward, t.from, t.forward and not t.exact)
  if match then
    local view = require("pageview.view")
    view.preview(t.page, t.win, match.line)
    view.set_match(t.page, { line = match.line, col = match.col })
  else
    restore(t)
  end
  vim.cmd.redraw()
end

--- The search command line is left: put the page back as it was. The search
--- itself, if submitted, then starts from there.
function M.leave()
  local t = typing
  typing = nil
  if t then
    vim.o.incsearch = t.incsearch
    restore(t)
  end
end

--- `n` (reverse = false) or `N` in a page buffer.
---@param page pageview.Page
---@param win integer
---@param reverse boolean
---@param count? integer
function M.next(page, win, reverse, count)
  local pat = vim.fn.getreg("/")
  if pat == "" then
    error_msg("E35: No previous regular expression")
    return
  end
  local forward = (vim.v.searchforward == 1) ~= reverse
  if vim.o.hlsearch then
    vim.v.hlsearch = 1
  end
  M.run(page, win, pat, forward, count)
end

return M
