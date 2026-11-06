-- Search in a page: the pattern is looked up in the source buffer, and the
-- page cursor goes to the row where the match is drawn.
--
-- `/` and `?` use Neovim's own search command line, so history and command
-- line plugins work as usual. When it is submitted in a page buffer, the
-- command is cancelled before Neovim searches the (empty) page lines, and the
-- source is searched instead. `n` and `N` are mapped in page buffers. The last
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

---@param pat string
---@param forward boolean
---@param match pageview.Match
local function report(pat, forward, match)
  local text = (forward and "/" or "?") .. pat
  if match.wrapped and not vim.o.shortmess:find("s", 1, true) then
    echo({
      { forward and "search hit BOTTOM, continuing at TOP" or "search hit TOP, continuing at BOTTOM", "WarningMsg" },
    })
    return
  end
  echo({ { text } })
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
  report(pat, forward, match)
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
