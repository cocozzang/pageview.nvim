if vim.g.loaded_pageview then
  return
end
vim.g.loaded_pageview = true

local subcommands = { "toggle", "open", "close" }

vim.api.nvim_create_user_command("Pageview", function(args)
  local sub = args.fargs[1] or "toggle"
  if not vim.tbl_contains(subcommands, sub) then
    vim.notify("pageview: unknown subcommand '" .. sub .. "'", vim.log.levels.ERROR)
    return
  end
  require("pageview")[sub]()
end, {
  nargs = "?",
  desc = "Switch a Markdown buffer between raw text and a rendered page",
  complete = function(lead)
    return vim.tbl_filter(function(s)
      return s:find(lead, 1, true) == 1
    end, subcommands)
  end,
})
