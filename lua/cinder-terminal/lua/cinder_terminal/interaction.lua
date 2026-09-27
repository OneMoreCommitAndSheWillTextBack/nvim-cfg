---The keyboard map of the workspace, declared once.
---
---Every entry says which surface it belongs to, which key it uses, what the
---hint row should call it and what it runs. Bindings, the contextual hint row
---and the `?` popup are all generated from this list, so they cannot drift
---apart the way three hand-written tables did.
---
---Three surfaces, and the rule that decides which one an action lives on:
---
---  sidebar  the containers/items panels. Their buffers are not editable, so
---           every letter is inert and the full verb set lives here.
---  pane     the terminal buffer in normal mode. This is a real Neovim buffer
---           where `v`, `y`, `d`, `r` and `n` mean something, so only
---           navigation and mode switches are bound here: the pane never
---           steals an operator prefix or a motion.
---  typing   the terminal buffer in Terminal mode. Everything belongs to the
---           job except the keys that leave it, so the hint row must not name
---           anything else: <Tab> would complete, `?` would be typed into the
---           program. Leaving is `<C-\\>`/`<Esc><Esc>` for normal mode and
---           `<C-b>` for the list.
local M = {}

---@class CinderTerminal.Interaction.Context
---@field surface "sidebar"|"pane"|"typing"
---@field panel? "containers"|"items" Sidebar panels the action applies to.
---@field provider? CinderTerminal.Provider
---@field caps? CinderTerminal.Provider.Capabilities
---@field node? CinderTerminal.Node

---@class CinderTerminal.Interaction
---@field name string Stable id, and the `keymaps` entry that overrides it.
---@field keys? string[]|fun(ctx): string[] Keys to bind; absent on native hints.
---@field option? string `keymaps` entry replacing `keys`.
---@field label? string|fun(ctx, keys): string Hint label, when it differs from
---the bound keys (`l` for `l`/`<CR>`, `v/y` for a native pair).
---@field help_label? string|fun(ctx, keys): string Label for the `?` popup,
---for keys that are too many to spell out there (`1-9` for ten digits).
---@field desc? string|fun(ctx): string? Hint text; nil hides the action.
---@field help_desc? string|fun(ctx): string? Text in the `?` popup.
---@field summary? string `:map` description, defaults to `desc`.
---@field surfaces string[] "sidebar" | "pane" | "typing".
---@field panels? string[] "containers" | "items", sidebar only.
---@field hint? boolean false: bound, but not advertised in the hint row.
---@field help? boolean false: not listed in the `?` popup.
---@field run? fun(ui: CinderTerminal.UI, key?: string) Bound as a Lua callback.
---`key` is the gesture that fired, for actions whose keys carry an argument
---(the digit jump to a terminal).
---@field rhs? string Bound as a key sequence instead of `run`.
---@field native? boolean Hint only: the key belongs to Neovim, the job or
---the user, so there is no mapping of ours behind it.
---@field translate? table<string, CinderTerminal.Interaction.Translation>
---Gesture -> the binding that implements it, for keys whose literal spelling
---would be a bad mapping. Only `<Esc><Esc>` needs it: bound literally, every
---lone `<Esc>` waits 'timeoutlen' before the job receives it.

---@class CinderTerminal.Interaction.Translation
---@field lhs string The key actually mapped.
---@field run fun(ui: CinderTerminal.UI) Handler for the mapped key.

---Keys the pane must never bind, because normal mode is where they work:
---operators, motions, insert entries and macro recording the user expects to
---behave natively while looking at a terminal's scrollback. `h` and `q` are
---here for the same reason: the pane used to spend them on "back to the list",
---which `<Tab>` now does without costing a motion or the record key.
M.NATIVE_PANE_KEYS = { "v", "y", "d", "c", "i", "a", "r", "n", "/", "?", "h", "q" }

