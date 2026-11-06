-- `gx` in a page: open the link drawn on the cursor row.
--
-- The page buffer has only empty lines, so the cursor cannot point at a word;
-- the row is the finest it gets. One link there is opened, several are
-- offered to choose from, and with none the raw buffer is shown at that line,
-- where links can be opened as usual.

local api = vim.api
local uv = vim.uv or vim.loop

local M = {}

--- Files that are not opened in Neovim but with the system's viewer.
local VIEWED = {}
for _, list in ipairs({
  "png jpg jpeg gif webp svg bmp ico tif tiff avif heic", -- pictures
  "pdf doc docx xls xlsx ppt pptx odt ods odp", -- documents
  "zip gz tgz tar xz 7z", -- archives
  "mp3 wav ogg flac mp4 m4v mov webm mkv avi", -- sound and video
}) do
  for ext in list:gmatch("%S+") do
    VIEWED[ext] = true
  end
end

---@param msg string
---@param level? integer
local function notify(msg, level)
  vim.notify("pageview: " .. msg, level or vim.log.levels.WARN)
end

--- Links drawn on a page row (0-based), in document order. A link that only
--- touches the row (the line above or below it) counts only if nothing else is
--- there.
---@param layout pageview.Layout
---@param row integer
---@return pageview.Link[]
function M.on_row(layout, row)
  local mostly, touching = {}, {}
  for _, link in ipairs(layout.links or {}) do
    local best = 0
    for _, r in ipairs(link.rows) do
      best = math.max(best, math.min(r[2], row + 1) - math.max(r[1], row))
    end
    if best >= 0.3 then
      mostly[#mostly + 1] = link
    elseif best > 0 then
      touching[#touching + 1] = link
    end
  end
  return #mostly > 0 and mostly or touching
end

--- Open a link: web and mail links with the system's handler, files of the
--- document's folder in Neovim (pictures, PDFs and such with the system's
--- viewer).
---@param page pageview.Page
---@param win integer
---@param link pageview.Link
function M.follow(page, win, link)
  local scheme = link.url:match("^(%a[%w+.-]*):")
  if scheme ~= "file" then
    local _, err = vim.ui.open(link.url)
    if err then
      notify(err, vim.log.levels.ERROR)
    end
    return
  end
  if not (page.params and page.params.base_href) and not link.href:match("^%a[%w+.-]*:") then
    notify("the buffer has no file name, so relative links have no folder")
    return
  end
  local path = vim.uri_to_fname((link.url:gsub("[?#].*$", "")))
  local st = uv.fs_stat(path)
  if not st then
    notify("no such file: " .. vim.fn.fnamemodify(path, ":~:."))
    return
  end
  local ext = path:match("%.(%w+)$")
  if st.type == "file" and ext and VIEWED[ext:lower()] then
    local _, err = vim.ui.open(path)
    if err then
      notify(err, vim.log.levels.ERROR)
    end
    return
  end
  api.nvim_win_call(win, function()
    vim.cmd.edit(vim.fn.fnameescape(path))
  end)
end

--- `gx` in a page.
---@param page pageview.Page
---@param win integer
function M.open(page, win)
  local layout = page.layout
  if not layout then
    notify("the page is still being rendered")
    return
  end
  local links = M.on_row(layout, api.nvim_win_get_cursor(win)[1] - 1)
  if #links == 0 then
    require("pageview.view").close(win)
  elseif #links == 1 then
    M.follow(page, win, links[1])
  else
    vim.ui.select(links, {
      prompt = "Open link",
      format_item = function(link)
        return link.text ~= "" and link.text ~= link.href and (link.text .. "  " .. link.href) or link.href
      end,
    }, function(link)
      if link and api.nvim_win_is_valid(win) then
        M.follow(page, win, link)
      end
    end)
  end
end

return M
