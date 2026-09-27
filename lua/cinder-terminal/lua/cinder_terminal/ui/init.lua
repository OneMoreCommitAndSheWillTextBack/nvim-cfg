---@class CinderTerminal.UI
---Lazygit style workspace drawn as cinder-ui cards: a containers card over an
---items card in the sidebar column, a terminal card on the right and a
---one-row hint card under both. The terminal card is only chrome: a real
---terminal window covers its content area, so the job keeps the native keys.
---
---The class is assembled from one module per responsibility; each module
---returns a method table and every method still lives on the workspace, so
---callers keep using `ui.new(opts)` and `workspace:method(...)` unchanged.
---Every module repeats the `CinderTerminal.UI` annotation so that LuaLS keeps
---the method types after the merge.
local workspace = require("cinder_terminal.ui.workspace")

local M = {}
M.__index = M

for _, part in ipairs({
  workspace,
  require("cinder_terminal.ui.selection"),
  require("cinder_terminal.ui.render"),
  require("cinder_terminal.ui.terminal"),
  require("cinder_terminal.ui.refresh"),
  require("cinder_terminal.ui.actions"),
  require("cinder_terminal.ui.keys"),
}) do
  for name, method in pairs(part) do
    M[name] = method
  end
end

---@param opts table
---@return CinderTerminal.UI
function M.new(opts)
  return setmetatable(workspace.initial_state(opts), M)
end

return M
