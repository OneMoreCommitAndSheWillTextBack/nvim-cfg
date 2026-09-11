---@class CinderTerminal.UI
---Snacks floating-window UI for cinder-terminal.nvim.
local M = {}
M.__index = M

local api = vim.api
local fn = vim.fn

---@class CinderTerminal.UIOptions
---@field sessions CinderTerminal.SessionManager
---@field highlights CinderTerminal.HighlightGroups
---@field width? number
---@field height? number
---@field sidebar_width? number
---@field sidebar_title? string
---@field border? string
---@field title? string

---@param opts CinderTerminal.UIOptions
---@return CinderTerminal.UI
function M.new(opts)
  return setmetatable({
    opts = opts,
    sessions = opts.sessions,
    highlights = opts.highlights,
    state = {
      layout = nil,
      sidebar = nil,
      terminal = nil,
      line_sessions = {},
      refresh_pending = false,
      augroup = nil,
    },
  }, M)
end

local function snacks()
  return _G.Snacks or require("snacks")
end

function M:workspace_visible()
  local current = api.nvim_get_current_win()
  local state = self.state
  if state.layout and state.layout.root and state.layout.root:win_valid() then
    if current == state.layout.root.win then
      return true
    end
  end
  if state.sidebar and state.sidebar:win_valid() and current == state.sidebar.win then
    return true
  end
  if state.terminal and state.terminal:win_valid() and current == state.terminal.win then
    return true
  end
  return false
end

function M:workspace_ready()
  local state = self.state
  return state.layout
    and state.layout:valid()
    and state.sidebar
    and state.sidebar:valid()
    and state.terminal
    and state.terminal:valid()
end

function M:update_title()
  local state = self.state
  if not (state.layout and state.layout.root and state.layout.root:win_valid()) then
    return
  end

  local session = self.sessions:current()
  local title = self.opts.title or " Terminal Sessions "
  if session then
    title = " " .. self.sessions:title(session.cwd) .. " "
  end
  state.layout.root:set_title(title, "center")
end

