---Which container/terminal the sidebar points at, and the scroll window that
---keeps the selected row visible. The selection lives in card data, not in a
---buffer cursor, so list lookup and scrolling are plain table walks.
local ui = require("cinder_ui")
local util = require("cinder_terminal.ui.util")

local CARD_BORDER = util.CARD_BORDER
local SIDEBAR_PANELS = util.SIDEBAR_PANELS

---@class CinderTerminal.UI
local M = {}

---@return CinderTerminal.Node?
function M:selected_container()
  for _, container in ipairs(self.state.containers) do
    if container.id == self.state.selected_container_id then
      return container
    end
  end
end

---@return CinderTerminal.Node?
function M:selected_item()
  for _, item in ipairs(self.state.items) do
    if item.id == self.state.selected_item_id then
      return item
    end
  end
end

---The row a freshly listed container should land on: the one the user looked
---at last, otherwise the provider's active one, otherwise the first.
---@param items CinderTerminal.Node[]
---@param remembered? string
---@return string?
function M:preferred_item_id(items, remembered)
  for _, item in ipairs(items) do
    if item.id == remembered or item.active then
      return item.id
    end
  end
  return items[1] and items[1].id or nil
end

---Select one sidebar row, whichever card owns it. `action_move` and the
---`next`/`prev` commands move the same selection under a different name.
---@param kind "containers"|"items"
---@param id string
function M:select_row(kind, id)
  if kind == "containers" then
    self:select_container(id)
  else
    self:select_item(id)
  end
end

---Select the first container owned by `name`, waiting for the next snapshot
---when the provider has not reported its data yet.
---@param name string
function M:select_provider(name)
  for _, container in ipairs(self.state.containers) do
    if container.provider == name then
      self:select_container(container.id)
      return true
    end
  end
  self.state.pending_provider = name
  self:refresh()
  return false
end

---@param id string
---@param opts? { focus?: boolean }
function M:select_container(id, opts)
  opts = opts or {}
  local state = self.state
  if state.selected_container_id == id and self:selected_container() then
    return
  end
  state.selected_container_id = id
  state.items = {}
  state.selected_item_id = nil

  local container = self:selected_container()
  if container then
    state.items = container.children or {}
    state.selected_item_id = self:preferred_item_id(state.items, state.memory[id])
    if state.selected_item_id then
      state.memory[id] = state.selected_item_id
    end
  end

  self:render()
  if opts.focus then
    self:set_focus("items")
  end
end

---@param id string
---@param opts? { attach?: boolean }
function M:select_item(id, opts)
  opts = opts or {}
  local state = self.state
  if state.selected_item_id == id then
    return
  end
  state.selected_item_id = id
  if state.selected_container_id then
    state.memory[state.selected_container_id] = id
  end
  self:render()
  if opts.attach ~= false then
    self:schedule_attach()
  end
end

function M:ensure_selection()
  local state = self.state
  local container = self:selected_container()
  if container then
    state.items = container.children or {}
  else
    local first = state.containers[1]
    state.selected_container_id = first and first.id or nil
    state.items = first and first.children or {}
    state.selected_item_id = nil
  end

  if state.selected_item_id and not self:selected_item() then
    state.selected_item_id = nil
  end

  if not state.selected_item_id then
    state.selected_item_id = self:preferred_item_id(state.items, state.memory[state.selected_container_id])
  end

  -- While the terminal has focus tmux is the source of truth for which window
  -- is on screen, so the item selection follows the active window.
  if state.focus == "terminal" then
    for _, item in ipairs(state.items) do
      if item.active then
        state.selected_item_id = item.id
        break
      end
    end
  end

  if state.selected_item_id then
    state.memory[state.selected_container_id] = state.selected_item_id
  end
end

---The rows and the selected id of one sidebar card. Both lists live in the
---same buffer, so every lookup names the card it means instead of repeating
---the same `kind == "containers" and ... or ...` in each of them.
---@param kind "containers"|"items"
---@return CinderTerminal.Node[] list
---@return string? selected_id
function M:sidebar_list(kind)
  local state = self.state
  if kind == "containers" then
    return state.containers, state.selected_container_id
  end
  return state.items, state.selected_item_id
end

---Index of the selected row in one of the two lists.
---@param kind "containers"|"items"
---@return number?
function M:selected_index(kind)
  local list, id = self:sidebar_list(kind)
  for index, node in ipairs(list) do
    if id ~= nil and node.id == id then
      return index
    end
  end
end

---Visible rows of one card: its height minus the two border rows.
---@param kind "containers"|"items"
---@return number
function M:view_height(kind)
  local d = self.state.metrics or self:dimensions()
  if kind == "containers" then
    return math.max(1, d.container_rows - CARD_BORDER)
  end
  return math.max(1, d.items_rows - CARD_BORDER)
end

---Keep the selected row inside the card window. The selection lives in the
---card data, not in the buffer cursor, so the window is data too.
function M:sync_scroll()
  local state = self.state
  for _, kind in ipairs(SIDEBAR_PANELS) do
    local list = self:sidebar_list(kind)
    local cursor = self:selected_index(kind)
    if cursor then
      state.scroll[kind] = ui.ensure_visible(cursor, state.scroll[kind], self:view_height(kind), #list)
    else
      state.scroll[kind] = 0
    end
  end
end

return M
