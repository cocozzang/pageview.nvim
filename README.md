# pageview.nvim

Toggle a Markdown buffer between raw text and a browser-rendered page, inside the same Neovim window.

> Work in progress. Not released yet.

The page is drawn by a headless Chromium-based browser and shown as images in the terminal, so it looks exactly
like a browser: proportional fonts, real heading sizes, spacing. You scroll it with the usual motions (`j`/`k`,
`Ctrl-d`/`Ctrl-u`, `gg`/`G`).

## Requirements

- Neovim 0.10+ with `'termguicolors'` on
- A terminal that supports the kitty graphics protocol with unicode placeholders: [kitty](https://sw.kovidgoyal.net/kitty/)
  or [Ghostty](https://ghostty.org/). tmux works with `set -g allow-passthrough on`.
- A Chromium-based browser: Google Chrome, Chromium, Brave or Microsoft Edge. It runs headless in the background,
  separate from your own browser windows.
- macOS or Linux

## Installation

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "cocozzang/pageview.nvim",
  cmd = "Pageview",
  opts = {},
}
```

`setup()` is optional. Without it the defaults below are used.

## Usage

| Command | |
|---|---|
| `:Pageview` / `:Pageview toggle` | Switch the current window between raw and page |
| `:Pageview open` | Show the page |
| `:Pageview close` | Back to the raw buffer |

No keys are mapped by default. For example:

```lua
vim.keymap.set("n", "<leader>um", "<cmd>Pageview toggle<cr>", { desc = "Toggle page view" })
```

Switching keeps your reading position. The page is rendered when you open it and again when the window width
changes; unchanged pages come from the cache.

### Statusline

`require("pageview").status()` returns `"PAGE"`, `"RAW"` (a buffer that can be shown as a page) or `""`.

```lua
-- lualine
sections = { lualine_x = { function() return require("pageview").status() end } }
```

## Configuration

```lua
require("pageview").setup({
  theme = nil, -- "github-dark" | "github-light"; nil follows 'background'
  background = "page", -- "page": only the article column | "full": whole window | "transparent"
  zoom = 1, -- multiplies the scale taken from the terminal font size
  font = {
    body = nil, -- CSS font-family list; nil uses GitHub's
    code = nil, -- nil uses the terminal font when it can be detected (Ghostty)
  },
  css = nil, -- path to a CSS file applied after the theme
  browser = nil, -- path to the browser; nil searches common locations
  browser_args = {}, -- extra browser arguments
  browser_idle_timeout = 600, -- seconds before an unused browser is closed; 0 keeps it
  filetypes = { "markdown" },
  cache_max_size = 200 * 1024 * 1024, -- bytes of rendered images kept on disk
})
```

Run `:checkhealth pageview` if something does not show up.

## How it works

1. The buffer text goes to a page shell with [markdown-it](https://github.com/markdown-it/markdown-it),
   [DOMPurify](https://github.com/cure53/DOMPurify) and
   [github-markdown-css](https://github.com/sindresorhus/github-markdown-css), loaded in a headless browser started
   with `--remote-debugging-pipe` and driven over the Chrome DevTools Protocol.
2. The page is laid out at the window width, with one terminal cell mapped to a fixed number of CSS pixels.
3. Slices of the page near the visible rows are captured as PNG files and sent to the terminal with the kitty
   graphics protocol. Each buffer line of the page buffer is one terminal row of the image.
4. Slices that scroll far away are freed from the terminal's memory again.

## Development

```sh
make deps   # busted and nlua into .luarocks (needs luarocks and LuaJIT headers)
make test   # needs a Chromium-based browser for the end-to-end tests
make lint   # lua-language-server
make fmt    # stylua
```

Bundled libraries are pinned in `assets/vendor/VERSIONS` and updated with `scripts/update-vendor.sh`.

## License

MIT. Bundled libraries keep their own licenses, included next to them in `assets/vendor/`:
markdown-it (MIT), github-markdown-css (MIT), DOMPurify (Apache-2.0 or MPL-2.0), highlight.js (BSD-3-Clause).
