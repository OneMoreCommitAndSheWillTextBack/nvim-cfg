---@class CinderTerminal
---cinder-terminal.nvim public API.
---
--- The implementation is split into session management, UI, and highlights.
--- Users normally only need `setup()` and the action methods below:
---
---   require("cinder_terminal").setup()
---   require("cinder_terminal").toggle()
local M = {}

local api = vim.api
local highlights = require("cinder_terminal.highlights")
local Session = require("cinder_terminal.session")
local UI = require("cinder_terminal.ui")

---@class CinderTerminal.Options
---@field cwd? string|fun():string Root directory for new sessions.
---@field root_markers? string[]|false Markers passed to `vim.fs.root`.
---@field shell? string|string[] Shell command used by terminal sessions.
---@field width? number Floating workspace width, relative to the editor.
---@field height? number Floating workspace height, relative to the editor.
---@field sidebar_width? number Session sidebar width.
---@field sidebar_title? string Session sidebar title.
---@field title? string Floating workspace title.
---@field border? string Floating workspace border style.
---@field highlights? {overrides?: table<string, vim.api.keyset.highlight|string>}

local defaults = {
  width = 0.88,
  height = 0.82,
  sidebar_width = 32,
  border = "rounded",
  root_markers = { ".git" },
}

---@type CinderTerminal.HighlightGroups
M.highlights = highlights.groups
M.highlight_groups = M.highlights

---@class CinderTerminal.Instance
---@field sessions CinderTerminal.SessionManager
---@field ui CinderTerminal.UI
local instance

local function options_with_defaults(opts)
  return vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

local function highlight_overrides(opts)
  if type(opts.highlights) ~= "table" then
    return nil
  end
  return opts.highlights.overrides or opts.highlights
end

local function define_commands()
  local commands = {
    CinderTerminalToggle = {
      function()
        M.toggle()
      end,
      "Toggle the terminal workspace",
    },
    CinderTerminalFocus = {
      function()
        M.focus()
      end,
      "Focus the terminal workspace",
    },
    CinderTerminalFocusSidebar = {
      function()
        M.focus_sidebar()
      end,
      "Focus the terminal session sidebar",
    },
    CinderTerminalClose = {
      function()
        M.close_workspace()
      end,
      "Close the terminal workspace",
    },
    CinderTerminalNew = {
      function(cmd)
        M.open(cmd.args ~= "" and cmd.args or nil)
      end,
      "Open a new terminal session",
      { nargs = "?", complete = "dir" },
    },
    CinderTerminalNext = {
      function()
        M.next()
      end,
      "Switch to the next terminal session",
    },
    CinderTerminalPrev = {
      function()
        M.prev()
      end,
      "Switch to the previous terminal session",
    },
  }

  for name, spec in pairs(commands) do
    if vim.fn.exists(":" .. name) ~= 2 then
      api.nvim_create_user_command(name, spec[1], vim.tbl_extend("force", spec[3] or {}, { desc = spec[2] }))
    end
  end
end

---@param opts? CinderTerminal.Options
---@return CinderTerminal
function M.setup(opts)
  local options = options_with_defaults(opts)
  local override_opt = highlight_overrides(options)

  if instance then
    return M
  end

  highlights.setup({ overrides = override_opt })

  local ui
  local sessions = Session.new({
    cwd = options.cwd,
    root_markers = options.root_markers,
    shell = options.shell,
    on_change = function()
      if ui then
        ui:refresh()
      end
    end,
    on_buffer = function(buf)
      if ui then
        ui:map_session_buffer(buf)
      end
    end,
  })

  ui = UI.new(vim.tbl_extend("force", options, {
    sessions = sessions,
    highlights = M.highlights,
  }))
  ui:setup_autocmds()

  instance = {
    sessions = sessions,
    ui = ui,
  }
  return M
end

---@param name string Colorscheme name, such as `everforest`.
---@param callback fun(groups: CinderTerminal.HighlightGroups)
function M.register_theme(name, callback)
  highlights.register_theme(name, callback)
end

function M.refresh_terminal_theme()
  return highlights.refresh_terminal_theme()
end

local function get_ui()
  if not instance then
    error('cinder-terminal.nvim is not initialized; call require("cinder_terminal").setup() first', 2)
  end
  return instance.ui
end

function M.refresh()
  return get_ui():refresh()
end

function M.open(cwd)
  return get_ui():open(cwd)
end

function M.toggle()
  return get_ui():toggle()
end

function M.focus()
  return get_ui():focus()
end

function M.focus_sidebar()
  return get_ui():focus_sidebar()
end

function M.activate_sidebar_line()
  return get_ui():activate_sidebar_line()
end

function M.select()
  return get_ui():select()
end

function M.add()
  return get_ui():add()
end

function M.copy_current()
  return get_ui():copy_current()
end

function M.close_workspace()
  return get_ui():close_workspace()
end

function M.close_current()
  return get_ui():close_current()
end

function M.restart_current()
  return get_ui():restart_current()
end

function M.next()
  return get_ui():next()
end

function M.prev()
  return get_ui():prev()
end

define_commands()

return M
