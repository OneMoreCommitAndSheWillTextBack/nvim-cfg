---Workspace lifecycle: the two real windows (the cinder-ui float and the
---terminal pane), their autocmds and timers, and the open/close/focus moves
---between the sidebar cards and the pane.
local layout = require("cinder_terminal.layout")
local ui = require("cinder_ui")
local util = require("cinder_terminal.ui.util")

local api = vim.api

local scratch = util.scratch
local valid_buf = util.valid_buf
local valid_win = util.valid_win

---@class CinderTerminal.UI
---@field opts table
---@field state table
---@field providers CinderTerminal.Provider[]
---@field provider_by_name table<string, CinderTerminal.Provider>
local M = {}

---@param opts table
---@return table
function M.initial_state(opts)
  return {
    opts = opts,
    providers = {},
    provider_by_name = {},
    state = {
      opened = false,
      focus = "items",
      card_focus = "items",
      containers = {},
      items = {},
      selected_container_id = nil,
      selected_item_id = nil,
      memory = {},
      scroll = { containers = 0, items = 0 },
      app = nil,
      win = {},
      buf = {},
      metrics = nil,
      refreshing = false,
      refresh_queued = false,
      -- Rebuilt on every open by `keys.map_sidebar`: {[panel] = {[lhs] = binding}}.
      sidebar_bindings = nil,
      attach_generation = 0,
      attach_timer = nil,
      attached_item_id = nil,
      attach_force = false,
      terminal_insert = false,
      escape_at = nil,
      shutting_down = false,
      pending_item = nil,
      pending_container = nil,
      pending_provider = nil,
      message = nil,
      message_level = nil,
      timer = nil,
      augroup = nil,
      terminal_title = "",
      mapped_buffers = {},
    },
  }
end

---@param providers CinderTerminal.Provider[]
function M:set_providers(providers)
  self.providers = providers
  self.provider_by_name = {}
  for _, provider in ipairs(providers) do
    self.provider_by_name[provider.name] = provider
  end
end

---@param node? CinderTerminal.Node
---@return CinderTerminal.Provider?
function M:provider(node)
  if not node then
    return nil
  end
  return self.provider_by_name[node.provider]
end

---@return CinderTerminal.HighlightGroups
function M:highlights()
  return self.opts.groups or require("cinder_terminal.highlights").groups
end

function M:is_open()
  return self.state.opened and valid_win(self.state.win.app) and valid_win(self.state.win.terminal)
end

function M:dimensions()
  return layout.compute({
    columns = vim.o.columns,
    lines = vim.o.lines,
    cmdheight = vim.o.cmdheight,
    width = self.opts.width,
    height = self.opts.height,
    left_ratio = self.opts.left_ratio,
    container_rows = #self.state.containers,
  })
end

---@param win number
local function base_window_options(win)
  if not valid_win(win) then
    return
  end
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].wrap = false
  vim.wo[win].list = false
  vim.wo[win].spell = false
end

---Window chrome of the two real windows. Card borders, titles, the selection
---bar and the hint row are all drawn by cinder-ui into the app buffer, so no
---window carries a winbar or a cursorline any more.
function M:apply_window_options()
  local state = self.state
  local hl = self:highlights()
  local app = state.win.app
  if valid_win(app) then
    base_window_options(app)
    vim.wo[app].winhighlight = table.concat({
      "Normal:" .. hl.sidebar,
      "NormalNC:" .. hl.sidebar,
      "EndOfBuffer:" .. hl.sidebar,
      "FloatBorder:" .. hl.border,
      "FloatTitle:" .. hl.title,
    }, ",")
  end
  local term = state.win.terminal
  if valid_win(term) then
    base_window_options(term)
    vim.wo[term].winfixbuf = true
    -- Both pane modes look identical, so the card title carries the marker.
    vim.wo[term].winhighlight = table.concat({
      "Normal:" .. hl.normal,
      "NormalNC:" .. hl.normal,
      "EndOfBuffer:" .. hl.normal,
    }, ",")
  end
end

function M:create_windows()
  local state = self.state
  local d = self:dimensions()
  state.metrics = d

  state.app = ui.App.new({
    width = d.frame.width,
    height = d.frame.height,
    row = d.frame.row,
    col = d.frame.col,
    border = self.opts.border,
    zindex = 40,
    focus = state.focus,
    enter = false,
  })
  state.app:open(self:build_tree())
  state.win.app = state.app.win
  state.buf.app = state.app.buf

  state.buf.hint = scratch("cinder_terminal_terminal", "hide")
  state.win.terminal = api.nvim_open_win(state.buf.hint, false, {
    relative = "win",
    win = state.win.app,
    row = 0,
    col = 0,
    width = 1,
    height = 1,
    style = "minimal",
    border = "none",
    zindex = 45,
  })
  self:apply_window_options()
  self:sync_terminal_window()
  self:map_buffers()
end

function M:reflow()
  if not self:is_open() then
    return
  end
  local state = self.state
  local d = self:dimensions()
  state.metrics = d
  state.app:set_geometry({
    width = d.frame.width,
    height = d.frame.height,
    row = d.frame.row,
    col = d.frame.col,
  })
  self:render()
end

