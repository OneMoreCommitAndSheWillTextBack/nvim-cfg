---@class CinderTerminal.SessionManager
---Terminal session state and process management for cinder-terminal.nvim.
local M = {}
M.__index = M

local api = vim.api
local fn = vim.fn

---@class CinderTerminal.SessionOptions
---@field cwd? string|fun():string Project directory used for new sessions.
---@field root_markers? string[]|false Markers passed to `vim.fs.root`.
---@field shell? string|string[] Shell command used by `termopen`.
---@field on_change? fun() Called after session state changes.
---@field on_buffer? fun(buf: number) Called after a terminal buffer is created.

---@class CinderTerminal.Session
---@field id number
---@field cwd string
---@field buf number
---@field status string
---@field job? number

---@param opts? CinderTerminal.SessionOptions
---@return CinderTerminal.SessionManager
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    opts = opts,
    sessions = {},
    current_id = nil,
    next_id = 1,
  }, M)
end

---@param path? string
---@return string?
function M:normalize(path)
  if not path or path == "" then
    return nil
  end
  local ok, ret = pcall(vim.fs.normalize, path)
  return ok and ret or path
end

---@param path? string
---@return string?
function M:normalize_dir(path)
  if not path or path == "" then
    return nil
  end
  local expanded = fn.expand(path)
  local absolute = fn.fnamemodify(expanded, ":p")
  return self:normalize(absolute)
end

---@return string
function M:root()
  local configured = self.opts.cwd
  if type(configured) == "function" then
    configured = configured()
  end
  if type(configured) == "string" and configured ~= "" then
    return self:normalize(configured) or fn.getcwd()
  end

  -- Keep LazyVim's project-root behavior when the plugin is used there, while
  -- remaining independent from LazyVim in a normal Neovim installation.
  if _G.LazyVim and type(LazyVim.root) == "function" then
    return self:normalize(LazyVim.root()) or fn.getcwd()
  end

  local markers = self.opts.root_markers
  if markers ~= false and vim.fs.root then
    local ok, ret = pcall(vim.fs.root, 0, markers or { ".git" })
    if ok and ret then
      return self:normalize(ret) or fn.getcwd()
    end
  end

  return self:normalize((vim.uv or vim.loop).cwd() or fn.getcwd()) or fn.getcwd()
end

---@return string|string[]
function M:command()
  local shell = self.opts.shell or vim.o.shell
  local snacks = _G.Snacks
  if not snacks then
    local ok, loaded = pcall(require, "snacks")
    snacks = ok and loaded or nil
  end
  local terminal = snacks and snacks.terminal
  if terminal and terminal.parse then
    return terminal.parse(shell)
  end
  return shell
end

---@param text string
---@param width number
---@return string
function M:display_text(text, width)
  if width <= 0 or fn.strdisplaywidth(text) <= width then
    return text
  end
  if width <= 3 then
    return fn.strcharpart(text, 0, width)
  end
  return fn.strcharpart(text, 0, width - 3) .. "..."
end

---@param cwd string
---@return string
function M:title(cwd)
  local label = fn.fnamemodify(cwd, ":~")
  return label == "" and cwd or label
end

---@return CinderTerminal.Session[]
function M:list()
  local list = {}
  local kept = {}
  for _, session in ipairs(self.sessions) do
    if session.buf and api.nvim_buf_is_valid(session.buf) then
      list[#list + 1] = session
      kept[#kept + 1] = session
    elseif self.current_id == session.id then
      self.current_id = nil
    end
  end
  self.sessions = kept
  table.sort(list, function(a, b)
    return a.id < b.id
  end)
  return list
end

---@param session? CinderTerminal.Session
---@return boolean
function M:is_running(session)
  return session ~= nil and session.buf ~= nil and api.nvim_buf_is_valid(session.buf) and session.status == "running"
end

---@param buf? number
---@return CinderTerminal.Session?
function M:find_by_buf(buf)
  if not buf then
    return nil
  end
  for _, session in ipairs(self.sessions) do
    if session.buf == buf then
      return session
    end
  end
end

---@param cwd? string
---@return CinderTerminal.Session?
function M:find_by_cwd(cwd)
  cwd = self:normalize(cwd)
  if not cwd then
    return nil
  end
  for _, session in ipairs(self.sessions) do
    if session.cwd == cwd and self:is_running(session) then
      return session
    end
  end
end

---@param session? CinderTerminal.Session
---@return string?
function M:process_cwd(session)
  if not (session and session.buf and api.nvim_buf_is_valid(session.buf)) then
    return nil
  end

  local job = vim.b[session.buf].terminal_job_id or session.job
  local pid = job and fn.jobpid(job)
  if not pid or pid <= 0 then
    return nil
  end

  local cwd = self:normalize(fn.resolve("/proc/" .. pid .. "/cwd"))
  if cwd and fn.isdirectory(cwd) == 1 then
    return cwd
  end
end

---@param session? CinderTerminal.Session
function M:set_current(session)
  self.current_id = session and session.id or nil
end

---@return CinderTerminal.Session?
function M:current()
  if self.current_id then
    for _, session in ipairs(self.sessions) do
      if session.id == self.current_id and session.buf and api.nvim_buf_is_valid(session.buf) then
        return session
      end
    end
  end

  local list = self:list()
  for _, session in ipairs(list) do
    if self:is_running(session) then
      return session
    end
  end
  return list[1]
end

---@param callback? fun()
function M:_changed(callback)
  if callback then
    callback()
  elseif self.opts.on_change then
    self.opts.on_change()
  end
end

---@param cwd? string
---@return CinderTerminal.Session
function M:create(cwd)
  cwd = self:normalize(cwd) or self:root()

  local buf = api.nvim_create_buf(false, true)
  local session = {
    id = self.next_id,
    cwd = cwd,
    buf = buf,
    status = "running",
    job = nil,
  }
  self.next_id = self.next_id + 1
  self.sessions[#self.sessions + 1] = session

  vim.b[buf].cinder_terminal_session_id = session.id
  vim.b[buf].cinder_terminal_cwd = cwd
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].buflisted = false
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "terminal"

  if self.opts.on_buffer then
    self.opts.on_buffer(buf)
  end

  api.nvim_buf_call(buf, function()
    session.job = fn.termopen(self:command(), {
      cwd = cwd,
      on_exit = function(_, code)
        local status = tonumber(code) or 0
        session.status = status == 0 and "done" or ("exit " .. status)
        self:_changed()
      end,
    })
  end)

  if not session.job or session.job <= 0 then
    session.status = "failed"
  end

  self:_changed()
  return session
end

---@param session CinderTerminal.Session
function M:remove(session)
  for i, item in ipairs(self.sessions) do
    if item == session then
      table.remove(self.sessions, i)
      break
    end
  end
  if self.current_id == session.id then
    self.current_id = nil
  end
  self:_changed()
end

---@return CinderTerminal.Session
function M:current_or_create()
  return self:current() or self:create(self:root())
end

return M
