-- demo/init.lua: a lazygit-style showcase for cinder_ui.
--
--   nvim -u NONE --cmd "set rtp+=/tmp/cinder-ui" -c "luafile /tmp/cinder-ui/demo/init.lua"
--
-- Keys: <Tab>/<S-Tab> cycle  j/k move  h/l/<CR> fold  0-5 jump  @ log  space/c/s/d fake action  q quit
local ui = require("cinder_ui")

vim.o.termguicolors = true
vim.o.background = "dark"
vim.o.laststatus = 0

local function hl(name, spec)
  vim.api.nvim_set_hl(0, name, spec)
end

hl("Normal", { fg = "#cdd6f4", bg = "#1e1e2e" })
hl("NormalFloat", { fg = "#cdd6f4", bg = "#1e1e2e" })
hl("CinderUiDemoDir", { fg = "#89b4fa", bold = true })
hl("CinderUiDemoFile", { fg = "#bac2de" })
hl("CinderUiDemoUntracked", { fg = "#f38ba8" })
hl("CinderUiDemoBranch", { fg = "#a6e3a1", bold = true })
hl("CinderUiDemoRef", { fg = "#cba6f7" })
hl("CinderUiDemoDiffAdd", { fg = "#a6e3a1" })
hl("CinderUiDemoDiffDel", { fg = "#f38ba8" })
hl("CinderUiDemoDiffHunk", { fg = "#94e2d5" })
hl("CinderUiDemoDiffMeta", { fg = "#6c7086" })
hl("CinderUiDemoTip", { fg = "#f9e2af" })

ui.setup()

-- ----------------------------------------------------------------------------
-- fake repo data
-- ----------------------------------------------------------------------------

local FILE_TREE = {
  name = "/",
  dir = true,
  children = {
    { name = "README.md", status = "??" },
    {
      name = "docs",
      dir = true,
      children = {
        { name = "01-overview.md", status = "??" },
        { name = "02-power-modeling.md", status = "??" },
        { name = "03-analysis-modes-and-flow.md", status = "??" },
        { name = "04-average-power.md", status = "??" },
        { name = "05-time-based-and-peak-power.md", status = "??" },
        { name = "06-switching-activity.md", status = "??" },
        { name = "07-multivoltage-upf.md", status = "??" },
        { name = "08-clock-network-power.md", status = "??" },
      },
    },
    {
      name = "lua",
      dir = true,
      children = {
        {
          name = "cinder_ui",
          dir = true,
          children = {
            { name = "app.lua" },
            { name = "canvas.lua" },
            { name = "card.lua" },
            { name = "geom.lua" },
            { name = "layout.lua" },
            { name = "render.lua" },
            { name = "theme.lua" },
            { name = "init.lua" },
          },
        },
      },
    },
  },
}

local BRANCHES = {
  { text = "* main", hl = "CinderUiDemoBranch" },
  { text = "  origin/main", hl = "CinderUiDemoRef" },
  { text = "  origin/dev", hl = "CinderUiDemoRef" },
  { text = "  origin/feat/cinder-ui", hl = "CinderUiDemoRef" },
}

local COMMITS = {
  { text = "9f2c1ab  wire cinder_ui cards into the sidebar" },
  { text = "37e0d41  drop tmux-manager" },
  { text = "b813f0e  normal/terminal mode switch (esc esc, i)" },
  { text = "4c9a77d  terminal pane keeps native v/y in normal mode" },
  { text = "e11b3a9  shell list: <C-b> + digit jump" },
  { text = "0d5f822  local: open with a default terminal" },
}

local DIFF = {
  { { text = "diff --git a/lua/cinder_ui/card.lua b/lua/cinder_ui/card.lua", hl = "CinderUiDemoDiffMeta" } },
  { { text = "@@ -1,4 +1,7 @@", hl = "CinderUiDemoDiffHunk" } },
  { { text = "+function M.validate(root)", hl = "CinderUiDemoDiffAdd" } },
  { { text = "+  -- returns a list of `path: message` errors", hl = "CinderUiDemoDiffAdd" } },
  { { text = "-  assert(true)", hl = "CinderUiDemoDiffDel" } },
  { { text = " end" } },
  { { text = "@@ -24,3 +27,5 @@", hl = "CinderUiDemoDiffHunk" } },
  { { text = "+local seen_ids = {}", hl = "CinderUiDemoDiffAdd" } },
  { { text = "+local seen_cards = {}", hl = "CinderUiDemoDiffAdd" } },
  { { text = " # 3 files changed, 12 insertions(+), 4 deletions(-)", hl = "CinderUiDemoDiffMeta" } },
}

