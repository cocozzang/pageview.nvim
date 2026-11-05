local kitty = require("pageview.backend.kitty")
local terminal = require("pageview.terminal")

local function codepoints(s)
  return vim.fn.str2list(s)
end

describe("kitty backend", function()
  it("encodes row and column as diacritics after each placeholder", function()
    local cps = codepoints(kitty.placeholder_row(2, 3))
    assert.are.same({
      0x10EEEE,
      0x030D, -- row 2
      0x0305, -- column 1
      0x10EEEE,
      0x030D,
      0x030D, -- column 2
      0x10EEEE,
      0x030D,
      0x030E, -- column 3
    }, cps)
  end)

  it("supports up to 297 cells", function()
    assert.are.equal(297, kitty.MAX_CELLS)
    assert.has_error(function()
      kitty.placeholder_row(298, 1)
    end)
  end)

  it("builds graphics commands", function()
    assert.are.equal("\27_Ga=d,d=I,i=7\27\\", kitty.command({ a = "d", d = "I", i = 7 }))
    assert.are.equal("\27_Ga=T,f=100;cGF0aA==\27\\", kitty.command({ a = "T", f = 100 }, "cGF0aA=="))
  end)

  it("wraps commands for tmux", function()
    assert.are.equal("\27Ptmux;\27\27_Gx\27\27\\\27\\", terminal.tmux_wrap("\27_Gx\27\\"))
  end)

  it("restores its highlight groups after :colorscheme clears them", function()
    terminal._writer = function() end
    local img = kitty.show("/tmp/a.png", 1, 1)
    vim.cmd("highlight clear")
    kitty.reapply()
    assert.are.equal(img.id, vim.api.nvim_get_hl(0, { name = img.hl }).fg)
    kitty.free(img)
    terminal._writer = nil
  end)

  it("sends the file path and frees with d=I", function()
    local written = {}
    terminal._writer = function(data)
      written[#written + 1] = data
    end
    local img = kitty.show("/tmp/a.png", 10, 4)
    kitty.free(img)
    terminal._writer = nil
    local all = table.concat(written)
    assert.matches("a=T", all, 1, true)
    assert.matches("U=1", all, 1, true)
    assert.matches("c=10", all, 1, true)
    assert.matches("r=4", all, 1, true)
    assert.matches(vim.base64.encode("/tmp/a.png"), all, 1, true)
    assert.matches("d=I", all, 1, true)
    assert.matches("i=" .. img.id, all, 1, true)
  end)
end)
