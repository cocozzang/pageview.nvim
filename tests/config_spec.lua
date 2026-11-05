local config = require("pageview.config")

describe("config", function()
  after_each(function()
    config.setup({})
  end)

  it("has valid defaults", function()
    assert.is_true((config.validate(config.defaults)))
  end)

  it("merges user options over the defaults", function()
    config.setup({ zoom = 1.5, font = { code = "Iosevka" } })
    local c = config.get()
    assert.are.equal(1.5, c.zoom)
    assert.are.equal("Iosevka", c.font.code)
    assert.are.equal("page", c.background)
  end)

  it("rejects bad values and keeps the previous config", function()
    local notified
    local orig = vim.notify
    vim.notify = function(msg)
      notified = msg
    end
    config.setup({ background = "pink", zoom = -1 })
    vim.notify = orig
    assert.matches("background", notified)
    assert.matches("zoom", notified)
    assert.are.equal("page", config.get().background)
  end)

  it("follows 'background' when no theme is set", function()
    local bg = vim.o.background
    vim.o.background = "light"
    assert.are.equal("github-light", config.theme())
    vim.o.background = "dark"
    assert.are.equal("github-dark", config.theme())
    vim.o.background = bg
  end)
end)
