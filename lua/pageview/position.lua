-- Source lines <-> page rows, from the blocks the browser measured.
--
-- Inside a block, its source lines are spread evenly over its rows. That is
-- exact for code, where every source line is one line on the page, and close
-- for text that the browser wraps differently from the source. Nested blocks
-- (a paragraph in a list item) are looked up from the innermost one.

local M = {}

--- The smallest block whose range [b[lo], b[hi]) contains `v`; the later one
--- (deeper in the document) on ties.
---@param blocks pageview.Block[]
---@param lo integer
---@param hi integer
---@param v number
---@return pageview.Block?
local function innermost(blocks, lo, hi, v)
  local best, size
  for _, b in ipairs(blocks) do
    if b[lo] <= v and v < b[hi] then
      local s = b[hi] - b[lo]
      if not size or s <= size then
        best, size = b, s
      end
    end
  end
  return best
end

--- Row (0-based, fractional) where a source line (0-based) is drawn. Lines
--- that are not drawn (blank lines, comments, link definitions) go to the top
--- of the next block, or the bottom of the last one.
---@param blocks pageview.Block[]
---@param line integer
---@return number
function M.row(blocks, line)
  local b = innermost(blocks, 1, 2, line)
  if b then
    return b[3] + (line - b[1]) / (b[2] - b[1]) * (b[4] - b[3])
  end
  local after, bottom
  for _, x in ipairs(blocks) do
    if x[1] > line and (not after or x[1] < after[1] or (x[1] == after[1] and x[3] < after[3])) then
      after = x
    end
    if x[2] <= line and (not bottom or x[4] > bottom) then
      bottom = x[4]
    end
  end
  return after and after[3] or bottom or 0
end

--- Source line (0-based) drawn at a row (0-based, fractional). Rows between
--- blocks (margins) go to the next block down, or the last line of the last one.
---@param blocks pageview.Block[]
---@param row number
---@return integer
function M.line(blocks, row)
  local b = innermost(blocks, 3, 4, row)
  if b then
    local n = b[2] - b[1]
    return math.min(b[2] - 1, b[1] + math.floor((row - b[3]) / (b[4] - b[3]) * n))
  end
  local after, last
  for _, x in ipairs(blocks) do
    if x[3] > row and (not after or x[3] < after[3]) then
      after = x
    end
    if x[4] <= row and (not last or x[4] > last[4] or (x[4] == last[4] and x[2] > last[2])) then
      last = x
    end
  end
  if after then
    return after[1]
  end
  return last and math.max(last[1], last[2] - 1) or 0
end

return M
