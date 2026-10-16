local H = require("tests.h")
local ui = require("cinder_ui")

local function pad(s, w)
  return s .. string.rep(" ", math.max(0, w - vim.fn.strdisplaywidth(s)))
end

local root = ui.card({
  layout = "column",
  children = {
    ui.card({ id = "a", tag = "1", title = "A", height = 3, body = ui.text({ lines = { "hello" } }) }),
    ui.card({
      id = "b",
      title = "B",
      height = ui.flex(1),
      body = ui.list({ items = { "one", "two", "three", "four", "five" }, cursor = 2 }),
    }),
  },
})

local actual = ui.render_string(root, { width = 20, height = 10 })
local expected = table.concat({
  "╭" .. string.rep("─", 18) .. "╮",
  "│╭─[1]─A" .. string.rep("─", 10) .. "╮│",
  "││" .. pad("hello", 16) .. "││",
  "│╰" .. string.rep("─", 16) .. "╯│",
  "│╭─B" .. string.rep("─", 14) .. "╮│",
  "││" .. pad("one", 15) .. "▐││",
  "││" .. pad("two", 16) .. "││",
  "││" .. pad("three", 16) .. "││",
  "│╰" .. string.rep("─", 16) .. "╯│",
  "╰" .. string.rep("─", 18) .. "╯",
}, "\n")
H.eq(actual, expected, "golden frame: nested cards, title/tag, scrollbar")

-- CJK titles keep their display width
local cjk = ui.card({
  layout = "column",
  children = {
    ui.card({ id = "c", tag = "0", title = "变更 · Unstaged", height = 3, body = ui.text({ lines = { "x" } }) }),
  },
})
local lines = vim.split(ui.render_string(cjk, { width = 26, height = 5 }), "\n")
H.eq(vim.fn.strdisplaywidth(lines[1]), 26, "frame line keeps its width with a cjk title")
H.ok(lines[2]:find("[0]─变更", 1, true) ~= nil, "cjk title rendered: " .. lines[2])

-- empty list shows the empty message
local empty = ui.card({
  layout = "column",
  children = {
    ui.card({ id = "e", title = "E", height = 3, body = ui.list({ items = {}, empty = "(empty)" }) }),
  },
})
local el = vim.split(ui.render_string(empty, { width = 16, height = 5 }), "\n")
H.ok(el[3]:find("(empty)", 1, true) ~= nil, "empty message rendered")

-- the scrollbar is sized from the widget's own rect: with padding it must not
-- start on a padding row nor stretch over the padded rows at the bottom
local padding_items = {}
for i = 1, 20 do
  padding_items[i] = tostring(i)
end
local padded = ui.card({
  layout = "column",
  children = {
    ui.card({
      id = "p",
      title = "P",
      height = ui.flex(1),
      padding = 1,
      body = ui.list({ items = padding_items, cursor = 1 }),
    }),
  },
})
local render = require("cinder_ui.render")
local pcanvas, placements = render.render_frame(padded, 20, 12, {})
local p = placements[2]
local inner = p.inner
local view = inner.height
local want_size = math.max(1, math.floor(view * view / 20))
local thumb_rows, thumb_col = {}, nil
for row = 1, 12 do
  local text = pcanvas:row_runs(row).text
  local at = text:find("▐", 1, true)
  if at then
    thumb_rows[#thumb_rows + 1] = row
    thumb_col = vim.fn.strdisplaywidth(text:sub(1, at - 1)) + 1
  end
end
H.eq(#thumb_rows, want_size, "thumb length follows the widget viewport, not the padded rect")
H.ok(thumb_rows[1] >= inner.row, "thumb starts inside the widget: first row " .. thumb_rows[1])
H.ok(thumb_rows[#thumb_rows] <= inner.row + inner.height - 1, "thumb ends inside the widget")
H.eq(thumb_col, inner.col + inner.width - 1, "thumb sits in the last inner column")
H.eq(inner.row, 4, "padding shifted the widget area")
H.eq(thumb_rows, { 4 }, "no thumb row on the padding row above the widget")
H.eq(vim.fn.strcharpart(pcanvas:row_runs(4).text, 18, 2), "││", "the card and root borders are untouched")

-- fractional flex bounds are floored, so cards still render as real boxes
local frac = ui.card({
  layout = "column",
  children = {
    ui.card({ id = "f1", title = "F1", height = ui.flex(1, { min = 5.5 }), body = ui.text({ lines = { "x" } }) }),
    ui.card({ id = "f2", title = "F2", height = ui.flex(1), body = ui.text({ lines = { "y" } }) }),
  },
})
local fl = vim.split(ui.render_string(frac, { width = 20, height = 8 }), "\n")
H.eq(#fl, 8, "frame keeps its height with fractional flex bounds")
H.ok(fl[6]:find("╰", 1, true) ~= nil, "first card keeps its bottom border: " .. fl[6])
H.ok(fl[7]:find("F2", 1, true) ~= nil, "second card is placed on a whole row: " .. fl[7])
for i = 1, #fl do
  H.eq(vim.fn.strdisplaywidth(fl[i]), 20, "row " .. i .. " keeps the frame width")
end
