---@class CinderTerminal.Provider.Local : CinderTerminal.Provider
---Local pty sessions: one container row that holds every Neovim shell.
local Session = require("cinder_terminal.session")
local providers = require("cinder_terminal.providers")

local M = {}
M.__index = M

local api = vim.api

---@param opts? table
---@return CinderTerminal.Provider.Local
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({
    name = "local",
    mark = nil,
    container_id = "local",
    capabilities = providers.capabilities({
      create_terminal = true,
      kill_terminal = true,
      restart_terminal = true,
    }),
    -- The first open of the workspace gets a shell to type into instead of an
    -- empty list waiting for `n` (`auto_shell = false` asks for the list).
    auto_shell = opts.auto_shell ~= false,
    auto_started = false,
    create_labels = { terminal = "local terminal" },
    opts = opts,
  }, M)

  self.pty = Session.new({
    cwd = opts.cwd,
    root_markers = opts.root_markers,
    shell = opts.shell,
    on_change = function()
      if self.on_change then
        self.on_change()
      end
    end,
    on_buffer = function(buf)
      if self.on_buffer then
        self.on_buffer(buf)
      end
    end,
  })
  return self
end

---@param id string
---@return CinderTerminal.Session?
function M:find(id)
  local session_id = tonumber((tostring(id):match("^local:(%d+)$")))
  if not session_id then
    return nil
  end
  for _, session in ipairs(self.pty:list()) do
    if session.id == session_id then
      return session
    end
  end
end

---@param session CinderTerminal.Session
---@return string
function M:node_id(session)
  return "local:" .. session.id
end

---Reason a freshly created session cannot be typed into, if any. A shell that
---never started stays in the list as a failed row, so nothing may call it a
---success just because `create()` returned.
---@param session? CinderTerminal.Session
---@return string? reason
function M:start_error(session)
  if not session or self.pty:is_running(session) then
    return nil
  end
  return session.error or "could not start shell"
end

---Buffer that `destroy` will delete for this node, if it belongs to a session.
---@param node CinderTerminal.Node
---@return number?
function M:buffer(node)
  local session = node and node.kind == "terminal" and self:find(node.id) or nil
  return session and session.buf or nil
end

---Have something ready for the first snapshot. Called once per open by the
---workspace, and the shell is created at most once per Neovim: killing it is a
---decision the user made, so reopening the workspace does not undo it.
function M:prepare()
  if self.auto_started or not self.auto_shell then
    return
  end
  self.auto_started = true
  if #self.pty:list() == 0 then
    self:create(self.pty:root())
  end
end

---@param cb fun(ok: boolean, containers: CinderTerminal.Node[], error?: string)
function M:snapshot(cb)
  local list = self.pty:list()
  local current = self.pty:current()
  local children = {}
  for _, session in ipairs(list) do
    local running = self.pty:is_running(session)
    children[#children + 1] = {
      id = self:node_id(session),
      kind = "terminal",
      provider = self.name,
      parent = self.container_id,
      label = self.pty:title(session.cwd),
      detail = running and nil or (session.status or "done"),
      status = running and "running" or (session.status or "done"),
      active = session == current,
    }
  end

  local count = #children
  local container = {
    id = self.container_id,
    kind = "container",
    provider = self.name,
    label = "local",
    detail = count == 1 and "1 shell" or (count .. " shells"),
    children = children,
  }
  cb(true, { container })
end

---A session the pane can show: its buffer exists and it is not a shell that
---never started.
---@param session? CinderTerminal.Session
---@return CinderTerminal.Session?
function M:attachable(session)
  if session and api.nvim_buf_is_valid(session.buf) and not self.pty:is_failed(session) then
    return session
  end
end