---@type CinderTerminal.Interaction[]
M.actions = {
  -- Sidebar: containers and items ------------------------------------------
  {
    name = "move",
    label = "j/k",
    desc = "move",
    help_desc = "move (native motions, `gg`/`G` work)",
    surfaces = { "sidebar" },
    native = true,
  },
  {
    name = "open",
    keys = { "l", "<CR>" },
    label = "l",
    desc = "open",
    help_desc = "open",
    summary = "Open",
    surfaces = { "sidebar" },
    panels = { "containers", "items" },
    run = function(ui)
      ui:action_open()
    end,
  },
  {
    name = "containers",
    keys = { "h" },
    desc = "containers",
    summary = "Focus containers",
    surfaces = { "sidebar" },
    panels = { "items" },
    run = function(ui)
      ui:set_focus("containers")
    end,
  },
  {
    name = "new",
    option = "new",
    keys = { "n" },
    desc = function(ctx)
      if ctx.panel == "containers" then
        return "new"
      end
      return ctx.caps.create_terminal and "new" or nil
    end,
    help_desc = function(ctx)
      return ctx.panel == "containers" and "new container" or "new terminal"
    end,
    summary = "Create",
    surfaces = { "sidebar" },
    panels = { "containers", "items" },
    run = function(ui)
      ui:action_create()
    end,
  },
  {
    name = "kill",
    option = "kill",
    keys = { "d" },
    desc = function(ctx)
      local allowed = ctx.panel == "containers" and ctx.caps.kill_container or ctx.caps.kill_terminal
      return allowed and "kill" or nil
    end,
    summary = "Kill",
    surfaces = { "sidebar" },
    panels = { "containers", "items" },
    run = function(ui)
      ui:action_kill()
    end,
  },
  {
    name = "rename",
    option = "rename",
    keys = { "r" },
    desc = function(ctx)
      if ctx.panel == "containers" then
        return ctx.caps.rename_container and "rename" or nil
      end
      if ctx.caps.rename_terminal then
        return "rename"
      end
      return ctx.caps.restart_terminal and "restart" or nil
    end,
    help_desc = function(ctx)
      return ctx.panel == "containers" and "rename" or "rename / restart"
    end,
    summary = "Rename or restart",
    surfaces = { "sidebar" },
    panels = { "containers", "items" },
    run = function(ui)
      ui:action_rename()
    end,
  },
  -- Bound in the panels, but the hint row stays short: the `?` popup has them.
  {
    name = "refresh",
    keys = { "R" },
    desc = "refresh",
    summary = "Refresh",
    hint = false,
    help = false,
    surfaces = { "sidebar" },
    panels = { "containers", "items" },
    run = function(ui)
      ui:action_refresh()
    end,
  },
  {
    name = "hide",
    keys = { "q" },
    desc = "hide",
    summary = "Hide workspace",
    hint = false,
    help = false,
    surfaces = { "sidebar" },
    panels = { "containers", "items" },
    run = function(ui)
      ui:action_close()
    end,
  },
  -- Terminal pane, normal mode --------------------------------------------
  {
    name = "insert",
    label = "i",
    desc = "insert",
    help_desc = "back to the job",
    surfaces = { "pane" },
    native = true,
  },
  {
    name = "yank",
    label = "v/y",
    desc = "select & yank",
    help_desc = "select and yank (native Neovim)",
    surfaces = { "pane" },
    native = true,
  },
  {
    name = "scroll",
    label = "j/k",
    desc = "scroll",
    help_desc = "scroll (native motions: `gg`/`G`, `<C-d>`/`<C-u>`)",
    surfaces = { "pane" },
    native = true,
  },

  {
    name = "switch",
    keys = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "0" },
    option = "switch",
    label = "1-9",
    help_label = "1-9 / 0",
    desc = "switch",
    help_desc = "switch to that terminal (`0` is the tenth); rows wear their digit",
    summary = "Switch terminal",
    -- The digit is the row's, not the hint row's: the list shows it beside
    -- every terminal, so the row does not have to spend width on it.
    hint = false,
    surfaces = { "sidebar" },
    panels = { "items" },
    run = function(ui, key)
      ui:action_switch(key)
    end,
  },
  -- Left in the table without keys: `<Tab>` is what leaves the pane now, so
  -- binding `q`/`h` here would only cost normal mode a motion and the record
  -- key. `keymaps.items` still brings the old jump back for anyone who wants
  -- it, and the hint row follows the moment it is configured.
  {
    name = "items",
    keys = {},
    option = "items",
    desc = "items",
    summary = "Items panel",
    surfaces = { "pane" },
    run = function(ui)
      ui:set_focus("items")
    end,
  },

  -- Terminal pane, typing --------------------------------------------------
  {
    name = "escape",
    option = "terminal_normal",
    keys = { "<C-\\>", "<Esc><Esc>" },
    label = function(_, keys)
      local labels = {}
      for _, lhs in ipairs(keys) do
        labels[#labels + 1] = M.key_label(lhs)
      end
      return table.concat(labels, " / ")
    end,
    desc = "normal mode",
    help_desc = "leave the job (normal mode)",
    summary = "Terminal normal mode",
    surfaces = { "typing" },
    rhs = "<C-\\><C-n>",
    -- `<Esc><Esc>` is not bound as two keys: that mapping would make Neovim
    -- hold every lone `<Esc>` for 'timeoutlen' before the job saw it, and a
    -- TUI cancels on the first one. One `<Esc>` is mapped instead; it forwards
    -- the byte itself and only counts a second press inside
    -- `opts.escape_window` as the gesture, so a single one costs nothing.
    translate = {
      ["<Esc><Esc>"] = {
        lhs = "<Esc>",
        run = function(ui)
          ui:terminal_escape()
        end,
      },
    },
  },
  {
    name = "list",
    option = "list",
    keys = { "<C-b>" },
    desc = "items",
    help_desc = "leave the job for the list",
    summary = "Items panel",
    surfaces = { "typing" },
    run = function(ui)
      ui:set_focus("items")
    end,
  },
  -- The user wires `<C-/>` globally, so it is the one key that also works
  -- while the job owns the keyboard.
  -- Everywhere. They come last so the hint row lists the keys of the current
  -- panel first and the pane keys after them, the way the panels always read.
  -- Tab swaps the tree and the pane instead of walking all three panels: a
  -- terminal is nearly always picked from the list of the container that is
  -- already selected, so stopping on the container tree first was a stop the
  -- user had to skip every time. The tree is walked with `h` (up) and `l`
  -- (down); the row names the pane Tab goes to, not the one it leaves.
  {
    name = "cycle",
    keys = { "<Tab>", "<S-Tab>" },
    label = function(_, keys)
      return M.key_label(keys[1] or "<Tab>")
    end,
    desc = function(ctx)
      return ctx.surface == "pane" and "items" or "terminal"
    end,
    summary = "Swap the sidebar and the terminal pane",
    help = false,
    surfaces = { "sidebar", "pane" },
    run = function(ui)
      ui:action_cycle()
    end,
  },
  {
    name = "hide_global",
    keys = { "<C-/>" },
    label = "C-/",
    desc = "hide",
    help = false,
    surfaces = { "sidebar", "pane", "typing" },
    native = true,
  },
  {
    name = "help",
    keys = { "?" },
    desc = "keys",
    summary = "Keys",
    help = false,
    surfaces = { "sidebar" },
    run = function(ui)
      ui:show_help()
    end,
  },
}

