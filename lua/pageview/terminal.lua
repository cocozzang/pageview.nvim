-- What the terminal is, how big its cells are in pixels, and how to write
-- escape sequences to it.
--
-- tmux is only detected through $TMUX so graphics commands can be wrapped in a
-- passthrough sequence. pageview never runs tmux commands.

local M = {}

---@class pageview.TerminalInfo
---@field name string e.g. "ghostty", "kitty", "wezterm", "unknown"
---@field tmux boolean running inside tmux
---@field graphics boolean supports kitty graphics with unicode placeholders

---@param name string
local function env(name)
  local v = os.getenv(name)
  return v ~= nil and v ~= "" and v or nil
end

--- Detect the terminal from environment variables. Inside tmux these are the
--- values inherited from the terminal that started the tmux server.
---@return pageview.TerminalInfo
function M.detect()
  local term = env("TERM") or ""
  local program = (env("TERM_PROGRAM") or ""):lower()
  local name = "unknown"
  if env("PAGEVIEW_TERMINAL") then
    name = env("PAGEVIEW_TERMINAL") --[[@as string]]
  elseif term == "xterm-ghostty" or program == "ghostty" or env("GHOSTTY_RESOURCES_DIR") or env("GHOSTTY_BIN_DIR") then
    name = "ghostty"
  elseif term == "xterm-kitty" or env("KITTY_WINDOW_ID") or env("KITTY_PID") then
    name = "kitty"
  elseif program == "wezterm" or env("WEZTERM_EXECUTABLE") or env("WEZTERM_PANE") then
    name = "wezterm"
  end
  return {
    name = name,
    tmux = env("TMUX") ~= nil,
    graphics = name == "ghostty" or name == "kitty",
  }
end

---@class pageview.CellSize
---@field cols integer
---@field rows integer
---@field width integer screen width in pixels
---@field height integer screen height in pixels
---@field cell_width number
---@field cell_height number

---@type pageview.CellSize|false|nil
local cached_size

---@type pageview.CellSize?
M._size = nil -- tests set a fixed size

--- Screen and cell size in pixels from TIOCGWINSZ. `nil` when the terminal
--- does not report pixel sizes.
---@return pageview.CellSize?
function M.size()
  if M._size then
    return M._size
  end
  if cached_size ~= nil then
    return cached_size or nil
  end
  cached_size = false
  local ok_ffi, ffi = pcall(require, "ffi")
  if not ok_ffi then
    return nil
  end
  pcall(
    ffi.cdef,
    [[
    typedef struct { unsigned short row, col, xpixel, ypixel; } pageview_winsize;
    int ioctl(int fd, unsigned long request, ...);
  ]]
  )
  local request
  if vim.fn.has("mac") == 1 or vim.fn.has("bsd") == 1 then
    request = 0x40087468
  elseif vim.fn.has("linux") == 1 then
    request = 0x5413
  else
    return nil
  end
  local ws = ffi.new("pageview_winsize") --[[@as { row: integer, col: integer, xpixel: integer, ypixel: integer }]]
  local ok, res = pcall(ffi.C.ioctl, 1, request, ws)
  if not ok or res ~= 0 or ws.col == 0 or ws.row == 0 or ws.xpixel == 0 or ws.ypixel == 0 then
    return nil
  end
  cached_size = {
    cols = ws.col,
    rows = ws.row,
    width = ws.xpixel,
    height = ws.ypixel,
    cell_width = ws.xpixel / ws.col,
    cell_height = ws.ypixel / ws.row,
  }
  return cached_size
end

--- Forget the cached size (call on VimResized).
function M.invalidate()
  cached_size = nil
end

--- Wrap an escape sequence so tmux passes it to the outer terminal.
---@param data string
---@return string
function M.tmux_wrap(data)
  return "\27Ptmux;" .. data:gsub("\27", "\27\27") .. "\27\\"
end

---@type fun(data: string)?
M._writer = nil -- tests replace this

--- Write raw bytes to the terminal.
---@param data string
function M.write(data)
  if M.detect().tmux then
    data = M.tmux_wrap(data)
  end
  if M._writer then
    M._writer(data)
    return
  end
  io.stdout:write(data)
  io.stdout:flush()
end

return M
