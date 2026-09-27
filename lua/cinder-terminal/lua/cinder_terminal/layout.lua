---@class CinderTerminal.Layout.Rect
---@field row number
---@field col number
---@field width number
---@field height number

---@class CinderTerminal.Layout
---@field frame CinderTerminal.Layout.Rect Floating frame, relative to the editor.
---@field containers CinderTerminal.Layout.Rect Top-left panel, relative to the frame.
---@field items CinderTerminal.Layout.Rect Bottom-left panel, relative to the frame.
---@field terminal CinderTerminal.Layout.Rect Right panel, relative to the frame.
---@field separator_col number Column of the vertical separator inside the frame.
---@field divider_row number Row of the horizontal divider inside the frame.
---@field help_row number Last inner row, used for the contextual key hints.
---@field body_height number Inner rows above the help row.
---@field inner_width number
---@field inner_height number
local M = {}

---@param value number
---@param min number
---@param max number
---@return number
local function clamp(value, min, max)
  if max < min then
    return min
  end
  return math.max(min, math.min(max, value))
end

---@class CinderTerminal.Layout.Context
---@field columns number
---@field lines number
---@field cmdheight? number
---@field width number Floating width ratio.
---@field height number Floating height ratio.
---@field left_ratio number Width ratio of the left column.
---@field container_rows number Number of container entries to show.
---@field min_items? number Minimum visible entries for the items panel.

---Every panel draws its name in a one-row winbar inside its own window, so a
---panel that should show `n` entries needs `n + TITLE_ROWS` rows.
local TITLE_ROWS = 1

---Compute every rectangle from a single source of truth. Panels are laid out
---relative to the frame text area; the frame border is drawn by Neovim outside
---of it, so the layout never has to model border cells.
---@param ctx CinderTerminal.Layout.Context
---@return CinderTerminal.Layout
function M.compute(ctx)
  local columns = math.max(40, ctx.columns)
  local lines = math.max(10, ctx.lines - (ctx.cmdheight or 0))
  local width = clamp(math.floor(columns * ctx.width), 60, columns - 2)
  local height = clamp(math.floor(lines * ctx.height), 14, lines - 1)
  local row = math.max(0, math.floor((lines - height - 2) / 2))
  local col = math.max(0, math.floor((columns - width - 2) / 2))

  local inner_width = width
  local inner_height = height
  local body_height = inner_height - 1

  local left = clamp(math.floor(inner_width * ctx.left_ratio), 24, inner_width - 25)
  local right_width = inner_width - left - 1

  local min_items = math.max(2, ctx.min_items or 4) + TITLE_ROWS
  local container_rows = math.max(1, ctx.container_rows) + TITLE_ROWS
  -- The divider row belongs to the items panel: it is that panel's winbar.
  local top_height = clamp(container_rows, 3, body_height - 1 - min_items)
  local items_height = body_height - top_height - 1

  return {
    frame = { row = row, col = col, width = width, height = height },
    inner_width = inner_width,
    inner_height = inner_height,
    body_height = body_height,
    separator_col = left,
    divider_row = top_height,
    containers = { row = 0, col = 0, width = left, height = top_height },
    items = { row = top_height + 1, col = 0, width = left, height = items_height },
    terminal = { row = 0, col = left + 1, width = right_width, height = body_height },
    help_row = inner_height - 1,
  }
end

return M
