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
  "││" .. pad("one", 16) .. "▐│",
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
