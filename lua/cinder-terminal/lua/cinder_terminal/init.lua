---@class CinderTerminal
---cinder-terminal.nvim public API.
---
---One floating workspace with a containers panel, an items panel and a terminal
---panel. Providers supply the data: `local` owns Neovim pty sessions, `tmux`
---owns tmux sessions and windows driven by a single embedded client.
local highlights = require("cinder_terminal.highlights")
local LocalProvider = require("cinder_terminal.providers.local")
local TmuxProvider = require("cinder_terminal.providers.tmux")
local UI = require("cinder_terminal.ui")

local api = vim.api

local M = {}

M.highlights = highlights.groups
M.highlight_groups = M.highlights

---@class CinderTerminal.Options
---@field cwd? string|fun():string Root directory for new local sessions.
---@field root_markers? string[]|false Markers passed to `vim.fs.root`.
---@field shell? string|string[] Shell used by local sessions.
---@field width? number Floating workspace width, relative to the editor.
---@field height? number Floating workspace height, relative to the editor.
---@field left_ratio? number Width ratio of the left column.
---@field border? string Floating border style.
---@field refresh_interval? number tmux poll interval in milliseconds; 0 disables it.
---@field confirm? boolean Ask before killing containers or terminals.
---@field escape_window? number Milliseconds a second `<Esc>` may take to count
---as the `<Esc><Esc>` gesture in the pane.
---@field keymaps? table<string, string|string[]|false>
---@field providers? { local?: table, tmux?: table }
---@field highlights? { overrides?: table<string, vim.api.keyset.highlight|string> }

local defaults = {
  width = 0.88,
  height = 0.86,
  left_ratio = 0.30,
  border = "rounded",
  refresh_interval = 1500,
  confirm = true,
  escape_window = 300,
  keymaps = {},
  providers = {
    ["local"] = { enabled = true },
    tmux = { enabled = true },
  },
}

local instance

---@param opts? CinderTerminal.Options
---@return table
local function options_with_defaults(opts)
  return vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

---@param options table
---@return table?
local function highlight_overrides(options)
  if type(options.highlights) ~= "table" then
    return nil
  end
  return options.highlights.overrides or options.highlights
end

---@param options table
---@return CinderTerminal.Provider[]
local function build_providers(options)
  local providers = {}
  local local_opts = options.providers["local"] or {}
  if local_opts.enabled ~= false then
    providers[#providers + 1] = LocalProvider.new({
      cwd = local_opts.cwd or options.cwd,
      root_markers = local_opts.root_markers or options.root_markers,
      shell = local_opts.shell or options.shell,
      auto_shell = local_opts.auto_shell,
    })
  end

  local tmux_opts = options.providers.tmux or {}
  if tmux_opts.enabled ~= false then
    providers[#providers + 1] = TmuxProvider.new({
      tmux_binary = tmux_opts.tmux_binary or options.tmux_binary,
      socket_name = tmux_opts.socket_name or options.socket_name,
      socket_path = tmux_opts.socket_path or options.socket_path,
    })
  end
  return providers
end

---@param name string
---@return CinderTerminal.Provider?
local function provider(name)
  if not instance then
    return nil
  end
  for _, item in ipairs(instance.providers) do
    if item.name == name then
      return item
    end
  end
end

---@return CinderTerminal.UI
local function ui()
  if not instance then
    error('cinder-terminal.nvim is not initialized; call require("cinder_terminal").setup() first', 2)
  end
  return instance.ui
end

