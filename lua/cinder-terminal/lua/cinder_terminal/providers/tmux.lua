---@class CinderTerminal.Provider.Tmux : CinderTerminal.Provider
---tmux sessions and windows backed by a single embedded client.
---
---The sidebar moves this client with `switch-client -c <tty>` instead of
---`select-window`, so browsing from Neovim never moves the current window of
---other clients attached to the same session.
local Tmux = require("cinder_terminal.tmux")
local providers = require("cinder_terminal.providers")

local M = {}
M.__index = M

local api = vim.api
local uv = vim.uv or vim.loop

---A client that dies within this window after starting counts as a failed
---attach; one that lives longer is considered healthy and clears the counter.
local CLIENT_STABLE_MS = 1500
---Failed attaches tolerated before backing off, and how long to wait.
local CLIENT_FAILURE_LIMIT = 3
local CLIENT_RETRY_MS = 2000
local CLIENT_RETRY_MAX_MS = 30000

---Attaching the embedded client to the session Neovim itself runs in makes
---tmux resize that session to the client, which resizes the pane hosting
---Neovim, which resizes the client: the workspace collapses within a few
---redraws. Killing that session or the pane Neovim lives in would take the
---editor down with it, so both are refused.
local HOST_ATTACH_ERROR = "cannot attach: Neovim runs inside this session"
local HOST_KILL_ERROR = "cannot kill: Neovim is running here"

local function running(job)
  if not job then
    return false
  end
  local ok, result = pcall(vim.fn.jobwait, { job }, 0)
  return ok and result[1] == -1
end

---@param buf number
---@return boolean
local function displayed(buf)
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(win) == buf then
      return true
    end
  end
  return false
end

---@param opts? table
---@return CinderTerminal.Provider.Tmux
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    name = "tmux",
    mark = "T",
    -- Shown in the hint row while the embedded client owns the keyboard:
    -- Neovim never maps it, tmux reads it straight from the pty.
    capabilities = providers.capabilities({
      create_container = true,
      create_terminal = true,
      kill_container = true,
      kill_terminal = true,
      rename_container = true,
      rename_terminal = true,
    }),
    create_labels = { container = "tmux session" },
    opts = opts,
    tmux = Tmux.new(opts),
    host_session_id = Tmux.session_from_env(),
    host_pane_id = vim.env.TMUX_PANE,
    sessions = {},
    containers = {},
    terminals = {},
    client = {
      job = nil,
      buf = nil,
      tty = nil,
      session_id = nil,
      window_id = nil,
      generation = 0,
      failures = 0,
      retry_at = 0,
      last_error = nil,
      stale = {},
    },
  }, M)
end

-- Data ---------------------------------------------------------------------