---@param lhs string
---@return string
function M.key_label(lhs)
  return (lhs:gsub("><", "> <"):gsub("[<>]", ""))
end

---@param name string
---@return CinderTerminal.Interaction?
function M.by_name(name)
  for _, candidate in ipairs(M.actions) do
    if candidate.name == name then
      return candidate
    end
  end
end

---@param action CinderTerminal.Interaction
---@param ctx CinderTerminal.Interaction.Context
---@param keys string[]
---@return string?
local function row_label(action, ctx, keys)
  if #keys > 0 then
    return M.label(action, ctx, keys)
  end
  return action.label
end

---@param value string|fun(ctx, keys): string|nil
---@param ctx CinderTerminal.Interaction.Context
---@param keys string[]
---@return string?
local function text(value, ctx, keys)
  if type(value) == "function" then
    return value(ctx, keys)
  end
  return value
end

---@param keys string[]
---@return string
local function join_labels(keys)
  local labels = {}
  for _, lhs in ipairs(keys) do
    labels[#labels + 1] = M.key_label(lhs)
  end
  return table.concat(labels, " / ")
end

---@param action CinderTerminal.Interaction
---@param ctx CinderTerminal.Interaction.Context
---@param keys string[]
---@return string
function M.label(action, ctx, keys)
  if action.label then
    return text(action.label, ctx, keys) or action.name
  end
  return join_labels(keys)
end

---@param action CinderTerminal.Interaction
---@param ctx CinderTerminal.Interaction.Context
---@param resolve fun(option: string, defaults: string[]): string[]
---@return string[]
---Every key of one action as a single string, for callers that list a whole
---section (`?`) and want the popup to spell out keys the hint row shortens.
---@param name string
---@param ctx CinderTerminal.Interaction.Context
---@param resolve fun(option: string, defaults: string[]): string[]
---@return string?
function M.keys_label(name, ctx, resolve)
  local action = M.by_name(name)
  if not action then
    return nil
  end
  return join_labels(M.keys(action, ctx, resolve))
end

function M.keys(action, ctx, resolve)
  local defaults = action.keys
  if type(defaults) == "function" then
    defaults = defaults(ctx)
  end
  defaults = defaults or {}
  if action.option then
    return resolve(action.option, defaults)
  end
  return defaults
end

---@param action CinderTerminal.Interaction
---@param ctx CinderTerminal.Interaction.Context
---@return boolean
function M.applies(action, ctx)
  if not vim.tbl_contains(action.surfaces, ctx.surface) then
    return false
  end
  if action.panels and not (ctx.panel and vim.tbl_contains(action.panels, ctx.panel)) then
    return false
  end
  return true
end

---@class CinderTerminal.Interaction.Binding
---@field action CinderTerminal.Interaction
---@field gesture string The key the user presses, spelled the way the hint
---row spells it. This is what `translate` is about: the gesture and the
---mapping that implements it are allowed to differ.
---@field lhs string The key to map.
---@field run? fun(ui: CinderTerminal.UI) Handler for this key alone.

---Actions bound in one surface, one entry per key. Capabilities do not gate
---bindings: the panel serves every provider at once, so a handler still checks
---and explains instead of the key silently vanishing.
---@param surface string
---@param panel? "containers"|"items"
---@param resolve fun(option: string, defaults: string[]): string[]
---@return CinderTerminal.Interaction.Binding[]
function M.bindings(surface, panel, resolve)
  local ctx = { surface = surface, panel = panel }
  local bindings = {}
  for _, action in ipairs(M.actions) do
    if (action.run or action.rhs) and M.applies(action, ctx) then
      for _, gesture in ipairs(M.keys(action, ctx, resolve)) do
        local translation = action.translate and action.translate[gesture]
        bindings[#bindings + 1] = {
          action = action,
          gesture = gesture,
          lhs = translation and translation.lhs or gesture,
          run = translation and translation.run or nil,
        }
      end
    end
  end
  return bindings
end

---The hint row of one context. Actions whose `desc` returns nil are hidden, so
---the row follows the same capability checks the handlers do.
---@param ctx CinderTerminal.Interaction.Context
---@param resolve fun(option: string, defaults: string[]): string[]
---@return { key: string, desc: string, keys: string[], native: boolean }[]
function M.hints(ctx, resolve)
  local rows = {}
  for _, action in ipairs(M.actions) do
    if action.hint ~= false and M.applies(action, ctx) then
      local keys = M.keys(action, ctx, resolve)
      local desc = text(action.desc, ctx, keys)
      local label = row_label(action, ctx, keys)
      if desc and label then
        rows[#rows + 1] = { key = label, desc = desc, keys = keys, native = action.native == true }
      end
    end
  end
  return rows
end

---Rows of the `?` popup for one context. The popup has room where the hint
---row does not, so an action whose `label` abbreviates its keys (`q` for
---`q`/`h`) spells every key out here.
---@param ctx CinderTerminal.Interaction.Context
---@param resolve fun(option: string, defaults: string[]): string[]
---@return { key: string, desc: string }[]
function M.help_rows(ctx, resolve)
  local rows = {}
  for _, action in ipairs(M.actions) do
    if action.help ~= false and M.applies(action, ctx) then
      local keys = M.keys(action, ctx, resolve)
      local desc = text(action.help_desc or action.desc, ctx, keys)
      local label
      if action.help_label then
        label = text(action.help_label, ctx, keys)
      elseif action.label and #keys > 0 then
        label = join_labels(keys)
      else
        label = row_label(action, ctx, keys)
      end
      if desc and label then
        rows[#rows + 1] = { key = label, desc = desc }
      end
    end
  end
  return rows
end

return M
