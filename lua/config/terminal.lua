local M = {}

local api = vim.api
local fn = vim.fn

local state = {
  layout = nil,
  sidebar = nil,
  terminal = nil,
  current = nil,
  sessions = {},
  next_id = 1,
  line_sessions = {},
  refresh_pending = false,
  augroup = nil,
}

local function snacks()
  return _G.Snacks or require("snacks")
end

local function normalize(path)
  if not path or path == "" then
    return nil
  end
  local ok, ret = pcall(vim.fs.normalize, path)
  return ok and ret or path
end

local function normalize_dir(path)
  if not path or path == "" then
    return nil
  end
  local expanded = fn.expand(path)
  local absolute = fn.fnamemodify(expanded, ":p")
  return normalize(absolute)
end

local function root()
  if _G.LazyVim and type(LazyVim.root) == "function" then
    return normalize(LazyVim.root()) or fn.getcwd()
  end
  return normalize((vim.uv or vim.loop).cwd() or fn.getcwd()) or fn.getcwd()
end

local function term_cmd()
  local shell = vim.o.shell
  local term = snacks().terminal
  if term and term.parse then
    return term.parse(shell)
  end
  return shell
end

local function jobstart(cmd, opts)
  opts = opts or {}
  if fn.termopen then
    return fn.termopen(cmd, opts)
  end
  opts.term = true
  return fn.jobstart(cmd, opts)
end

local function session_title(cwd)
  local label = fn.fnamemodify(cwd, ":~")
  if label == "" then
    label = cwd
  end
  return label
end

local function display_text(text, width)
  if width <= 0 then
    return text
  end
  if fn.strdisplaywidth(text) <= width then
    return text
  end
  if width <= 3 then
    return fn.strcharpart(text, 0, width)
  end
  return fn.strcharpart(text, 0, width - 3) .. "..."
end

