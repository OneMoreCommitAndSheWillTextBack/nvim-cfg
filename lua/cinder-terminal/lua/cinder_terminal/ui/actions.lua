---Everything the user asks the workspace to do: create, kill, rename,
---restart, switch, open/close and the `?` help popup.
local interaction = require("cinder_terminal.interaction")
local providers = require("cinder_terminal.providers")
local util = require("cinder_terminal.ui.util")

local api = vim.api
local fn = vim.fn

local scratch = util.scratch
local valid_buf = util.valid_buf
local valid_win = util.valid_win

---Column the `?` popup aligns its descriptions in. Wide enough for the
---longest key label the interaction table can produce.
local HELP_DESC_COLUMN = 14

---@class CinderTerminal.UI
local M = {}

---@param buf number
---@param ns number
---@param group string
---@param row number
---@param col_start number
---@param col_end number
---@param priority number
local function mark(buf, ns, group, row, col_start, col_end, priority)
  if not valid_buf(buf) or not group or col_end <= col_start then
    return
  end
  api.nvim_buf_set_extmark(buf, ns, row, col_start, {
    end_row = row,
    end_col = col_end,
    hl_group = group,
    priority = priority,
  })
end

---@param chunks { [1]: string, [2]?: string }[]
---@return string line
---@return { [1]: string, [2]: number, [3]: number }[] spans
local function compose(chunks)
  local line, spans, pos = "", {}, 0
  for _, chunk in ipairs(chunks) do
    local text, group = chunk[1], chunk[2]
    if text and text ~= "" then
      if group then
        spans[#spans + 1] = { group, pos, pos + #text }
      end
      line = line .. text
      pos = pos + #text
    end
  end
  return line, spans
end

---Keep the terminal pane alive when the buffer it shows is about to be
---deleted: Neovim closes a `winfixbuf` window whose buffer disappears, which
---would take the whole workspace with it.
---@param buf? number
function M:release_buffer(buf)
  local state = self.state
  if not buf or not api.nvim_buf_is_valid(buf) then
    return
  end
  local win = state.win.terminal
  if not valid_win(win) or api.nvim_win_get_buf(win) ~= buf then
    return
  end
  self:show_hint({ "" })
end

---Buffer a provider would delete for `node`, if it owns one at all.
---@param node? CinderTerminal.Node
---@return number?
function M:node_buffer(node)
  if not node then
    return nil
  end
  local provider = self:provider(node)
  if not provider or type(provider.buffer) ~= "function" then
    return nil
  end
  return provider:buffer(node)
end

function M:action_open()
  local state = self.state
  if state.focus == "containers" then
    self:set_focus("items")
    return
  end
  if state.focus == "items" then
    self:set_focus("terminal")
  end
end

---Move the selected row of the focused list by `delta` rows. Shared by the
---`j`/`k`-family keys and by the public `next`/`prev` commands.
---@param delta number
function M:move_selection(delta)
  local kind = self.state.focus == "containers" and "containers" or "items"
  local list = self:sidebar_list(kind)
  if #list == 0 then
    return
  end
  local current = self:selected_index(kind) or 1
  local target = math.max(1, math.min(#list, current + delta))
  if target == current then
    return
  end
  self:select_row(kind, list[target].id)
end

---The sidebar motions. The list cursor is card data, so the familiar keys are
---bound instead of inherited: `j`/`k` (with counts), `gg`/`G`, and a half-page
---`<C-d>`/`<C-u>`; the selection bar follows, the window scroll follows it.
---@param key string
function M:action_move(key)
  local kind = self.state.card_focus
  local list = self:sidebar_list(kind)
  if #list == 0 then
    return
  end
  local count = math.max(1, vim.v.count1)
  local current = self:selected_index(kind) or 1
  local target
  if key == "gg" then
    target = count
  elseif key == "G" then
    target = count > 1 and count or #list
  elseif key == "<C-d>" then
    target = current + math.max(1, math.floor(self:view_height(kind) / 2)) * count
  elseif key == "<C-u>" then
    target = current - math.max(1, math.floor(self:view_height(kind) / 2)) * count
  elseif key == "k" then
    target = current - count
  else
    target = current + count
  end
  target = math.max(1, math.min(#list, target))
  if target == current then
    return
  end
  self:select_row(kind, list[target].id)
end

function M:action_create()
  local state = self.state
  if state.focus == "containers" then
    self:create_menu()
    return
  end
  local container = self:selected_container()
  local provider = self:provider(container)
  if not container or not provider or not provider.capabilities.create_terminal then
    return
  end
  provider:create_terminal(container, function(ok, id, error)
    if not ok then
      -- A dismissed prompt reports nothing and, more importantly, must not
      -- queue a selection for a terminal that was never created.
      if providers.is_silent(error) then
        return
      end
      self:notify_failure(error, "could not create the terminal")
      return
    end
    if id then
      state.pending_item = id
    end
    self:refresh()
  end)
end

function M:create_menu()
  local state = self.state
  local cursor = self:selected_container()
  local entries = {}
  for _, provider in ipairs(self.providers) do
    for _, entry in ipairs(self:menu_entries(provider)) do
      entries[#entries + 1] = entry
    end
  end
  if #entries == 0 then
    return
  end

  local default
  for _, entry in ipairs(entries) do
    if cursor and entry.provider.name == cursor.provider then
      default = entry
      break
    end
  end
  default = default or entries[1]

  if #entries == 1 then
    self:run_menu_entry(default)
    return
  end

  vim.ui.select(entries, {
    prompt = "Create",
    format_item = function(entry)
      return entry.label
    end,
  }, function(choice)
    if choice then
      self:run_menu_entry(choice)
    end
  end)
end

---@param provider CinderTerminal.Provider
---@return table[]
function M:menu_entries(provider)
  local entries = {}
  local labels = provider.create_labels or {}
  if provider.capabilities.create_terminal and labels.terminal then
    entries[#entries + 1] = { label = labels.terminal, kind = "terminal", provider = provider }
  end
  if provider.capabilities.create_container and labels.container then
    entries[#entries + 1] = { label = labels.container, kind = "container", provider = provider }
  end
  return entries
end

---@param entry table
function M:run_menu_entry(entry)
  local state = self.state
  local provider = entry.provider
  local function done(ok, id, error)
    if not ok then
      if providers.is_silent(error) then
        return
      end
      self:notify_failure(
        error,
        entry.kind == "container" and "could not create the container" or "could not create the terminal"
      )
      return
    end
    if id then
      state.pending_container = id
    end
    self:refresh()
  end

  if entry.kind == "container" then
    provider:create_container(done)
    return
  end
  local container = self:selected_container()
  if container and container.provider == provider.name then
    provider:create_terminal(container, done)
    return
  end
  local root = provider.container_id
  provider:create_terminal({ id = root or provider.name, kind = "container", provider = provider.name }, done)
end

function M:action_kill()
  local state = self.state
  local node, provider
  if state.focus == "containers" then
    node = self:selected_container()
    provider = self:provider(node)
    if provider and not provider.capabilities.kill_container then
      self:notify("this container cannot be killed", "error")
      return
    end
  else
    node = self:selected_item()
    provider = self:provider(node or self:selected_container())
    if provider and not provider.capabilities.kill_terminal then
      self:notify("this terminal cannot be killed", "error")
      return
    end
  end
  if not node or not provider then
    return
  end
  if node.locked then
    self:notify(node.locked, "error")
    return
  end

  local prompt = node.kind == "container" and string.format('Kill "%s" and every terminal inside it?', node.label)
    or string.format('Kill "%s"?', node.label)
  if self.opts.confirm ~= false and fn.confirm(prompt, "&Yes\n&No", 2) ~= 1 then
    return
  end

  self:release_buffer(self:node_buffer(node))
  provider:kill(node, function(ok, error)
    if not ok then
      self:notify_failure(error, "could not kill it")
      return
    end
    if state.selected_item_id == node.id then
      state.selected_item_id = nil
    end
    if state.selected_container_id == node.id then
      state.selected_container_id = nil
      state.items = {}
    end
    self:refresh()
  end)
end

function M:action_rename()
  local state = self.state
  local is_container = state.focus == "containers"
  local node = is_container and self:selected_container() or self:selected_item()
  local provider = self:provider(node or self:selected_container())
  if not node or not provider then
    return
  end

  if provider.capabilities.restart_terminal and not provider.capabilities.rename_terminal and not is_container then
    self:restart_node(node, provider)
    return
  end

  local can_rename = is_container and provider.capabilities.rename_container
    or (not is_container and provider.capabilities.rename_terminal)
  if not can_rename then
    self:notify("this entry cannot be renamed", "error")
    return
  end

  vim.ui.input({ prompt = "Rename: ", default = node.label }, function(value)
    if not value or value == "" or value == node.label or not self:is_open() then
      return
    end
    provider:rename(node, value, function(ok, error)
      if not ok then
        self:notify_failure(error, "could not rename it")
      end
      self:refresh()
    end)
  end)
end

---Restart the selected terminal in place. Providers that own a buffer hand a
---fresh one over, so the pane is released first.
---@param node? CinderTerminal.Node
---@param provider? CinderTerminal.Provider
function M:restart_node(node, provider)
  node = node or self:selected_item()
  provider = provider or self:provider(node)
  if not node or not provider or not provider.capabilities.restart_terminal then
    return
  end
  self:release_buffer(self:node_buffer(node))
  provider:restart(node, function(ok, error)
    if not ok then
      self:notify_failure(error, "could not restart it")
    end
    self:refresh()
  end)
end

---User pressed refresh: re-read every provider and force one re-attach, which
---is also how a backed-off tmux client gets retried.
function M:action_refresh()
  self.state.attach_force = true
  self:invalidate_terminal()
  self:refresh()
end

function M:action_close()
  self:close()
end

---Jump to the n-th terminal of the selected container and hand it the
---keyboard: switching windows is what the list is for, and a digit is the
---shortest path from "typing in shell 1" to "typing in shell 3". The digits
---are the ones printed beside the rows, so `0` is the tenth.
---@param key string
function M:action_switch(key)
  local state = self.state
  local index = tonumber(key)
  if not index then
    return
  end
  if index == 0 then
    index = 10
  end
  local node = state.items[index]
  if not node then
    self:notify(("no terminal %d"):format(index))
    return
  end
  self:select_item(node.id)
  self:set_focus("terminal")
end

---Tab: swap the sidebar and the pane.
---
---The containers panel is deliberately not a stop. A terminal is nearly always
---picked from the list of the container that is already selected, so a cycle
---that stopped on the container tree first made every Tab pay for a panel the
---user rarely changes. The tree is still walked directly: `h` goes up to the
---containers, `l` comes back down to the list.
function M:action_cycle()
  if self.state.focus == "terminal" then
    self:set_focus("items")
    return
  end
  self:set_focus("terminal", { insert = true })
end

function M:show_help()
  local hl = self:highlights()
  local resolve = self:resolver()
  -- One row per action, spelled the way the popup spells keys: hint rows may
  -- shorten a list, the popup has room for every key.
  local function keys_of(name, fallback)
    return interaction.keys_label(name, { surface = "sidebar" }, resolve) or fallback
  end
  -- Escape keys first: they are the way out of the mode the pane opens in.
  local terminal_rows = interaction.help_rows_for({
    self:interaction_context("typing"),
    self:interaction_context("pane"),
  }, resolve)
  local sections = {
    { "Containers", interaction.help_rows(self:interaction_context("containers"), resolve) },
    { "Terminals", interaction.help_rows(self:interaction_context("items"), resolve) },
    { "Terminal", terminal_rows },
    {
      "Global",
      {
        { key = keys_of("cycle", "<Tab>"), desc = "swap the sidebar and the terminal" },
        { key = keys_of("hide_global", "<C-/>"), desc = "hide workspace" },
        { key = keys_of("refresh", "R"), desc = "refresh" },
        { key = "?", desc = "close this help" },
      },
    },
  }

  local lines, spans = {}, {}
  for index, section in ipairs(sections) do
    if index > 1 then
      lines[#lines + 1] = ""
      spans[#spans + 1] = {}
    end
    lines[#lines + 1] = "  " .. section[1]
    spans[#spans + 1] = { { hl.title, 2, #("  " .. section[1]) } }
    for _, row in ipairs(section[2]) do
      local line, row_spans = compose({
        { "    " .. row.key },
        { string.rep(" ", math.max(2, HELP_DESC_COLUMN - #row.key)) },
        { row.desc, hl.detail },
      })
      lines[#lines + 1] = line
      spans[#spans + 1] = row_spans
    end
  end

  local content = 0
  for _, line in ipairs(lines) do
    content = math.max(content, fn.strdisplaywidth(line))
  end
  -- The popup is placed against the editor, so the screen is its hard bound the
  -- way the layout treats it: an editor shorter than the key list gets a smaller
  -- float - the buffer keeps every row, so the rest is a scroll away - instead
  -- of one whose last sections sit below the screen edge.
  local columns, rows = vim.o.columns, math.max(2, vim.o.lines - vim.o.cmdheight)
  local width = math.max(1, math.min(math.max(46, content + 4), columns - 4))
  local height = math.max(1, math.min(#lines + 2, rows - 2))
  local buf = scratch("cinder_terminal_help")
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local namespace = api.nvim_create_namespace("CinderTerminal.Help")
  for row, row_spans in ipairs(spans) do
    for _, span in ipairs(row_spans) do
      mark(buf, namespace, span[1], row - 1, span[2], span[3], 10)
    end
  end

  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(0, math.floor((rows - height - 2) / 2)),
    col = math.max(0, math.floor((columns - width - 2) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = self.opts.border,
    title = " Keys ",
    title_pos = "center",
    zindex = 60,
  })
  -- The popup owns a window the workspace has to be able to close: hiding the
  -- workspace with the help open would otherwise strand a float on screen.
  self.state.win.help = win
  vim.wo[win].winhighlight = table.concat({
    "Normal:" .. hl.normal,
    "FloatBorder:" .. hl.border,
    "FloatTitle:" .. hl.title,
  }, ",")
  local function close_help()
    if api.nvim_win_is_valid(win) then
      pcall(api.nvim_win_close, win, true)
    end
    local state = self.state
    if state.win.help == win then
      state.win.help = nil
    end
    local target = state.focus == "terminal" and state.win.terminal or state.win.app
    if self:is_open() and valid_win(target) then
      api.nvim_set_current_win(target)
    end
  end
  for _, key in ipairs({ "q", "<Esc>", "?" }) do
    vim.keymap.set("n", key, close_help, { buffer = buf, silent = true, nowait = true, desc = "Close help" })
  end
end

return M
