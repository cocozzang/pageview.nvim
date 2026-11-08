local M = {}

function M.check()
  local health = vim.health
  local config = require("pageview.config")
  local terminal = require("pageview.terminal")
  local browser = require("pageview.browser")

  health.start("pageview: Neovim")
  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Neovim 0.10 or newer is required")
  end
  if vim.o.termguicolors then
    health.ok("'termguicolors' is on")
  else
    health.error(
      "'termguicolors' is off",
      { "Images are found through 24-bit colors. Add `vim.o.termguicolors = true`." }
    )
  end
  local ok, err = config.validate(config.get())
  if ok then
    health.ok("configuration is valid")
  else
    health.error("invalid configuration:\n" .. err)
  end

  health.start("pageview: terminal")
  local info = terminal.detect()
  if info.graphics then
    health.ok(("%s supports kitty graphics with unicode placeholders"):format(info.name))
  else
    health.error(("terminal not supported: %s"):format(info.name), {
      "Supported: kitty, Ghostty.",
      "If your terminal supports kitty unicode placeholders, set PAGEVIEW_TERMINAL=kitty.",
    })
  end
  if info.tmux then
    health.info(
      "inside tmux: images need `set -g allow-passthrough on` (or `all`) in tmux.conf. pageview does not change tmux settings."
    )
  end
  local size = terminal.size()
  if size then
    health.ok(
      ("cell size %.1f x %.1f px (%d x %d cells, %d x %d px)"):format(
        size.cell_width,
        size.cell_height,
        size.cols,
        size.rows,
        size.width,
        size.height
      )
    )
  else
    health.error("the terminal does not report its size in pixels (TIOCGWINSZ)")
  end

  health.start("pageview: browser")
  local path = browser.find()
  if not path then
    health.error("no Chromium-based browser found", {
      "Install Google Chrome, Chromium, Brave or Microsoft Edge,",
      "or set `browser` to the executable path.",
    })
  else
    local res = vim.system({ path, "--version" }, { text = true }):wait(5000)
    local version = res and res.code == 0 and vim.trim(res.stdout or "") or "version unknown"
    health.ok(("%s (%s)"):format(path, version))
  end
  local assets = browser.assets_dir()
  if vim.uv.fs_stat(assets .. "/page.html") then
    health.ok("assets found: " .. assets)
  else
    health.error("assets missing: " .. assets)
  end
  health.info("cache: " .. require("pageview.cache").root())
end

return M
