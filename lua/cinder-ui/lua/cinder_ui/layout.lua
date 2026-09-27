-- cinder_ui.layout: turn a card tree into concrete rectangles (placements).
-- A placement is { card, rect, inner, path, id } where `rect` includes the card's
-- border and `inner` is the content area (inside border + padding).
local geom = require("cinder_ui.geom")

local M = {}

local function spec_of(child, axis)
  local v = (axis == "row") and child.width or child.height
  if type(v) == "number" then
    return { kind = "fixed", size = math.max(0, math.floor(v)) }
  end
  if type(v) == "table" and v.__flex then
    return { kind = "flex", weight = v.weight or 1, min = v.min, max = v.max }
  end
  return { kind = "flex", weight = 1 }
end

-- Distribute `avail` cells over size specs. Fixed sizes are honored, flex items share
-- the rest by weight (clamped by min/max). If everything does not fit, flexible items
-- are shrunk starting with the largest one.
local function allocate(specs, avail)
  local n = #specs
  local sizes = {}
  local fixed_sum = 0
  local flex = {}
  for i = 1, n do
    if specs[i].kind == "fixed" then
      sizes[i] = specs[i].size
      fixed_sum = fixed_sum + sizes[i]
    else
      flex[#flex + 1] = i
    end
  end

  local had_overflow = math.max(0, fixed_sum - avail)
  local rem = math.max(0, avail - fixed_sum)

  if #flex > 0 then
    local active = {}
    for _, i in ipairs(flex) do
      active[i] = true
    end
    while true do
      local wsum, touched = 0, false
      for _, i in ipairs(flex) do
        if active[i] then
          wsum = wsum + (specs[i].weight or 1)
        end
      end
      if wsum <= 0 then
        break
      end
      for _, i in ipairs(flex) do
        if active[i] then
          local s = specs[i]
          local share = rem * (s.weight or 1) / wsum
          if s.min and share < s.min - 1e-9 then
            sizes[i] = s.min
            rem = rem - s.min
            active[i] = false
            touched = true
          elseif s.max and share > s.max + 1e-9 then
            sizes[i] = s.max
            rem = rem - s.max
            active[i] = false
            touched = true
          end
        end
      end
      if not touched or rem <= 0 then
        break
      end
    end

    local wsum, left = 0, rem
    for _, i in ipairs(flex) do
      if active[i] then
        wsum = wsum + (specs[i].weight or 1)
      end
    end
    local fracs = {}
    if wsum > 0 and left > 0 then
      for _, i in ipairs(flex) do
        if active[i] then
          local exact = left * (specs[i].weight or 1) / wsum
          local base = math.floor(exact)
          sizes[i] = base
          fracs[#fracs + 1] = { i = i, frac = exact - base }
        end
      end
      local assigned = 0
      for _, i in ipairs(flex) do
        if active[i] then
          assigned = assigned + (sizes[i] or 0)
        end
      end
      local leftover = left - assigned
      table.sort(fracs, function(a, b)
        return a.frac > b.frac
      end)
      local k = 1
      while leftover > 0 and #fracs > 0 do
        local item = fracs[k]
        local s = specs[item.i]
        if s.max == nil or (sizes[item.i] or 0) < s.max then
          sizes[item.i] = (sizes[item.i] or 0) + 1
          leftover = leftover - 1
        end
        k = k + 1
        if k > #fracs then
          k = 1
        end
      end
    end
    for _, i in ipairs(flex) do
      if sizes[i] == nil then
        sizes[i] = 0
      end
    end
  end

  local total = 0
  for i = 1, n do
    total = total + (sizes[i] or 0)
  end
  local overflow = math.max(had_overflow, total - avail)
  if overflow > 0 then
    had_overflow = overflow
  end
  local guard = 0
  while overflow > 0 and guard < 10000 do
    guard = guard + 1
    local pick, pick_size = nil, 0
    for _, i in ipairs(flex) do
      local size = sizes[i] or 0
      if size > (specs[i].min or 0) and size > pick_size then
        pick, pick_size = i, size
      end
    end
    if not pick then
      for i = n, 1, -1 do
        if (sizes[i] or 0) > 0 then
          pick = i
          break
        end
      end
    end
    if not pick then
      break
    end
    sizes[pick] = sizes[pick] - 1
    overflow = overflow - 1
  end

  return sizes, had_overflow
end

function M.compute(root, rect)
  local placements, warnings = {}, {}

  local function walk(node, r, path)
    -- The root frame is drawn by the app window itself, never by the canvas.
    local has_border = path ~= "root" and node.border ~= false
    local inner = geom.inset(r, has_border and 1 or 0)
    if node.padding then
      inner = geom.inset(inner, node.padding)
    end
    placements[#placements + 1] = {
      card = node,
      rect = r,
      inner = inner,
      path = path,
      id = node.id,
    }
    if node.children then
      local axis = node.layout or "column"
      local avail = (axis == "row") and inner.width or inner.height
      local n = #node.children
      local specs = {}
      for i = 1, n do
        specs[i] = spec_of(node.children[i], axis)
      end
      local sizes, overflow = allocate(specs, avail)
      if overflow and overflow > 0 then
        warnings[#warnings + 1] =
          string.format("%s: squeezed, %d %s clipped", path, overflow, axis == "row" and "columns" or "rows")
      end
      local pos = (axis == "row") and inner.col or inner.row
      for i, ch in ipairs(node.children) do
        local size = sizes[i] or 0
        local child_rect
        if axis == "row" then
          child_rect = geom.new(inner.row, pos, inner.height, size)
        else
          child_rect = geom.new(pos, inner.col, size, inner.width)
        end
        pos = pos + size
        child_rect = geom.intersect(child_rect, inner)
        walk(ch, child_rect, string.format("%s.children[%d]", path, i - 1))
      end
    end
  end

  walk(root, rect, "root")
  return placements, warnings
end

return M