local LOG_TIPS = {
  { { text = "You can hide/focus this panel by pressing '@'", hl = "CinderUiDemoTip" } },
  { { text = "Press '?' for keybindings, 'q' to quit", hl = "CinderUiDemoTip" } },
  "",
}

-- ----------------------------------------------------------------------------
-- state + data accessors
-- ----------------------------------------------------------------------------

local state = {
  focus = "files",
  files = { cursor = 3, top = 0, expanded = { ["/"] = true, ["/docs"] = true, ["/lua"] = false } },
  branches = { cursor = 1, top = 0 },
  commits = { cursor = 1, top = 0 },
  stash = { cursor = 1, top = 0 },
  log = {},
}

local function files_items()
  local out = {}
  local function walk(node, path, depth)
    local expanded = node.dir and state.files.expanded[path]
    out[#out + 1] = {
      node = node,
      path = path,
      dir = node.dir or false,
      text = (node.name == "/") and "/" or (node.name .. (node.dir and "/" or "")),
      depth = depth,
      glyph = node.dir and (expanded and "▼" or "▶") or (node.status or ""),
      glyph_hl = node.dir and "CinderUiDemoDir" or "CinderUiDemoUntracked",
      hl = node.dir and "CinderUiDemoDir" or "CinderUiDemoFile",
    }
    if node.dir and expanded then
      for _, child in ipairs(node.children or {}) do
        local child_path = (path == "/" and "" or path) .. "/" .. child.name
        walk(child, child_path, depth + 1)
      end
    end
  end
  walk(FILE_TREE, "/", 0)
  return out
end

local function items_of(id)
  if id == "files" then
    return files_items()
  elseif id == "branches" then
    return BRANCHES
  elseif id == "commits" then
    return COMMITS
  end
  return {}
end

local function text_lines(lines)
  return function()
    return lines
  end
end

local function list_get(id)
  return function()
    local st = state[id]
    return { items = items_of(id), cursor = st.cursor, top = st.top }
  end
end

