-- headless integration: real float window, buffer lines, extmark spans
local H = require("tests.h")
local ui = require("cinder_ui")

ui.setup()

local app = ui.App.new({ width = 40, height = 10, enter = false })
local root = ui.card({
  layout = "column",
  children = {
    ui.card({ id = "a", tag = "1", title = "Alpha", height = 3, body = ui.text({ lines = { "hello" } }) }),
    ui.card({
      id = "b",
      title = "Beta",
      height = ui.flex(1),
      body = ui.list({ items = { "one", "two", "three" }, cursor = 2 }),
    }),
  },
})

app:open(root)
H.ok(app.is_open, "app opened")
H.ok(app.win ~= nil and vim.api.nvim_win_is_valid(app.win), "window valid")

local cfg = vim.api.nvim_win_get_config(app.win)
H.eq(cfg.width, math.min(40, vim.o.columns), "window width")
H.eq(cfg.height, math.min(10, vim.o.lines), "window height")

local lines = vim.api.nvim_buf_get_lines(app.buf, 0, -1, false)
H.eq(#lines, cfg.height, "one buffer line per canvas row")
H.ok(lines[1]:find("Alpha", 1, true) ~= nil, "card title in buffer: " .. lines[1])
H.ok(lines[1]:find("│hello", 1, true) == nil, "row 1 is a border row")
H.eq(lines[2], "│hello" .. string.rep(" ", 33) .. "│", "content row")

local function marks_on(row0)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(app.buf, app.ns, 0, -1, { details = true })) do
    if m[2] == row0 then
      out[#out + 1] = m
    end
  end
  return out
end

local title_spans = {}
for _, m in ipairs(marks_on(0)) do
  for _, vt in ipairs(m[4].virt_text or {}) do
    title_spans[#title_spans + 1] = vt[2]
  end
end
H.ok(vim.tbl_contains(title_spans, ui.theme.title_inactive), "unfocused card title uses the theme title_inactive hl")
H.ok(not vim.tbl_contains(title_spans, ui.theme.title), "unfocused card title is not highlighted as focused")
H.ok(vim.tbl_contains(title_spans, ui.theme.tag), "tag span uses the theme tag hl")

-- focusing a card highlights its cursor row through derived highlight groups
app:focus("b")
app:redraw()

-- the float maps the cursor row and the non-current-window fallbacks onto the
-- float background, so the parked cursor does not show as a block over the bar
local whl = vim.split(vim.wo[app.win].winhighlight, ",")
for _, entry in ipairs({ "Cursor:NormalFloat", "NormalNC:NormalFloat", "EndOfBuffer:NormalFloat" }) do
  H.ok(vim.tbl_contains(whl, entry), "winhighlight maps " .. entry)
end

local focused_spans = {}
for _, m in ipairs(marks_on(3)) do
  for _, vt in ipairs(m[4].virt_text or {}) do
    focused_spans[#focused_spans + 1] = vt[2]
  end
end
H.ok(vim.tbl_contains(focused_spans, ui.theme.title), "focused card title uses the theme title hl")

local function find_marks(pred)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(app.buf, app.ns, 0, -1, { details = true })) do
    if pred(m[4]) then
      return m
    end
  end
end
local sel = find_marks(function(d)
  for _, vt in ipairs(d.virt_text or {}) do
    if tostring(vt[2]):find("^CinderUiVar") then
      return true
    end
  end
  return false
end)
H.ok(sel ~= nil, "focused cursor row uses a derived (variant) highlight")
if sel then
  H.eq(sel[2] + 1, 6, "cursor row parked on the second list item")
  local cursor = vim.api.nvim_win_get_cursor(app.win)
  H.eq(cursor[1], 6, "real cursor parked on the focused row")
end

-- re-render after a data change updates the buffer
local items = { "one", "two", "three" }
local lw = app:find("b")
lw.body = ui.list({
  get = function()
    return { items = items, cursor = 1 }
  end,
})
table.insert(items, "four")
app:redraw()
local updated = vim.api.nvim_buf_get_lines(app.buf, 0, -1, false)
H.ok(updated[8]:find("four", 1, true) ~= nil, "buffer reflects closed-over data: " .. tostring(updated[8]))

-- regression: shrinking a list replaces whole line ranges; `nvim_buf_set_lines`
-- relocates extmarks that sit inside a replaced range onto the following line, so
-- a per-line span diff used to leave stale overlays behind (visible as ghost text).
local marks_before = #vim.api.nvim_buf_get_extmarks(app.buf, app.ns, 0, -1, {})
local shrunk = { "one" }
lw.body = ui.list({
  get = function()
    return { items = shrunk, cursor = 1, top = 0 }
  end,
})
app:redraw()
local marks_after = #vim.api.nvim_buf_get_extmarks(app.buf, app.ns, 0, -1, {})
H.ok(marks_after <= marks_before, "re-render does not accumulate extmarks: " .. marks_before .. " -> " .. marks_after)
local shrunk_lines = vim.api.nvim_buf_get_lines(app.buf, 0, -1, false)
H.ok(shrunk_lines[7]:find("three", 1, true) == nil, "stale list rows are cleared: " .. tostring(shrunk_lines[7]))

app:close()
H.ok(not app.is_open, "app closed")
H.ok(not vim.api.nvim_win_is_valid(app.win or -1), "window gone")

-- regression: reopening a closed app used to diff the fresh buffer against the
-- previous frame and render an empty float
local reopen_root = ui.card({
  layout = "column",
  children = {
    ui.card({ id = "r", title = "R", height = ui.flex(1), body = ui.text({ lines = { "reopened" } }) }),
  },
})
local re = ui.App.new({ width = 24, height = 6, enter = false })
re:open(reopen_root)
local first = vim.api.nvim_buf_get_lines(re.buf, 0, -1, false)
H.ok(#first > 1, "first open draws a frame: " .. vim.inspect(first))
H.ok(first[2]:find("reopened", 1, true) ~= nil, "first open draws the content: " .. tostring(first[2]))
re:close()
re:open(reopen_root)
local second = vim.api.nvim_buf_get_lines(re.buf, 0, -1, false)
H.eq(#second, 6, "reopened buffer has one line per canvas row")
H.ok(
  second[2] and second[2]:find("reopened", 1, true) ~= nil,
  "reopen draws the content again: " .. vim.inspect(second)
)
re:close()

-- a full-height app must not cover the command line
local saved_cmdheight = vim.o.cmdheight
vim.o.cmdheight = 2
local tall = ui.App.new({ width = 30, height = 1, enter = false })
tall:open(reopen_root)
H.eq(
  vim.api.nvim_win_get_config(tall.win).height,
  vim.o.lines - 2,
  "height is clamped to the rows above the command line"
)
tall:close()
vim.o.cmdheight = saved_cmdheight