function M:setup_autocmds()
  local state = self.state
  if state.augroup then
    return
  end
  state.augroup = api.nvim_create_augroup("CinderTerminalUI", { clear = true })

  api.nvim_create_autocmd("WinEnter", {
    group = state.augroup,
    callback = function()
      self:sync_focus_from_window()
    end,
  })

  api.nvim_create_autocmd("ModeChanged", {
    group = state.augroup,
    callback = function()
      if not self:is_open() then
        return
      end
      -- Track the pane's own mode, not the focus: the title has to keep
      -- saying `normal` after the cursor moves back to a list.
      local win = state.win.terminal
      if valid_win(win) and api.nvim_get_current_win() == win then
        state.terminal_insert = api.nvim_get_mode().mode == "t"
      end
      -- The terminal card title carries the mode and the hint row swaps
      -- between insert and normal keys, so both have to follow the mode.
      self:render()
    end,
  })

  api.nvim_create_autocmd("VimResized", {
    group = state.augroup,
    callback = function()
      if not self:is_open() then
        return
      end
      self:reflow()
    end,
  })

  api.nvim_create_autocmd("ColorScheme", {
    group = state.augroup,
    callback = function()
      if self:is_open() then
        self:render()
      end
    end,
  })

  -- Closing the workspace float or the terminal pane (`:q`, `:bd` on the
  -- terminal buffer, a window manager quirk) would otherwise leave the
  -- workspace half alive: `is_open()` turns false while the other window stays
  -- on screen. Hiding the workspace keeps every session alive and the next
  -- open rebuilds it.
  api.nvim_create_autocmd("VimLeavePre", {
    group = state.augroup,
    callback = function()
      state.shutting_down = true
    end,
  })

  api.nvim_create_autocmd("WinClosed", {
    group = state.augroup,
    callback = function(args)
      local win = tonumber(args.match)
      if not win or not state.opened or state.shutting_down then
        return
      end
      if win ~= state.win.app and win ~= state.win.terminal then
        return
      end
      vim.schedule(function()
        if state.opened and not self:is_open() then
          self:close()
        end
      end)
    end,
  })
end

function M:start_timer()
  local interval = self.opts.refresh_interval
  if self.state.timer or not interval or interval <= 0 then
    return
  end
  local uv = vim.uv or vim.loop
  self.state.timer = uv.new_timer()
  self.state.timer:start(
    interval,
    interval,
    vim.schedule_wrap(function()
      if self:is_open() then
        self:refresh()
      end
    end)
  )
end

function M:stop_timer()
  local timer = self.state.timer
  if not timer then
    return
  end
  pcall(timer.stop, timer)
  pcall(timer.close, timer)
  self.state.timer = nil
end

---Let every provider make sure the first snapshot has something to show.
---Providers are asked on every open and stay idempotent themselves, so a
---terminal the user killed is not resurrected by reopening the workspace.
function M:prepare_providers()
  for _, provider in ipairs(self.providers or {}) do
    if type(provider.prepare) == "function" then
      provider:prepare()
    end
  end
end

function M:open()
  local state = self.state
  if self:is_open() then
    self:set_focus(state.focus == "terminal" and "terminal" or state.card_focus, { insert = state.focus == "terminal" })
    return
  end
  state.opened = true
  state.message = nil
  state.attached_item_id = nil
  self:create_windows()
  self:setup_autocmds()
  self:start_timer()
  self:prepare_providers()
  self:refresh()
  -- Open on the terminal when there is something to type into, otherwise land
  -- on the items panel so `n` creates the first one.
  local target = self:selected_item() and "terminal" or "items"
  self:set_focus(target, { insert = target == "terminal" })
end

function M:close()
  local state = self.state
  if not state.opened then
    return
  end
  state.opened = false
  self:stop_timer()
  state.attach_generation = state.attach_generation + 1
  if state.attach_timer then
    pcall(state.attach_timer.stop, state.attach_timer)
    pcall(state.attach_timer.close, state.attach_timer)
    state.attach_timer = nil
  end
  pcall(vim.cmd.stopinsert)
  for _, win in pairs({ state.win.terminal }) do
    if valid_win(win) then
      pcall(api.nvim_win_close, win, true)
    end
  end
  if state.app then
    state.app:close()
    state.app = nil
  end
  for _, buf in pairs(state.buf) do
    if valid_buf(buf) then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
  end
  state.win, state.buf = {}, {}
  state.metrics = nil
end

function M:toggle()
  if self:is_open() then
    self:close()
  else
    self:open()
  end
end

function M:sync_focus_from_window()
  local state = self.state
  if not self:is_open() then
    return
  end
  local win = api.nvim_get_current_win()
  local target
  if win == state.win.app then
    target = state.card_focus
  elseif win == state.win.terminal then
    target = "terminal"
  else
    return
  end
  if target == state.focus then
    return
  end
  state.focus = target
  if target == "terminal" then
    state.terminal_insert = api.nvim_get_mode().mode == "t"
  else
    state.card_focus = target
  end
  self:render()
end

---@param kind "containers"|"items"|"terminal"
---@param opts? { insert?: boolean }
function M:set_focus(kind, opts)
  opts = opts or {}
  local state = self.state
  if not self:is_open() then
    return
  end
  local win = kind == "terminal" and state.win.terminal or state.win.app
  if not valid_win(win) then
    return
  end
  state.focus = kind
  if kind ~= "terminal" then
    state.card_focus = kind
    pcall(vim.cmd.stopinsert)
  end
  self:render()
  api.nvim_set_current_win(win)

  if kind == "terminal" then
    state.terminal_insert = opts.insert ~= false
    if state.terminal_insert and vim.bo[api.nvim_win_get_buf(win)].buftype == "terminal" then
      self:enter_terminal_insert()
    end
  end
end

return M
