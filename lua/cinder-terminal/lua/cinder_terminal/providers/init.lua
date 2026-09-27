---@class CinderTerminal.Node
---@field id string Stable id, provider scoped: `local`, `local:3`, `tmux:$1`, `tmux:@3`.
---@field kind "container"|"terminal"
---@field provider string Provider name.
---@field label string Primary text of the row.
---@field detail? string Secondary, dimmed text of the row.
---@field status? string Machine readable state: `running`, `done`, `exit 1`, `attached`.
---@field mark? string Type letter shown in the containers panel: `T`, `D`, or nil.
---@field active? boolean True for the terminal tmux currently shows.
---@field parent? string Container id of a terminal node.
---@field children? CinderTerminal.Node[] Container children.
---@field locked? string Reason this node refuses to be killed, if any.

---@class CinderTerminal.Provider.Capabilities
---@field create_container boolean
---@field create_terminal boolean
---@field kill_container boolean
---@field kill_terminal boolean
---@field rename_container boolean
---@field rename_terminal boolean
---@field restart_terminal boolean

---Providers implement this interface. `show` receives `(node, cb, opts)`; the
---optional `opts.force` asks for a retry after a failed attach. The optional
---`buffer(node)` reports the buffer the provider would delete for `node`, so
---the UI can release the pane before it disappears. Everything the UI draws is
---data: a provider never knows about panels, keys or hints.
---@class CinderTerminal.Provider
---@field name string
---@field mark? string Type letter shown in the containers panel.
---@field container_id? string The one container a flat provider owns.
---@field capabilities CinderTerminal.Provider.Capabilities
---@field create_labels? { container?: string, terminal?: string } What the
---create menu calls the things this provider makes.
---@field opts table
---@field on_change? fun() Called when the provider's own state changed.
---@field on_buffer? fun(buf: number) Called for every terminal buffer it makes,
---so the workspace can map the pane keys into it.
---@field prepare? fun(self) Called before the workspace's first snapshot:
---providers use it to have something to show (the local shell) instead of
---making the user create the first terminal. Must be cheap and idempotent.
---@field snapshot fun(cb: fun(ok: boolean, containers: CinderTerminal.Node[], error?: string))
---@field show fun(node: CinderTerminal.Node, cb: fun(ok: boolean, buf?: number, error?: string), opts?: { force?: boolean })
---@field buffer? fun(node: CinderTerminal.Node): number?
---@field create_container? fun(cb: fun(ok: boolean, id?: string, error?: string))
---@field create_terminal? fun(container: CinderTerminal.Node, cb: fun(ok: boolean, id?: string, error?: string))
---@field kill? fun(node: CinderTerminal.Node, cb: fun(ok: boolean, error?: string))
---@field rename? fun(node: CinderTerminal.Node, label: string, cb: fun(ok: boolean, error?: string))
---@field restart? fun(node: CinderTerminal.Node, cb: fun(ok: boolean, error?: string))
---@field close? fun()

local M = {}

---@param caps? table
---@return CinderTerminal.Provider.Capabilities
function M.capabilities(caps)
  return vim.tbl_deep_extend("force", {
    create_container = false,
    create_terminal = false,
    kill_container = false,
    kill_terminal = false,
    rename_container = false,
    rename_terminal = false,
    restart_terminal = false,
  }, caps or {})
end

---@param node CinderTerminal.Node
---@param capabilities CinderTerminal.Provider.Capabilities
---@return string[]
function M.actions(node, capabilities)
  local actions = {}
  if node.kind == "container" then
    if capabilities.create_terminal then
      actions[#actions + 1] = "new"
    end
    if capabilities.kill_container then
      actions[#actions + 1] = "kill"
    end
    if capabilities.rename_container then
      actions[#actions + 1] = "rename"
    end
  else
    if capabilities.create_terminal then
      actions[#actions + 1] = "new"
    end
    if capabilities.kill_terminal then
      actions[#actions + 1] = "kill"
    end
    if capabilities.rename_terminal then
      actions[#actions + 1] = "rename"
    end
    if capabilities.restart_terminal then
      actions[#actions + 1] = "restart"
    end
  end
  return actions
end

---Neovim is inconsistent about the third argument of `on_exit`: `jobstart`
---hands over the string `"exit"`, while a job with a pty (and `termopen`) can
---hand over the collected output lines instead. Both shapes have to be
---tolerated: `table.concat` on the string raised an error inside the callback,
---which left Neovim sitting on a `Press ENTER` prompt with the workspace stuck
---on stale data.
---@param event any
---@param limit? number Maximum length of the returned text.
---@return string?
function M.exit_reason(event, limit)
  local lines = {}
  if type(event) == "table" then
    for _, line in ipairs(event) do
      if type(line) == "string" then
        lines[#lines + 1] = line
      end
    end
  elseif type(event) == "string" then
    -- `jobstart` passes the event name instead of output lines, and the name
    -- says nothing about why the job ended.
    if event ~= "exit" then
      lines[1] = event
    end
  end
  local text = table.concat(lines, " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then
    return nil
  end
  limit = limit or 120
  return #text > limit and (text:sub(1, limit) .. "…") or text
end

return M
