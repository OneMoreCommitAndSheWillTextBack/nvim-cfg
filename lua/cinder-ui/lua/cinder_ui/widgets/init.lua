-- Widget renderers. A widget reads fresh data through its `get()` closure on every
-- render and draws into the given rect; it never stores state.
local M = {}

local impl = {
  text = require("cinder_ui.widgets.text"),
  list = require("cinder_ui.widgets.list"),
  tree = require("cinder_ui.widgets.tree"),
}

function M.render(widget, canvas, rect, env)
  local mod = impl[widget.__widget]
  if not mod then
    return nil
  end
  return mod.render(widget, canvas, rect, env)
end

return M
