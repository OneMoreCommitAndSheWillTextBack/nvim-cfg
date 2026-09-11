--- Highlight layers used by cinder-terminal.nvim.
---
--- The refresh order is intentionally fixed:
---
---   theme callback > user overrides > plugin defaults
---
--- A theme adapter is registered with `register_theme()`. The adapter is only
--- called when its name matches `vim.g.colors_name`.
local M = {}

---@class CinderTerminal.HighlightGroups
---@field normal string Terminal content and unused cells.
---@field sidebar string Session list background.
---@field selected string Selected row in the session list.
---@field border string Outer border and internal separator.
---@field title string Workspace title.
---@type CinderTerminal.HighlightGroups
M.groups = {
  normal = "CinderTerminal.Normal",
  sidebar = "CinderTerminal.Sidebar",
  selected = "CinderTerminal.Selected",
  border = "CinderTerminal.Border",
  title = "CinderTerminal.Title",
}

local defaults = {
  [M.groups.normal] = "NormalFloat",
  [M.groups.sidebar] = "NormalFloat",
  [M.groups.selected] = "CursorLine",
  [M.groups.border] = "FloatBorder",
  [M.groups.title] = "FloatTitle",
}

local theme_callbacks = {}
local configured_overrides = {}
local configured = false

local function apply_defaults()
  -- Do not use `default = true`: refresh must remove colors from the previous
  -- theme before applying the current theme.
  for group, link in pairs(defaults) do
    vim.api.nvim_set_hl(0, group, { link = link })
  end
end

---@param overrides? table<string, vim.api.keyset.highlight|string>
local function apply_overrides(overrides)
  for name, value in pairs(overrides or {}) do
    local group = M.groups[name] or name
    local spec = type(value) == "string" and { link = value } or value
    vim.api.nvim_set_hl(0, group, spec)
  end
end

--- Rebuild the CinderTerminal highlight layer for the active colorscheme.
--- The current theme callback wins over user overrides, which win over the
--- plugin defaults.
function M.refresh_terminal_theme()
  apply_defaults()
  apply_overrides(configured_overrides)

  local callback = theme_callbacks[vim.g.colors_name]
  if callback then
    callback(M.groups)
  end
end

---@param name string Colorscheme name, such as `everforest`.
---@param callback fun(groups: CinderTerminal.HighlightGroups)
function M.register_theme(name, callback)
  assert(type(name) == "string" and name ~= "", "theme name must be a non-empty string")
  assert(type(callback) == "function", "theme callback must be a function")
  theme_callbacks[name] = callback

  -- Support adapters registered after setup, including a theme that was
  -- loaded before the adapter was registered.
  if configured and vim.g.colors_name == name then
    M.refresh_terminal_theme()
  end
end

---@param opts? {overrides?: table<string, vim.api.keyset.highlight|string>}
---@return CinderTerminal.HighlightGroups
function M.setup(opts)
  if configured then
    return M.groups
  end

  configured_overrides = vim.deepcopy((opts and opts.overrides) or {})
  configured = true

  local group = vim.api.nvim_create_augroup("CinderTerminalHighlights", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = M.refresh_terminal_theme,
  })

  -- A colorscheme may already have been loaded before this plugin initializes.
  M.refresh_terminal_theme()
  return M.groups
end

return M
