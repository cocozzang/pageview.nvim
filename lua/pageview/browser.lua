-- The headless browser pageview renders with.
--
-- One browser per Neovim process, started on first use, kept running, and
-- closed after `browser_idle_timeout` seconds without work. Each Neovim
-- process uses its own profile folder: two browsers sharing one profile
-- would hand off to each other and the second pipe would never answer.

local async = require("pageview.async")
local cdp = require("pageview.cdp")
local config = require("pageview.config")

local uv = vim.uv or vim.loop

local M = {}

local CANDIDATES = {
  mac = {
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
  },
  linux = {
    "google-chrome-stable",
    "google-chrome",
    "chromium",
    "chromium-browser",
    "brave-browser",
    "brave",
    "microsoft-edge-stable",
    "microsoft-edge",
  },
}

--- Path of the browser to use, or nil.
---@return string?
function M.find()
  local configured = config.get().browser
  if configured then
    local path = vim.fn.exepath(vim.fn.expand(configured))
    return path ~= "" and path or nil
  end
  if vim.fn.has("mac") == 1 then
    local home = vim.env.HOME or ""
    for _, p in ipairs(CANDIDATES.mac) do
      for _, full in ipairs({ p, home .. p }) do
        if vim.fn.executable(full) == 1 then
          return full
        end
      end
    end
  end
  for _, name in ipairs(CANDIDATES.linux) do
    local path = vim.fn.exepath(name)
    if path ~= "" then
      return path
    end
  end
  return nil
end

--- Folder holding page.html and the bundled libraries.
---@return string
function M.assets_dir()
  local here = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.normalize(vim.fn.fnamemodify(here, ":p:h:h:h") .. "/assets")
end

---@class pageview.Browser
---@field client pageview.cdp.Client
---@field session string CDP session of the rendering tab
---@field state? string key of the document currently laid out in the tab
---@field busy integer jobs running

---@type pageview.Browser?
local current
---@type fun(err?: any, b?: pageview.Browser)[]?
local waiting -- callbacks waiting for a launch in progress
local idle_timer ---@type uv.uv_timer_t?
local profile_dir ---@type string?

local function profile()
  if not profile_dir then
    profile_dir =
      vim.fs.joinpath(vim.fn.stdpath("cache") --[[@as string]], "pageview", ("profile-%d"):format(vim.fn.getpid()))
  end
  return profile_dir
end

local function call(client, method, params, session)
  return async.await(function(cb)
    client:send(method, params, session, cb)
  end)
end

---@param path string
---@return pageview.Browser
local function launch(path)
  local args = {
    "--headless=new",
    "--remote-debugging-pipe",
    "--user-data-dir=" .. profile(),
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-extensions",
    "--disable-gpu",
    "--hide-scrollbars",
    "--mute-audio",
    "--disable-background-networking",
    "--disable-component-update",
    "--disable-sync",
    "about:blank",
  }
  vim.list_extend(args, config.get().browser_args)
  local client, err = cdp.spawn(path, args, {
    on_exit = function()
      current = nil
    end,
  })
  if not client then
    error(("could not start %s: %s"):format(path, err), 0)
  end
  local ok, res = pcall(function()
    call(client, "Browser.getVersion")
    -- Reuse the tab the browser opened instead of creating a second renderer.
    local targets = call(client, "Target.getTargets").targetInfos or {}
    local target_id
    for _, t in ipairs(targets) do
      if t.type == "page" then
        target_id = t.targetId
        break
      end
    end
    if not target_id then
      target_id = call(client, "Target.createTarget", { url = "about:blank" }).targetId
    end
    local session = call(client, "Target.attachToTarget", { targetId = target_id, flatten = true }).sessionId
    call(client, "Page.enable", nil, session)
    -- Load the page shell and wait for it.
    local loaded = false
    local off = client:on("Page.loadEventFired", function(_, sid)
      if sid == session then
        loaded = true
      end
    end)
    call(client, "Page.navigate", { url = vim.uri_from_fname(M.assets_dir() .. "/page.html") }, session)
    local waited = 0
    while not loaded and waited < 10000 do
      async.sleep(10)
      waited = waited + 10
    end
    off()
    if not loaded then
      error("page.html did not load", 0)
    end
    return session
  end)
  if not ok then
    client:close()
    error(res .. (client.stderr ~= "" and ("\n" .. client.stderr) or ""), 0)
  end
  return { client = client, session = res, busy = 0 }
end

local function arm_idle_timer()
  local timeout = config.get().browser_idle_timeout
  if timeout <= 0 then
    return
  end
  idle_timer = idle_timer or assert(uv.new_timer())
  idle_timer:stop()
  idle_timer:start(timeout * 1000, 0, function()
    vim.schedule(function()
      if current and current.busy == 0 then
        M.shutdown()
      end
    end)
  end)
end

--- Get the running browser, starting it if needed. Must run inside async.run.
---@return pageview.Browser
function M.get()
  if current and not current.client.closed then
    arm_idle_timer()
    return current
  end
  local path = M.find()
  if not path then
    error("no Chromium-based browser found. Install Chrome, Chromium, Brave or Edge, or set `browser`.", 0)
  end
  if waiting then
    return async.await(function(cb)
      table.insert(waiting, cb)
    end)
  end
  waiting = {}
  local ok, res = pcall(launch, path)
  local cbs = waiting
  waiting = nil
  if ok then
    current = res
  end
  for _, cb in ipairs(cbs) do
    if ok then
      cb(nil, res)
    else
      cb(res)
    end
  end
  if not ok then
    error(res, 0)
  end
  arm_idle_timer()
  return res
end

-- The rendering tab holds one document at a time, so jobs take turns.
local lock_held = false
local lock_waiters = {} ---@type fun(err?: string)[]

--- Run `fn(browser)` with exclusive use of the rendering tab. The browser is
--- marked busy meanwhile so the idle timer does not close it. Must run inside
--- async.run.
---@param fn fun(b: pageview.Browser): any
---@return any
function M.with(fn)
  if lock_held then
    async.await(function(cb)
      table.insert(lock_waiters, cb)
    end)
  end
  lock_held = true
  local ok, res = pcall(function()
    local b = M.get()
    b.busy = b.busy + 1
    local ok2, res2 = pcall(fn, b)
    b.busy = b.busy - 1
    if not ok2 then
      error(res2, 0)
    end
    return res2
  end)
  local next_waiter = table.remove(lock_waiters, 1)
  if next_waiter then
    vim.schedule(function()
      next_waiter(nil) -- the lock passes on without being released
    end)
  else
    lock_held = false
  end
  arm_idle_timer()
  if not ok then
    error(res, 0)
  end
  return res
end

--- Send a CDP command to the rendering tab. Must run inside async.run.
---@param b pageview.Browser
---@param method string
---@param params? table
---@return table
function M.call(b, method, params)
  return call(b.client, method, params, b.session)
end

---@return boolean
function M.running()
  return current ~= nil and not current.client.closed
end

--- Close the browser. With `sync`, wait for it (used when Neovim exits).
---@param sync? boolean
function M.shutdown(sync)
  if idle_timer then
    idle_timer:stop()
  end
  local b = current
  current = nil
  local dir = profile_dir
  local function cleanup()
    if dir then
      vim.fn.delete(dir, "rf")
    end
  end
  if not b then
    cleanup()
    return
  end
  if sync then
    b.client:close_sync(2000)
    cleanup()
  else
    b.client:close(cleanup)
  end
end

return M
