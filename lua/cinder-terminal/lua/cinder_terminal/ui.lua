---@class CinderTerminal.UI
---Lazygit style workspace drawn as cinder-ui cards: a containers card over an
---items card in the sidebar column, a terminal card on the right and a
---one-row hint card under both. The terminal card is only chrome: a real
---terminal window covers its content area, so the job keeps the native keys.
local layout = require("cinder_terminal.layout")
local interaction = require("cinder_terminal.interaction")
local ui = require("cinder_ui")

local M = {}
M.__index = M

local api = vim.api

---How long a second `<Esc>` may take to count as `<Esc><Esc>` in the pane.
---Only the gesture uses it: the first `<Esc>` is already on its way to the job
---when the window starts, so a lone one never waits.
local ESCAPE_WINDOW_MS = 300
local fn = vim.fn

local SIDEBAR_PANELS = { "containers", "items" }
local ATTACH_DEBOUNCE = 60

---The cell a card spends on each side; card content widths subtract it.
local CARD_BORDER = 2

local function valid_win(win)
  return win ~= nil and api.nvim_win_is_valid(win)
end

local function valid_buf(buf)
  return buf ~= nil and api.nvim_buf_is_valid(buf)
end

---@param filetype string
---@param bufhidden? string Defaults to `wipe`; the terminal placeholder needs
---`hide`, otherwise it dies as soon as the pane leaves it and can no longer be
---restored.
---@return number
local function scratch(filetype, bufhidden)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = bufhidden or "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = filetype
  return buf
end

---@param buf number
---@param lines string[]
local function set_lines(buf, lines)
  if not valid_buf(buf) then
    return
  end
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, #lines > 0 and lines or { "" })
  vim.bo[buf].modifiable = false
end

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

---@param text string
---@param width number
---@return string
local function display_text(text, width)
  text = tostring(text or "")
  if width <= 0 or fn.strdisplaywidth(text) <= width then
    return text
  end
  if width <= 3 then
    return fn.strcharpart(text, 0, width)
  end
  return fn.strcharpart(text, 0, width - 3) .. "..."
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

---@param node CinderTerminal.Node
---@param highlights CinderTerminal.HighlightGroups
---@return string
local function detail_group(node, highlights)
  local status = node.status or ""
  if status == "" or status == "running" or status == "active" or status == "attached" then
    return highlights.detail
  end
  return highlights.error
end

---@param opts table
---@return CinderTerminal.UI
function M.new(opts)
  local self = setmetatable({
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
      layout = nil,
      rendering = false,
      refreshing = false,
      refresh_queued = false,
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
  }, M)
  return self
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

-- Lifecycle ----------------------------------------------------------------

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
    min_items = 4,
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

---@return string
function M:containers_title()
  return "Containers"
end

---@return string
function M:items_title()
  local container = self:selected_container()
  return (container and container.label) or "Terminals"
end

