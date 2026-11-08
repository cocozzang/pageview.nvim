-- Finding the bundled assets in a git checkout and in a luarocks install.

local browser = require("pageview.browser")

local uv = vim.uv or vim.loop

---@param path string
local function touch(path)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "w"))
  f:close()
end

describe("assets", function()
  local root, rtp

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    root = assert(uv.fs_realpath(root)) -- macOS: /var is /private/var
    rtp = vim.o.runtimepath
    vim.o.runtimepath = vim.env.VIMRUNTIME -- without this checkout's plugin folder
  end)

  after_each(function()
    vim.o.runtimepath = rtp
    vim.fn.delete(root, "rf")
  end)

  it("are beside the lua folder in a git checkout", function()
    touch(root .. "/repo/lua/pageview/browser.lua")
    touch(root .. "/repo/assets/page.html")
    assert.equal(root .. "/repo/assets", browser.find_assets(root .. "/repo/lua/pageview/browser.lua"))
  end)

  it("are beside plugin/pageview.lua in a luarocks install", function()
    -- luarocks: modules in share/lua, copied folders in the rock's folder
    local lua_file = root .. "/tree/share/lua/5.1/pageview/browser.lua"
    local rock = root .. "/tree/lib/luarocks/rocks-5.1/pageview.nvim/0.1.0-1"
    touch(lua_file)
    touch(rock .. "/plugin/pageview.lua")
    touch(rock .. "/assets/page.html")
    vim.opt.runtimepath:append(rock)
    assert.equal(rock .. "/assets", browser.find_assets(lua_file))
  end)

  it("fall back to the first guess when missing", function()
    local lua_file = root .. "/repo/lua/pageview/browser.lua"
    touch(lua_file)
    assert.equal(root .. "/repo/assets", browser.find_assets(lua_file))
  end)

  it("are found for this checkout", function()
    vim.o.runtimepath = rtp
    assert.is_not_nil(uv.fs_stat(browser.assets_dir() .. "/page.html"))
  end)
end)
