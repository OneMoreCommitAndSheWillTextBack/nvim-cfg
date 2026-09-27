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
---@field border string Outer border and internal separator.
---@field title string Focused panel title and the glowing separator.
---@field title_inactive string Unfocused panel title.
---@field selected string Selected row of the focused panel.
---@field selected_inactive string Selected row of an unfocused panel.
---@field help string Contextual key hint row.
---@field mark string Container type letter, such as `T` or `D`.
---@field detail string Secondary row text.
---@field error string Failed terminals and error messages.
---@type CinderTerminal.HighlightGroups
M.groups = {
  normal = "CinderTerminal.Normal",
  sidebar = "CinderTerminal.Sidebar",
  selected = "CinderTerminal.Selected",
  border = "CinderTerminal.Border",
  title = "CinderTerminal.Title",
  title_inactive = "CinderTerminal.TitleInactive",
  selected_inactive = "CinderTerminal.SelectedInactive",
  help = "CinderTerminal.Help",
  mark = "CinderTerminal.Mark",
  detail = "CinderTerminal.Detail",
  error = "CinderTerminal.Error",
}

local defaults = {
  [M.groups.normal] = "NormalFloat",
  [M.groups.sidebar] = "NormalFloat",
  [M.groups.selected] = "CursorLine",
  [M.groups.border] = "FloatBorder",
  [M.groups.title] = "FloatTitle",
  [M.groups.title_inactive] = "Comment",
  [M.groups.selected_inactive] = "CursorLine",
  [M.groups.help] = "Comment",
  [M.groups.mark] = "Special",
  [M.groups.detail] = "Comment",
  [M.groups.error] = "DiagnosticError",
}

local theme_callbacks = {}
local configured_overrides = {}
local configured = false

---@param first integer 0xRRGGBB
---@param second integer 0xRRGGBB
---@param ratio number 0 keeps `first`, 1 gives `second`
---@return integer
local function blend(first, second, ratio)
  local result = 0
  for index = 0, 2 do
    local weight = 256 ^ index
    local a = math.floor(first / weight) % 256
    local b = math.floor(second / weight) % 256
    local value = math.floor(a + (b - a) * ratio + 0.5) % 256
    result = result + value * weight
  end
  return result
end

---@param name string
---@return table
local function resolved(name)
  return vim.api.nvim_get_hl(0, { name = name, link = false })
end

---The focused panel keeps 'CursorLine'; a half faded cursorline in the
---unfocused panels is the lazygit "which pane has the cursor" cue. Colorschemes
---without a cursorline background keep the plain link.
local function apply_inactive_cursorline()
  local normal = resolved("Normal")
  local cursorline = resolved("CursorLine")
  if type(normal.bg) ~= "number" or type(cursorline.bg) ~= "number" then
    return
  end
  vim.api.nvim_set_hl(0, M.groups.selected_inactive, { bg = blend(cursorline.bg, normal.bg, 0.55) })
end

local function apply_defaults()
  -- Do not use `default = true`: refresh must remove colors from the previous
  -- theme before applying the current theme.
  for group, link in pairs(defaults) do
    vim.api.nvim_set_hl(0, group, { link = link })
  end
  apply_inactive_cursorline()
end

---@param overrides? table<string, vim.api.keyset.highlight|string>
local function apply_overrides(overrides)
  for name, value in pairs(overrides or {}) do
    local group = M.groups[name] or name
    local spec = type(value) == "string" and { link = value } or value
    vim.api.nvim_set_hl(0, group, spec)
  end
end

---Card groups cinder-ui draws with, derived from the semantic groups above so
---the cards wear the colorscheme instead of a palette of their own. cinder-ui
---derives a per-row variant from `CinderUiCursor`, hence the background.
local function apply_card_theme()
  local border = resolved(M.groups.border)
  local title = resolved(M.groups.title)
  local cursor = resolved(M.groups.selected)

  vim.api.nvim_set_hl(0, "CinderUiBorder", border.fg and { fg = border.fg } or { link = M.groups.border })
  vim.api.nvim_set_hl(
    0,
    "CinderUiBorderFocus",
    title.fg and { fg = title.fg, bold = title.bold } or { link = M.groups.title }
  )
  vim.api.nvim_set_hl(0, "CinderUiTitle", { link = M.groups.title })
  vim.api.nvim_set_hl(0, "CinderUiTag", { link = M.groups.mark })
  vim.api.nvim_set_hl(0, "CinderUiDim", { link = M.groups.detail })
  vim.api.nvim_set_hl(0, "CinderUiScrollbar", { link = M.groups.title })
  vim.api.nvim_set_hl(0, "CinderUiCursor", cursor.bg and { bg = cursor.bg } or { link = M.groups.selected })

  -- cinder-ui caches the highlight variants it derives per row; a new
  -- colorscheme has to drop them or the selection bar keeps the old colors.
  -- `setup()` only applies defaults, so the groups set just above survive.
  -- cinder-ui is a declared dependency, so a missing one must fail loudly
  -- instead of leaving the cards with the wrong colors forever.
  require("cinder_ui.theme").setup()
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
  apply_card_theme()
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