---@return string
function M:terminal_title()
  local state = self.state
  local label = state.terminal_title ~= "" and state.terminal_title or "Terminal"
  local marker = self:pane_normal_mode() and "  ·  normal" or ""
  -- The card spends one cell per border and two more before the title, so a
  -- long terminal name must be cut here: otherwise the marker is clipped away
  -- and the pane silently stops saying which mode it is in.
  local budget = (state.layout and state.layout.terminal_width or 60) - 4
  return display_text(label, math.max(1, budget - #marker)) .. marker
end

---The terminal card is chrome: keep the real terminal window exactly on its
---content area, so the card border and title stay visible around the job.
function M:sync_terminal_window()
  local state = self.state
  local win = state.win.terminal
  if not valid_win(win) or not state.app then
    return
  end
  local placement = state.app:placement("terminal")
  local inner = placement and placement.inner
  if not inner or inner.width < 1 or inner.height < 1 then
    return
  end
  pcall(api.nvim_win_set_config, win, {
    relative = "win",
    win = state.win.app,
    row = inner.row - 1,
    col = inner.col - 1,
    width = inner.width,
    height = inner.height,
    style = "minimal",
    border = "none",
    zindex = 45,
  })
end

function M:create_windows()
  local state = self.state
  local d = self:dimensions()
  state.layout = d

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
  state.layout = d
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
        self:refresh(false)
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
  self:refresh(true)
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
  state.layout = nil
end

function M:toggle()
  if self:is_open() then
    self:close()
  else
    self:open()
  end
end

-- Selection ----------------------------------------------------------------

---@return CinderTerminal.Node?
function M:selected_container()
  for _, container in ipairs(self.state.containers) do
    if container.id == self.state.selected_container_id then
      return container
    end
  end
end

---@return CinderTerminal.Node?
function M:selected_item()
  for _, item in ipairs(self.state.items) do
    if item.id == self.state.selected_item_id then
      return item
    end
  end
end

---Select the first container owned by `name`, waiting for the next snapshot
---when the provider has not reported its data yet.
---@param name string
function M:select_provider(name)
  for _, container in ipairs(self.state.containers) do
    if container.provider == name then
      self:select_container(container.id)
      return true
    end
  end
  self.state.pending_provider = name
  self:refresh(true)
  return false
end

---@param id string
---@param opts? { focus?: boolean }
function M:select_container(id, opts)
  opts = opts or {}
  local state = self.state
  if state.selected_container_id == id and self:selected_container() then
    return
  end
  state.selected_container_id = id
  state.items = {}
  state.selected_item_id = nil

  local container = self:selected_container()
  if container then
    state.items = container.children or {}
    local remembered = state.memory[id]
    local preferred
    for _, item in ipairs(state.items) do
      if item.id == remembered or item.active then
        preferred = item.id
        break
      end
    end
    state.selected_item_id = preferred or (state.items[1] and state.items[1].id or nil)
    if state.selected_item_id then
      state.memory[id] = state.selected_item_id
    end
  end

  self:render()
  if opts.focus then
    self:set_focus("items")
  end
end

---@param id string
---@param opts? { attach?: boolean }
function M:select_item(id, opts)
  opts = opts or {}
  local state = self.state
  if state.selected_item_id == id then
    return
  end
  state.selected_item_id = id
  if state.selected_container_id then
    state.memory[state.selected_container_id] = id
  end
  self:render()
  if opts.attach ~= false then
    self:schedule_attach()
  end
end

function M:ensure_selection()
  local state = self.state
  if not self:selected_container() then
    local first = state.containers[1]
    state.selected_container_id = first and first.id or nil
    state.items = first and first.children or {}
    state.selected_item_id = nil
  else
    local container = self:selected_container()
    state.items = container.children or {}
  end

  if state.selected_item_id and not self:selected_item() then
    state.selected_item_id = nil
  end

  if not state.selected_item_id then
    local remembered = state.memory[state.selected_container_id]
    local preferred
    for _, item in ipairs(state.items) do
      if item.id == remembered or item.active then
        preferred = item.id
        break
      end
    end
    state.selected_item_id = preferred or (state.items[1] and state.items[1].id or nil)
  end

  -- While the terminal has focus tmux is the source of truth for which window
  -- is on screen, so the item selection follows the active window.
  if state.focus == "terminal" then
    for _, item in ipairs(state.items) do
      if item.active then
        state.selected_item_id = item.id
        break
      end
    end
  end

  if state.selected_item_id then
    state.memory[state.selected_container_id] = state.selected_item_id
  end
end

-- Rendering ----------------------------------------------------------------

---Index of the selected row in one of the two lists.
---@param kind string
---@return number?
function M:selected_index(kind)
  local state = self.state
  local list = kind == "containers" and state.containers or state.items
  local id = kind == "containers" and state.selected_container_id or state.selected_item_id
  for index, node in ipairs(list) do
    if node.id == id then
      return index
    end
  end
end

---Visible rows of one card: its height minus the two border rows.
---@param kind string
---@return number
function M:view_height(kind)
  local d = self.state.layout or self:dimensions()
  if kind == "containers" then
    return math.max(1, d.container_rows - CARD_BORDER)
  end
  return math.max(1, d.items_rows - CARD_BORDER)
end

---Keep the selected row inside the card window. The selection lives in the
---card data, not in the buffer cursor, so the window is data too.
function M:sync_scroll()
  local state = self.state
  for _, kind in ipairs(SIDEBAR_PANELS) do
    local list = kind == "containers" and state.containers or state.items
    local cursor = self:selected_index(kind)
    if cursor then
      state.scroll[kind] = ui.ensure_visible(cursor, state.scroll[kind], self:view_height(kind), #list)
    else
      state.scroll[kind] = 0
    end
  end
end

---Text budget of a row: the card content minus the mark/digit column and the
---two spaces that separate it from the label.
---@return number
function M:row_text_width()
  local d = self.state.layout
  local inner = math.max(8, (d and d.sidebar_width or 30) - CARD_BORDER)
  return inner - 4
end

---@return table[]
function M:containers_rows()
  local state = self.state
  local hl = self:highlights()
  local width = self:row_text_width()
  local rows = {}
  for _, node in ipairs(state.containers) do
    rows[#rows + 1] = {
      segments = {
        { text = node.mark and (node.mark .. " ") or "  ", hl = node.mark and hl.mark or nil },
        { text = display_text(node.label, width) },
        { text = node.detail and ("  " .. node.detail) or "", hl = hl.detail },
      },
    }
  end
  return rows
end

---The digit is part of the list, not of the hint row: it says which key
---reaches this terminal, and only the ten a digit can address wear one.
---@return table[]
function M:items_rows()
  local state = self.state
  local hl = self:highlights()
  local width = self:row_text_width()
  local rows = {}
  for index, node in ipairs(state.items) do
    local digit = index <= 10 and ((index % 10) .. " ") or "  "
    rows[#rows + 1] = {
      segments = {
        { text = digit, hl = hl.detail },
        { text = display_text(node.label, width) },
        { text = node.detail and ("  " .. node.detail) or "", hl = detail_group(node, hl) },
      },
    }
  end
  return rows
end

---@return string
function M:items_empty()
  local provider = self:provider(self:selected_container())
  if provider and provider.capabilities.create_terminal then
    return "  n  new terminal"
  end
  return "  empty"
end

---@return table
function M:containers_data()
  return {
    items = self:containers_rows(),
    cursor = self:selected_index("containers") or 0,
    top = self.state.scroll.containers,
    empty = "  no containers",
  }
end

---@return table
function M:items_data()
  return {
    items = self:items_rows(),
    cursor = self:selected_index("items") or 0,
    top = self.state.scroll.items,
    empty = self:items_empty(),
  }
end

---The hint row, straight out of `interaction`; a pending message wins.
---@return { text: string, hl: string }[]
function M:hint_line()
  local state = self.state
  local hl = self:highlights()
  local width = math.max(8, (state.layout and state.layout.inner_width or 80) - 1)
  if state.message then
    return { { text = " " .. display_text(state.message, width), hl = hl.error } }
  end
  local parts = {}
  for _, entry in ipairs(self:context_keys()) do
    parts[#parts + 1] = "[" .. entry.key .. "] " .. entry.desc
  end
  return { { text = display_text(" " .. table.concat(parts, "  ") .. " ", width), hl = hl.help } }
end

---The card tree of the workspace: the sidebar column (containers over items),
---the terminal card whose content area the real terminal window covers, and
---the hint card under both.
---@return table
function M:build_tree()
  local state = self.state
  local d = state.layout
  return ui.card({
    layout = "column",
    children = {
      ui.card({
        border = false,
        layout = "row",
        height = ui.flex(1),
        children = {
          ui.card({
            border = false,
            layout = "column",
            width = d.sidebar_width,
            children = {
              ui.card({
                id = "containers",
                title = self:containers_title(),
                height = d.container_rows,
                body = ui.list({
                  get = function()
                    return self:containers_data()
                  end,
                }),
              }),
              ui.card({
                id = "items",
                title = self:items_title(),
                height = ui.flex(1, { min = 4 }),
                body = ui.list({
                  get = function()
                    return self:items_data()
                  end,
                }),
              }),
            },
          }),
          ui.card({
            id = "terminal",
            title = self:terminal_title(),
            width = ui.flex(1, { min = 25 }),
            body = ui.text({
              get = function()
                return {}
              end,
            }),
          }),
        },
      }),
      ui.card({
        border = false,
        height = 1,
        body = ui.text({
          get = function()
            return { self:hint_line() }
          end,
        }),
      }),
    },
  })
end

function M:render()
  if not self:is_open() then
    return
  end
  local state = self.state
  state.layout = self:dimensions()
  self:sync_scroll()
  state.app.focused_id = state.focus
  state.app:open(self:build_tree())
  self:sync_terminal_window()
  self:render_terminal()
end

---Where the keyboard is right now, for `interaction`. An explicit `kind`
---asks for one surface regardless of the focus, which is how the `?` popup
---lists every context at once.
---@param kind? "containers"|"items"|"pane"|"typing"
---@return CinderTerminal.Interaction.Context
function M:interaction_context(kind)
  local state = self.state
  local function sidebar(panel)
    local node = panel == "containers" and self:selected_container() or self:selected_item()
    local provider = self:provider(node or self:selected_container())
    return {
      surface = "sidebar",
      panel = panel,
      node = node,
      provider = provider,
      caps = (provider and provider.capabilities) or {},
    }
  end
  local function pane(surface)
    local provider = self:provider(self:selected_item())
    return {
      surface = surface,
      provider = provider,
      caps = (provider and provider.capabilities) or {},
    }
  end
  if kind == "containers" or kind == "items" then
    return sidebar(kind)
  end
  if kind == "pane" or kind == "typing" then
    return pane(kind)
  end
  if state.focus == "terminal" then
    return pane(self:terminal_normal_mode() and "pane" or "typing")
  end
  return sidebar(state.focus == "containers" and "containers" or "items")
end

---@param option string
---@param defaults string[]
---@return string[]
function M:resolve_keys(option, defaults)
  return self:keys_for(option, defaults)
end

---The hint row of the focused panel, straight out of `interaction`.
---@return { key: string, desc: string, keys: string[], native: boolean }[]
function M:context_keys()
  return interaction.hints(self:interaction_context(), function(option, defaults)
    return self:resolve_keys(option, defaults)
  end)
end

---@param text string
---@param level? string
function M:notify(text, level)
  if not text or text == "" then
    return
  end
  self.state.message = text
  self.state.message_level = level
  self:render()
  vim.defer_fn(function()
    if self.state.message == text then
      self.state.message, self.state.message_level = nil, nil
      if self:is_open() then
        self:render()
      end
    end
  end, 5000)
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

-- Terminal pane ------------------------------------------------------------

---Hand the keyboard to the job. Headless Neovim cannot reach Terminal-Job
---mode, so the tests spy on this instead of asserting the mode itself.
function M:enter_terminal_insert()
  pcall(vim.cmd.startinsert)
end

---Leave the job for normal mode, the way Neovim's own `<C-\><C-n>` does.
function M:enter_terminal_normal()
  local keys = api.nvim_replace_termcodes("<C-\\><C-n>", true, false, true)
  pcall(api.nvim_feedkeys, keys, "n", false)
end

---Send raw bytes to the job. The mapping that calls this is buffer-local, so
---the job is the one in the buffer the keys arrived in, not necessarily the
---one on screen in the pane.
---@param text string
function M:send_to_job(text)
  local buf = api.nvim_get_current_buf()
  if vim.bo[buf].buftype ~= "terminal" then
    local win = self.state.win.terminal
    buf = valid_win(win) and api.nvim_win_get_buf(win) or nil
  end
  local channel = buf and vim.bo[buf].channel or nil
  if channel and channel > 0 then
    pcall(api.nvim_chan_send, channel, text)
  end
end

---The `<Esc><Esc>` gesture, implemented through one `<Esc>`.
---
---Bound literally, `<Esc><Esc>` makes Neovim hold every lone `<Esc>` for
---'timeoutlen' before the job receives it, and `<Esc>` is the key a TUI waits
---for. The pane maps a single `<Esc>` instead: it forwards the byte right away
---and only a second press inside `escape_window` leaves the job.
---@see CinderTerminal.Interaction.Translation
function M:terminal_escape()
  local state = self.state
  local now = (vim.uv or vim.loop).now()
  local last = state.escape_at
  if last and now - last <= (self.opts.escape_window or ESCAPE_WINDOW_MS) then
    state.escape_at = nil
    self:enter_terminal_normal()
    return
  end
  state.escape_at = now
  self:send_to_job("\27")
end

---@param buf number
---@param title string
function M:set_terminal_buffer(buf, title)
  local state = self.state
  local win = state.win.terminal
  if not valid_win(win) then
    return
  end
  state.terminal_title = title or ""
  local previous = api.nvim_win_get_buf(win)
  local had_terminal = valid_buf(previous) and vim.bo[previous].buftype == "terminal"
  vim.wo[win].winfixbuf = false
  if valid_buf(buf) and api.nvim_win_get_buf(win) ~= buf then
    pcall(api.nvim_win_set_buf, win, buf)
  end
  vim.wo[win].winfixbuf = true
  -- `show()` is asynchronous, so the pane can receive its first real terminal
  -- after `set_focus` already decided to type into it. Without this the pane
  -- would settle in normal mode and the first keystrokes would be commands
  -- instead of shell input. A pane that already held a terminal keeps the
  -- mode the user left it in.
  if
    not had_terminal
    and state.focus == "terminal"
    and state.terminal_insert
    and valid_buf(buf)
    and vim.bo[buf].buftype == "terminal"
  then
    self:enter_terminal_insert()
  end
  if valid_buf(buf) and not state.mapped_buffers[buf] then
    state.mapped_buffers[buf] = true
    self:map_terminal_buffer(buf)
  end
  self:render()
end

---True while the pane holds a job that Neovim currently drives in normal
---mode, focused or not. The title uses it so the marker does not vanish when
---the cursor moves to a list — that is still the mode the pane comes back in.
---@return boolean
function M:pane_normal_mode()
  local state = self.state
  local win = state.win.terminal
  if not valid_win(win) then
    return false
  end
  local buf = api.nvim_win_get_buf(win)
  return vim.bo[buf].buftype == "terminal" and not state.terminal_insert
end

---True while the focused pane takes keys for the plugin instead of the job,
---which is what the hint row has to follow.
---@return boolean
function M:terminal_normal_mode()
  local state = self.state
  if state.focus ~= "terminal" then
    return false
  end
  local win = state.win.terminal
  if not valid_win(win) then
    return false
  end
  local buf = api.nvim_win_get_buf(win)
  return vim.bo[buf].buftype == "terminal" and api.nvim_get_mode().mode ~= "t"
end

---Force the next render to re-show the selected terminal. Called after the
---embedded tmux client exits.
function M:invalidate_terminal()
  self.state.attached_item_id = nil
  self.state.attach_generation = self.state.attach_generation + 1
  self:schedule_attach()
end

function M:schedule_attach()
  local state = self.state
  if state.attach_timer then
    pcall(state.attach_timer.stop, state.attach_timer)
    pcall(state.attach_timer.close, state.attach_timer)
    state.attach_timer = nil
  end
  local uv = vim.uv or vim.loop
  local timer = uv.new_timer()
  state.attach_timer = timer
  timer:start(
    ATTACH_DEBOUNCE,
    0,
    vim.schedule_wrap(function()
      pcall(timer.stop, timer)
      pcall(timer.close, timer)
      if state.attach_timer == timer then
        state.attach_timer = nil
      end
      if self:is_open() then
        self:attach_selected()
      end
    end)
  )
end

function M:render_terminal()
  local node = self:selected_item()
  local id = node and node.id or nil
  if id == self.state.attached_item_id then
    return
  end
  self:schedule_attach()
end

---Show placeholder text in the terminal pane (no session, attach failure).
---@param lines string[]
function M:show_hint(lines)
  local state = self.state
  local buf = state.buf.hint
  if not valid_buf(buf) then
    buf = scratch("cinder_terminal_terminal", "hide")
    state.buf.hint = buf
    vim.bo[buf].modifiable = true
  end
  self:set_terminal_buffer(buf, "")
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

function M:attach_selected()
  local state = self.state
  local node = self:selected_item()
  local generation = state.attach_generation + 1
  state.attach_generation = generation
  local force = state.attach_force
  state.attach_force = false

  state.attached_item_id = node and node.id or nil
  if not node then
    self:show_hint({ "", "  select a terminal with l" })
    return
  end

  local provider = self:provider(node)
  if not provider then
    return
  end
  provider:show(node, function(ok, buf, error)
    if not self:is_open() or state.attach_generation ~= generation then
      return
    end
    if not ok or not buf then
      if error then
        self:notify(error, "error")
        self:show_hint({ "", "  " .. error })
      end
      return
    end
    local label = node.label
    local container = self:selected_container()
    if container and container.id ~= node.id then
      label = container.label .. " › " .. node.label
    end
    self:set_terminal_buffer(buf, label)
  end, { force = force })
end

-- Refresh ------------------------------------------------------------------

function M:refresh(force)
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
          self:refresh(true)
        end)
      end
      return
    end
    index = index + 1
    provider:snapshot(function(ok, containers, error)
      results[provider.name] = { ok = ok, containers = containers or {}, error = error }
      step()
    end)
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

-- Actions ------------------------------------------------------------------

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
  local state = self.state
  local kind = state.focus == "containers" and "containers" or "items"
  local list = kind == "containers" and state.containers or state.items
  if #list == 0 then
    return
  end
  local current = self:selected_index(kind) or 1
  local target = math.max(1, math.min(#list, current + delta))
  if target == current then
    return
  end
  if kind == "containers" then
    self:select_container(list[target].id)
  else
    self:select_item(list[target].id)
  end
end

---The sidebar motions. The list cursor is card data, so the familiar keys are
---bound instead of inherited: `j`/`k` (with counts), `gg`/`G`, and a half-page
---`<C-d>`/`<C-u>`; the selection bar follows, the window scroll follows it.
---@param key string
function M:action_move(key)
  local state = self.state
  local kind = state.card_focus
  local list = kind == "containers" and state.containers or state.items
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
  if kind == "containers" then
    self:select_container(list[target].id)
  else
    self:select_item(list[target].id)
  end
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
      if error then
        self:notify(error, "error")
      end
      return
    end
    if id then
      state.pending_item = id
    end
    self:refresh(true)
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
      if error then
        self:notify(error, "error")
      end
      return
    end
    if id then
      state.pending_container = id
    end
    self:refresh(true)
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
      if error then
        self:notify(error, "error")
      end
      return
    end
    if state.selected_item_id == node.id then
      state.selected_item_id = nil
    end
    if state.selected_container_id == node.id then
      state.selected_container_id = nil
      state.items = {}
    end
    self:refresh(true)
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
      if not ok and error then
        self:notify(error, "error")
      end
      self:refresh(true)
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
    if not ok and error then
      self:notify(error, "error")
    end
    self:refresh(true)
  end)
end

---User pressed refresh: re-read every provider and force one re-attach, which
---is also how a backed-off tmux client gets retried.
function M:action_refresh()
  self.state.attach_force = true
  self:invalidate_terminal()
  self:refresh(true)
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
  local terminal_rows = interaction.help_rows(self:interaction_context("typing"), resolve)
  vim.list_extend(terminal_rows, interaction.help_rows(self:interaction_context("pane"), resolve))
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
        { string.rep(" ", math.max(2, 14 - #row.key)) },
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
  local width = math.max(46, math.min(content + 4, vim.o.columns - 4))
  local height = #lines + 2
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

  local columns, rows = vim.o.columns, vim.o.lines - vim.o.cmdheight
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(0, math.floor((rows - height) / 2)),
    col = math.max(0, math.floor((columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = self.opts.border,
    title = " Keys ",
    title_pos = "center",
    zindex = 60,
  })
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
    local target = state.focus == "terminal" and state.win.terminal or state.win.app
    if self:is_open() and valid_win(target) then
      api.nvim_set_current_win(target)
    end
  end
  for _, key in ipairs({ "q", "<Esc>", "?" }) do
    vim.keymap.set("n", key, close_help, { buffer = buf, silent = true, nowait = true, desc = "Close help" })
  end
end

-- Keymaps ------------------------------------------------------------------

---@param buf number
---@param mode string
---@param lhs string?
---@param rhs function
---@param desc string
function M:map(buf, mode, lhs, rhs, desc)
  if not lhs then
    return
  end
  vim.keymap.set(mode, lhs, rhs, { buffer = buf, silent = true, nowait = true, desc = desc })
end

function M:map_buffers()
  self:map_sidebar()
  self:map_surface(self.state.buf.hint, "n", interaction.bindings("pane", nil, self:resolver()))
end

---One buffer serves both sidebar cards, so a key is resolved against the
---panel that has the cursor *when it is pressed*: the union of the two panels
---is mapped, and a key only one panel knows is inert in the other.
function M:map_sidebar()
  local buf = self.state.buf.app
  if not valid_buf(buf) then
    return
  end
  local mapped = {}
  for _, panel in ipairs(SIDEBAR_PANELS) do
    for _, binding in ipairs(interaction.bindings("sidebar", panel, self:resolver())) do
      if not mapped[binding.lhs] then
        mapped[binding.lhs] = true
        self:map(buf, "n", binding.lhs, function()
          self:run_sidebar(binding.lhs)
        end, binding.action.summary or binding.action.name)
      end
    end
  end
end

---@param lhs string
function M:run_sidebar(lhs)
  for _, binding in ipairs(interaction.bindings("sidebar", self.state.card_focus, self:resolver())) do
    if binding.lhs == lhs then
      self:invoke(binding)
      return
    end
  end
end

---@param binding CinderTerminal.Interaction.Binding
function M:invoke(binding)
  local action = binding.action
  if binding.run then
    binding.run(self, binding.gesture)
  elseif action.rhs then
    local keys = api.nvim_replace_termcodes(action.rhs, true, false, true)
    pcall(api.nvim_feedkeys, keys, "n", false)
  else
    action.run(self, binding.gesture)
  end
end

---@return fun(option: string, defaults: string[]): string[]
function M:resolver()
  local ui = self
  return function(option, defaults)
    return ui:resolve_keys(option, defaults)
  end
end

---Bind one surface's actions into a buffer. Each binding names the key to
---map (`lhs`) and, when the gesture and the mapping differ, its own handler.
---@param buf number
---@param mode string
---@param bindings CinderTerminal.Interaction.Binding[]
function M:map_surface(buf, mode, bindings)
  for _, binding in ipairs(bindings) do
    local action = binding.action
    if not binding.run and action.rhs then
      -- Keep the key sequence a mapping, the way Neovim's own `<C-\><C-n>`
      -- does: it must not wait for another key and shows up as `rhs`.
      self:map(buf, mode, binding.lhs, action.rhs, action.summary or action.name)
    else
      self:map(buf, mode, binding.lhs, function()
        self:invoke(binding)
      end, action.summary or action.name)
    end
  end
end

---Keys configured for one action. The option takes a single key, a list (a
---pane may want more than one way out of Terminal mode) or `false` to disable
---the action; the fallback applies when nothing is configured.
---@param name string
---@param fallback string|string[]
---@return string[]
function M:keys_for(name, fallback)
  local configured = self.opts.keymaps and self.opts.keymaps[name]
  if configured == nil then
    configured = fallback
  end
  if configured == false then
    return {}
  end
  local list = type(configured) == "table" and configured or { configured }
  local keys = {}
  for _, lhs in ipairs(list) do
    if type(lhs) == "string" and lhs ~= "" then
      keys[#keys + 1] = lhs
    end
  end
  return keys
end

---@param buf number
function M:map_terminal_buffer(buf)
  -- Normal mode of the pane is the same surface as the placeholder buffer, so
  -- `q`, `h` and the pane keys mean the same thing whether or not a job is on
  -- screen. Terminal mode keeps only the escape sequences the registry
  -- declares; Neovim's own `<C-\><C-n>` waits for a second key and reads as
  -- "the key does nothing", so the pane binds each one on its own.
  self:map_surface(buf, "n", interaction.bindings("pane", nil, self:resolver()))
  self:map_surface(buf, "t", interaction.bindings("typing", nil, self:resolver()))
end

return M
