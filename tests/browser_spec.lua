-- Browser lifetime, with a real headless browser.
-- Skipped when no Chromium-based browser is installed.

local async = require("pageview.async")
local browser = require("pageview.browser")
local config = require("pageview.config")

local it_browser = browser.find() and it or pending
local uv = vim.uv or vim.loop

---@return pageview.Browser
local function get()
  local b, err, done
  async.run(browser.get, function(e, res)
    err, b, done = e, res, true
  end)
  assert.is_true(vim.wait(30000, function()
    return done
  end, 10))
  assert.is_nil(err)
  return b
end

describe("browser", function()
  setup(function()
    config.setup({ browser_args = vim.fn.has("linux") == 1 and { "--no-sandbox" } or {} })
  end)

  teardown(function()
    browser.shutdown(true)
  end)

  it_browser("keeps a new browser when the old one reports its exit late", function()
    local old = get()
    local old_exit = assert(old.client.on_exit)
    browser.shutdown(true)
    local new = get()
    old_exit(0, 0) -- as if the old browser's exit arrived only now
    assert.is_true(browser.running())
    assert.are.equal(new, get())
  end)

  it_browser("gives every launch its own profile folder and removes it", function()
    local old = get()
    browser.shutdown(true)
    assert.is_nil(uv.fs_stat(old.profile), "profile folder left behind")
    local new = get()
    assert.are_not.equal(old.profile, new.profile)
    assert.is_not_nil(uv.fs_stat(new.profile))
  end)

  it_browser("removes profile folders left behind before a launch", function()
    local root = vim.fs.dirname(get().profile)
    -- a process that is gone
    local handle, dead_pid
    handle, dead_pid = uv.spawn("true", {}, function()
      handle:close()
    end)
    assert.is_true(vim.wait(5000, function()
      return handle:is_closing()
    end, 10))
    local function folder(name)
      local path = vim.fs.joinpath(root, name)
      vim.fn.mkdir(path, "p")
      return path
    end
    local mine = folder(("profile-%d-0"):format(vim.fn.getpid()))
    local gone = folder(("profile-%d-1"):format(dead_pid))
    local alive = folder("profile-1-1") -- pid 1 is always running

    browser.shutdown(true)
    get()
    assert.is_nil(uv.fs_stat(mine))
    assert.is_nil(uv.fs_stat(gone))
    assert.is_not_nil(uv.fs_stat(alive))
    vim.fn.delete(alive, "rf")
  end)
end)
