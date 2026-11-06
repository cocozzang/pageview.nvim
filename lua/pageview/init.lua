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
