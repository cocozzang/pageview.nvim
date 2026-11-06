-- Lay a markdown document out in the browser and capture it in slices.
--
-- Everything is aligned to terminal cells: the page is captured at
-- (cell size / scale) CSS pixels per cell, so one image pixel row maps to the
-- terminal pixel grid and slices join on cell boundaries.

local browser = require("pageview.browser")
local cache = require("pageview.cache")
local kitty = require("pageview.backend.kitty")

local M = {}

--- Rows per image slice. Small enough to capture quickly, well under the
--- 297-row limit of placeholder diacritics.
M.SLICE_ROWS = 48

--- Bump when the layout or capture logic changes so old cache entries are ignored.
M.VERSION = 2 -- 2: captures from a fresh tab (version 1 could cache tiled images)

---@class pageview.RenderParams
---@field src string markdown source
---@field base_href? string folder of the source file, for relative links
---@field cols integer window width in cells
---@field win_rows integer window height in cells
---@field cell_width number pixels
---@field cell_height number pixels
---@field zoom number
---@field theme pageview.Theme
---@field background pageview.Background
---@field body_font? string
---@field code_font? string
---@field css? string extra CSS

---@class pageview.Layout
---@field version integer
---@field total_rows integer
---@field col0 integer first window column covered by the image (0-based)
---@field ncols integer image width in cells
---@field slice_rows integer
---@field slices integer number of slices
---@field dpr number
---@field cell_width number
---@field cell_height number
---@field lines integer[][] { source line (0-based), row (0-based) } in document order

--- Device pixels per CSS pixel: follow the terminal font (snacks.nvim uses the
--- same cell_width / 8 guess), then apply the zoom.
---@param cell_width number
---@param zoom number
---@return number
function M.scale(cell_width, zoom)
  return math.max(1, cell_width / 8) * zoom
end

--- Everything that changes the pixels, for the cache key.
---@param p pageview.RenderParams
---@param assets_fingerprint string
---@return string
function M.key(p, assets_fingerprint)
  return cache.key({
    M.VERSION,
    assets_fingerprint,
    p.src,
    p.base_href or "",
    p.cols,
    p.cell_width,
    p.cell_height,
    p.zoom,
    p.theme,
    p.background,
    p.body_font or "",
    p.code_font or "",
    p.css or "",
    M.SLICE_ROWS,
  })
end

