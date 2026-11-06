-- Rendered pages on disk: stdpath("cache")/pageview/pages/<key>/
--   meta.json  layout (rows, crop, source line positions)
--   NNN.png    image slices, captured on demand

local uv = vim.uv or vim.loop

local M = {}

---@return string
function M.root()
  return vim.fs.joinpath(vim.fn.stdpath("cache") --[[@as string]], "pageview")
end

---@param key string
---@return string
function M.dir(key)
  return vim.fs.joinpath(M.root(), "pages", key)
end

--- Stable key for everything that changes the pixels.
---@param parts table
---@return string
function M.key(parts)
  return vim.fn.sha256(vim.json.encode(parts)):sub(1, 32)
end

---@param key string
---@return table?
function M.load_meta(key)
  local path = vim.fs.joinpath(M.dir(key), "meta.json")
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local ok, meta = pcall(vim.json.decode, f:read("*a"))
  f:close()
  if not ok or type(meta) ~= "table" then
    return nil
  end
  uv.fs_utime(M.dir(key), os.time(), os.time()) -- mark as recently used
  return meta
end

---@param key string
---@param meta table
function M.save_meta(key, meta)
  local dir = M.dir(key)
  vim.fn.mkdir(dir, "p")
  local f = assert(io.open(vim.fs.joinpath(dir, "meta.json"), "w"))
  f:write(vim.json.encode(meta))
  f:close()
end

---@param key string
---@param index integer
---@return string
function M.slice_path(key, index)
  return vim.fs.joinpath(M.dir(key), ("%03d.png"):format(index))
end

---@param path string
---@return boolean
function M.exists(path)
  return uv.fs_stat(path) ~= nil
end

--- Write bytes atomically (write to a temp file, then rename).
---@param path string
---@param data string
function M.write(path, data)
  local tmp = path .. ".tmp"
  local f = assert(io.open(tmp, "wb"))
  f:write(data)
  f:close()
  assert(uv.fs_rename(tmp, path))
end

--- Delete least recently used pages until the total size is under `max_bytes`.
---@param max_bytes integer
---@param keep? table<string, boolean> keys that must not be deleted
function M.prune(max_bytes, keep)
  local pages = vim.fs.joinpath(M.root(), "pages")
  if not uv.fs_stat(pages) then
    return
  end
  local entries, total = {}, 0
  for name, kind in vim.fs.dir(pages) do
    if kind == "directory" then
      local dir = vim.fs.joinpath(pages, name)
      local size = 0
      for file in vim.fs.dir(dir) do
        local st = uv.fs_stat(vim.fs.joinpath(dir, file))
        size = size + (st and st.size or 0)
      end
      local st = uv.fs_stat(dir)
      entries[#entries + 1] = { key = name, dir = dir, size = size, mtime = st and st.mtime.sec or 0 }
      total = total + size
    end
  end
  table.sort(entries, function(a, b)
    return a.mtime < b.mtime
  end)
  for _, e in ipairs(entries) do
    if total <= max_bytes then
      break
    end
    if not (keep and keep[e.key]) then
      vim.fn.delete(e.dir, "rf")
      total = total - e.size
    end
  end
end

return M
