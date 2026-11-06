-- Chrome DevTools Protocol over --remote-debugging-pipe.
--
-- The browser reads commands from fd 3 and writes replies and events to fd 4.
-- Each message is one JSON object followed by a NUL byte. No websocket needed.

local uv = vim.uv or vim.loop

local M = {}

--- Splits a byte stream into NUL-terminated messages.
---@class pageview.cdp.Decoder
---@field private chunks string[]
local Decoder = {}
Decoder.__index = Decoder
M.Decoder = Decoder

---@return pageview.cdp.Decoder
function Decoder.new()
  return setmetatable({ chunks = {} }, Decoder)
end

--- Feed raw bytes. Returns the complete messages found so far.
---@param data string
---@return string[]
function Decoder:feed(data)
  local out = {}
  local start = 1
  while true do
    local i = data:find("\0", start, true)
    if not i then
      if start <= #data then
        self.chunks[#self.chunks + 1] = data:sub(start)
      end
      break
    end
    self.chunks[#self.chunks + 1] = data:sub(start, i - 1)
    out[#out + 1] = table.concat(self.chunks)
    self.chunks = {}
    start = i + 1
  end
  return out
end

---@class pageview.cdp.Client
---@field closed boolean
---@field stderr string last bytes the browser wrote to stderr
---@field handle uv.uv_process_t
---@field pipes table<string, uv.uv_pipe_t>
---@field pending table<integer, fun(err?: string, result?: table)>
---@field listeners table<string, table<integer, fun(params: table, session?: string)>>
---@field next_id integer
---@field on_exit? fun(code: integer, signal: integer)
local Client = {}
Client.__index = Client
M.Client = Client

local MAX_STDERR = 8192
local DEFAULT_TIMEOUT = 30000

--- Start a browser and connect to it.
---@param cmd string executable
---@param args string[] arguments (must include --remote-debugging-pipe)
---@param opts? { on_exit?: fun(code: integer, signal: integer) }
---@return pageview.cdp.Client?, string? err
function M.spawn(cmd, args, opts)
  opts = opts or {}
  local self = setmetatable({
    closed = false,
    stderr = "",
    pending = {},
    listeners = {},
    next_id = 0,
    on_exit = opts.on_exit,
  }, Client)

  -- Give every fd a pipe so the stdio list has no holes.
  local pipes = {
    stdin = uv.new_pipe(false),
    stdout = uv.new_pipe(false),
    stderr = uv.new_pipe(false),
    to_browser = uv.new_pipe(false),
    from_browser = uv.new_pipe(false),
  }
  self.pipes = pipes

  ---@diagnostic disable-next-line: missing-fields
  local handle, pid_or_err = uv.spawn(cmd, {
    args = args,
    stdio = { pipes.stdin, pipes.stdout, pipes.stderr, pipes.to_browser, pipes.from_browser },
  }, function(code, signal)
    self:_on_exit(code, signal)
  end)
  if not handle then
    for _, p in pairs(pipes) do
      p:close()
    end
    return nil, tostring(pid_or_err)
  end
  self.handle = handle
  pipes.stdin:close()

  pipes.stdout:read_start(function() end)
  pipes.stderr:read_start(function(_, data)
    if data then
      self.stderr = (self.stderr .. data):sub(-MAX_STDERR)
    end
  end)

  local decoder = Decoder.new()
  pipes.from_browser:read_start(function(err, data)
    if err or not data then
      return
    end
    for _, raw in ipairs(decoder:feed(data)) do
      local ok, msg = pcall(vim.json.decode, raw, { luanil = { object = true, array = true } })
      if ok and type(msg) == "table" then
        self:_dispatch(msg)
      end
    end
  end)
  return self
end

---@package
---@param msg table
function Client:_dispatch(msg)
  if msg.id then
    local cb = self.pending[msg.id]
    self.pending[msg.id] = nil
    if cb then
      local err = msg.error and (msg.error.message or vim.inspect(msg.error)) or nil
      vim.schedule(function()
        cb(err, msg.result)
      end)
    end
  elseif msg.method then
    local fns = self.listeners[msg.method]
    if fns then
      for _, fn in pairs(fns) do
        vim.schedule(function()
          fn(msg.params or {}, msg.sessionId)
        end)
      end
    end
  end
end

---@package
function Client:_on_exit(code, signal)
  self.closed = true
  for _, p in pairs(self.pipes) do
    if not p:is_closing() then
      p:close()
    end
  end
  if not self.handle:is_closing() then
    self.handle:close()
  end
  local pending = self.pending
  self.pending = {}
  vim.schedule(function()
    for _, cb in pairs(pending) do
      cb("browser exited")
    end
    if self.on_exit then
      self.on_exit(code, signal)
    end
  end)
end

--- Send a command. `cb(err, result)` runs on the main loop.
---@param method string
---@param params? table
---@param session? string
---@param cb fun(err?: string, result?: table)
---@param timeout? integer ms
function Client:send(method, params, session, cb, timeout)
  if self.closed then
    vim.schedule(function()
      cb("browser is not running")
    end)
    return
  end
  self.next_id = self.next_id + 1
  local id = self.next_id
  local timer = assert(uv.new_timer())
  local finished = false
  self.pending[id] = function(err, result)
    if finished then
      return
    end
    finished = true
    if timer and not timer:is_closing() then
      timer:close()
    end
    cb(err, result)
  end
  timer:start(timeout or DEFAULT_TIMEOUT, 0, function()
    local pending = self.pending[id]
    self.pending[id] = nil
    if pending then
      vim.schedule(function()
        pending(("%s timed out"):format(method))
      end)
    end
  end)
  local msg = vim.json.encode({
    id = id,
    method = method,
    -- an empty Lua table would encode as [] and the browser rejects it
    params = (params == nil or next(params) == nil) and vim.empty_dict() or params,
    sessionId = session,
  })
  self.pipes.to_browser:write(msg .. "\0")
end

--- Subscribe to an event. Returns a function that unsubscribes.
---@param method string
---@param fn fun(params: table, session?: string)
---@return fun()
function Client:on(method, fn)
  self.listeners[method] = self.listeners[method] or {}
  local list = self.listeners[method]
  local key = #list + 1
  while list[key] do
    key = key + 1
  end
  list[key] = fn
  return function()
    list[key] = nil
  end
end

--- Ask the browser to quit, then kill it if it does not.
---@param cb? fun()
function Client:close(cb)
  if self.closed then
    if cb then
      vim.schedule(cb)
    end
    return
  end
  local done = false
  local function finish()
    if done then
      return
    end
    done = true
    if cb then
      cb()
    end
  end
  local prev = self.on_exit
  self.on_exit = function(...)
    if prev then
      prev(...)
    end
    finish()
  end
  self:send("Browser.close", nil, nil, function() end, 2000)
  vim.defer_fn(function()
    if not self.closed then
      pcall(self.handle.kill, self.handle, "sigkill")
    end
  end, 3000)
end

--- Block until the browser exits (used on VimLeavePre).
---@param ms integer
function Client:close_sync(ms)
  if self.closed then
    return
  end
  self:send("Browser.close", nil, nil, function() end, ms)
  vim.wait(ms, function()
    return self.closed
  end, 10)
  if not self.closed then
    pcall(self.handle.kill, self.handle, "sigkill")
  end
end

return M
