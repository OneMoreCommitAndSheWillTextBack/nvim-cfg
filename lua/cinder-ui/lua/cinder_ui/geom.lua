-- cinder_ui.geom: pure rectangle math. All rectangles are 1-based {row, col, height, width}.
local M = {}

function M.new(row, col, height, width)
  return { row = row or 1, col = col or 1, height = height or 0, width = width or 0 }
end

function M.copy(r)
  return M.new(r.row, r.col, r.height, r.width)
end

function M.empty(r)
  return r == nil or r.height <= 0 or r.width <= 0
end

-- inset(r, 1) or inset(r, { top = 1, right = 0, bottom = 1, left = 0 })
function M.inset(r, o)
  if o == nil or o == 0 then
    return M.copy(r)
  end
  local top, right, bottom, left
  if type(o) == "number" then
    top, right, bottom, left = o, o, o, o
  else
    top, right, bottom, left = o.top or 0, o.right or 0, o.bottom or 0, o.left or 0
  end
  return M.new(r.row + top, r.col + left, r.height - top - bottom, r.width - left - right)
end

function M.contains(r, row, col)
  return r ~= nil and row >= r.row and row < r.row + r.height and col >= r.col and col < r.col + r.width
end

function M.intersect(a, b)
  local row = math.max(a.row, b.row)
  local col = math.max(a.col, b.col)
  local bottom = math.min(a.row + a.height, b.row + b.height)
  local right = math.min(a.col + a.width, b.col + b.width)
  return M.new(row, col, bottom - row, right - col)
end

return M
