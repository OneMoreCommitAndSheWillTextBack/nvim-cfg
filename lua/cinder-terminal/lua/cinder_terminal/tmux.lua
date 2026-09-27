---@class CinderTerminal.Tmux.Session
---@field id string Stable `$n` id.
---@field name string
---@field attached number Number of attached clients.
---@field windows_count number

---@class CinderTerminal.Tmux.Window
---@field session_id string
---@field id string Stable `@n` id.
---@field index number
---@field name string
---@field active boolean
---@field panes_count number
---@field active_pane_id string
---@field active_pane_command string
---@field active_pane_path string

---@class CinderTerminal.Tmux.Client
---@field pid number
---@field tty string
---@field session string

---@class CinderTerminal.Tmux
---Shell-free tmux adapter. All commands go through `vim.system`; parsing is
---kept in pure functions so it can be tested without a running server.
local M = {}
M.__index = M

local SESSION_FORMAT = table.concat({
  "#{session_id}",
  "#{session_name}",
  "#{session_attached}",
  "#{session_windows}",
}, "\t")

-- `list-windows` runs in a window context: pane_* fields describe the active
-- pane of that window and are only used for window-level metadata.
local WINDOW_FORMAT = table.concat({
  "#{session_id}",
  "#{window_id}",
  "#{window_index}",
  "#{window_name}",
  "#{window_active}",
  "#{window_panes}",
  "#{pane_id}",
  "#{pane_current_command}",
  "#{pane_current_path}",
}, "\t")

local CLIENT_FORMAT = table.concat({
  "#{client_pid}",
  "#{client_tty}",
  "#{client_session}",
}, "\t")

---@param text string
---@return string[]
local function lines_from(text)
  text = (text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  if text == "" then
    return {}
  end
  local lines = vim.split(text, "\n", { plain = true, trimempty = false })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

---@param line string
---@return string[]
local function fields_from(line)
  return vim.split(line, "\t", { plain = true, trimempty = false })
end

---@param value string?
---@return boolean
local function bool(value)
  return value == "1" or value == "on" or value == "true" or value == "yes"
end

---@param value string?
---@param fallback number
---@return number
local function number(value, fallback)
  local parsed = tonumber(value)
  return parsed == nil and fallback or parsed
end

---@param text string
---@return CinderTerminal.Tmux.Session[]
function M.parse_sessions(text)
  local sessions = {}
  for _, line in ipairs(lines_from(text)) do
    local fields = fields_from(line)
    if fields[1] and fields[1] ~= "" then
      sessions[#sessions + 1] = {
        id = fields[1],
        name = fields[2] or fields[1],
        attached = number(fields[3], 0),
        windows_count = number(fields[4], 0),
      }
    end
  end
  return sessions
end

---@param text string
---@return CinderTerminal.Tmux.Window[]
function M.parse_windows(text)
  local windows = {}
  for _, line in ipairs(lines_from(text)) do
    local fields = fields_from(line)
    if fields[1] and fields[2] then
      windows[#windows + 1] = {
        session_id = fields[1],
        id = fields[2],
        index = number(fields[3], 0),
        name = fields[4] or fields[2],
        active = bool(fields[5]),
        panes_count = number(fields[6], 0),
        active_pane_id = fields[7] or "",
        active_pane_command = fields[8] or "",
        active_pane_path = fields[9] or "",
      }
    end
  end
  return windows
end

---@param text string
---@return CinderTerminal.Tmux.Client[]
function M.parse_clients(text)
  local clients = {}
  for _, line in ipairs(lines_from(text)) do
    local fields = fields_from(line)
    local pid = tonumber(fields[1])
    if pid and fields[2] and fields[2] ~= "" then
      clients[#clients + 1] = {
        pid = pid,
        tty = fields[2],
        session = fields[3] or "",
      }
    end
  end
  return clients
end

---@param message string?
---@return boolean
function M.is_no_server_error(message)
  message = message or ""
  return message:match("no server running") ~= nil
    or message:match("failed to connect") ~= nil
    or message:match("error connecting") ~= nil
    or message:match("No such file or directory") ~= nil
end

---Socket of the server Neovim itself is attached to, if any. `TMUX` is
---`<socket>,<pid>,<session>`.
---@return string?
function M.socket_from_env()
  local value = vim.env.TMUX
  if not value or value == "" then
    return nil
  end
  return value:match("^([^,]+),") or nil
end

---Session id (`$n`) that hosts this Neovim, if any. The third field of `TMUX`
---is the session id without its `$` prefix.
---@return string?
function M.session_from_env()
  local value = vim.env.TMUX
  if not value or value == "" then
    return nil
  end
  local id = value:match(",([^,]+)$")
  if not id or id == "" then
    return nil
  end
  return "$" .. id
end

---@param opts? table
---@return CinderTerminal.Tmux
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    binary = opts.tmux_binary or "tmux",
    socket_name = opts.socket_name,
    -- Adopting the socket of the surrounding tmux keeps every command and the
    -- embedded client on one server, even when Neovim runs inside tmux on a
    -- non-default socket (`tmux -L work`); without it `attach-session` would
    -- look at the default socket and exit immediately.
    socket_path = opts.socket_path or (not opts.socket_name and M.socket_from_env() or nil),
  }, M)
