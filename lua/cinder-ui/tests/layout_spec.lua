local H = require("tests.h")
local ui = require("cinder_ui")
local geom = require("cinder_ui.geom")
local layout = require("cinder_ui.layout")

local function text_card(o)
  o.body = ui.text({ lines = {} })
  return ui.card(o)
end

-- column: fixed + flex
local root = ui.card({
  layout = "column",
  children = {
    text_card({ id = "a", title = "A", height = 3 }),
    text_card({ id = "b", title = "B", height = ui.flex(1) }),
  },
})
local pl = layout.compute(root, geom.new(1, 1, 12, 30))
H.eq(#pl, 3, "placement count")
H.eq(pl[1].path, "root", "root placement first")
H.eq(pl[2].rect.row, 1, "a starts at the top of the root inner rect")
H.eq(pl[2].rect.height, 3, "a keeps its fixed height")
H.eq(pl[3].rect.row, 4, "b follows a")
H.eq(pl[3].rect.height, 9, "b flexes")
H.eq(pl[3].inner.height, 7, "b inner height")
H.eq(pl[3].rect.width, 30, "children span the full inner width")

-- row: two flex widths, one clamped by max
local rowroot = ui.card({
  layout = "row",
  children = {
    text_card({ id = "l", title = "L", width = ui.flex(1, { max = 20 }) }),
    text_card({ id = "r", title = "R", width = ui.flex(2) }),
  },
})
local rp = layout.compute(rowroot, geom.new(1, 1, 10, 60))
H.eq(rp[2].rect.width, 20, "left clamped to max")
H.eq(rp[3].rect.col, 21, "right starts after left")
H.eq(rp[3].rect.width, 40, "right takes the rest")

-- nesting: a borderless container passes its area down to the children
local nested = ui.card({
  layout = "column",
  children = {
    ui.card({
      id = "wrap",
      layout = "column",
      border = false,
      height = ui.flex(1),
      children = {
        text_card({ id = "c1", title = "C1", height = ui.flex(1) }),
        text_card({ id = "c2", title = "C2", height = ui.flex(1) }),
      },
    }),
  },
})
local np = layout.compute(nested, geom.new(1, 1, 10, 40))
local by_id = {}
for _, p in ipairs(np) do
  if p.id then
    by_id[p.id] = p
  end
end
H.eq(by_id.wrap.rect.height, 10, "borderless container fills")
H.eq(by_id.wrap.inner.height, 10, "borderless container has no inset")
H.eq(by_id.c1.rect.height, 5, "nested flex split upper half")
H.eq(by_id.c2.rect.height, 5, "nested flex split lower half")

-- squeeze: mins that cannot fit produce a warning and are clipped
local tight = ui.card({
  layout = "column",
  children = {
    text_card({ id = "t1", height = ui.flex(1, { min = 4 }) }),
    text_card({ id = "t2", height = ui.flex(1, { min = 4 }) }),
  },
})
local tp, warnings = layout.compute(tight, geom.new(1, 1, 5, 20))
H.eq(tp[2].rect.height, 4, "first keeps its min")
H.ok(tp[3].rect.height < 4, "second is squeezed")
H.ok(#warnings > 0, "squeeze reported as a layout warning")

-- clipping: children never escape their parent
for _, p in ipairs(tp) do
  H.ok(p.rect.row >= 1 and p.rect.height >= 0, "rect stays inside the canvas")
end
