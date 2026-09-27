-- tree widget: list with a default item renderer for flattened tree rows.
-- Items are flat rows produced by the plugin:
--   { text = "docs", depth = 0, glyph = "▼", glyph_hl = "...", hl = "..." }
-- or { segments = { ... } } for full control.
local list = require("cinder_ui.widgets.list")

local M = {}

local function default_tree_item(item)
  if type(item) ~= "table" then
    return tostring(item)
  end
  if item.segments then
    return item.segments
  end
  local segs = { { text = string.rep("  ", item.depth or 0) } }
  if item.glyph ~= nil and item.glyph ~= "" then
    segs[#segs + 1] = { text = item.glyph, hl = item.glyph_hl }
    segs[#segs + 1] = { text = " " }
  end
  segs[#segs + 1] = { text = item.text or "", hl = item.hl }
  return segs
end

function M.render(w, canvas, rect, env)
  return list.render_with(w, canvas, rect, env, w.item_render or default_tree_item)
end

return M
