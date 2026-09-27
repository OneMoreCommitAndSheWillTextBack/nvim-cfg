---@class CinderTerminal.Layout.Rect
---@field row number
---@field col number
---@field width number
---@field height number

---@class CinderTerminal.Layout
---@field frame CinderTerminal.Layout.Rect Workspace float; Neovim draws its border outside of it.
---@field inner_width number
---@field inner_height number
---@field body_height number Rows the cards get; the hint card owns the last row.
---@field sidebar_width number Width of the sidebar column, card borders included.
---@field terminal_width number Width of the terminal card.
---@field hint_row number 0-based row of the hint card inside the frame.
---@field container_rows number Card height that fits every container entry.
---@field items_rows number Height of the items card.
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
---@field width number Workspace width ratio.
---@field height number Workspace height ratio.
---@field left_ratio number Width ratio of the sidebar column.
---@field container_rows number Number of container entries to show.
---@field min_items? number Minimum visible entries for the items list.

---The workspace is a cinder-ui card tree: an outer frame, a row that holds the
---sidebar column and the terminal card, and a one-row hint card under both.
---`BORDER` is what one card spends per side; the sidebar and the terminal card
---sit next to each other, so their own borders are the divider. The layout
---therefore only has to place the frame and hand cinder-ui the sizes.
local BORDER = 2
local HINT_ROWS = 1
local MIN_ITEM_ROWS = 4

---Compute the frame rectangle and the card sizes from a single source of truth.
---@param ctx CinderTerminal.Layout.Context
---@return CinderTerminal.Layout
function M.compute(ctx)
  local columns = math.max(40, ctx.columns)
  local lines = math.max(12, ctx.lines - (ctx.cmdheight or 0))
  local width = clamp(math.floor(columns * ctx.width), 60, columns - 2)
  local height = clamp(math.floor(lines * ctx.height), 16, lines - 1)
  local row = math.max(0, math.floor((lines - height - 2) / 2))
  local col = math.max(0, math.floor((columns - width - 2) / 2))

  local body_height = math.max(BORDER, height - HINT_ROWS)
  local sidebar_width = clamp(math.floor(width * ctx.left_ratio), 26, width - 26)
  local min_items = math.max(2, ctx.min_items or MIN_ITEM_ROWS) + BORDER
  local wanted = math.max(0, ctx.container_rows) + BORDER
  local container_rows = clamp(wanted, BORDER, math.max(BORDER, body_height - min_items))

  return {
    frame = { row = row, col = col, width = width, height = height },
    inner_width = width,
    inner_height = height,
    body_height = body_height,
    sidebar_width = sidebar_width,
    terminal_width = width - sidebar_width,
    hint_row = height - HINT_ROWS,
    container_rows = container_rows,
    items_rows = math.max(BORDER, body_height - container_rows),
  }
end

return M
