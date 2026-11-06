-- pageview.nvim: switch a Markdown buffer between its raw text and a page
-- rendered by a headless browser, inside the same window.

local config = require("pageview.config")

local M = {}

local initialized = false
local function init()
  if not initialized then
    initialized = true
    require("pageview.view").setup_autocmds()
  end
end

--- Configure pageview. Optional: defaults work without calling it.
---@param opts? pageview.Config|table
function M.setup(opts)
  config.setup(opts)
end

--- Show the rendered page in the current window.
---@param win? integer
function M.open(win)
  init()
  require("pageview.view").open(win)
end

--- Return to the raw buffer.
---@param win? integer
function M.close(win)
  init()
  require("pageview.view").close(win)
end

--- Switch between raw and page.
---@param win? integer
function M.toggle(win)
  init()
  require("pageview.view").toggle(win)
end

--- In a page: go to the next match of the last search pattern in the source,
--- like `n`. With `reverse`, like `N`. Takes a count.
---@param reverse? boolean
function M.search_next(reverse)
  init()
  local win = vim.api.nvim_get_current_win()
  local page = require("pageview.view").get(vim.api.nvim_win_get_buf(win))
  if page then
    require("pageview.search").next(page, win, reverse == true, vim.v.count1)
  end
end

--- In a page: open the link on the cursor row, like `gx`. With several, pick
--- one; with none, switch to raw at that line.
function M.open_link()
  init()
  local win = vim.api.nvim_get_current_win()
  local page = require("pageview.view").get(vim.api.nvim_win_get_buf(win))
  if page then
    require("pageview.links").open(page, win)
  end
end

--- "PAGE" in a page buffer, "RAW" in a buffer that can be shown as a page,
--- "" elsewhere. For statuslines.
---@param buf? integer
---@return string
function M.status(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if vim.b[buf].pageview_raw then
    return "PAGE"
  end
  if vim.tbl_contains(config.get().filetypes, vim.bo[buf].filetype) then
    return "RAW"
  end
  return ""
end

return M