---@param node CinderTerminal.Node
---@param cb fun(ok: boolean, buf?: number, error?: string)
function M:show(node, cb)
  if node.kind == "container" then
    -- A container whose shells all failed explains itself instead of putting
    -- one of their empty buffers in the pane.
    local list = self.pty:list()
    local session = self:attachable(self.pty:current())
    for _, candidate in ipairs(list) do
      session = session or self:attachable(candidate)
    end
    if session then
      cb(true, session.buf)
      return
    end
    cb(false, nil, list[1] and list[1].error or "no local terminal yet")
    return
  end

  local session = self:find(node.id)
  if not session or not api.nvim_buf_is_valid(session.buf) then
    cb(false, nil, "terminal no longer exists")
    return
  end
  if self.pty:is_failed(session) then
    -- Nothing was ever attached to that buffer: showing it would only put an
    -- empty pane on screen where the reason belongs.
    cb(false, nil, session.error or "the shell did not start")
    return
  end
  self.pty:set_current(session)
  cb(true, session.buf)
end

---@param container CinderTerminal.Node
---@param cb fun(ok: boolean, id?: string, error?: string)
function M:create_terminal(container, cb)
  vim.ui.input({
    prompt = "Terminal cwd: ",
    default = self.pty:root(),
    completion = "dir",
  }, function(value)
    if not value or value == "" then
      -- Dismissing the prompt is not a failure: the caller stays silent about
      -- `SILENT` instead of painting a red banner for a decision the user made.
      cb(false, nil, providers.SILENT)
      return
    end
    local cwd = self.pty:normalize_dir(value)
    if not cwd or vim.fn.isdirectory(cwd) == 0 then
      cb(false, nil, "invalid directory: " .. value)
      return
    end
    local session = self:create(cwd)
    local failure = session and self:start_error(session) or "could not start shell"
    if failure then
      cb(false, nil, failure)
      return
    end
    cb(true, self:node_id(session), nil)
  end)
end

---@param cwd string
---@return CinderTerminal.Session?
function M:create(cwd)
  local session = self.pty:create(cwd)
  if not self.pty:is_running(session) then
    return session
  end
  self.pty:set_current(session)
  return session
end

---@param node CinderTerminal.Node
---@param cb fun(ok: boolean, error?: string)
function M:kill(node, cb)
  local session = self:find(node.id)
  if not session then
    cb(false, "terminal no longer exists")
    return
  end
  self:destroy(session)
  cb(true)
end

---@param node CinderTerminal.Node
---@param cb fun(ok: boolean, error?: string)
function M:restart(node, cb)
  local session = self:find(node.id)
  if not session then
    cb(false, "terminal no longer exists")
    return
  end
  local cwd = session.cwd
  local fresh = self:create(cwd)
  local failure = fresh and self:start_error(fresh)
  if failure then
    -- A restart that could not spawn leaves the session the user was looking
    -- at alone instead of trading a working shell for a failed row.
    if fresh then
      self:destroy(fresh)
    end
    cb(false, failure)
    return
  end
  self:destroy(session)
  cb(true)
end

---@param node CinderTerminal.Node
---@param cb fun(ok: boolean, id?: string, error?: string)
function M:duplicate(node, cb)
  local cwd
  if node and node.kind == "terminal" then
    local session = self:find(node.id)
    cwd = session and (self.pty:process_cwd(session) or session.cwd)
  end
  cwd = cwd or self.pty:root()
  local session = self:create(cwd)
  local failure = session and self:start_error(session) or "could not start shell"
  if failure then
    cb(false, nil, failure)
    return
  end
  cb(true, self:node_id(session), nil)
end

---Release every local session. Called when the plugin is torn down, not when
---the workspace is hidden: hiding keeps the shells alive.
function M:close()
  for _, session in ipairs(self.pty:list()) do
    self:destroy(session)
  end
end

---@param session CinderTerminal.Session
function M:destroy(session)
  if session.buf and api.nvim_buf_is_valid(session.buf) then
    pcall(api.nvim_buf_delete, session.buf, { force = true })
  end
  self.pty:remove(session)
end

return M
