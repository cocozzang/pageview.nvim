-- The headless browser pageview renders with.
--
-- One browser per Neovim process, started on first use, kept running, and
-- closed after `browser_idle_timeout` seconds without work. Every launch gets
-- its own profile folder: two browsers sharing one profile hand off to each
-- other, so a new browser started while the last one is still shutting down
-- would exit at once.

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

--- Where the assets folder is for a module file at `lua_file`. In a git
--- checkout it is beside the lua folder. A luarocks install puts the lua files
--- in the tree's share/lua and the other folders in the rock's own folder,
--- which plugin managers (rocks.nvim) add to 'runtimepath': there it is beside
--- plugin/pageview.lua. Falls back to the first guess, for checkhealth to
--- report.
---@param lua_file string
---@return string
function M.find_assets(lua_file)
  local candidates = { vim.fn.fnamemodify(lua_file, ":p:h:h:h") .. "/assets" }
  for _, plugin in ipairs(vim.api.nvim_get_runtime_file("plugin/pageview.lua", true)) do
    candidates[#candidates + 1] = vim.fn.fnamemodify(plugin, ":p:h:h") .. "/assets"
  end
  for _, dir in ipairs(candidates) do
    if vim.uv.fs_stat(dir .. "/page.html") then
      return vim.fs.normalize(dir)
    end
  end
  return vim.fs.normalize(candidates[1])
end

local assets ---@type string?

--- Folder holding page.html and the bundled libraries.
---@return string
function M.assets_dir()
  if assets then
    return assets
  end
  local dir = M.find_assets(debug.getinfo(1, "S").source:sub(2))
  if vim.uv.fs_stat(dir .. "/page.html") then
    assets = dir -- not kept while missing: 'runtimepath' may still change
  end
  return dir
end

---@class pageview.Browser
---@field client pageview.cdp.Client
---@field session string CDP session of the rendering tab
---@field state? string key of the document currently laid out in the tab
---@field busy integer jobs running
---@field profile string its profile folder, removed when it exits

---@type pageview.Browser?
local current
---@type fun(err?: any, b?: pageview.Browser)[]?
local waiting -- callbacks waiting for a launch in progress
local idle_timer ---@type uv.uv_timer_t?
local launches = 0

---@return string
local function new_profile()
  launches = launches + 1
  return vim.fs.joinpath(
    vim.fn.stdpath("cache") --[[@as string]],
    "pageview",
    ("profile-%d-%d"):format(vim.fn.getpid(), launches)
  )
end

--- Remove profile folders left behind. A browser's helper processes can still
--- write to its folder after it exited and the folder was removed, and Neovim
--- itself may have been killed. Before each launch, folders of this Neovim's
--- earlier browsers and of Neovim processes that are gone are removed.
---@param keep string the folder about to be used
local function sweep_profiles(keep)
  local root = vim.fs.dirname(keep)
  if not uv.fs_stat(root) then
    return
  end
  local me = vim.fn.getpid()
  for name, kind in vim.fs.dir(root) do
    local pid = kind == "directory" and tonumber(name:match("^profile%-(%d+)"))
    if pid then
      local path = vim.fs.joinpath(root, name)
      local stale
      if pid == me then
        stale = path ~= keep and not (current and current.profile == path)
      else
        local ok, _, err = uv.kill(pid, 0)
        stale = not ok and err == "ESRCH"
      end
      if stale then
        vim.fn.delete(path, "rf")
      end
    end
  end
end

local function call(client, method, params, session)
  return async.await(function(cb)
    client:send(method, params, session, cb)
  end)
end

---@param path string
---@return pageview.Browser
local function launch(path)
  -- A missing file still "loads" (as an error page), so check first.
  local page = M.assets_dir() .. "/page.html"
  if not vim.uv.fs_stat(page) then
    error(("bundled files not found: %s. See :checkhealth pageview"):format(page), 0)
  end
  local dir = new_profile()
  sweep_profiles(dir)
  local args = {
    "--headless=new",
    "--remote-debugging-pipe",
    "--user-data-dir=" .. dir,
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
  local b ---@type pageview.Browser?
  local client, err = cdp.spawn(path, args, {
    on_exit = function()
      -- An old browser can report its exit after a new one started.
      if b and current == b then
        current = nil
      end
      vim.fn.delete(dir, "rf")
    end,
  })
  if not client then
    error(("could not start %s: %s"):format(path, err), 0)
  end
  local ok, res = pcall(function()
    call(client, "Browser.getVersion")
    -- Render in a tab we create. The tab the browser opens at startup returns
    -- repeated tiles when capturing beyond its viewport, so close it instead
    -- of reusing it (that also frees its renderer).
    local initial = call(client, "Target.getTargets").targetInfos or {}
    local target_id = call(client, "Target.createTarget", { url = "about:blank" }).targetId
    for _, t in ipairs(initial) do
      if t.type == "page" and t.targetId ~= target_id then
        pcall(call, client, "Target.closeTarget", { targetId = t.targetId })
      end
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
    call(client, "Page.navigate", { url = vim.uri_from_fname(page) }, session)
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
  b = { client = client, session = res, busy = 0, profile = dir }
  return b
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
  if not b then
    return
  end
  if sync then
    b.client:close_sync(2000)
    -- Neovim may be exiting: do not wait for the exit callback to remove it
    vim.fn.delete(b.profile, "rf")
  else
    b.client:close()
  end
end

return M
