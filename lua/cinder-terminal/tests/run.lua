-- Headless tests: nvim --headless -u NONE -i NONE -l tests/run.lua
local source = debug.getinfo(1, "S").source:sub(2)
local plugin_root = vim.fn.fnamemodify(source, ":p:h:h")
vim.opt.rtp:prepend(plugin_root)
-- The workspace is drawn with the sibling cinder-ui library.
vim.opt.rtp:prepend(vim.fn.fnamemodify(plugin_root, ":h") .. "/cinder-ui")

local api = vim.api

local layout = require("cinder_terminal.layout")
local providers = require("cinder_terminal.providers")
local session = require("cinder_terminal.session")
local tmux = require("cinder_terminal.tmux")

local passed, failed = 0, 0

local function run_case(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    print(string.format("FAIL %s: %s", name, err))
  end
end

local function eq(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", message or "value", vim.inspect(expected), vim.inspect(actual)))
  end
end

local function truthy(value, message)
  if not value then
    error(message or "expected a truthy value")
  end
end

---Content lines of one card, straight out of the app buffer: cinder-ui writes
---one buffer line per canvas row, so a card's inner rectangle is also its
---text rectangle.
---@param workspace table
---@param id string
---@return string[]
local function card_lines(workspace, id)
  local placement = workspace.state.app:placement(id)
  truthy(placement ~= nil, "card " .. id .. " is placed")
  local inner = placement.inner
  local lines = api.nvim_buf_get_lines(workspace.state.buf.app, inner.row - 1, inner.row - 1 + inner.height, false)
  local out = {}
  for index, line in ipairs(lines) do
    out[index] = vim.fn.strcharpart(line, inner.col - 1, inner.width)
  end
  return out
end

-- Layout -------------------------------------------------------------------

run_case("layout tiles the frame into cards", function()
  local d = layout.compute({
    columns = 200,
    lines = 60,
    cmdheight = 1,
    width = 0.9,
    height = 0.86,
    left_ratio = 0.3,
    container_rows = 4,
  })
  eq(d.frame.width, 180, "frame width")
  eq(d.frame.height, 50, "frame height")
  eq(d.sidebar_width + d.terminal_width, d.inner_width, "sidebar and terminal fill the frame")
  eq(d.body_height + 1, d.inner_height, "the hint card owns one row")
  eq(d.container_rows, 6, "four containers plus the two border rows")
  eq(d.items_rows, d.body_height - d.container_rows, "items take the rest of the column")
  eq(d.hint_row, d.inner_height - 1, "hint card is the last inner row")
end)

run_case("layout keeps every card usable in a small window", function()
  local d = layout.compute({
    columns = 60,
    lines = 18,
    cmdheight = 0,
    width = 0.9,
    height = 0.9,
    left_ratio = 0.3,
    container_rows = 12,
  })
  truthy(d.container_rows >= 2, "containers keep at least their border")
  truthy(d.items_rows >= 2, "items keep at least their border")
  truthy(d.sidebar_width >= 24, "sidebar keeps a usable width")
  truthy(d.terminal_width >= 25, "terminal keeps a usable width")
  truthy(d.frame.row >= 0 and d.frame.col >= 0, "frame stays on screen")
  eq(d.sidebar_width + d.terminal_width, d.inner_width, "cards still tile the frame")
end)

-- tmux parsing -------------------------------------------------------------

run_case("tmux parses sessions", function()
  local sessions = tmux.parse_sessions("$1\tdev\t1\t3\n$2\twork\t0\t1\n")
  eq(#sessions, 2, "session count")
  eq(sessions[1].id, "$1", "session id")
  eq(sessions[1].name, "dev", "session name")
  eq(sessions[1].attached, 1, "attached clients")
  eq(sessions[1].windows_count, 3, "window count")
end)

run_case("tmux parses windows", function()
  local windows = tmux.parse_windows("$1\t@3\t2\tnvim\t1\t2\t%9\tvim\t/home/dev\n")
  eq(#windows, 1, "window count")
  eq(windows[1].id, "@3", "window id")
  eq(windows[1].index, 2, "window index")
  eq(windows[1].name, "nvim", "window name")
  eq(windows[1].active, true, "active flag")
  eq(windows[1].panes_count, 2, "pane count")
  eq(windows[1].active_pane_id, "%9", "active pane")
end)

run_case("tmux parses clients and detects a missing server", function()
  local clients = tmux.parse_clients("4242\t/dev/pts/3\tdev\n")
  eq(#clients, 1, "client count")
  eq(clients[1].tty, "/dev/pts/3", "client tty")
  truthy(tmux.is_no_server_error("no server running on /tmp/tmux-1000/default"), "detects missing server")
  truthy(
    tmux.is_no_server_error("error connecting to /tmp/tmux-1000/default (Operation not permitted)"),
    "detects refused socket"
  )
  truthy(not tmux.is_no_server_error("duplicate session: dev"), "keeps real errors")
end)

-- Capabilities -------------------------------------------------------------

run_case("exit reasons survive every shape Neovim passes to on_exit", function()
  eq(providers.exit_reason({ "can't find session: dev" }), "can't find session: dev", "output lines become the reason")
  eq(providers.exit_reason("exit"), nil, "the event name alone is not a reason")
  eq(
    providers.exit_reason("failed to connect to /tmp/tmux.sock"),
    "failed to connect to /tmp/tmux.sock",
    "plain text is kept"
  )
  eq(providers.exit_reason(nil), nil, "no event means no reason")
  eq(providers.exit_reason({ 42, "line" }), "line", "non-string entries are skipped instead of raising")
  local long = string.rep("x", 200)
  local truncated = providers.exit_reason(long, 60)
  truthy(
    truncated:sub(1, 60) == string.rep("x", 60) and truncated:sub(-3) == "…",
    "long reasons keep their head and end in an ellipsis"
  )
end)

run_case("actions follow provider capabilities", function()
  local caps = providers.capabilities({ create_terminal = true, kill_terminal = true })
  eq(table.concat(providers.actions({ kind = "container" }, caps), ","), "new", "containers only create")
  eq(table.concat(providers.actions({ kind = "terminal" }, caps), ","), "new,kill", "terminals create and kill")

  local full = providers.capabilities({
    create_container = true,
    create_terminal = true,
    kill_container = true,
    kill_terminal = true,
    rename_container = true,
    rename_terminal = true,
    restart_terminal = true,
  })
  eq(table.concat(providers.actions({ kind = "container" }, full), ","), "new,kill,rename", "full container actions")
  eq(
    table.concat(providers.actions({ kind = "terminal" }, full), ","),
    "new,kill,rename,restart",
    "full terminal actions"
  )
end)

-- Session manager ----------------------------------------------------------

run_case("local sessions expose cwd and status", function()
  local manager = session.new({ cwd = vim.fn.getcwd(), shell = { vim.o.shell } })
  local created = manager:create(vim.fn.getcwd())
  truthy(created ~= nil, "session created")
  eq(created.cwd, manager:normalize(vim.fn.getcwd()), "cwd normalized")
  eq(manager:is_running(created), true, "shell is running")
  eq(manager:find_by_buf(created.buf), created, "lookup by buffer")
  truthy(manager:title(created.cwd) ~= "", "session label")

  manager:remove(created)
  if api.nvim_buf_is_valid(created.buf) then
    api.nvim_buf_delete(created.buf, { force = true })
  end
end)

-- Workspace integration ----------------------------------------------------

run_case("the session Neovim runs in is marked, unattachable and unkillable", function()
  local Tmux = require("cinder_terminal.tmux")
  local TmuxProvider = require("cinder_terminal.providers.tmux")
  local previous_tmux, previous_pane = vim.env.TMUX, vim.env.TMUX_PANE
  vim.env.TMUX = "/tmp/cinder-host.sock,4242,7"
  vim.env.TMUX_PANE = "%3"
  eq(Tmux.session_from_env(), "$7", "the Tmux adapter reads the host session from TMUX")

  local provider = TmuxProvider.new({})
  eq(provider.host_session_id, "$7", "the provider remembers the host session")
  eq(provider.host_pane_id, "%3", "the provider remembers the pane Neovim lives in")

  local window = {
    session_id = "$7",
    id = "@9",
    index = 1,
    name = "bash",
    active = true,
    panes_count = 1,
    active_pane_id = "%3",
    active_pane_command = "nvim",
    active_pane_path = "/tmp",
  }
  local other = {
    session_id = "$8",
    id = "@10",
    index = 1,
    name = "bash",
    active = true,
    panes_count = 1,
    active_pane_id = "%4",
    active_pane_command = "bash",
    active_pane_path = "/tmp",
  }
  provider.tmux.snapshot = function(_, cb)
    cb(true, {
      { id = "$7", name = "host", attached = 0, windows_count = 1, windows = { window } },
      { id = "$8", name = "other", attached = 0, windows_count = 1, windows = { other } },
    })
  end
  local containers
  provider:snapshot(function(_, list)
    containers = list
  end)
  eq(#containers, 2, "two containers")
  eq(containers[1].detail, "1 window · current", "the host session is labelled")
  truthy(containers[1].locked ~= nil, "the host session refuses to be killed")
  truthy(containers[1].children[1].locked ~= nil, "the pane running Neovim refuses to be killed")
  eq(containers[2].locked, nil, "other sessions stay killable")
  eq(containers[2].children[1].locked, nil, "other windows stay killable")
  eq(containers[1].children[1].active_pane_id, "%3", "window nodes carry their active pane")

  local show_ok, show_error = true, nil
  provider:show(containers[1], function(ok, _, err)
    show_ok, show_error = ok, err
  end)
  eq(show_ok, false, "attaching to the host session is refused")
  truthy((show_error or ""):find("Neovim", 1, true) ~= nil, "the refusal explains itself")

  local kill_ok, kill_error = true, nil
  provider:kill(containers[1], function(ok, err)
    kill_ok, kill_error = ok, err
  end)
  eq(kill_ok, false, "killing the host session is refused")
  truthy((kill_error or ""):find("Neovim", 1, true) ~= nil, "the kill refusal explains itself")

  vim.env.TMUX, vim.env.TMUX_PANE = previous_tmux, previous_pane
end)

run_case("workspace renders containers, items and terminal", function()
  local highlights = require("cinder_terminal.highlights")
  local LocalProvider = require("cinder_terminal.providers.local")
  local UI = require("cinder_terminal.ui")

  highlights.setup()
  local workspace = UI.new({
    width = 0.9,
    height = 0.86,
    left_ratio = 0.3,
    border = "rounded",
    refresh_interval = 0,
    confirm = false,
    keymaps = {},
    groups = highlights.groups,
  })
  local local_provider = LocalProvider.new({ cwd = vim.fn.getcwd(), shell = { vim.o.shell } })
  workspace:set_providers({ local_provider })
  workspace:open()

  truthy(workspace:is_open(), "workspace is open")
  workspace:refresh()
  eq(#workspace.state.containers, 1, "one container")
  eq(workspace.state.containers[1].label, "local", "container label")

  -- The provider prepares a shell, so the first open has something to type
  -- into and lands in the pane instead of the empty list.
  eq(#workspace.state.items, 1, "the local container starts with a shell")
  eq(workspace.state.focus, "terminal", "the pane takes the keyboard")

  local created = local_provider:find(workspace.state.items[1].id)
  truthy(created ~= nil, "local session created")
  eq(workspace.state.items[1].provider, "local", "item provider")
  eq(workspace.state.selected_item_id, "local:" .. created.id, "item selected")

  truthy(
    vim.wait(1000, function()
      return api.nvim_win_get_buf(workspace.state.win.terminal) == created.buf
    end, 20),
    "terminal pane shows the session buffer"
  )

  eq(vim.bo[workspace.state.buf.app].filetype, "cinderui", "the workspace buffer is the cinder-ui canvas")
  local text = table.concat(card_lines(workspace, "containers"), "\n")
  truthy(text:find("local", 1, true) ~= nil, "containers card lists the local container")

  -- The terminal card is chrome: the real pane window sits exactly on its
  -- content area so the job keeps Neovim's native keys.
  local placement = workspace.state.app:placement("terminal")
  local config = api.nvim_win_get_config(workspace.state.win.terminal)
  eq(config.relative, "win", "the pane is anchored to the workspace float")
  eq(config.row, placement.inner.row - 1, "the pane starts on the card content")
  eq(config.col, placement.inner.col - 1, "and at the card's column")
  eq(config.width, placement.inner.width, "the pane is as wide as the card content")
  eq(config.height, placement.inner.height, "the pane is as tall as the card content")

  workspace:close()
  truthy(not workspace:is_open(), "workspace is closed")

  if api.nvim_buf_is_valid(created.buf) then
    api.nvim_buf_delete(created.buf, { force = true })
  end
  local_provider:close()
end)

-- Lifecycle regression tests ----------------------------------------------

---@return table, table workspace, local provider
local function make_workspace()
  local highlights = require("cinder_terminal.highlights")
  local LocalProvider = require("cinder_terminal.providers.local")
  local UI = require("cinder_terminal.ui")

  highlights.setup()
  local workspace = UI.new({
    width = 0.9,
    height = 0.86,
    left_ratio = 0.3,
    border = "rounded",
    refresh_interval = 0,
    confirm = false,
    keymaps = {},
    groups = highlights.groups,
  })
  -- `auto_shell = false` keeps the fixture's list empty: these cases count
  -- the sessions they create themselves, and the default shell has its own
  -- case below.
  local local_provider = LocalProvider.new({
    cwd = vim.fn.getcwd(),
    shell = { vim.o.shell },
    auto_shell = false,
  })
  workspace:set_providers({ local_provider })
  local_provider.on_buffer = function(buf)
    workspace:map_terminal_buffer(buf)
  end
  workspace:open()
  workspace:refresh()
  return workspace, local_provider
end

local function wait_for(timeout, fn)
  return vim.wait(timeout, fn, 20)
end

run_case("the local container starts with a shell", function()
  local highlights = require("cinder_terminal.highlights")
  local LocalProvider = require("cinder_terminal.providers.local")
  local UI = require("cinder_terminal.ui")

  highlights.setup()
  local function workspace_with(provider)
    local workspace = UI.new({
      width = 0.9,
      height = 0.86,
      left_ratio = 0.3,
      border = "rounded",
      refresh_interval = 0,
      confirm = false,
      keymaps = {},
      groups = highlights.groups,
    })
    workspace:set_providers({ provider })
    return workspace
  end

  local provider = LocalProvider.new({ cwd = vim.fn.getcwd(), shell = { vim.o.shell } })
  local workspace = workspace_with(provider)
  workspace:open()
  eq(#workspace.state.items, 1, "the first open already has a shell")
  eq(workspace.state.focus, "terminal", "and the shell takes the keyboard")
  truthy(
    wait_for(1000, function()
      local session = provider:find(workspace.state.items[1].id)
      return session and api.nvim_win_get_buf(workspace.state.win.terminal) == session.buf
    end),
    "the pane shows the prepared shell, not the placeholder"
  )

  -- Killing the shell is a decision the user made; reopening the workspace
  -- does not undo it.
  workspace:set_focus("items")
  workspace:action_kill()
  truthy(
    wait_for(1500, function()
      return #workspace.state.items == 0
    end),
    "the shell is gone"
  )
  workspace:close()
  workspace:open()
  eq(#workspace.state.items, 0, "reopening does not resurrect a killed shell")
  workspace:close()

  -- `auto_shell = false` asks for the plain empty list the plugin had before.
  local bare = LocalProvider.new({
    cwd = vim.fn.getcwd(),
    shell = { vim.o.shell },
    auto_shell = false,
  })
  local bare_workspace = workspace_with(bare)
  bare_workspace:open()
  eq(#bare_workspace.state.items, 0, "auto_shell = false keeps the list empty")
  eq(bare_workspace.state.focus, "items", "and lands where `n` makes the first terminal")
  bare_workspace:close()
  bare:close()
end)

run_case("killing the displayed terminal keeps the workspace open", function()
  local workspace, local_provider = make_workspace()
  local first = local_provider:create(vim.fn.getcwd())
  local second = local_provider:create(vim.fn.getcwd())
  workspace:refresh()
  eq(#workspace.state.items, 2, "two local terminals")

  workspace:select_item("local:" .. first.id)
  workspace:set_focus("terminal")
  truthy(
    wait_for(1000, function()
      return api.nvim_win_get_buf(workspace.state.win.terminal) == first.buf
    end),
    "pane shows the first session"
  )

  workspace:set_focus("items")
  workspace:select_item("local:" .. first.id)
  workspace:action_kill()
  truthy(
    wait_for(1500, function()
      return #workspace.state.items == 1
    end),
    "killed session disappears from the sidebar"
  )
  truthy(workspace:is_open(), "workspace stays open after deleting the displayed buffer")
  truthy(
    wait_for(1000, function()
      return api.nvim_win_get_buf(workspace.state.win.terminal) == second.buf
    end),
    "pane falls back to the surviving session"
  )

  workspace:select_item("local:" .. second.id)
  workspace:action_kill()
  truthy(
    wait_for(1500, function()
      return #workspace.state.items == 0
    end),
    "last session removed"
  )
  truthy(workspace:is_open(), "workspace survives killing its last terminal")
  truthy(
    wait_for(1500, function()
      if api.nvim_win_get_buf(workspace.state.win.terminal) ~= workspace.state.buf.hint then
        return false
      end
      local hint = table.concat(api.nvim_buf_get_lines(workspace.state.buf.hint, 0, -1, false), "\n")
      return hint:find("select a terminal", 1, true) ~= nil
    end),
    "pane shows the placeholder text"
  )

  workspace:close()
  local_provider:close()
end)

run_case("restarting the displayed terminal keeps the workspace open", function()
  local workspace, local_provider = make_workspace()
  local created = local_provider:create(vim.fn.getcwd())
  workspace:refresh()
  workspace:select_item("local:" .. created.id)

  workspace:set_focus("terminal")
  truthy(
    wait_for(1000, function()
      return api.nvim_win_get_buf(workspace.state.win.terminal) == created.buf
    end),
    "pane shows the session"
  )

  workspace:set_focus("items")
  workspace:restart_node(workspace:selected_item())
  truthy(
    wait_for(1500, function()
      return workspace.state.attach_generation > 0 and #workspace.state.items == 1
    end),
    "restart keeps a single session"
  )
  truthy(workspace:is_open(), "workspace stays open after restarting the displayed buffer")
  local replacement = workspace.state.items[1]
  truthy(replacement.id ~= "local:" .. created.id, "restart created a fresh session")
  truthy(
    wait_for(1000, function()
      return api.nvim_win_get_buf(workspace.state.win.terminal) == local_provider:find(replacement.id).buf
    end),
    "pane shows the restarted session"
  )

  workspace:close()
  local_provider:close()
end)

run_case("closing a workspace window hides the workspace", function()
  local workspace, local_provider = make_workspace()
  api.nvim_win_close(workspace.state.win.app, true)
  truthy(
    wait_for(1000, function()
      return workspace.state.opened == false
    end),
    "workspace hid itself"
  )
  eq(workspace:is_open(), false, "workspace is closed")
  eq(#api.nvim_list_wins() >= 1, true, "neovim still has a window")

  workspace:open()
  truthy(workspace:is_open(), "workspace reopens after the self-heal")
  workspace:close()
  local_provider:close()
end)

run_case("a tmux client buffer is never reused for a new job", function()
  local TmuxProvider = require("cinder_terminal.providers.tmux")
  local provider = TmuxProvider.new({})

  local scratch = provider:ensure_buffer()
  truthy(api.nvim_buf_is_valid(scratch) and vim.bo[scratch].buftype ~= "terminal", "first buffer is plain")

  local terminal_buf = api.nvim_create_buf(false, true)
  api.nvim_buf_call(terminal_buf, function()
    vim.fn.termopen({ vim.o.shell, "-c", "exit 0" })
  end)
  truthy(
    wait_for(2000, function()
      return vim.bo[terminal_buf].buftype == "terminal"
    end),
    "buffer turned into a terminal buffer"
  )

  provider.client.buf = terminal_buf
  local fresh = provider:ensure_buffer()
  truthy(fresh ~= terminal_buf, "a terminal buffer is not reused")
  eq(#provider.client.stale, 1, "the dead buffer is queued for the sweep")

  provider:sweep_buffers()
  eq(api.nvim_buf_is_valid(terminal_buf), false, "sweep removes the undisplayed dead buffer")
  eq(#provider.client.stale, 0, "sweep clears its queue")

  if api.nvim_buf_is_valid(scratch) then
    api.nvim_buf_delete(scratch, { force = true })
  end
  if api.nvim_buf_is_valid(fresh) then
    api.nvim_buf_delete(fresh, { force = true })
  end
end)

run_case("the focused card carries the focus border", function()
  local workspace, local_provider = make_workspace()

  ---Highlight of a card's top-left corner, read from the canvas extmarks.
  ---@param id string
  ---@return string?
  local function border_hl(id)
    local placement = workspace.state.app:placement(id)
    local row, col = placement.rect.row - 1, placement.rect.col - 1
    for _, extmark in
      ipairs(api.nvim_buf_get_extmarks(workspace.state.buf.app, workspace.state.app.ns, { row, col }, { row, col }, {
        details = true,
      }))
    do
      for _, span in ipairs(extmark[4].virt_text or {}) do
        if span[2] then
          return span[2]
        end
      end
    end
  end

  workspace:set_focus("containers")
  eq(border_hl("containers"), "CinderUiBorderFocus", "the focused card border glows")
  eq(border_hl("items"), "CinderUiBorder", "the unfocused card keeps the plain border")

  workspace:set_focus("items")
  eq(border_hl("items"), "CinderUiBorderFocus", "focus moved to the items card")
  eq(border_hl("containers"), "CinderUiBorder", "and left the containers card")

  workspace:close()
  local_provider:close()
end)

run_case("tmux adopts the socket of the surrounding server", function()
  local Tmux = require("cinder_terminal.tmux")
  local previous = vim.env.TMUX
  vim.env.TMUX = "/tmp/cinder-test-socket,4242,0"
  eq(Tmux.socket_from_env(), "/tmp/cinder-test-socket", "socket parsed from TMUX")
  eq(Tmux.new({}).socket_path, "/tmp/cinder-test-socket", "adapter adopts the env socket")
  eq(Tmux.new({ socket_name = "work" }).socket_path, nil, "explicit socket name wins")
  eq(Tmux.new({ socket_path = "/tmp/x" }).socket_path, "/tmp/x", "explicit socket path wins")
  vim.env.TMUX = previous
end)

run_case("the containers card leaves room for its border", function()
  local d = layout.compute({
    columns = 200,
    lines = 60,
    cmdheight = 1,
    width = 0.9,
    height = 0.86,
    left_ratio = 0.3,
    container_rows = 6,
  })
  eq(d.container_rows, 8, "six containers plus the two border rows")
  truthy(d.items_rows - 2 >= 4, "items keep four entries below their border")
end)

---@param id string
---@param label string
---@return CinderTerminal.Node
local function stub_container(id, label)
  return {
    id = id,
    kind = "container",
    provider = "stub",
    label = label,
    detail = "1 window",
    children = {},
  }
end

---@param containers CinderTerminal.Node[]
---@return table
local function stub_provider(containers)
  return {
    name = "stub",
    mark = "S",
    capabilities = providers.capabilities({ create_container = true, create_terminal = true }),
    create_labels = { container = "stub session" },
    snapshot = function(_, cb)
      cb(true, containers)
    end,
    show = function(_, _, cb)
      cb(false, nil, "stub provider has no terminal")
    end,
  }
end

run_case("the containers panel grows and shrinks with the container list", function()
  local highlights = require("cinder_terminal.highlights")
  local UI = require("cinder_terminal.ui")

  highlights.setup()
  local workspace = UI.new({
    width = 0.9,
    height = 0.86,
    left_ratio = 0.3,
    border = "rounded",
    refresh_interval = 0,
    confirm = false,
    keymaps = {},
    groups = highlights.groups,
  })
  local containers = { stub_container("stub:1", "one"), stub_container("stub:2", "two") }
  workspace:set_providers({ stub_provider(containers) })
  workspace:open()
  workspace:refresh()
  eq(#workspace.state.containers, 2, "two containers")
  eq(workspace.state.app:placement("containers").rect.height, 4, "the card shows two containers below its border")

  for i = 3, 8 do
    containers[#containers + 1] = stub_container("stub:" .. i, "c" .. i)
  end
  workspace:refresh()
  eq(#workspace.state.containers, 8, "eight containers")
  eq(
    workspace.state.app:placement("containers").rect.height,
    10,
    "the card grew instead of clipping the new containers"
  )

  containers = { containers[1] }
  workspace:set_providers({ stub_provider(containers) })
  workspace:refresh()
  eq(workspace.state.app:placement("containers").rect.height, 3, "the card shrinks again")

  workspace:close()
end)

---`nvim_buf_get_keymap` reports `<C-\>` as `<C-Bslash>`, so both sides of a
---comparison are reduced to their key code first.
---@param lhs string
---@return string
local function key_code(lhs)
  return api.nvim_replace_termcodes(lhs, true, false, true)
end

---@param buf number
---@return table<string, table> key code -> terminal-mode mapping
local function terminal_normal_maps(buf)
  local maps = {}
  for _, map in ipairs(api.nvim_buf_get_keymap(buf, "t")) do
    if map.desc == "Terminal normal mode" then
      maps[key_code(map.lhs)] = map
    end
  end
  return maps
end

run_case("a terminal pane leaves the job with the configured escape keys", function()
  local workspace, local_provider = make_workspace()
  local first = local_provider:create(vim.fn.getcwd())
  workspace:refresh()

  local maps = terminal_normal_maps(first.buf)
  local instant = maps[key_code("<C-\\>")]
  truthy(instant, "<C-\\> is bound in terminal mode")
  truthy(instant.rhs:upper() == "<C-\\><C-N>", "<C-\\> runs Neovim's normal mode sequence")
  eq(instant.nowait, 1, "<C-\\> does not wait for a longer mapping")

  -- `<Esc><Esc>` is one mapping on `<Esc>`, not two keys: a literal two-key map
  -- would hold every lone `<Esc>` for 'timeoutlen' before the job received it.
  local double = maps[key_code("<Esc>")]
  truthy(double, "the double escape is recognized through a single <Esc>")
  truthy(double.callback ~= nil, "and it decides in Lua instead of waiting for a second key")
  eq(maps[key_code("<Esc><Esc>")], nil, "nothing makes a lone <Esc> wait for a follow-up")
  eq(vim.tbl_count(maps), 2, "both default escape hatches are bound")

  workspace.opts.keymaps = { terminal_normal = "<Esc>" }
  local custom = terminal_normal_maps(local_provider:create(vim.fn.getcwd()).buf)
  truthy(custom[key_code("<Esc>")], "a string configures one key")
  eq(vim.tbl_count(custom), 1, "a string replaces the defaults instead of adding to them")

  workspace.opts.keymaps = { terminal_normal = { "<Esc>", "<C-\\>" } }
  local listed = terminal_normal_maps(local_provider:create(vim.fn.getcwd()).buf)
  truthy(listed[key_code("<Esc>")] and listed[key_code("<C-\\>")], "a list binds every escape in it")
  eq(vim.tbl_count(listed), 2, "a list binds exactly the keys it names")

  workspace.opts.keymaps = { terminal_normal = false }
  local third = local_provider:create(vim.fn.getcwd())
  eq(vim.tbl_count(terminal_normal_maps(third.buf)), 0, "terminal_normal = false keeps Neovim's own sequence")

  workspace:close()
  local_provider:close()
end)

run_case("the double escape sends one Esc and leaves on the second", function()
  local workspace, local_provider = make_workspace()
  local session = local_provider:create(vim.fn.getcwd())
  workspace:refresh()
  workspace:select_item("local:" .. session.id)
  workspace:set_focus("terminal")

  local sent, left = {}, 0
  workspace.send_to_job = function(_, text)
    sent[#sent + 1] = text
  end
  workspace.enter_terminal_normal = function()
    left = left + 1
  end

  workspace:terminal_escape()
  eq(left, 0, "a single Esc stays in the job")
  eq(table.concat(sent), "\27", "and reaches it as the byte it expects")

  workspace:terminal_escape()
  eq(left, 1, "a second press inside the window leaves the job")
  eq(#sent, 1, "the gesture key is not typed into the job")

  -- A press after the window starts the gesture over instead of leaving.
  workspace.state.escape_at = (vim.uv or vim.loop).now() - 5000
  workspace:terminal_escape()
  eq(left, 1, "a second press long after the first is not the gesture")
  eq(#sent, 2, "so it goes to the job like any other Esc")

  workspace:close()
  local_provider:close()
end)

run_case("digits switch terminals from the list", function()
  local UI = require("cinder_terminal.ui")
  local highlights = require("cinder_terminal.highlights")
  highlights.setup()
  local workspace = UI.new({
    width = 0.9,
    height = 0.86,
    left_ratio = 0.3,
    border = "rounded",
    refresh_interval = 0,
    confirm = false,
    keymaps = {},
    groups = highlights.groups,
  })
  local container = stub_container("stub:1", "one")
  for index = 1, 11 do
    container.children[#container.children + 1] = {
      id = "stub:c" .. index,
      kind = "terminal",
      provider = "stub",
      parent = "stub:1",
      label = "shell-" .. index,
    }
  end
  workspace:set_providers({ stub_provider({ container }) })
  workspace:open()
  workspace:refresh()
  workspace:set_focus("items")
  eq(#workspace.state.items, 11, "eleven terminals")

  -- The row wears the digit that reaches it, and only the ten a single digit
  -- can address wear one.
  local rows = card_lines(workspace, "items")
  for index = 1, 10 do
    local want = (index % 10) .. " "
    eq(rows[index]:sub(1, 2), want, "row " .. index .. " wears its digit")
  end
  eq(rows[11]:sub(1, 2), "  ", "the eleventh row wears none")

  workspace:action_switch("3")
  eq(workspace.state.focus, "terminal", "the digit hands the keyboard to the pane")
  eq(workspace:selected_item().id, "stub:c3", "and selects the third terminal")

  workspace:set_focus("items")
  local inner = workspace.state.app:placement("items").inner
  eq(api.nvim_win_get_cursor(workspace.state.win.app)[1], inner.row + 2, "the cursor follows the jump")
  workspace:action_switch("0")
  eq(workspace:selected_item().id, "stub:c10", "0 is the tenth terminal")

  -- The popup has room for all ten digits, so it spells them out.
  workspace:set_focus("items")
  workspace:show_help()
  local help
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if vim.bo[buf].filetype == "cinder_terminal_help" then
      help = buf
    end
  end
  truthy(help, "the popup opened")
  local text = table.concat(api.nvim_buf_get_lines(help, 0, -1, false), "\n")
  truthy(text:find("1-9 / 0", 1, true), "the popup spells out every digit")
  pcall(api.nvim_win_close, api.nvim_get_current_win(), true)

  workspace:set_focus("items")
  workspace.state.message = nil
  workspace.state.items = vim.list_slice(workspace.state.items, 1, 3)
  workspace:action_switch("9")
  eq(workspace.state.focus, "items", "a digit with nothing behind it leaves the focus alone")
  truthy(workspace.state.message ~= nil, "and the workspace explains why")

  workspace:close()
end)

run_case("while typing, <C-b> leaves the job for the list", function()
  local interaction = require("cinder_terminal.interaction")
  local workspace, local_provider = make_workspace()
  local session = local_provider:create(vim.fn.getcwd())
  workspace:refresh()
  truthy(
    wait_for(1000, function()
      return api.nvim_win_get_buf(workspace.state.win.terminal) == session.buf
    end),
    "pane shows the session"
  )

  local bound = {}
  for _, map in ipairs(api.nvim_buf_get_keymap(session.buf, "t")) do
    bound[api.nvim_replace_termcodes(map.lhs, true, false, true)] = true
  end
  truthy(bound[key_code("<C-b>")], "<C-b> is bound in Terminal mode")

  local hinted = {}
  for _, row in ipairs(interaction.hints(workspace:interaction_context("typing"), workspace:resolver())) do
    hinted[row.key] = row.desc
  end
  eq(hinted["C-b"], "items", "the hint row says where it goes")
  for _, desc in pairs(hinted) do
    truthy(desc ~= "tmux prefix", "no provider advertises a prefix any more")
  end

  interaction.by_name("list").run(workspace, "<C-b>")
  eq(workspace.state.focus, "items", "the key lands in the list")

  workspace:close()
  local_provider:close()
end)

run_case("in normal mode, <C-b> also returns to the list", function()
  local interaction = require("cinder_terminal.interaction")
  local workspace, local_provider = make_workspace()
  local session = local_provider:create(vim.fn.getcwd())
  workspace:refresh()
  truthy(
    wait_for(1000, function()
      return api.nvim_win_get_buf(workspace.state.win.terminal) == session.buf
    end),
    "pane shows the session"
  )

  local bound = {}
  for _, map in ipairs(api.nvim_buf_get_keymap(session.buf, "n")) do
    bound[key_code(map.lhs)] = true
  end
  truthy(bound[key_code("<C-b>")], "<C-b> is bound in the pane's normal mode")

  local hinted = {}
  for _, row in ipairs(interaction.hints(workspace:interaction_context("pane"), workspace:resolver())) do
    hinted[row.key] = row.desc
  end
  eq(hinted["C-b"], "items", "the pane hint row says where it goes")

  -- The help popup merges the typing and pane rows, so the key both modes
  -- share must show up exactly once.
  local listed = 0
  for _, row in
    ipairs(interaction.help_rows_for({
      workspace:interaction_context("typing"),
      workspace:interaction_context("pane"),
    }, workspace:resolver()))
  do
    if row.key == "C-b" then
      listed = listed + 1
    end
  end
  eq(listed, 1, "the popup lists the shared key once")

  interaction.by_name("list").run(workspace, "<C-b>")
  eq(workspace.state.focus, "items", "the key lands in the list")

  workspace:close()
  local_provider:close()
end)

run_case("Tab swaps the sidebar and the pane", function()
  local workspace, local_provider = make_workspace()
  local session = local_provider:create(vim.fn.getcwd())
  workspace:refresh()
  workspace:select_item("local:" .. session.id)

  -- The containers panel is deliberately not a stop: reaching the list or the
  -- pane must never cost a hop through the container tree.
  workspace:set_focus("containers")
  workspace:action_cycle()
  eq(workspace.state.focus, "terminal", "a sidebar panel hands the keyboard to the pane")
  workspace:action_cycle()
  eq(workspace.state.focus, "items", "and the pane hands it back to the list, not the tree")

  workspace:set_focus("items")
  workspace:action_cycle()
  eq(workspace.state.focus, "terminal", "the list does the same")
  workspace:action_cycle()
  eq(workspace.state.focus, "items", "and the swap goes both ways")

  for _ = 1, 4 do
    workspace:action_cycle()
    truthy(workspace.state.focus ~= "containers", "Tab never lands on the container tree")
  end

  -- The hint row is too narrow to name both keys, so the popup spells them out.
  workspace:show_help()
  local help
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if vim.bo[buf].filetype == "cinder_terminal_help" then
      help = buf
    end
  end
  truthy(help, "the popup opened")
  local text = table.concat(api.nvim_buf_get_lines(help, 0, -1, false), "\n")
  truthy(text:find("Tab / S-Tab", 1, true), "the popup names both swap keys")
  truthy(text:find("swap the sidebar and the terminal", 1, true), "and says what the swap does")
  pcall(api.nvim_win_close, api.nvim_get_current_win(), true)

  workspace:close()
  local_provider:close()
end)

run_case("normal mode keeps the native keys native", function()
  local interaction = require("cinder_terminal.interaction")
  local workspace, local_provider = make_workspace()
  local session = local_provider:create(vim.fn.getcwd())
  workspace:refresh()

  local bound = {}
  for _, map in ipairs(api.nvim_buf_get_keymap(session.buf, "n")) do
    bound[map.lhs] = true
  end
  -- `v`, `y`, `i` and the operator prefixes are how text is selected, yanked
  -- and edited in normal mode; the pane must not turn them into commands.
  for _, key in ipairs({ "v", "y", "i", "a", "d", "r", "n", "/" }) do
    eq(bound[key], nil, "normal mode leaves " .. key .. " alone")
  end
  truthy(bound["<Tab>"], "Tab is the way back to the list")
  eq(bound["q"], nil, "q stays Neovim's macro key")
  eq(bound["h"], nil, "and h stays a motion")

  -- The old jump to the list is unbound by default, not deleted: a config can
  -- put it back and the hint row will say so.
  workspace.opts.keymaps = { items = "q" }
  local rebound = local_provider:create(vim.fn.getcwd())
  workspace:refresh()
  local keys = {}
  for _, map in ipairs(api.nvim_buf_get_keymap(rebound.buf, "n")) do
    keys[map.lhs] = true
  end
  truthy(keys["q"], "keymaps.items restores the jump to the list")
  local advertised = false
  for _, entry in ipairs(interaction.hints({ surface = "pane", caps = {} }, workspace:resolver())) do
    advertised = advertised or entry.key == "q"
  end
  truthy(advertised, "and the hint row advertises it again")
  workspace.opts.keymaps = {}

  workspace:close()
  local_provider:close()
end)

run_case("the pane types into a terminal that attaches after focus", function()
  local workspace, local_provider = make_workspace()
  local session = local_provider:create(vim.fn.getcwd())
  workspace:refresh()

  -- Headless Neovim cannot hold Terminal-Job mode, so the test counts the
  -- transition instead of reading the mode; a real pty check lives in the
  -- dev notes. The placeholder is on screen here, which is exactly when the
  -- pane used to settle in normal mode and eat the first keystrokes.
  local entered = 0
  workspace.enter_terminal_insert = function()
    entered = entered + 1
  end
  workspace:select_item("local:" .. session.id)
  workspace:set_focus("terminal")
  truthy(
    wait_for(2000, function()
      return api.nvim_win_get_buf(workspace.state.win.terminal) == session.buf
    end),
    "the session buffer reached the pane"
  )
  eq(entered, 1, "the pane switches to the job once the terminal buffer is on screen")

  workspace:close()
  local_provider:close()
end)

---@param buf number
---@param mode string
---@return table<string, boolean> key code -> true
local function bound_keys(buf, mode)
  local bound = {}
  for _, map in ipairs(api.nvim_buf_get_keymap(buf, mode)) do
    bound[key_code(map.lhs)] = true
  end
  return bound
end

run_case("the hint row only names keys that are really bound", function()
  local workspace, local_provider = make_workspace()
  local session = local_provider:create(vim.fn.getcwd())
  workspace:refresh()
  workspace:select_item("local:" .. session.id)
  truthy(
    wait_for(2000, function()
      return api.nvim_win_get_buf(workspace.state.win.terminal) == session.buf
    end),
    "the session buffer reached the pane"
  )

  local interaction = require("cinder_terminal.interaction")

  ---Native hints (`j/k`, `v/y`) name keys the plugin does not own; every other
  ---row must point at a real buffer-local mapping. A gesture and its mapping
  ---may differ (`<Esc><Esc>` is one `<Esc>`), so the check walks the binding
  ---table: every mapping it names has to exist, and every gesture a hint names
  ---has to be in it.
  local function check(where, surface, panel, mode, buf)
    local bound = bound_keys(buf, mode)
    local gestures = {}
    for _, binding in ipairs(interaction.bindings(surface, panel, workspace:resolver())) do
      gestures[binding.gesture] = true
      truthy(bound[key_code(binding.lhs)], where .. " does not bind the mapping for " .. binding.gesture)
    end
    for _, entry in ipairs(workspace:context_keys()) do
      if not entry.native then
        for _, gesture in ipairs(entry.keys) do
          truthy(gestures[gesture], where .. " advertises " .. gesture .. " without binding it")
        end
      end
    end
  end

  workspace:set_focus("containers")
  check("the containers panel", "sidebar", "containers", "n", workspace.state.buf.app)
  workspace:set_focus("items")
  check("the items panel", "sidebar", "items", "n", workspace.state.buf.app)

  local real_mode = api.nvim_get_mode
  local function with_mode(mode, fn)
    api.nvim_get_mode = function()
      return { mode = mode }
    end
    local ok, err = pcall(fn)
    api.nvim_get_mode = real_mode
    if not ok then
      error(err)
    end
  end

  workspace:set_focus("terminal")
  with_mode("nt", function()
    check("the pane in normal mode", "pane", nil, "n", session.buf)
  end)
  with_mode("t", function()
    check("the pane while typing", "typing", nil, "t", session.buf)
  end)

  workspace:close()
  local_provider:close()
end)

run_case("the container tree is still one key from the list", function()
  local interaction = require("cinder_terminal.interaction")
  local resolve = function(_, defaults)
    return defaults
  end
  local function bound(surface, panel, name)
    for _, binding in ipairs(interaction.bindings(surface, panel, resolve)) do
      if binding.action.name == name then
        return binding.lhs
      end
    end
  end
  eq(bound("sidebar", "items", "containers"), "h", "h goes up to the containers")
  eq(bound("sidebar", "containers", "open"), "l", "l comes back down to the list")
  eq(bound("pane", nil, "cycle"), "<Tab>", "and Tab is what leaves the pane")
end)

run_case("the pane never steals a native key", function()
  local interaction = require("cinder_terminal.interaction")
  local resolve = function(_, defaults)
    return defaults
  end
  local native = {}
  for _, lhs in ipairs(interaction.NATIVE_PANE_KEYS) do
    native[lhs] = true
  end
  for _, binding in ipairs(interaction.bindings("pane", nil, resolve)) do
    eq(native[binding.lhs], nil, binding.action.name .. " binds the native " .. binding.lhs .. " in the pane")
  end
end)

run_case("the pane keeps its mode marker while another panel has focus", function()
  local workspace, local_provider = make_workspace()
  local session = local_provider:create(vim.fn.getcwd())
  workspace:refresh()
  workspace:select_item("local:" .. session.id)
  workspace:set_focus("terminal")
  truthy(
    wait_for(2000, function()
      return api.nvim_win_get_buf(workspace.state.win.terminal) == session.buf
    end),
    "the session buffer reached the pane"
  )

  local function title()
    local placement = workspace.state.app:placement("terminal")
    return api.nvim_buf_get_lines(workspace.state.buf.app, placement.rect.row - 1, placement.rect.row, false)[1]
  end
  eq(title():find("normal", 1, true), nil, "typing shows no normal marker")

  -- The user presses the escape key: the pane leaves the job while it still
  -- has focus, which is what the ModeChanged hook records.
  local real = api.nvim_get_mode
  api.nvim_get_mode = function()
    return { mode = "nt" }
  end
  api.nvim_exec_autocmds("ModeChanged", {})
  api.nvim_get_mode = real
  truthy(title():find("normal", 1, true) ~= nil, "the marker appears in normal mode")

  workspace:set_focus("items")
  truthy(title():find("normal", 1, true) ~= nil, "and stays when the cursor moves to a list")

  workspace:close()
  local_provider:close()
end)

run_case("the hint row follows the pane mode", function()
  local workspace, local_provider = make_workspace()
  local first = local_provider:create(vim.fn.getcwd())
  workspace:refresh()
  workspace:select_item("local:" .. first.id)
  workspace:set_focus("terminal")
  truthy(
    wait_for(1000, function()
      return api.nvim_win_get_buf(workspace.state.win.terminal) == first.buf
    end),
    "pane shows the session"
  )

  local function keys()
    local parts = {}
    for _, entry in ipairs(workspace:context_keys()) do
      parts[#parts + 1] = entry.key .. " " .. entry.desc
    end
    return table.concat(parts, " | ")
  end

  local function with_mode(mode, fn)
    local real = api.nvim_get_mode
    api.nvim_get_mode = function()
      return { mode = mode }
    end
    local ok, err = pcall(fn)
    api.nvim_get_mode = real
    if not ok then
      error(err)
    end
  end

  with_mode("t", function()
    truthy(keys():find("normal mode", 1, true), "insert mode offers the escape key")
    truthy(keys():find("Esc Esc", 1, true), "the escape is spelled the way it is pressed")
    truthy(keys():find("C-b items", 1, true), "insert mode offers the way to the list")
    eq(keys():find("next pane", 1, true), nil, "insert mode does not advertise keys the job would receive")
    eq(keys():find("tmux prefix", 1, true), nil, "a local shell does not advertise the tmux prefix")
  end)
  with_mode("nt", function()
    truthy(keys():find("insert", 1, true), "normal mode offers the way back to the job")
    truthy(keys():find("scroll", 1, true), "normal mode advertises the native motions")
    truthy(keys():find("select", 1, true), "normal mode advertises the native selection keys")
  end)

  workspace:close()
  local_provider:close()
end)

run_case("the workspace keeps its hint card inside the frame", function()
  local workspace, local_provider = make_workspace()
  local d = workspace:dimensions()
  eq(
    api.nvim_win_get_height(workspace.state.win.app),
    d.inner_height,
    "the workspace float is as tall as the layout says"
  )
  local lines = api.nvim_buf_get_lines(workspace.state.buf.app, 0, -1, false)
  eq(#lines, d.inner_height, "every canvas row has a buffer line, hint included")
  truthy(lines[d.hint_row + 1]:find("%[", 1) ~= nil, "the hint row lists the contextual keys")

  workspace:close()
  local_provider:close()
end)

local function main()
  print(("%d passed, %d failed"):format(passed, failed))
  if failed > 0 then
    vim.cmd("cquit 1")
  end
end

main()
