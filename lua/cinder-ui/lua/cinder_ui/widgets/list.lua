-- list widget: opts = { get = fn() -> data } (or a static `items` list), where
--   data = {
--     items = { string | { text, hl } | segments },
--     cursor = number, top = number, empty = string,
--   }
-- opts.item_render = fn(item, index, ctx) -> string | segments
-- The cursor row is highlighted in every card: the focused one with the cursor
-- background, an unfocused one with the dimmer `cursor_inactive` variant (which
-- the theme leaves undefined when the colorscheme has nothing to derive it from,
-- in which case an unfocused cursor row is left unpainted).
local M = {}

local function call(v)
  if type(v) == "function" then
    return v()
  end
  return v
end

-- keep `cursor` visible inside a window of `height` rows starting at `top`
function M.ensure_visible(cursor, top, height, total)
  if total <= 0 then
    return 0
  end
  height = math.max(1, height or 1)
  top = top or 0
  cursor = math.max(1, math.min(cursor or 1, total))
  if cursor <= top then
    top = cursor - 1
  end
  if cursor > top + height then
    top = cursor - height
  end
  top = math.max(0, math.min(top, math.max(0, total - height)))
  return top
end

local function default_item_render(item)
  if type(item) == "table" then
    if item.segments then
      return item.segments
    end
    if item.text ~= nil then
      return item
    end
    return tostring(item)
  end
  return tostring(item)
end

function M.render_with(w, canvas, rect, env, render_item)
  local data = w.get and call(w.get) or w
  local items = (data and data.items) or {}
  local total = #items
  local height = rect.height
  if total == 0 then
    local msg = (data and data.empty) or w.empty or ""
    if msg ~= "" then
      canvas:put_text(rect.row, rect.col, msg, env.theme.dim, rect.width)
    end
    return nil
  end
  local cursor = call(data.cursor) or 0
  local top = call(data.top) or 0
  top = math.max(0, math.min(top, math.max(0, total - height)))
  for i = 1, math.min(height, total) do
    local index = top + i
    local item = items[index]
    if item == nil then
      break
    end
    local y = rect.row + i - 1
    local selected = env.focused and index == cursor
    -- The cursor row carries a bar even when its card is not focused, just a
    -- dimmer one; without an inactive background there is no bar at all.
    local inactive = not env.focused
    local bar = index == cursor and env.theme.cursor_variant(nil, inactive) or nil
    local transform
    if index == cursor and bar then
      transform = function(hl)
        return env.theme.cursor_variant(hl, inactive)
      end
    end
    local value
    if render_item then
      value = render_item(item, index, { selected = selected, focused = env.focused, cursor = cursor })
    else
      value = default_item_render(item)
    end
    local used = canvas:put_rich(y, rect.col, value, rect.width, transform) or 0
    if bar and used < rect.width then
      -- pad the cursor row so the selection bar spans the whole card width
      canvas:put_text(y, rect.col + used, string.rep(" ", rect.width - used), bar)
    end
  end
  local out = {}
  if total > height then
    out.scroll = { top = top, size = height, total = total }
  end
  if cursor >= top + 1 and cursor <= top + height then
    out.cursor_row = rect.row + (cursor - top) - 1
  end
  return out
end

function M.render(w, canvas, rect, env)
  return M.render_with(w, canvas, rect, env, w.item_render)
end

return M