---@param cb fun(ok: boolean, containers: CinderTerminal.Node[], error?: string)
function M:snapshot(cb)
  if vim.fn.executable(self.tmux.binary) ~= 1 then
    -- Without the binary the provider stays silent instead of failing on every
    -- tick, and the create menu stops offering tmux sessions.
    self.capabilities.create_container = false
    self.capabilities.create_terminal = false
    cb(true, {})
    return
  end
  self.capabilities.create_container = true
  self.capabilities.create_terminal = true
  self.tmux:snapshot(function(ok, sessions, error)
    if not ok then
      cb(false, {}, error)
      return
    end
    self.sessions = sessions
    self.containers, self.terminals = {}, {}
    self:sweep_buffers()

    local containers = {}
    for _, session in ipairs(sessions) do
      local session_id = session.id
      local is_host = self:is_host_session(session_id)
      local children = {}
      for _, window in ipairs(session.windows or {}) do
        local node = {
          id = "tmux:" .. window.id,
          kind = "terminal",
          provider = self.name,
          parent = "tmux:" .. session_id,
          label = string.format("%d %s", window.index, window.name),
          detail = window.panes_count > 1 and (window.panes_count .. " panes") or nil,
          status = window.active and "active" or nil,
          active = window.active,
          session_id = session_id,
          window_id = window.id,
          active_pane_id = window.active_pane_id,
          locked = self:is_host_pane(window.active_pane_id) and HOST_KILL_ERROR or nil,
        }
        children[#children + 1] = node
        self.terminals[node.id] = node
      end

      local count = #children
      local node = {
        id = "tmux:" .. session_id,
        kind = "container",
        provider = self.name,
        mark = self.mark,
        label = session.name,
        detail = (count == 1 and "1 window" or (count .. " windows")) .. (is_host and " · current" or ""),
        status = session.attached > 0 and "attached" or nil,
        children = children,
        session_id = session_id,
        attached = session.attached,
        locked = is_host and HOST_KILL_ERROR or nil,
      }
      containers[#containers + 1] = node
      self.containers[node.id] = node
    end
    cb(true, containers)
  end)
end

---@param container CinderTerminal.Node
---@return CinderTerminal.Node?
function M:preferred_child(container)
  local children = container.children or {}
  for _, child in ipairs(children) do
    if child.active then
      return child
    end
  end
  return children[1]
end

---@param session_id? string
---@return boolean
function M:is_host_session(session_id)
  return session_id ~= nil and session_id == self.host_session_id
end

---@param pane_id? string
---@return boolean
function M:is_host_pane(pane_id)
  return pane_id ~= nil and self.host_pane_id ~= nil and pane_id == self.host_pane_id
end

-- Terminal ----------------------------------------------------------------

---@param node CinderTerminal.Node
---@param cb fun(ok: boolean, buf?: number, error?: string)
---@param opts? { force?: boolean } `force` retries after a failed attach.
function M:show(node, cb, opts)
  if opts and opts.force then
    self.client.failures, self.client.retry_at, self.client.last_error = 0, 0, nil
  end
  local session_id, window_id
  if node.kind == "container" then
    local container = self.containers[node.id]
    if not container then
      cb(false, nil, "session no longer exists")
      return
    end
    session_id = container.session_id
    local child = self:preferred_child(container)
    window_id = child and child.window_id or nil
  else
    local terminal = self.terminals[node.id]
    if not terminal then
      cb(false, nil, "window no longer exists")
      return
    end
    session_id, window_id = terminal.session_id, terminal.window_id
  end
  if self:is_host_session(session_id) then
    cb(false, nil, HOST_ATTACH_ERROR)
    return
  end
  self:focus(session_id, window_id, cb)
end

---@param session_id string
---@param window_id? string
---@param cb fun(ok: boolean, buf?: number, error?: string)
function M:focus(session_id, window_id, cb)
  local client = self.client
  if running(client.job) then
    if client.session_id == session_id and (not window_id or client.window_id == window_id) then
      cb(true, client.buf)
      return
    end
    self:client_tty(function(tty)
      if not tty then
        self:restart(session_id, window_id, cb)
        return
      end
      self:switch(tty, session_id, window_id, function(ok, error)
        if ok then
          cb(true, client.buf)
        else
          self:restart(session_id, window_id, cb)
        end
      end)
    end)
    return
  end
  self:restart(session_id, window_id, cb)
end

---@param detail? string
function M:record_failure(detail)
  local client = self.client
  client.failures = (client.failures or 0) + 1
  if detail and detail ~= "" then
    client.last_error = detail
  end
  if client.failures >= CLIENT_FAILURE_LIMIT then
    local delay = math.min(CLIENT_RETRY_MS * 2 ^ (client.failures - CLIENT_FAILURE_LIMIT), CLIENT_RETRY_MAX_MS)
    client.retry_at = uv.now() + delay
  end
end

---Message shown while `attach-session` keeps failing. Repeated attempts stay
---silent: the pane already explains itself.
---@param detail? string
---@return string?
function M:attach_error(detail)
  local client = self.client
  if (client.failures or 0) > CLIENT_FAILURE_LIMIT then
    return nil
  end
  local reason = detail or client.last_error
  local text = "could not start the tmux client"
  if reason and reason ~= "" then
    text = text .. ": " .. reason
  end
  if (client.failures or 0) >= CLIENT_FAILURE_LIMIT then
    text = text .. " (R retries)"
  end
  return text
end

---@param session_id string
---@param window_id? string
---@param cb fun(ok: boolean, buf?: number, error?: string)
function M:restart(session_id, window_id, cb)
  if uv.now() < (self.client.retry_at or 0) then
    cb(false, nil, nil)
    return
  end
  if running(self.client.job) then
    pcall(vim.fn.jobstop, self.client.job)
  end
  local client = self.client
  client.job, client.tty, client.session_id, client.window_id = nil, nil, nil, nil
  client.generation = client.generation + 1
  local generation = client.generation

  local buf = self:ensure_buffer()
  local job, failure
  api.nvim_buf_call(buf, function()
    local ok, result = pcall(vim.fn.termopen, self.tmux:attach_command(session_id), {
      on_exit = function(_, code, event)
        -- `event` is the string "exit" for plain jobs and the collected output
        -- lines for a pty; `exit_reason` accepts either shape.
        local reason = providers.exit_reason(event, 120)
        vim.schedule(function()
          if client.generation ~= generation then
            return
          end
          client.job, client.tty, client.session_id, client.window_id = nil, nil, nil, nil
          if code ~= 0 then
            self:record_failure(reason)
            if self.on_change then
              self.on_change()
            end
          end
        end)
      end,
    })
    if ok then
      job = result
    else
      failure = tostring(result):gsub("^.*Vim:", "")
    end
  end)

  if not job or job <= 0 then
    self:record_failure(failure)
    cb(false, nil, self:attach_error(failure))
    return
  end
  client.job = job
  client.session_id = session_id
  client.buf = buf
  vim.defer_fn(function()
    if client.job == job then
      client.failures, client.retry_at, client.last_error = 0, 0, nil
    end
  end, CLIENT_STABLE_MS)

  local pid = vim.fn.jobpid(job)
  self:lookup_tty(pid, function(tty)
    if client.generation ~= generation then
      return
    end
    client.tty = tty
    if window_id and tty then
      self:switch(tty, session_id, window_id, function()
        cb(true, buf)
      end)
      return
    end
    cb(true, buf)
  end)
end

---@return number
function M:new_client_buffer()
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "cinder_tmux_client"
  return buf
end

---`termopen` refuses a buffer that already went through a terminal job, and a
---dead client leaves `buftype=terminal` plus its scrollback behind, so every
---start gets a clean buffer. The previous one is swept once nothing shows it.
---@return number
function M:ensure_buffer()
  local buf = self.client.buf
  if buf and api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype ~= "terminal" then
    return buf
  end
  if buf and api.nvim_buf_is_valid(buf) then
    self.client.stale[#self.client.stale + 1] = buf
  end
  return self:new_client_buffer()
end

---Release client buffers that no window displays any more.
function M:sweep_buffers()
  local client = self.client
  if #client.stale == 0 then
    return
  end
  local kept = {}
  for _, buf in ipairs(client.stale) do
    if api.nvim_buf_is_valid(buf) and displayed(buf) then
      kept[#kept + 1] = buf
    elseif api.nvim_buf_is_valid(buf) then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
  end
  client.stale = kept
end

---@param pid number
---@param cb fun(tty: string?)
---@param attempt? number
function M:lookup_tty(pid, cb, attempt)
  attempt = attempt or 1
  self.tmux:client_tty(pid, function(tty)
    if tty then
      cb(tty)
      return
    end
    if attempt >= 8 or not api.nvim_buf_is_valid(self.client.buf or -1) then
      cb(nil)
      return
    end
    vim.defer_fn(function()
      self:lookup_tty(pid, cb, attempt + 1)
    end, 50)
  end)
end

---@param cb fun(tty: string?)
function M:client_tty(cb)
  local client = self.client
  if client.tty then
    cb(client.tty)
    return
  end
  self:lookup_tty(vim.fn.jobpid(client.job), cb)
end

---@param tty string
---@param session_id string
---@param window_id? string
---@param cb fun(ok: boolean, error: string)
function M:switch(tty, session_id, window_id, cb)
  if not window_id then
    self.tmux:switch_client(tty, session_id, nil, function(ok, error)
      if ok then
        self.client.session_id, self.client.window_id = session_id, nil
      end
      cb(ok, error)
    end)
    return
  end

  self.tmux:switch_client(tty, session_id, window_id, function(ok, error)
    if ok then
      self.client.session_id, self.client.window_id = session_id, window_id
      cb(true, "")
      return
    end
    -- Fallback for tmux builds that reject `session:window` targets: when the
    -- client already lives in the session, a plain select-window is enough.
    if self.client.session_id == session_id then
      self.tmux:select_window(window_id, function(selected, select_error)
        if selected then
          self.client.window_id = window_id
        end
        cb(selected, select_error)
      end)
      return
    end
    cb(false, error)
  end)
end

-- Actions -----------------------------------------------------------------

---@param cb fun(ok: boolean, id?: string, error?: string)
function M:create_container(cb)
  local list = self.sessions
  local used = {}
  for _, session in ipairs(list) do
    used[session.name] = true
  end
  local base = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
  if base == "" then
    base = "tmux"
  end

  vim.ui.input({ prompt = "tmux session name: ", default = base }, function(value)
    if value == nil then
      cb(false, nil, nil)
      return
    end
    value = value:gsub("%s+$", "")
    if value == "" then
      cb(false, nil, "session name must not be empty")
      return
    end
    if used[value] then
      local index = 2
      while used[value .. "-" .. index] do
        index = index + 1
      end
      value = value .. "-" .. index
    end
    self.tmux:new_session(value, function(ok, session_id, error)
      if not ok then
        cb(false, nil, error)
        return
      end
      cb(true, "tmux:" .. session_id)
    end)
  end)
end

---@param container CinderTerminal.Node
---@param cb fun(ok: boolean, id?: string, error?: string)
function M:create_terminal(container, cb)
  local node = self.containers[container.id]
  local session_id = node and node.session_id or container.session_id
  if not session_id then
    cb(false, nil, "session no longer exists")
    return
  end
  self.tmux:new_window(session_id, function(ok, window_id, error)
    if not ok then
      cb(false, nil, error)
      return
    end
    cb(true, "tmux:" .. window_id)
  end)
end

---@param node CinderTerminal.Node
---@param cb fun(ok: boolean, error?: string)
function M:kill(node, cb)
  if node.kind == "container" then
    local session_id = node.session_id or (self.containers[node.id] or {}).session_id
    if self:is_host_session(session_id) then
      cb(false, HOST_KILL_ERROR)
      return
    end
    self.tmux:kill_session(session_id, function(ok, error)
      cb(ok, ok and nil or error)
    end)
    return
  end
  local terminal = self.terminals[node.id] or {}
  if self:is_host_pane(node.active_pane_id or terminal.active_pane_id) then
    cb(false, HOST_KILL_ERROR)
    return
  end
  self.tmux:kill_window(node.window_id or terminal.window_id, function(ok, error)
    cb(ok, ok and nil or error)
  end)
end

---@param node CinderTerminal.Node
---@param label string
---@param cb fun(ok: boolean, error?: string)
function M:rename(node, label, cb)
  if node.kind == "container" then
    local session_id = node.session_id or (self.containers[node.id] or {}).session_id
    self.tmux:rename_session(session_id, label, function(ok, error)
      cb(ok, ok and nil or error)
    end)
    return
  end
  local window_id = node.window_id or (self.terminals[node.id] or {}).window_id
  self.tmux:rename_window(window_id, label, function(ok, error)
    cb(ok, ok and nil or error)
  end)
end

---Release the embedded client. Called when the plugin is torn down, not when
---the workspace is hidden: hiding keeps the client alive for an instant reopen.
function M:close()
  if running(self.client.job) then
    pcall(vim.fn.jobstop, self.client.job)
  end
  local buf = self.client.buf
  if buf and api.nvim_buf_is_valid(buf) then
    pcall(api.nvim_buf_delete, buf, { force = true })
  end
  self.client = {
    job = nil,
    buf = nil,
    tty = nil,
    session_id = nil,
    window_id = nil,
    generation = self.client.generation + 1,
    failures = 0,
    retry_at = 0,
    last_error = nil,
    stale = {},
  }
end

return M
