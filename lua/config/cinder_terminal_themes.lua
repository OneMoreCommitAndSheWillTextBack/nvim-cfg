-- Theme adapters are declared while Lazy parses specs, then applied after the
-- local cinder-terminal plugin has been loaded.
local M = {
  adapters = {},
  terminal = nil,
}

---@param name string
---@param callback fun(groups: CinderTerminal.HighlightGroups)
function M.register(name, callback)
  assert(type(name) == "string" and name ~= "", "theme name must be a non-empty string")
  assert(type(callback) == "function", "theme callback must be a function")
  M.adapters[name] = callback

  if M.terminal then
    M.terminal.register_theme(name, callback)
  end
end

---@param terminal CinderTerminal
function M.apply(terminal)
  M.terminal = terminal
  for name, callback in pairs(M.adapters) do
    terminal.register_theme(name, callback)
  end
end

return M
