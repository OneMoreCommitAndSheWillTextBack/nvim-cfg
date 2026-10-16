-- inactive variants: derived highlight groups must never collide, an unfocused
-- card wears the dimmer title/cursor highlights, and without a derived inactive
-- background an unfocused cursor row stays unpainted.
local H = require("tests.h")
local ui = require("cinder_ui")
local render = require("cinder_ui.render")
local list = require("cinder_ui.widgets.list")
local geom = require("cinder_ui.geom")

local theme = ui.theme
ui.setup()

-- pin the inactive background so the spec does not depend on the ambient
-- colorscheme; everything below restores it.
local saved_inactive = vim.api.nvim_get_hl(0, { name = theme.cursor_inactive, link = false })
local INACTIVE_BG = 0x334455
vim.api.nvim_set_hl(0, theme.cursor_inactive, { bg = INACTIVE_BG })
local restore_inactive = function()
  vim.api.nvim_set_hl(0, theme.cursor_inactive, saved_inactive)
end
local hl_bg = function(name)
  return vim.api.nvim_get_hl(0, { name = name, link = false }).bg
end

-- 1. every derived group gets a name of its own
local first = theme.variant("Normal", { bg = "#111111" })
local other_base = theme.variant("Comment", { bg = "#111111" })
local other_override = theme.variant("Normal", { bg = "#222222" })
H.ok(first ~= other_base, "different bases get different groups: " .. first .. " / " .. other_base)
H.ok(first ~= other_override, "different overrides get different groups: " .. first .. " / " .. other_override)
H.eq(theme.variant("Normal", { bg = "#111111" }), first, "the same variant is reused from the cache")
H.eq(hl_bg(first), 0x111111, "the first variant keeps its own background")
H.eq(hl_bg(other_override), 0x222222, "the later variant keeps its own background")

-- a setup() reset drops the cache but must not hand out a used name again
theme.setup()
local after_setup = theme.variant("Normal", { bg = "#111111" })
H.ok(after_setup ~= first, "setup() never reuses a group name")
H.eq(hl_bg(after_setup), 0x111111, "the fresh variant carries its background")
H.eq(hl_bg(first), 0x111111, "the previous variant is not repainted")

-- 2. cursor_variant semantics
local cursor_bg = hl_bg(theme.cursor)
H.ok(type(cursor_bg) == "number", "the theme defines the focused cursor background")
local focused = theme.cursor_variant("SomeBase")
H.ok(focused ~= "SomeBase", "a focused cursor row is derived from the cursor background")
H.eq(hl_bg(focused), cursor_bg, "the focused variant uses the cursor background")

vim.api.nvim_set_hl(0, theme.cursor_inactive, {})
H.eq(theme.cursor_variant("SomeBase", true), "SomeBase", "no inactive background: base is returned unchanged")
vim.api.nvim_set_hl(0, theme.cursor_inactive, { bg = INACTIVE_BG })
local inactive = theme.cursor_variant("SomeBase", true)
H.ok(inactive ~= "SomeBase", "an inactive cursor row gets a derived group of its own")
H.eq(hl_bg(inactive), INACTIVE_BG, "the inactive variant uses the inactive background")
H.ok(inactive ~= focused, "the inactive variant differs from the focused one")

-- 3. widget level: an unfocused list still marks its cursor row
local w = ui.list({ items = { "one", "two", "three" }, cursor = 3 })
local rect = geom.new(1, 1, 3, 12)

local focused_canvas = render.Canvas.new(12, 3)
local focused_out = list.render(w, focused_canvas, rect, { focused = true, theme = theme })
H.eq(focused_out.cursor_row, 3, "the focused list reports its cursor row")
H.eq(focused_canvas:row_runs(3).spans[1].text, "three" .. string.rep(" ", 7), "focused bar spans the card width")
H.eq(hl_bg(focused_canvas:row_runs(3).spans[1].hl), cursor_bg, "focused bar uses the cursor background")