function M:render_sidebar()
  local state = self.state
  if not (state.sidebar and state.sidebar:buf_valid()) then
    return
  end

  local win = state.sidebar.win
  local width = (win and api.nvim_win_is_valid(win)) and api.nvim_win_get_width(win) or 30
  local lines = {
    "Terminal Sessions",
    "",
  }
  state.line_sessions = {}

  local list = self.sessions:list()
  if #list == 0 then
    lines[#lines + 1] = "No sessions"
    lines[#lines + 1] = "Press n to create one"
  else
    local current = self.sessions:current()
    for _, session in ipairs(list) do
      local marker = session == current and ">" or " "
      local status = session.status or "running"
      local label = self.sessions:title(session.cwd)
      local row = string.format("%s %d %-8s %s", marker, session.id, status, label)
      row = self.sessions:display_text(row, width - 1)
      lines[#lines + 1] = row
      state.line_sessions[#lines] = session.id
    end
  end

  vim.bo[state.sidebar.buf].modifiable = true
  api.nvim_buf_set_lines(state.sidebar.buf, 0, -1, false, lines)
  vim.bo[state.sidebar.buf].modifiable = false
end

function M:refresh_now()
  self.state.refresh_pending = false
  if self.state.sidebar and self.state.sidebar:buf_valid() then
    self:render_sidebar()
  end
  self:update_title()
end

function M:refresh()
  if self.state.refresh_pending then
    return
  end
  self.state.refresh_pending = true
  vim.schedule(function()
    self:refresh_now()
  end)
end

function M:set_terminal_focus(start_insert)
  local terminal = self.state.terminal
  if not (terminal and terminal:win_valid()) then
    return
  end
  api.nvim_set_current_win(terminal.win)
  if start_insert then
    vim.cmd.startinsert()
  else
    vim.cmd.stopinsert()
  end
end

function M:set_sidebar_focus()
  local sidebar = self.state.sidebar
  if not (sidebar and sidebar:win_valid()) then
    return
  end
  pcall(vim.cmd.stopinsert)
  api.nvim_set_current_win(sidebar.win)
end

---@param buf number
function M:map_session_buffer(buf)
  local function opts(desc)
    return { buffer = buf, desc = desc, nowait = true, silent = true }
  end

  vim.keymap.set("t", "<Esc><Esc>", [[<C-\><C-n>]], opts("Terminal Normal Mode"))
  vim.keymap.set("n", "<C-w>h", function()
    self:focus_sidebar()
  end, opts("Focus Terminal Sidebar"))
  vim.keymap.set("n", "<leader>wh", function()
    self:focus_sidebar()
  end, opts("Focus Terminal Sidebar"))
  vim.keymap.set("n", "q", function()
    self:close_workspace()
  end, opts("Close Terminal Workspace"))
  vim.keymap.set("n", "]T", function()
    self:next()
  end, opts("Next Terminal Session"))
  vim.keymap.set("n", "[T", function()
    self:prev()
  end, opts("Previous Terminal Session"))
  vim.keymap.set("n", "<leader>Ts", function()
    self:select()
  end, opts("Select Terminal Session"))
  vim.keymap.set("n", "<leader>Ta", function()
    self:add()
  end, opts("Add Terminal Session"))
  vim.keymap.set("n", "<leader>Tx", function()
    self:close_current()
  end, opts("Close Terminal Session"))
end

function M:ensure_layout()
  local state = self.state
  if self:workspace_ready() then
    return
  end
  if state.layout and state.layout:valid() then
    state.layout:update()
    if self:workspace_ready() then
      return
    end
  end

  local session = self.sessions:current() or self.sessions:create(self.sessions:root())
  self.sessions:set_current(session)

  state.sidebar = snacks().win({
    show = false,
    enter = false,
    fixbuf = true,
    minimal = true,
    border = "right",
    width = self.opts.sidebar_width or 32,
    title = self.opts.sidebar_title or " Sessions ",
    title_pos = "center",
    bo = {
      buftype = "nofile",
      bufhidden = "wipe",
      buflisted = false,
      swapfile = false,
      modifiable = false,
      filetype = "cinder_terminal_sidebar",
    },
    wo = {
      cursorline = true,
      number = false,
      relativenumber = false,
      signcolumn = "no",
      statuscolumn = "",
      wrap = false,
      winbar = "",
      winhighlight = table.concat({
        "Normal:" .. self.highlights.sidebar,
        "NormalNC:" .. self.highlights.sidebar,
        "EndOfBuffer:" .. self.highlights.sidebar,
        "CursorLine:" .. self.highlights.selected,
        "FloatBorder:" .. self.highlights.border,
        "FloatTitle:" .. self.highlights.title,
      }, ","),
    },
    keys = {
      q = false,
      close = {
        "q",
        function()
          self:close_workspace()
        end,
        desc = "Close Workspace",
        mode = "n",
      },
      activate = {
        "<cr>",
        function()
          self:activate_sidebar_line()
        end,
        desc = "Activate Session",
        mode = "n",
      },
      new_session = {
        "n",
        function()
          self:open(self.sessions:root())
        end,
        desc = "New Session",
        mode = "n",
      },
      copy_session = {
        "c",
        function()
          self:copy_current()
        end,
        desc = "Copy Session",
        mode = "n",
      },
      add_session = {
        "a",
        function()
          self:add()
        end,
        desc = "Add Session",
        mode = "n",
      },
      close_session = {
        "x",
        function()
          self:close_current()
        end,
        desc = "Close Session",
        mode = "n",
      },
      prev = {
        "[T",
        function()
          self:prev()
        end,
        desc = "Previous Session",
        mode = "n",
      },
      next = {
        "]T",
        function()
          self:next()
        end,
        desc = "Next Session",
        mode = "n",
      },
      refresh = {
        "r",
        function()
          self:refresh()
        end,
        desc = "Refresh",
        mode = "n",
      },
      focus_terminal = {
        "<leader>wl",
        function()
          self:focus()
        end,
        desc = "Focus Terminal",
        mode = "n",
      },
    },
  })

  state.terminal = snacks().win({
    show = false,
    enter = false,
    fixbuf = true,
    minimal = true,
    border = false,
    buf = session.buf,
    bo = {
      bufhidden = "hide",
    },
    wo = {
      number = false,
      relativenumber = false,
      signcolumn = "no",
      statuscolumn = "",
      wrap = false,
      winbar = "",
      cursorline = false,
      winhighlight = table.concat({
        "Normal:" .. self.highlights.normal,
        "NormalNC:" .. self.highlights.normal,
        "EndOfBuffer:" .. self.highlights.normal,
      }, ","),
    },
    keys = {
      q = false,
    },
  })

  state.layout = snacks().layout.new({
    show = false,
    layout = {
      box = "horizontal",
      width = self.opts.width or 0.88,
      height = self.opts.height or 0.82,
      border = self.opts.border or "rounded",
      title = self.opts.title or " Terminal Sessions ",
      title_pos = "center",
      wo = {
        winhighlight = table.concat({
          "Normal:" .. self.highlights.normal,
          "NormalNC:" .. self.highlights.normal,
          "FloatBorder:" .. self.highlights.border,
          "FloatTitle:" .. self.highlights.title,
          "WinSeparator:" .. self.highlights.border,
        }, ","),
      },
      { win = "sidebar", width = self.opts.sidebar_width or 32, border = "right" },
      { win = "terminal", border = "none" },
    },
    wins = {
      sidebar = state.sidebar,
      terminal = state.terminal,
    },
    on_close = function()
      state.layout = nil
      state.sidebar = nil
      state.terminal = nil
      state.line_sessions = {}
    end,
  })

  state.layout:show()
  self:refresh()
end

---@param session CinderTerminal.Session
---@param opts? {focus?: boolean, insert?: boolean}
function M:activate_session(session, opts)
  opts = opts or {}
  self.sessions:set_current(session)
  self:ensure_layout()
  if self.state.terminal and self.state.terminal:win_valid() then
    self.state.terminal:set_buf(session.buf)
  end
  self:refresh()
  if opts.focus ~= false then
    self:set_terminal_focus(opts.insert == true)
  end
end

---@param cwd? string
function M:open(cwd)
  if type(cwd) ~= "string" or cwd == "bottom" or cwd == "right" or cwd == "top" or cwd == "left" then
    cwd = self.sessions:root()
  end
  local session = self.sessions:create(cwd)
  self:activate_session(session, { focus = true, insert = true })
  return session
end

function M:toggle()
  if self:workspace_visible() and self.state.layout and self.state.layout:valid() then
    self:close_workspace()
    return
  end
  self:activate_session(self.sessions:current_or_create(), { focus = true, insert = true })
end

function M:focus()
  self:activate_session(self.sessions:current_or_create(), { focus = true, insert = false })
end

function M:focus_sidebar()
  local session = self.sessions:current_or_create()
  self.sessions:set_current(session)
  self:ensure_layout()
  self:refresh()
  self:set_sidebar_focus()
end

function M:activate_sidebar_line()
  local sidebar = self.state.sidebar
  if not (sidebar and sidebar:win_valid()) then
    return
  end
  local line = api.nvim_win_get_cursor(sidebar.win)[1]
  local session_id = self.state.line_sessions[line]
  if not session_id then
    return
  end
  for _, session in ipairs(self.sessions:list()) do
    if session.id == session_id then
      self:activate_session(session, { focus = true, insert = false })
      return
    end
  end
end

function M:select()
  local list = self.sessions:list()
  if #list == 0 then
    self:open()
    return
  end

  vim.ui.select(list, {
    prompt = "Terminal Session",
    format_item = function(session)
      local marker = session == self.sessions:current() and ">" or " "
      return string.format(
        "%s %d  %s  %s",
        marker,
        session.id,
        session.status or "running",
        self.sessions:title(session.cwd)
      )
    end,
  }, function(session)
    if session then
      self:activate_session(session, { focus = true, insert = false })
    end
  end)
end

function M:add()
  vim.ui.input({
    prompt = "Terminal cwd: ",
    default = self.sessions:root(),
    completion = "dir",
  }, function(value)
    if not value or value == "" then
      return
    end
    local cwd = self.sessions:normalize_dir(value)
    if not cwd or fn.isdirectory(cwd) == 0 then
      vim.notify("Invalid directory: " .. value, vim.log.levels.ERROR)
      return
    end
    self:open(cwd)
  end)
end

function M:copy_current()
  local session
  local terminal = self.state.terminal
  if terminal and terminal:win_valid() and api.nvim_get_current_win() == terminal.win then
    session = self.sessions:find_by_buf(api.nvim_win_get_buf(terminal.win))
  end
  session = session or self.sessions:current()
  if not session then
    return self:open()
  end
  return self:open(self.sessions:process_cwd(session) or session.cwd)
end

function M:close_workspace()
  pcall(vim.cmd.stopinsert)
  if self.state.layout then
    self.state.layout:close()
  end
  self.state.layout = nil
  self.state.sidebar = nil
  self.state.terminal = nil
  self.state.line_sessions = {}
  self.state.refresh_pending = false
end

function M:close_current()
  local session = self.sessions:current()
  if not session then
    return
  end

  local list = self.sessions:list()
  local index
  for i, item in ipairs(list) do
    if item == session then
      index = i
      break
    end
  end

  if #list == 1 then
    if session.buf and api.nvim_buf_is_valid(session.buf) then
      pcall(api.nvim_buf_delete, session.buf, { force = true })
    end
    self.sessions:remove(session)
    self:close_workspace()
    return
  end

  local next_session = list[((index or 1) % #list) + 1]
  if next_session and next_session.buf and api.nvim_buf_is_valid(next_session.buf) then
    self.sessions:set_current(next_session)
    if self.state.terminal and self.state.terminal:win_valid() then
      self.state.terminal:set_buf(next_session.buf)
    end
    self:refresh()
    self:set_terminal_focus(false)
  end

  if session.buf and api.nvim_buf_is_valid(session.buf) then
    pcall(api.nvim_buf_delete, session.buf, { force = true })
  end
  self.sessions:remove(session)
  self:refresh()
end

function M:restart_current()
  local session = self.sessions:current()
  if not session then
    return
  end
  local cwd = session.cwd
  self:close_current()
  self:open(cwd)
end

function M:next()
  local list = self.sessions:list()
  if #list == 0 then
    self:open()
    return
  end
  local session = self.sessions:current() or list[1]
  local index
  for i, item in ipairs(list) do
    if item == session then
      index = i
      break
    end
  end
  index = index or 1
  self:activate_session(list[(index % #list) + 1], { focus = true, insert = false })
end

function M:prev()
  local list = self.sessions:list()
  if #list == 0 then
    self:open()
    return
  end
  local session = self.sessions:current() or list[1]
  local index
  for i, item in ipairs(list) do
    if item == session then
      index = i
      break
    end
  end
  index = index or 1
  self:activate_session(list[((index - 2) % #list) + 1], { focus = true, insert = false })
end

function M:setup_autocmds()
  if self.state.augroup then
    return
  end
  self.state.augroup = api.nvim_create_augroup("CinderTerminalUI", { clear = true })
  api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
    group = self.state.augroup,
    callback = function(ev)
      local session = self.sessions:find_by_buf(ev.buf)
      if not session then
        return
      end
      if api.nvim_get_current_win() == (self.state.terminal and self.state.terminal.win or -1) then
        self.sessions:set_current(session)
      end
      self:refresh()
    end,
  })
end

return M