local function sessions_sorted()
  local list = {}
  local kept = {}
  for _, session in ipairs(state.sessions) do
    if session.buf and api.nvim_buf_is_valid(session.buf) then
      list[#list + 1] = session
      kept[#kept + 1] = session
    elseif state.current == session.id then
      state.current = nil
    end
  end
  state.sessions = kept
  table.sort(list, function(a, b)
    return a.id < b.id
  end)
  return list
end

local function session_running(session)
  return session and session.buf and api.nvim_buf_is_valid(session.buf) and session.status == "running"
end

local function find_session_by_buf(buf)
  if not buf then
    return nil
  end
  for _, session in ipairs(state.sessions) do
    if session.buf == buf then
      return session
    end
  end
end

local function find_session_by_cwd(cwd)
  cwd = normalize(cwd)
  if not cwd then
    return nil
  end
  for _, session in ipairs(state.sessions) do
    if session.cwd == cwd and session_running(session) then
      return session
    end
  end
end

local function session_process_cwd(session)
  if not (session and session.buf and api.nvim_buf_is_valid(session.buf)) then
    return nil
  end

  local job = vim.b[session.buf].terminal_job_id or session.job
  local pid = job and fn.jobpid(job)
  if not pid or pid <= 0 then
    return nil
  end

  local cwd = normalize(fn.resolve("/proc/" .. pid .. "/cwd"))
  if cwd and fn.isdirectory(cwd) == 1 then
    return cwd
  end
end

local function focused_session()
  local current_win = api.nvim_get_current_win()
  if state.terminal and state.terminal:win_valid() and current_win == state.terminal.win then
    return find_session_by_buf(api.nvim_win_get_buf(current_win))
  end
end

local function current_session()
  if state.current then
    for _, session in ipairs(state.sessions) do
      if session.id == state.current and session.buf and api.nvim_buf_is_valid(session.buf) then
        return session
      end
    end
  end
  local list = sessions_sorted()
  for _, session in ipairs(list) do
    if session_running(session) then
      return session
    end
  end
  return list[1]
end

local function workspace_visible()
  local current = api.nvim_get_current_win()
  if state.layout and state.layout.root and state.layout.root:win_valid() then
    local root_win = state.layout.root.win
    if current == root_win then
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

local function workspace_ready()
  return state.layout
    and state.layout:valid()
    and state.sidebar
    and state.sidebar:valid()
    and state.terminal
    and state.terminal:valid()
end

local function update_title()
  if not (state.layout and state.layout.root and state.layout.root:win_valid()) then
    return
  end
  local session = current_session()
  local title = " Terminal Sessions "
  if session then
    title = " " .. session_title(session.cwd) .. " "
  end
  state.layout.root:set_title(title, "center")
end

local function render_sidebar()
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

  local list = sessions_sorted()
  if #list == 0 then
    lines[#lines + 1] = "No sessions"
    lines[#lines + 1] = "Press n to create one"
  else
    for _, session in ipairs(list) do
      local marker = session.id == state.current and ">" or " "
      local status = session.status or "running"
      local label = session_title(session.cwd)
      local row = string.format("%s %d %-8s %s", marker, session.id, status, label)
      row = display_text(row, width - 1)
      lines[#lines + 1] = row
      state.line_sessions[#lines] = session.id
    end
  end

  vim.bo[state.sidebar.buf].modifiable = true
  api.nvim_buf_set_lines(state.sidebar.buf, 0, -1, false, lines)
  vim.bo[state.sidebar.buf].modifiable = false
end

local function refresh_now()
  state.refresh_pending = false
  if state.sidebar and state.sidebar:buf_valid() then
    render_sidebar()
  end
  update_title()
end

function M.refresh()
  if state.refresh_pending then
    return
  end
  state.refresh_pending = true
  vim.schedule(refresh_now)
end

local function set_terminal_focus(start_insert)
  if not (state.terminal and state.terminal:win_valid()) then
    return
  end
  api.nvim_set_current_win(state.terminal.win)
  if start_insert then
    vim.cmd.startinsert()
  else
    vim.cmd.stopinsert()
  end
end

local function set_sidebar_focus()
  if not (state.sidebar and state.sidebar:win_valid()) then
    return
  end
  pcall(vim.cmd.stopinsert)
  api.nvim_set_current_win(state.sidebar.win)
end

local function map_session_buffer(buf)
  local function opts(desc)
    return { buffer = buf, desc = desc, nowait = true, silent = true }
  end

  vim.keymap.set("t", "<Esc><Esc>", [[<C-\><C-n>]], opts("Terminal Normal Mode"))
  vim.keymap.set("n", "<C-w>h", function()
    M.focus_sidebar()
  end, opts("Focus Terminal Sidebar"))
  vim.keymap.set("n", "<leader>wh", function()
    M.focus_sidebar()
  end, opts("Focus Terminal Sidebar"))
  vim.keymap.set("n", "q", function()
    M.close_workspace()
  end, opts("Close Terminal Workspace"))
  vim.keymap.set("n", "]T", function()
    M.next()
  end, opts("Next Terminal Session"))
  vim.keymap.set("n", "[T", function()
    M.prev()
  end, opts("Previous Terminal Session"))
  vim.keymap.set("n", "<leader>Ts", function()
    M.select()
  end, opts("Select Terminal Session"))
  vim.keymap.set("n", "<leader>Ta", function()
    M.add()
  end, opts("Add Terminal Session"))
  vim.keymap.set("n", "<leader>Tx", function()
    M.close_current()
  end, opts("Close Terminal Session"))
end

local function create_session(cwd)
  cwd = normalize(cwd) or root()

  local buf = api.nvim_create_buf(false, true)
  local session = {
    id = state.next_id,
    cwd = cwd,
    buf = buf,
    status = "running",
    job = nil,
  }
  state.next_id = state.next_id + 1
  state.sessions[#state.sessions + 1] = session

  vim.b[buf].terminal_mux_session_id = session.id
  vim.b[buf].terminal_mux_cwd = cwd
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].buflisted = false
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "terminal"
  map_session_buffer(buf)

  api.nvim_buf_call(buf, function()
    session.job = jobstart(term_cmd(), {
      cwd = cwd,
      on_exit = function(_, code)
        local status = tonumber(code) or 0
        session.status = status == 0 and "done" or ("exit " .. status)
        M.refresh()
      end,
    })
  end)

  if not session.job or session.job <= 0 then
    session.status = "failed"
  end

  M.refresh()
  return session
end

local function remove_session(session)
  for i, item in ipairs(state.sessions) do
    if item == session then
      table.remove(state.sessions, i)
      break
    end
  end
  if state.current == session.id then
    state.current = nil
  end
end

local function ensure_layout()
  if workspace_ready() then
    return
  end
  if state.layout and state.layout:valid() then
    state.layout:update()
    if workspace_ready() then
      return
    end
  end

  local session = current_session() or create_session(root())
  state.current = session.id

  state.sidebar = snacks().win({
    show = false,
    enter = false,
    fixbuf = true,
    minimal = true,
    border = "right",
    width = 32,
    title = " Sessions ",
    title_pos = "center",
    bo = {
      buftype = "nofile",
      bufhidden = "wipe",
      buflisted = false,
      swapfile = false,
      modifiable = false,
      filetype = "terminal_mux_sidebar",
    },
    wo = {
      cursorline = true,
      number = false,
      relativenumber = false,
      signcolumn = "no",
      statuscolumn = "",
      wrap = false,
      winbar = "",
    },
    keys = {
      q = false,
      close = {
        "q",
        function()
          M.close_workspace()
        end,
        desc = "Close Workspace",
        mode = "n",
      },
      activate = {
        "<cr>",
        function()
          M.activate_sidebar_line()
        end,
        desc = "Activate Session",
        mode = "n",
      },
      new_session = {
        "n",
        function()
          M.open(root())
        end,
        desc = "New Session",
        mode = "n",
      },
      copy_session = {
        "c",
        function()
          M.copy_current()
        end,
        desc = "Copy Session",
        mode = "n",
      },
      add_session = {
        "a",
        function()
          M.add()
        end,
        desc = "Add Session",
        mode = "n",
      },
      close_session = {
        "x",
        function()
          M.close_current()
        end,
        desc = "Close Session",
        mode = "n",
      },
      prev = {
        "[T",
        function()
          M.prev()
        end,
        desc = "Previous Session",
        mode = "n",
      },
      next = {
        "]T",
        function()
          M.next()
        end,
        desc = "Next Session",
        mode = "n",
      },
      refresh = {
        "r",
        function()
          M.refresh()
        end,
        desc = "Refresh",
        mode = "n",
      },
      focus_terminal_leader = {
        "<leader>wl",
        function()
          M.focus()
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
    },
    keys = {
      q = false,
    },
  })

  state.layout = snacks().layout.new({
    show = false,
    layout = {
      box = "horizontal",
      width = 0.88,
      height = 0.82,
      border = "rounded",
      title = " Terminal Sessions ",
      title_pos = "center",
      { win = "sidebar", width = 32, border = "right" },
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
  M.refresh()
end

local function ordered_index(session)
  local list = sessions_sorted()
  for i, item in ipairs(list) do
    if item == session then
      return i, list
    end
  end
  return nil, list
end

local function activate_session(session, opts)
  opts = opts or {}
  state.current = session.id
  ensure_layout()
  if state.terminal and state.terminal:win_valid() then
    state.terminal:set_buf(session.buf)
  end
  M.refresh()
  if opts.focus ~= false then
    set_terminal_focus(opts.insert == true)
  end
end

local function current_or_root_session()
  return current_session() or create_session(root())
end

function M.open(cwd)
  if type(cwd) ~= "string" or cwd == "bottom" or cwd == "right" or cwd == "top" or cwd == "left" then
    cwd = root()
  end
  local session = create_session(cwd)
  activate_session(session, { focus = true, insert = true })
  return session
end

function M.toggle()
  if workspace_visible() and state.layout and state.layout:valid() then
    M.close_workspace()
    return
  end
  local session = current_or_root_session()
  activate_session(session, { focus = true, insert = true })
end

function M.focus()
  local session = current_or_root_session()
  activate_session(session, { focus = true, insert = false })
end

function M.focus_sidebar()
  local session = current_or_root_session()
  state.current = session.id
  ensure_layout()
  M.refresh()
  set_sidebar_focus()
end

function M.activate_sidebar_line()
  if not (state.sidebar and state.sidebar:win_valid()) then
    return
  end
  local line = api.nvim_win_get_cursor(state.sidebar.win)[1]
  local session_id = state.line_sessions[line]
  if not session_id then
    return
  end
  for _, session in ipairs(state.sessions) do
    if session.id == session_id and session.buf and api.nvim_buf_is_valid(session.buf) then
      activate_session(session, { focus = true, insert = false })
      return
    end
  end
end

function M.select()
  local list = sessions_sorted()
  if #list == 0 then
    M.open()
    return
  end

  vim.ui.select(list, {
    prompt = "Terminal Session",
    format_item = function(session)
      local marker = session.id == state.current and ">" or " "
      return string.format("%s %d  %s  %s", marker, session.id, session.status or "running", session_title(session.cwd))
    end,
  }, function(session)
    if session then
      activate_session(session, { focus = true, insert = false })
    end
  end)
end

function M.add()
  vim.ui.input({
    prompt = "Terminal cwd: ",
    default = root(),
    completion = "dir",
  }, function(value)
    if not value or value == "" then
      return
    end
    local cwd = normalize_dir(value)
    if not cwd or fn.isdirectory(cwd) == 0 then
      vim.notify("Invalid directory: " .. value, vim.log.levels.ERROR)
      return
    end
    M.open(cwd)
  end)
end

function M.copy_current()
  local session = focused_session() or current_session()
  if not session then
    return M.open()
  end
  return M.open(session_process_cwd(session) or session.cwd)
end

function M.close_workspace()
  pcall(vim.cmd.stopinsert)
  if state.layout then
    state.layout:close()
  end
  state.layout = nil
  state.sidebar = nil
  state.terminal = nil
  state.line_sessions = {}
  state.refresh_pending = false
end

function M.close_current()
  local session = current_session()
  if not session then
    return
  end

  local index, list = ordered_index(session)
  if #list == 1 then
    if session.buf and api.nvim_buf_is_valid(session.buf) then
      pcall(api.nvim_buf_delete, session.buf, { force = true })
    end
    remove_session(session)
    M.close_workspace()
    return
  end

  local next_session = list[((index or 1) % #list) + 1]
  if next_session and next_session.buf and api.nvim_buf_is_valid(next_session.buf) then
    state.current = next_session.id
    if state.terminal and state.terminal:win_valid() then
      state.terminal:set_buf(next_session.buf)
    end
    M.refresh()
    set_terminal_focus(false)
  end

  if session.buf and api.nvim_buf_is_valid(session.buf) then
    pcall(api.nvim_buf_delete, session.buf, { force = true })
  end
  remove_session(session)
  M.refresh()
end

function M.restart_current()
  local session = current_session()
  if not session then
    return
  end
  local cwd = session.cwd
  M.close_current()
  M.open(cwd)
end

function M.next()
  local list = sessions_sorted()
  if #list == 0 then
    M.open()
    return
  end
  local session = current_session() or list[1]
  local index
  for i, item in ipairs(list) do
    if item == session then
      index = i
      break
    end
  end
  index = index or 1
  activate_session(list[(index % #list) + 1], { focus = true, insert = false })
end

function M.prev()
  local list = sessions_sorted()
  if #list == 0 then
    M.open()
    return
  end
  local session = current_session() or list[1]
  local index
  for i, item in ipairs(list) do
    if item == session then
      index = i
      break
    end
  end
  index = index or 1
  activate_session(list[((index - 2) % #list) + 1], { focus = true, insert = false })
end

local function setup_autocmds()
  if state.augroup then
    return
  end
  state.augroup = api.nvim_create_augroup("terminal_mux", { clear = true })
  api.nvim_create_autocmd({ "TermOpen", "TermClose", "WinEnter", "BufEnter" }, {
    group = state.augroup,
    callback = function(ev)
      local session = find_session_by_buf(ev.buf)
      if session then
        if ev.event == "TermClose" then
          local status = tonumber((vim.v.event and vim.v.event.status) or 0) or 0
          session.status = status == 0 and "done" or ("exit " .. status)
        end
        if api.nvim_get_current_win() == (state.terminal and state.terminal.win or -1) then
          state.current = session.id
        end
        M.refresh()
      end
    end,
  })
end

setup_autocmds()

return M