--- Turn the browser's measurements (CSS px) into a cell layout.
---@param p pageview.RenderParams
---@param m { height: number, left: number, articleWidth: number, lines: number[][] }
---@return pageview.Layout
function M.plan(p, m)
  local dpr = M.scale(p.cell_width, p.zoom)
  local cw, ch = p.cell_width, p.cell_height
  local col0, ncols = 0, p.cols
  if p.background ~= "full" then
    col0 = math.max(0, math.floor(m.left * dpr / cw + 1e-6))
    local col1 = math.min(p.cols, math.ceil((m.left + m.articleWidth) * dpr / cw - 1e-6))
    ncols = math.max(1, col1 - col0)
  end
  ncols = math.min(ncols, kitty.MAX_CELLS)
  local total_rows = math.max(1, math.ceil(m.height * dpr / ch - 1e-6))
  local lines = {}
  for _, l in ipairs(m.lines) do
    lines[#lines + 1] = { l[1], math.floor(l[2] * dpr / ch + 1e-6) }
  end
  return {
    version = M.VERSION,
    total_rows = total_rows,
    col0 = col0,
    ncols = ncols,
    slice_rows = M.SLICE_ROWS,
    slices = math.ceil(total_rows / M.SLICE_ROWS),
    dpr = dpr,
    cell_width = cw,
    cell_height = ch,
    lines = lines,
  }
end

--- First row (0-based) and row count of a slice (1-based index).
---@param layout pageview.Layout
---@param index integer
---@return integer row0, integer rows
function M.slice_rows(layout, index)
  local row0 = (index - 1) * layout.slice_rows
  return row0, math.min(layout.slice_rows, layout.total_rows - row0)
end

---@type string|false|nil
local terminal_font

--- Font family of the terminal, quoted for CSS. Only Ghostty can be asked.
---@return string?
function M.terminal_font()
  if terminal_font ~= nil then
    return terminal_font or nil
  end
  terminal_font = false
  local bin = vim.env.GHOSTTY_BIN_DIR and (vim.env.GHOSTTY_BIN_DIR .. "/ghostty") or vim.fn.exepath("ghostty")
  if bin ~= "" and vim.fn.executable(bin) == 1 then
    local ok, res = pcall(function()
      return vim.system({ bin, "+show-config" }, { text = true }):wait(2000)
    end)
    if ok and res and res.code == 0 and res.stdout then
      local family = ("\n" .. res.stdout):match("\nfont%-family = ([^\n]+)")
      if family and family ~= "" then
        terminal_font = '"' .. vim.trim(family):gsub('"', "") .. '"'
      end
    end
  end
  return terminal_font or nil
end

--- Hash of the files in an assets folder: every file outside `vendor/`, and
--- `vendor/VERSIONS` for the bundled libraries (their files only change with it).
---@param dir string
---@return string
function M.fingerprint(dir)
  local names = {}
  for name, kind in vim.fs.dir(dir, { depth = math.huge }) do
    if kind == "file" and (not vim.startswith(name, "vendor/") or name == "vendor/VERSIONS") then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  local parts = {}
  for _, name in ipairs(names) do
    local fd = io.open(dir .. "/" .. name, "rb")
    parts[#parts + 1] = name .. "\n" .. (fd and fd:read("*a") or "")
    if fd then
      fd:close()
    end
  end
  -- vim.fn would turn a string with NUL bytes into a Blob
  local all = table.concat(parts, "\n--\n"):gsub("%z", "\\0")
  return vim.fn.sha256(all):sub(1, 16)
end

---@type string?
local fingerprint
--- Fingerprint of the bundled assets, so updates invalidate the cache.
---@return string
function M.assets_fingerprint()
  fingerprint = fingerprint or M.fingerprint(browser.assets_dir())
  return fingerprint
end

local function evaluate(b, expression)
  local res = browser.call(b, "Runtime.evaluate", {
    expression = expression,
    awaitPromise = true,
    returnByValue = true,
  })
  if res.exceptionDetails then
    local d = res.exceptionDetails
    error("page script failed: " .. ((d.exception and d.exception.description) or d.text or "?"), 0)
  end
  return res.result and res.result.value
end

--- Lay the document out in the browser tab. Must run inside async.run with the
--- browser held by browser.with().
---@param b pageview.Browser
---@param p pageview.RenderParams
---@param key string
---@return pageview.Layout
function M.layout(b, p, key)
  local dpr = M.scale(p.cell_width, p.zoom)
  browser.call(b, "Emulation.setDeviceMetricsOverride", {
    width = math.max(1, math.floor(p.cols * p.cell_width / dpr)),
    height = math.max(1, math.floor(p.win_rows * p.cell_height / dpr)),
    deviceScaleFactor = dpr,
    mobile = false,
  })
  browser.call(b, "Emulation.setEmulatedMedia", {
    features = { { name = "prefers-color-scheme", value = p.theme == "github-light" and "light" or "dark" } },
  })
  if p.background == "transparent" then
    browser.call(b, "Emulation.setDefaultBackgroundColorOverride", { color = { r = 0, g = 0, b = 0, a = 0 } })
  else
    browser.call(b, "Emulation.setDefaultBackgroundColorOverride", {})
  end
  local m = evaluate(
    b,
    ("pageviewRender(%s, %s)"):format(
      vim.json.encode(p.src),
      vim.json.encode({
        baseHref = p.base_href,
        bodyFont = p.body_font,
        codeFont = p.code_font,
        css = p.css,
        background = p.background,
      })
    )
  )
  local layout = M.plan(p, m)
  evaluate(b, ("pageviewSetHeight(%.4f)"):format(layout.total_rows * p.cell_height / dpr))
  b.state = key
  return layout
end

--- Capture one slice to a PNG file. Re-lays the document out first if the tab
--- currently shows something else.
---@param b pageview.Browser
---@param p pageview.RenderParams
---@param key string
---@param layout pageview.Layout
---@param index integer
---@param path string
function M.capture(b, p, key, layout, index, path)
  if b.state ~= key then
    local again = M.layout(b, p, key)
    if again.total_rows ~= layout.total_rows or again.ncols ~= layout.ncols then
      error("layout changed while capturing", 0)
    end
  end
  local dpr, cw, ch = layout.dpr, layout.cell_width, layout.cell_height
  local row0, rows = M.slice_rows(layout, index)
  local shot = browser.call(b, "Page.captureScreenshot", {
    format = "png",
    captureBeyondViewport = true,
    clip = {
      x = layout.col0 * cw / dpr,
      y = row0 * ch / dpr,
      width = layout.ncols * cw / dpr,
      height = rows * ch / dpr,
      scale = 1,
    },
  })
  cache.write(path, vim.base64.decode(shot.data))
end

return M