local function log(msg)
  state.log[#state.log + 1] = { { text = "› ", hl = "CinderUiDemoTip" }, { text = msg } }
  while #state.log > 8 do
    table.remove(state.log, 1)
  end
end

local function log_data()
  local out = {}
  for _, line in ipairs(LOG_TIPS) do
    out[#out + 1] = line
  end
  for _, line in ipairs(state.log) do
    out[#out + 1] = line
  end
  return out
end

-- ----------------------------------------------------------------------------
-- layout: cards all the way down
-- ----------------------------------------------------------------------------

local root = ui.card({
  layout = "row",
  children = {
    ui.card({
      id = "left",
      layout = "column",
      border = false,
      width = ui.flex(1, { min = 26, max = 42 }),
      children = {
        ui.card({
          id = "status",
          tag = "1",
          title = "Status",
          height = 3,
          focusable = false,
          body = ui.text({ get = text_lines({ { { text = "ptpx → main", hl = "CinderUiDemoBranch" } } }) }),
        }),
        ui.card({
          id = "files",
          tag = "2",
          title = "Files · Worktrees · Submodules",
          height = ui.flex(3, { min = 5 }),
          body = ui.tree({
            get = function()
              return {
                items = files_items(),
                cursor = state.files.cursor,
                top = state.files.top,
                empty = "no files",
              }
            end,
          }),
        }),
        ui.card({
          id = "branches",
          tag = "3",
          title = "Local branches · Remotes · Tags",
          height = ui.flex(2, { min = 4 }),
          body = ui.list({ get = list_get("branches") }),
        }),
        ui.card({
          id = "commits",
          tag = "4",
          title = "Commits · Reflog",
          height = ui.flex(2, { min = 4 }),
          body = ui.list({ get = list_get("commits") }),
        }),
        ui.card({
          id = "stash",
          tag = "5",
          title = "Stash",
          height = ui.flex(1, { min = 3 }),
          body = ui.list({
            get = function()
              return { items = {}, cursor = 1, top = 0, empty = "no stash entries" }
            end,
          }),
        }),
      },
    }),
    ui.card({
      id = "right",
      layout = "column",
      border = false,
      width = ui.flex(3),
      children = {
        ui.card({
          id = "diff",
          tag = "0",
          title = "变更 · Unstaged changes",
          height = ui.flex(1, { min = 6 }),
          body = ui.text({ get = text_lines(DIFF) }),
        }),
        ui.card({
          id = "log",
          title = "Command log",
          height = ui.flex(1, { min = 4, max = 12 }),
          body = ui.text({ get = log_data }),
        }),
      },
    }),
  },
})

local errors = ui.validate(root)
if errors then
  error("demo layout is invalid:\n  " .. table.concat(errors, "\n  "), 0)
end

-- ----------------------------------------------------------------------------
-- app + keymaps (the plugin owns policy; cinder_ui only renders)
-- ----------------------------------------------------------------------------

local app = ui.App.new({ width = 0.92, height = 0.94, focus = "files" })
app:open(root)

local function view_h(id)
  local p = app:placement(id)
  return p and math.max(1, p.inner.height) or 1
end

local function footer()
  local st = state[state.focus]
  local total = #items_of(state.focus)
  local pos = (st and st.cursor) or 0
  if total == 0 then
    pos = 0
  end
  return string.format(
    "  %s  %d/%d  ·  <Tab> cycle  j/k move  h/l fold  0-5 jump  @ log  q quit  ",
    state.focus,
    pos,
    total
  )
end

local function rerender()
  app:set_footer(footer())
  app:invalidate()
end

local function move(delta)
  local id = state.focus
  local st = state[id]
  local total = #items_of(id)
  if not st or total == 0 then
    return
  end
  st.cursor = math.max(1, math.min(total, (st.cursor or 1) + delta))
  st.top = ui.ensure_visible(st.cursor, st.top, view_h(id), total)
  rerender()
end

local function fold(expand)
  if state.focus ~= "files" then
    return
  end
  local item = files_items()[state.files.cursor]
  if not item then
    return
  end
  if not item.dir then
    if expand == false then
      -- h on a file: jump to its parent directory
      local parent = item.path:match("^(.*)/[^/]+$")
      for i, other in ipairs(files_items()) do
        if other.path == parent then
          state.files.cursor = i
          state.files.top = ui.ensure_visible(i, state.files.top, view_h("files"), #files_items())
          rerender()
          return
        end
      end
    end
    return
  end
  local new = expand
  if new == nil then
    new = not state.files.expanded[item.path]
  end
  if new == true and state.files.expanded[item.path] and #(item.node.children or {}) > 0 then
    -- l on an already expanded directory: descend into the first child
    state.files.cursor = state.files.cursor + 1
    state.files.top = ui.ensure_visible(state.files.cursor, state.files.top, view_h("files"), #files_items())
    rerender()
    return
  end
  state.files.expanded[item.path] = new and true or nil
  log((new and "Expand " or "Collapse ") .. item.path)
  local after = files_items()
  state.files.cursor = math.max(1, math.min(#after, state.files.cursor))
  state.files.top = ui.ensure_visible(state.files.cursor, state.files.top, view_h("files"), #after)
  rerender()
end

local function act(what)
  local id = state.focus
  local st = state[id]
  local item = st and items_of(id)[st.cursor or 0] or nil
  local name = type(item) == "table" and (item.text or "?") or "?"
  local verbs = { stage = "Stage", commit = "Commit", stash = "Stash", discard = "Discard" }
  log(string.format("%s: %s", verbs[what] or what, name))
  rerender()
end

local last_focus = "files"
local function toggle_log()
  if state.focus == "log" then
    state.focus = last_focus
  else
    last_focus = state.focus
    state.focus = "log"
  end
  rerender()
end

local function focus_tag(tag)
  for _, p in ipairs(app.placements or {}) do
    if p.card.tag == tag and p.id and p.card.body and p.card.focusable ~= false then
      state.focus = p.id
      app:focus(p.id)
      rerender()
      return
    end
  end
end

local HELP = {
  "keybindings:",
  "  <Tab>/<S-Tab>  cycle cards",
  "  j/k            move cursor",
  "  h/l, <CR>      collapse / expand (files)",
  "  0-5            jump to card by tag",
  "  @              focus the command log",
  "  <Space> c s d  fake stage/commit/stash/discard",
  "  q              quit",
}

local function help()
  for _, line in ipairs(HELP) do
    log(line)
  end
  rerender()
end

vim.keymap.set("n", "q", function()
  app:close()
  vim.cmd("qa!")
end, { buffer = app.buf, nowait = true, silent = true })

local function map(lhs, fn)
  vim.keymap.set("n", lhs, fn, { buffer = app.buf, nowait = true, silent = true })
end

map("<Tab>", function()
  app:cycle(1)
  state.focus = app.focused_id
  rerender()
end)
map("<S-Tab>", function()
  app:cycle(-1)
  state.focus = app.focused_id
  rerender()
end)
map("j", function()
  move(1)
end)
map("k", function()
  move(-1)
end)
map("h", function()
  fold(false)
end)
map("l", function()
  fold(true)
end)
map("<CR>", function()
  fold(nil)
end)
map("@", toggle_log)
map("<Space>", function()
  act("stage")
end)
map("c", function()
  act("commit")
end)
map("s", function()
  act("stash")
end)
map("d", function()
  act("discard")
end)
map("?", help)
for d = 0, 5 do
  map(tostring(d), function()
    focus_tag(tostring(d))
  end)
end

log("demo ready — 3 files changed")
rerender()

return app