---Callback for "create one more local terminal": remember the new id so the
---next snapshot selects it, then re-read the providers. `:CinderTerminalNew`
---and `copy_current()` differ only in what they ask the provider to do.
---@param workspace CinderTerminal.UI
---@param failure string What to report when the provider sends no message.
---@return fun(ok: boolean, id?: string, error?: string)
local function after_create(workspace, failure)
  return function(ok, id, error)
    if not ok then
      workspace:notify_failure(error, failure)
      return
    end
    if id then
      workspace.state.pending_item = id
    end
    workspace:refresh()
  end
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
      "Focus the terminal pane",
    },
    CinderTerminalFocusSidebar = {
      function()
        M.focus_sidebar()
      end,
      "Focus the terminals panel",
    },
    CinderTerminalSelect = {
      function()
        M.select()
      end,
      "Focus the containers panel",
    },
    CinderTerminalClose = {
      function()
        M.close_workspace()
      end,
      "Hide the terminal workspace",
    },
    CinderTerminalNew = {
      function(cmd)
        M.open(cmd.args ~= "" and cmd.args or nil)
      end,
      "Open a new local terminal session",
      { nargs = "?", complete = "dir" },
    },
    CinderTerminalTmux = {
      function()
        M.open_tmux()
      end,
      "Open the workspace on the tmux containers",
    },
    CinderTerminalRefresh = {
      function()
        M.refresh()
      end,
      "Refresh the terminal workspace",
    },
    CinderTerminalNext = {
      function()
        M.next()
      end,
      "Select the next entry",
    },
    CinderTerminalPrev = {
      function()
        M.prev()
      end,
      "Select the previous entry",
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
  if instance then
    return M
  end
  local options = options_with_defaults(opts)
  highlights.setup({ overrides = highlight_overrides(options) })

  local workspace = UI.new(vim.tbl_extend("force", options, { groups = highlights.groups }))
  local providers = build_providers(options)
  for _, item in ipairs(providers) do
    item.on_buffer = function(buf)
      workspace:map_terminal_buffer(buf)
    end
    item.on_change = function()
      if item.name == "tmux" then
        workspace:invalidate_terminal()
      end
      workspace:refresh()
    end
  end
  workspace:set_providers(providers)

  instance = {
    ui = workspace,
    providers = providers,
    options = options,
    sessions = providers[1] and providers[1].pty or nil,
  }
  define_commands()
  return M
end

---@param name string Colorscheme name, such as `everforest`.
---@param callback fun(groups: CinderTerminal.HighlightGroups)
function M.register_theme(name, callback)
  highlights.register_theme(name, callback)
end

function M.refresh_terminal_theme()
  highlights.refresh_terminal_theme()
end

function M.is_open()
  return instance ~= nil and instance.ui:is_open()
end

function M.open(cwd)
  local workspace = ui()
  if type(cwd) == "string" and cwd ~= "" and cwd ~= "bottom" and cwd ~= "right" then
    -- Start the requested shell before the workspace does its first snapshot:
    -- the container is not empty, so the provider's prepare leaves it alone
    -- and `:CinderTerminalNew <dir>` starts one shell, not two.
    local local_provider = provider("local")
    local session = local_provider and local_provider:create(cwd) or nil
    if session then
      workspace.state.pending_item = "local:" .. session.id
    end
  end
  workspace:open()
  return M
end

function M.open_tmux()
  local workspace = ui()
  workspace:open()
  workspace:select_provider("tmux")
  workspace:set_focus("containers")
  return M
end

function M.toggle()
  ui():toggle()
  return M
end

function M.focus()
  local workspace = ui()
  workspace:open()
  workspace:set_focus("terminal", { insert = true })
  return M
end

function M.focus_sidebar()
  local workspace = ui()
  workspace:open()
  workspace:set_focus("items")
  return M
end

function M.select()
  local workspace = ui()
  workspace:open()
  workspace:set_focus("containers")
  return M
end

function M.add()
  local workspace = ui()
  workspace:open()
  local local_provider = provider("local")
  if not local_provider then
    return M
  end
  local_provider:create_terminal(
    { id = "local", kind = "container", provider = "local" },
    after_create(workspace, "could not create the terminal")
  )
  return M
end

function M.copy_current()
  local workspace = ui()
  local local_provider = provider("local")
  if not local_provider then
    return M
  end
  local node = workspace:selected_item()
  local_provider:duplicate(node, after_create(workspace, "could not copy the terminal"))
  return M
end

function M.close_workspace()
  ui():close()
  return M
end

function M.close_current()
  ui():action_kill()
  return M
end

function M.restart_current()
  local workspace = ui()
  local node = workspace:selected_item()
  if not node or node.provider ~= "local" then
    return M
  end
  workspace:restart_node(node, provider("local"))
  return M
end

function M.next()
  ui():move_selection(1)
  return M
end

function M.prev()
  ui():move_selection(-1)
  return M
end

function M.refresh()
  ui():refresh()
  return M
end

define_commands()

return M