local loose_canvas = render.Canvas.new(12, 3)
local loose_out = list.render(w, loose_canvas, rect, { focused = false, theme = theme })
H.eq(loose_out.cursor_row, 3, "the unfocused list still reports its cursor row")
local loose_span = loose_canvas:row_runs(3).spans[1]
H.ok(loose_span ~= nil, "unfocused cursor row is painted")
H.eq(loose_span and loose_span.text, "three" .. string.rep(" ", 7), "unfocused bar spans the card width")
H.eq(hl_bg(loose_span and loose_span.hl), INACTIVE_BG, "unfocused bar uses the inactive background")
H.eq(#loose_canvas:row_runs(1).spans, 0, "rows without the cursor stay unpainted")

vim.api.nvim_set_hl(0, theme.cursor_inactive, {})
local bare_canvas = render.Canvas.new(12, 3)
local bare_out = list.render(w, bare_canvas, rect, { focused = false, theme = theme })
H.eq(bare_out.cursor_row, 3, "the cursor row is reported even without a bar")
H.eq(#bare_canvas:row_runs(3).spans, 0, "no inactive background: the unfocused cursor row is not painted")
vim.api.nvim_set_hl(0, theme.cursor_inactive, { bg = INACTIVE_BG })

-- 4. full frame: focused card titles use `title`, unfocused ones `title_inactive`
local root = ui.card({
  layout = "column",
  children = {
    ui.card({ id = "a", title = "Alpha", height = 3, body = ui.text({ lines = { "a" } }) }),
    ui.card({
      id = "b",
      title = "Beta",
      height = ui.flex(1),
      body = ui.list({ items = { "one", "two", "three" }, cursor = 2 }),
    }),
  },
})
-- rows: the root frame owns row 1 -> card a 2..4 (title row 2), card b 5..11
-- (title row 5, inner rows 6..10, cursor row 7)
local function span_hls(canvas, row)
  local out = {}
  for _, span in ipairs(canvas:row_runs(row).spans) do
    out[#out + 1] = span.hl
  end
  return out
end

local function bgs_on(canvas, row)
  local out = {}
  for _, span in ipairs(canvas:row_runs(row).spans) do
    local bg = hl_bg(span.hl)
    if bg ~= nil then
      out[#out + 1] = bg
    end
  end
  return out
end

local canvas = render.render_frame(root, 20, 12, { focused_id = "a" })
H.ok(vim.tbl_contains(span_hls(canvas, 2), theme.title), "focused card title uses title")
H.ok(vim.tbl_contains(span_hls(canvas, 5), theme.title_inactive), "unfocused card title uses title_inactive")
H.ok(not vim.tbl_contains(span_hls(canvas, 5), theme.title), "unfocused card title is not the focused one")

-- a theme without title_inactive falls back to title
local plain = {}
for k, v in pairs(theme) do
  plain[k] = v
end
plain.title_inactive = nil
local plain_canvas = render.render_frame(root, 20, 12, { focused_id = "a", theme = plain })
H.ok(vim.tbl_contains(span_hls(plain_canvas, 5), theme.title), "title_inactive falls back to title")

-- the root frame follows the same rule
local titled_root = ui.card({
  id = "root",
  title = "Root",
  layout = "column",
  children = {
    ui.card({ id = "c", title = "Gamma", height = 3, body = ui.text({ lines = { "c" } }) }),
  },
})
local root_loose = render.render_frame(titled_root, 20, 6, { focused_id = "c" })
H.ok(vim.tbl_contains(span_hls(root_loose, 1), theme.title_inactive), "an unfocused root title is inactive")
local root_focused = render.render_frame(titled_root, 20, 6, { focused_id = "root" })
H.ok(vim.tbl_contains(span_hls(root_focused, 1), theme.title), "a focused root title uses title")

-- 5. full frame: the unfocused cursor row wears the inactive background
-- card b inner rows 6..10 with cursor 2 -> row 7
H.ok(vim.tbl_contains(bgs_on(canvas, 7), INACTIVE_BG), "unfocused cursor row uses the inactive background")
local focused_frame = render.render_frame(root, 20, 12, { focused_id = "b" })
H.ok(vim.tbl_contains(bgs_on(focused_frame, 7), cursor_bg), "focused cursor row uses the cursor background")
H.ok(not vim.tbl_contains(bgs_on(focused_frame, 7), INACTIVE_BG), "the focused row is not painted as inactive")

vim.api.nvim_set_hl(0, theme.cursor_inactive, {})
local bare_frame = render.render_frame(root, 20, 12, { focused_id = "a" })
H.eq(bgs_on(bare_frame, 7), {}, "no inactive background: the unfocused cursor row carries no background")
restore_inactive()
