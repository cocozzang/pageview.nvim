---@alias pageview.Background "page"|"full"|"transparent"
---@alias pageview.Theme "github-dark"|"github-light"

---@class pageview.Config
---@field theme? pageview.Theme Theme preset. `nil` follows 'background'.
---@field background pageview.Background "page": capture only the article column; "full": fill the window with the theme background; "transparent": no background.
---@field zoom number Multiplier on top of the terminal font scale.
---@field font pageview.FontConfig
---@field css? string Path to a CSS file applied after the theme.
---@field browser? string Path to a Chromium-based browser. `nil` searches common locations.
---@field browser_args string[] Extra command-line arguments for the browser.
---@field browser_idle_timeout integer Seconds without rendering before the browser is closed. 0 keeps it running.
---@field filetypes string[] Filetypes that can be shown as a page.
---@field cache_max_size integer Bytes of rendered images kept on disk.
---@field keymaps boolean Map `n`, `N` and `gx` in page buffers.

---@class pageview.FontConfig
---@field body? string CSS font-family list for text. `nil` uses GitHub's list.
---@field code? string CSS font-family list for code. `nil` uses the terminal font when it can be detected.

local M = {}

---@type pageview.Config
M.defaults = {
  theme = nil,
  background = "page",
  zoom = 1,
  font = { body = nil, code = nil },
  css = nil,
  browser = nil,
  browser_args = {},
  browser_idle_timeout = 600,
  filetypes = { "markdown" },
  cache_max_size = 200 * 1024 * 1024,
  keymaps = true,
}

---@type pageview.Config
local current = vim.deepcopy(M.defaults)

---@param cond boolean
---@param msg string
local function check(errors, cond, msg)
  if not cond then
    errors[#errors + 1] = msg
  end
end

local function is_list_of_strings(v)
  if type(v) ~= "table" then
    return false
  end
  for _, s in ipairs(v) do
    if type(s) ~= "string" then
      return false
    end
  end
  return true
end

--- Validate a full config table.
---@param c pageview.Config
---@return boolean ok, string? err
function M.validate(c)
  local e = {}
  check(
    e,
    c.theme == nil or c.theme == "github-dark" or c.theme == "github-light",
    "theme: expected nil, 'github-dark' or 'github-light'"
  )
  check(
    e,
    c.background == "page" or c.background == "full" or c.background == "transparent",
    "background: expected 'page', 'full' or 'transparent'"
  )
  check(e, type(c.zoom) == "number" and c.zoom > 0, "zoom: expected a positive number")
  check(e, type(c.font) == "table", "font: expected a table")
  if type(c.font) == "table" then
    check(e, c.font.body == nil or type(c.font.body) == "string", "font.body: expected a string")
    check(e, c.font.code == nil or type(c.font.code) == "string", "font.code: expected a string")
  end
  check(e, c.css == nil or type(c.css) == "string", "css: expected a file path")
  check(e, c.browser == nil or type(c.browser) == "string", "browser: expected a file path")
  check(e, is_list_of_strings(c.browser_args), "browser_args: expected a list of strings")
  check(
    e,
    type(c.browser_idle_timeout) == "number" and c.browser_idle_timeout >= 0,
    "browser_idle_timeout: expected a number >= 0"
  )
  check(e, is_list_of_strings(c.filetypes), "filetypes: expected a list of strings")
  check(e, type(c.cache_max_size) == "number" and c.cache_max_size >= 0, "cache_max_size: expected a number >= 0")
  check(e, type(c.keymaps) == "boolean", "keymaps: expected a boolean")
  if #e > 0 then
    return false, table.concat(e, "\n")
  end
  return true
end

--- Merge user options over the defaults. `vim.g.pageview` is read too, so
--- the plugin can be configured without calling setup().
---@param opts? table
function M.setup(opts)
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), vim.g.pageview or {}, opts or {})
  local ok, err = M.validate(merged)
  if not ok then
    vim.notify("pageview: invalid config\n" .. err, vim.log.levels.ERROR)
    return
  end
  current = merged
end

---@return pageview.Config
function M.get()
  return current
end

--- Theme to use right now.
---@return pageview.Theme
function M.theme()
  return current.theme or (vim.o.background == "light" and "github-light" or "github-dark")
end

-- Apply vim.g.pageview even when setup() is never called.
if vim.g.pageview then
  M.setup()
end

return M
