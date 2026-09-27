---Surface mapping: which key runs which interaction binding, and the
---resolution of user-configured key overrides.
local interaction = require("cinder_terminal.interaction")
local util = require("cinder_terminal.ui.util")

local api = vim.api

local SIDEBAR_PANELS = util.SIDEBAR_PANELS
local valid_buf = util.valid_buf

---@class CinderTerminal.UI
local M = {}

---Where the keyboard is right now, for `interaction`. An explicit `kind`
---asks for one surface regardless of the focus, which is how the `?` popup
---lists every context at once.
---@param kind? "containers"|"items"|"pane"|"typing"
---@return CinderTerminal.Interaction.Context
function M:interaction_context(kind)
  local state = self.state
  local function sidebar(panel)
    local node = panel == "containers" and self:selected_container() or self:selected_item()
    local provider = self:provider(node or self:selected_container())
    return {
      surface = "sidebar",
      panel = panel,
      node = node,
      provider = provider,
      caps = (provider and provider.capabilities) or {},
    }
  end
  local function pane(surface)
    local provider = self:provider(self:selected_item())
    return {
      surface = surface,
      provider = provider,
      caps = (provider and provider.capabilities) or {},
    }
  end
  if kind == "containers" or kind == "items" then
    return sidebar(kind)
  end
  if kind == "pane" or kind == "typing" then
    return pane(kind)
  end
  if state.focus == "terminal" then
    return pane(self:terminal_normal_mode() and "pane" or "typing")
  end
  return sidebar(state.focus == "containers" and "containers" or "items")
end

---@param option string
---@param defaults string[]
---@return string[]
function M:resolve_keys(option, defaults)
  return self:keys_for(option, defaults)
end

---The hint row of the focused panel, straight out of `interaction`.
---@return { key: string, desc: string, keys: string[], native: boolean }[]
function M:context_keys()
  return interaction.hints(self:interaction_context(), function(option, defaults)
    return self:resolve_keys(option, defaults)
  end)
end

---@param buf number
---@param mode string
---@param lhs string?
---@param rhs string|function A key sequence or a Lua callback.
---@param desc string
function M:map(buf, mode, lhs, rhs, desc)
  if not lhs then
    return
  end
  vim.keymap.set(mode, lhs, rhs, { buffer = buf, silent = true, nowait = true, desc = desc })
end

function M:map_buffers()
  self:map_sidebar()
  self:map_surface(self.state.buf.hint, "n", interaction.bindings("pane", nil, self:resolver()))
end

---One buffer serves both sidebar cards, so a key is resolved against the
---panel that has the cursor *when it is pressed*: the union of the two panels
---is mapped, and a key only one panel knows is inert in the other. The
---binding tables are built once per mapping pass and kept in
---`state.sidebar_bindings`, so a keypress is a table lookup instead of a
---rebuild of every binding in the panel.
function M:map_sidebar()
  local buf = self.state.buf.app
  if not valid_buf(buf) then
    return
  end
  local by_panel, mapped = {}, {}
  for _, panel in ipairs(SIDEBAR_PANELS) do
    by_panel[panel] = {}
    for _, binding in ipairs(interaction.bindings("sidebar", panel, self:resolver())) do
      by_panel[panel][binding.lhs] = binding
      if not mapped[binding.lhs] then
        mapped[binding.lhs] = true
        self:map(buf, "n", binding.lhs, function()
          self:run_sidebar(binding.lhs)
        end, binding.action.summary or binding.action.name)
      end
    end
  end
  self.state.sidebar_bindings = by_panel
end

---@param lhs string
function M:run_sidebar(lhs)
  local by_panel = self.state.sidebar_bindings
  local binding = by_panel and by_panel[self.state.card_focus][lhs] or nil
  if binding then
    self:invoke(binding)
  end
end

---@param binding CinderTerminal.Interaction.Binding
function M:invoke(binding)
  local action = binding.action
  if binding.run then
    -- A `translate` handler belongs to one specific key, so it takes no
    -- gesture; an action handler may need it (the digit jump).
    binding.run(self)
    return
  end
  if action.rhs then
    local keys = api.nvim_replace_termcodes(action.rhs, true, false, true)
    pcall(api.nvim_feedkeys, keys, "n", false)
    return
  end
  action.run(self, binding.gesture)
end

---@return fun(option: string, defaults: string[]): string[]
function M:resolver()
  local ui = self
  return function(option, defaults)
    return ui:resolve_keys(option, defaults)
  end
end

---Bind one surface's actions into a buffer. Each binding names the key to
---map (`lhs`) and, when the gesture and the mapping differ, its own handler.
---@param buf number
---@param mode string
---@param bindings CinderTerminal.Interaction.Binding[]
function M:map_surface(buf, mode, bindings)
  for _, binding in ipairs(bindings) do
    local action = binding.action
    if not binding.run and action.rhs then
      -- Keep the key sequence a mapping, the way Neovim's own `<C-\><C-n>`
      -- does: it must not wait for another key and shows up as `rhs`.
      self:map(buf, mode, binding.lhs, action.rhs, action.summary or action.name)
    else
      self:map(buf, mode, binding.lhs, function()
        self:invoke(binding)
      end, action.summary or action.name)
    end
  end
end

---Keys configured for one action. The option takes a single key, a list (a
---pane may want more than one way out of Terminal mode) or `false` to disable
---the action; the fallback applies when nothing is configured.
---@param name string
---@param fallback string|string[]
---@return string[]
function M:keys_for(name, fallback)
  local configured = self.opts.keymaps and self.opts.keymaps[name]
  if configured == nil then
    configured = fallback
  end
  if configured == false then
    return {}
  end
  local list = type(configured) == "table" and configured or { configured }
  local keys = {}
  for _, lhs in ipairs(list) do
    if type(lhs) == "string" and lhs ~= "" then
      keys[#keys + 1] = lhs
    end
  end
  return keys
end

---@param buf number
function M:map_terminal_buffer(buf)
  -- Normal mode of the pane is the same surface as the placeholder buffer, so
  -- `q`, `h` and the pane keys mean the same thing whether or not a job is on
  -- screen. Terminal mode keeps only the escape sequences the registry
  -- declares; Neovim's own `<C-\><C-n>` waits for a second key and reads as
  -- "the key does nothing", so the pane binds each one on its own.
  self:map_surface(buf, "n", interaction.bindings("pane", nil, self:resolver()))
  self:map_surface(buf, "t", interaction.bindings("typing", nil, self:resolver()))
end

return M