end

---@param args string[]
---@return string[]
function M:command(args)
  local command = { self.binary }
  if self.socket_path and self.socket_path ~= "" then
    vim.list_extend(command, { "-S", self.socket_path })
  elseif self.socket_name and self.socket_name ~= "" then
    vim.list_extend(command, { "-L", self.socket_name })
  end
  vim.list_extend(command, args)
  return command
end

---@param args string[]
---@param callback? fun(ok: boolean, stdout: string, stderr: string, code: number)
---@return any
function M:run(args, callback)
  local command = self:command(args)
  local done = callback or function() end
  if vim.system then
    return vim.system(command, { text = true }, function(result)
      vim.schedule(function()
        done(result.code == 0, result.stdout or "", result.stderr or "", result.code or 1)
      end)
    end)
  end

  local stdout, stderr, finished = {}, {}, false
  local function finish(code)
    if finished then
      return
    end
    finished = true
    vim.schedule(function()
      done(code == 0, table.concat(stdout, "\n"), table.concat(stderr, "\n"), code or 1)
    end)
  end

  local job = vim.fn.jobstart(command, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        vim.list_extend(stdout, data)
      end
    end,
    on_stderr = function(_, data)
      if data then
        vim.list_extend(stderr, data)
      end
    end,
    on_exit = function(_, code)
      finish(code)
    end,
  })
  if job <= 0 then
    finish(127)
  end
  return job
end

---@param callback fun(ok: boolean, sessions: CinderTerminal.Tmux.Session[], error?: string)
function M:list_sessions(callback)
  self:run({ "list-sessions", "-F", SESSION_FORMAT }, function(ok, stdout, stderr)
    if not ok then
      callback(false, {}, stderr ~= "" and stderr or stdout)
      return
    end
    callback(true, M.parse_sessions(stdout))
  end)
end

---@param callback fun(ok: boolean, windows: CinderTerminal.Tmux.Window[], error?: string)
function M:list_windows(callback, session_id)
  local args = { "list-windows" }
  if session_id then
    vim.list_extend(args, { "-t", session_id })
  else
    vim.list_extend(args, { "-a" })
  end
  vim.list_extend(args, { "-F", WINDOW_FORMAT })
  self:run(args, function(ok, stdout, stderr)
    if not ok then
      callback(false, {}, stderr ~= "" and stderr or stdout)
      return
    end
    callback(true, M.parse_windows(stdout))
  end)
end

