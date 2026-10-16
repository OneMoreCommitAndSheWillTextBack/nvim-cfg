---Provider polling: ask every provider for a snapshot, merge the results and
---re-point the selection at whatever the snapshot says is alive.
---@class CinderTerminal.UI
local M = {}

---A provider reports failure through its callback, but it can also raise before
---it ever gets there: `vim.system` throws when tmux cannot be spawned at all,
---and `vim.fs.root`/`jobstart` do the same for a bad path. One provider falling
---over must not wedge the poll, so the throw becomes the same failed result the
---provider would have sent and the chain moves on.
---@param err any
---@return string
local function error_text(err)
  return type(err) == "string" and err or vim.inspect(err)
end

function M:refresh()
  local state = self.state
  if not self:is_open() then
    return
  end
  if state.refreshing then
    state.refresh_queued = true
    return
  end
  state.refreshing = true

  local providers = self.providers
  local index, results = 1, {}
  local function step()
    local provider = providers[index]
    if not provider then
      state.refreshing = false
      if not self:is_open() then
        state.refresh_queued = false
        return
      end
      self:apply_snapshot(results)
      if state.refresh_queued then
        state.refresh_queued = false
        vim.schedule(function()
          self:refresh()
        end)
      end
      return
    end
    index = index + 1
    -- `settled` keeps a provider that both reports and then throws from
    -- advancing the chain twice.
    local settled = false
    local function done(ok, containers, error)
      if settled then
        return
      end
      settled = true
      results[provider.name] = { ok = ok, containers = containers or {}, error = error }
      step()
    end
    local ok, err = pcall(provider.snapshot, provider, done)
    if not ok then
      done(false, {}, error_text(err))
    end
  end
  step()
end

---@param results table<string, { ok: boolean, containers: CinderTerminal.Node[], error?: string }>
function M:apply_snapshot(results)
  local state = self.state
  local containers, errors = {}, {}
  for _, provider in ipairs(self.providers) do
    local result = results[provider.name]
    if result and result.ok then
      vim.list_extend(containers, result.containers)
    elseif result and result.error then
      errors[#errors + 1] = result.error
    end
  end
  state.containers = containers

  if state.pending_container then
    for _, container in ipairs(containers) do
      if container.id == state.pending_container then
        state.selected_container_id = container.id
        state.selected_item_id = nil
        state.memory[container.id] = nil
        state.pending_container = nil
        break
      end
    end
  end
  if state.pending_item then
    for _, container in ipairs(containers) do
      for _, child in ipairs(container.children or {}) do
        if child.id == state.pending_item then
          state.selected_container_id = container.id
          state.selected_item_id = child.id
          state.pending_item = nil
          break
        end
      end
    end
  end
  if state.pending_provider then
    for _, container in ipairs(containers) do
      if container.provider == state.pending_provider then
        state.selected_container_id = container.id
        state.selected_item_id = nil
        state.memory[container.id] = nil
        break
      end
    end
    state.pending_provider = nil
  end

  self:ensure_selection()

  if state.attached_item_id then
    local alive = false
    for _, node in ipairs(state.items) do
      if node.id == state.attached_item_id then
        alive = true
        break
      end
    end
    if not alive then
      -- The pane content died with the terminal: re-attach so the placeholder
      -- replaces it instead of leaving an empty panel behind.
      self:invalidate_terminal()
    end
  end
  self:render()
  if #errors > 0 then
    self:notify(table.concat(errors, "  "), "error")
  end
end

return M
