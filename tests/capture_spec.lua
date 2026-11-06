-- Captures must show the page once, not repeated tiles. The tab a headless
-- browser opens at startup used to return tiled images when capturing beyond
-- its viewport. Needs a browser and ImageMagick to inspect the pixels.

local async = require("pageview.async")
local browser = require("pageview.browser")
local config = require("pageview.config")
local render = require("pageview.render")

local magick = vim.fn.executable("magick") == 1 and { "magick" }
  or (vim.fn.executable("convert") == 1 and { "convert" })
  or nil
local it_capture = (browser.find() and magick) and it or pending

---@param args string[]
local function im(args)
  local cmd = vim.list_extend(vim.deepcopy(magick --[[@as string[] ]]), args)
  local res = vim.system(cmd, { text = true }):wait(10000)
  assert(res.code == 0, res.stderr)
  return vim.trim(res.stdout)
end

describe("capture", function()
  setup(function()
    config.setup({ browser_args = vim.fn.has("linux") == 1 and { "--no-sandbox" } or {} })
  end)

  teardown(function()
    browser.shutdown(true)
  end)

  it_capture("shows the first slice once, without repeated tiles", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    ---@type pageview.RenderParams
    local p = {
      -- a title, then a tall empty block: everything below the title must be plain background
      src = '# Title\n\n<div style="height: 2000px"></div>\n\nEnd',
      cols = 120,
      win_rows = 30,
      cell_width = 20,
      cell_height = 40,
      zoom = 1,
      theme = "github-dark",
      background = "page",
    }
    local path = dir .. "/001.png"
    local done, err
    async.run(function()
      browser.with(function(b)
        local layout = render.layout(b, p, "capture-test")
        render.capture(b, p, "capture-test", layout, 1, path)
      end)
    end, function(e)
      err, done = e, true
    end)
    assert.is_true(vim.wait(30000, function()
      return done
    end, 10))
    assert.is_nil(err)

    -- below the title (y >= 300 px) the slice is one flat color
    local spread = im({
      path,
      "-crop",
      "100%x1500+0+300",
      "+repage",
      "-colorspace",
      "gray",
      "-format",
      "%[fx:standard_deviation]",
      "info:",
    })
    assert.are.equal(0, tonumber(spread))
    -- and the edges are the article background, not white
    local edge = im({ path, "-format", "%[pixel:p{1,600}]", "info:" })
    assert.are_not.equal("srgb(255,255,255)", edge)
    vim.fn.delete(dir, "rf")
  end)
end)
