-- Small coroutine helpers so async code reads top to bottom.
--
--   async.run(function()
--     local value = async.await(function(cb) do_something(cb) end) -- cb(err, value)
--   end, function(err) ... end)

local M = {}

---@type table<thread, fun(...)>
local steps = setmetatable({}, { __mode = "k" })

--- Run `fn` in a new coroutine. `done(err, ...)` is called when it finishes or fails.
---@param fn fun(...)
---@param done? fun(err?: string, ...)
function M.run(fn, done)
  local co = coroutine.create(fn)
  local function step(...)
    local ret = vim.F.pack_len(coroutine.resume(co, ...))
    if not ret[1] then
      steps[co] = nil
      local err = debug.traceback(co, tostring(ret[2]))
      if done then
        done(err)
      else
        vim.notify("pageview: " .. err, vim.log.levels.ERROR)
      end
    elseif coroutine.status(co) == "dead" then
      steps[co] = nil
      if done then
        done(nil, unpack(ret, 2, ret.n))
      end
    end
  end
  steps[co] = step
  step()
end

--- Wait for a callback-style function. `fn(cb)` must call `cb(err, ...)` once.
--- Raises the error, returns the values.
---@param fn fun(cb: fun(err?: any, ...))
---@return any ...
function M.await(fn)
  local co = coroutine.running()
  local step = co and steps[co]
  assert(step, "pageview.async.await: must be called inside async.run")
  local sync, result = true, nil
  fn(function(...)
    if sync then
      result = vim.F.pack_len(...)
    elseif vim.in_fast_event() then
      local args = vim.F.pack_len(...)
      vim.schedule(function()
        step(vim.F.unpack_len(args))
      end)
    else
      step(...)
    end
  end)
  sync = false
  local ret = result or vim.F.pack_len(coroutine.yield())
  if ret[1] ~= nil then
    error(ret[1], 0)
  end
  return unpack(ret, 2, ret.n)
end

--- Sleep inside a coroutine.
---@param ms integer
function M.sleep(ms)
  M.await(function(cb)
    vim.defer_fn(function()
      cb(nil)
    end, ms)
  end)
end

return M