---@param callback fun(ok: boolean, sessions: table[], error?: string)
function M:snapshot(callback)
  self:list_sessions(function(ok, sessions, error)
    if not ok then
      if M.is_no_server_error(error) then
        callback(true, {})
      else
        callback(false, {}, error)
      end
      return
    end
    if #sessions == 0 then
      callback(true, sessions)
      return
    end

    self:list_windows(function(windows_ok, windows, windows_error)
      if not windows_ok then
        if M.is_no_server_error(windows_error) then
          callback(true, sessions)
        else
          callback(false, {}, windows_error)
        end
        return
      end

      local by_session = {}
      for _, session in ipairs(sessions) do
        session.windows = {}
        by_session[session.id] = session
      end
      for _, window in ipairs(windows) do
        local session = by_session[window.session_id]
        if session then
          session.windows[#session.windows + 1] = window
        end
      end
      for _, session in ipairs(sessions) do
        table.sort(session.windows, function(a, b)
          return a.index < b.index
        end)
      end
      callback(true, sessions)
    end)
  end)
end

---@param callback fun(ok: boolean, clients: CinderTerminal.Tmux.Client[], error?: string)
function M:list_clients(callback)
  self:run({ "list-clients", "-F", CLIENT_FORMAT }, function(ok, stdout, stderr)
    if not ok then
      callback(false, {}, stderr ~= "" and stderr or stdout)
      return
    end
    callback(true, M.parse_clients(stdout))
  end)
end

---Find the tty of the client owned by `pid`.
---@param pid number
---@param callback fun(tty: string?)
function M:client_tty(pid, callback)
  if not pid or pid <= 0 then
    callback(nil)
    return
  end
  self:list_clients(function(ok, clients)
    if not ok then
      callback(nil)
      return
    end
    for _, client in ipairs(clients) do
      if client.pid == pid then
        callback(client.tty)
        return
      end
    end
    callback(nil)
  end)
end

---Move one client to a session/window without touching other clients.
---@param tty string
---@param session_id string
---@param window_id? string
---@param callback fun(ok: boolean, error: string)
function M:switch_client(tty, session_id, window_id, callback)
  local target = session_id
  if window_id and window_id ~= "" then
    target = session_id .. ":" .. window_id
  end
  self:run({ "switch-client", "-c", tty, "-t", target }, function(ok, stdout, stderr)
    callback(ok, stderr ~= "" and stderr or stdout)
  end)
end

---@param window_id string
---@param callback fun(ok: boolean, error: string)
function M:select_window(window_id, callback)
  self:run({ "select-window", "-t", window_id }, function(ok, stdout, stderr)
    callback(ok, stderr ~= "" and stderr or stdout)
  end)
end

---Command that attaches a fresh client to `session_id`. `TMUX` is cleared so
---the client is a real client of the same server instead of a nested session.
---@param session_id string
---@return string[]
function M:attach_command(session_id)
  local command = { "env", "-u", "TMUX", self.binary }
  if self.socket_path and self.socket_path ~= "" then
    vim.list_extend(command, { "-S", self.socket_path })
  elseif self.socket_name and self.socket_name ~= "" then
    vim.list_extend(command, { "-L", self.socket_name })
  end
  vim.list_extend(command, { "attach-session", "-f", "ignore-size", "-t", session_id })
  return command
end

---@param session_id string
---@param callback fun(ok: boolean, session_id: string, error: string)
function M:new_session(session_id, callback)
  self:run({ "new-session", "-d", "-P", "-F", "#{session_id}", "-s", session_id }, function(ok, stdout, stderr)
    callback(ok, (stdout or ""):gsub("%s+$", ""), stderr ~= "" and stderr or stdout)
  end)
end

---@param session_id string
---@param callback fun(ok: boolean, error: string)
function M:kill_session(session_id, callback)
  self:run({ "kill-session", "-t", session_id }, function(ok, stdout, stderr)
    callback(ok, stderr ~= "" and stderr or stdout)
  end)
end

---@param session_id string
---@param name string
---@param callback fun(ok: boolean, error: string)
function M:rename_session(session_id, name, callback)
  self:run({ "rename-session", "-t", session_id, name }, function(ok, stdout, stderr)
    callback(ok, stderr ~= "" and stderr or stdout)
  end)
end

---@param session_id string
---@param callback fun(ok: boolean, window_id: string, error: string)
function M:new_window(session_id, callback)
  self:run({ "new-window", "-d", "-P", "-F", "#{window_id}", "-t", session_id }, function(ok, stdout, stderr)
    callback(ok, (stdout or ""):gsub("%s+$", ""), stderr ~= "" and stderr or stdout)
  end)
end

---@param window_id string
---@param callback fun(ok: boolean, error: string)
function M:kill_window(window_id, callback)
  self:run({ "kill-window", "-t", window_id }, function(ok, stdout, stderr)
    callback(ok, stderr ~= "" and stderr or stdout)
  end)
end

---@param window_id string
---@param name string
---@param callback fun(ok: boolean, error: string)
function M:rename_window(window_id, name, callback)
  self:run({ "rename-window", "-t", window_id, name }, function(ok, stdout, stderr)
    callback(ok, stderr ~= "" and stderr or stdout)
  end)
end

return M
