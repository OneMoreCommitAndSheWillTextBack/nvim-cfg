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

---Fixed sizes are taken as given; everything else becomes a flex candidate.
---@return table sizes Fixed entries filled in.
---@return number[] flex Indices of the flex entries, in child order.
---@return number fixed_sum
local function split_fixed(specs)
  local sizes, flex, fixed_sum = {}, {}, 0
  for i, spec in ipairs(specs) do
    if spec.kind == "fixed" then
      sizes[i] = spec.size
      fixed_sum = fixed_sum + spec.size
    else
      flex[#flex + 1] = i
    end
  end
  return sizes, flex, fixed_sum
end

---Hand `rem` cells to the flex entries by weight, freezing an entry at its
---min/max as soon as its share breaks the bound. Freezing one entry frees
---cells for the others, so the pass repeats until nothing freezes. Returns the
---cells still unassigned (negative when the mins alone do not fit).
---@param rem number
---@return number rem
local function share_flex(sizes, specs, flex, rem)
  while true do
    local wsum, frozen = 0, false
    for _, i in ipairs(flex) do
      if sizes[i] == nil then
        wsum = wsum + (specs[i].weight or 1)
      end
    end
    if wsum <= 0 then
      break
    end
    for _, i in ipairs(flex) do
      if sizes[i] == nil then
        local spec = specs[i]
        local share = rem * (spec.weight or 1) / wsum
        if spec.min and share < spec.min - 1e-9 then
          sizes[i] = spec.min
          rem = rem - spec.min
          frozen = true
        elseif spec.max and share > spec.max + 1e-9 then
          sizes[i] = spec.max
          rem = rem - spec.max
          frozen = true
        end
      end
    end
    if not frozen or rem <= 0 then
      break
    end
  end
  return rem
end

---Floor every unfrozen share and hand the remaining cells to the largest
---fractions, one cell each, never past `max`.
local function round_flex(sizes, specs, flex, rem)
  local wsum = 0
  for _, i in ipairs(flex) do
    if sizes[i] == nil then
      wsum = wsum + (specs[i].weight or 1)
    end
  end
  if wsum > 0 and rem > 0 then
    local fractions, assigned = {}, 0
    for _, i in ipairs(flex) do
      if sizes[i] == nil then
        local exact = rem * (specs[i].weight or 1) / wsum
        sizes[i] = math.floor(exact)
        assigned = assigned + sizes[i]
        fractions[#fractions + 1] = { i = i, frac = exact - sizes[i] }
      end
    end
    table.sort(fractions, function(a, b)
      return a.frac > b.frac
    end)
    local leftover = rem - assigned
    local k = 1
    while leftover > 0 do
      local item = fractions[k]
      local max = specs[item.i].max
      if max == nil or sizes[item.i] < max then
        sizes[item.i] = sizes[item.i] + 1
        leftover = leftover - 1
      end
      k = k + 1
      if k > #fractions then
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

---Take `overflow` cells back. Flex entries give first, the largest one at a
---time and never below their min; after that any entry gives, the last one
---first, so the tail of the list pays for the clipping. Terminates because
---every pass either shrinks a size or returns.
local function shrink(sizes, specs, flex, overflow)
  while overflow > 0 do
    local pick, pick_size = nil, 0
    for _, i in ipairs(flex) do
      local size = sizes[i] or 0
      if size > (specs[i].min or 0) and size > pick_size then
        pick, pick_size = i, size
      end
    end
    if not pick then
      for i = #specs, 1, -1 do
        if (sizes[i] or 0) > 0 then
          pick = i
          break
        end
      end
    end
    if not pick then
      return
    end
    sizes[pick] = sizes[pick] - 1
    overflow = overflow - 1
  end
end

---Distribute `avail` cells over size specs, reporting how many cells had to be
---clipped when even the mins do not fit.
local function allocate(specs, avail)
  local sizes, flex, fixed_sum = split_fixed(specs)
  local overflow = math.max(0, fixed_sum - avail)
  local rem = math.max(0, avail - fixed_sum)
  if #flex > 0 then
    rem = share_flex(sizes, specs, flex, rem)
    round_flex(sizes, specs, flex, rem)
  end

  local total = 0
  for i = 1, #specs do
    total = total + (sizes[i] or 0)
  end
  overflow = math.max(overflow, total - avail)
  if overflow > 0 then
    shrink(sizes, specs, flex, overflow)
  end
  return sizes, overflow
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
