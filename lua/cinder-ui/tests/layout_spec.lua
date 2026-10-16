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

-- allocate: table-driven pins for fixed/flex/min/max/overflow behavior. A
-- borderless row hands each child exactly the size `allocate` returned, so the
-- child widths are the function's output.
local function widths(specs, avail)
  local children = {}
  for i, spec in ipairs(specs) do
    children[i] = text_card({ width = spec })
  end
  local pl = layout.compute(ui.card({ layout = "row", border = false, children = children }), geom.new(1, 1, 4, avail))
  local got = {}
  for i = 2, #pl do
    got[#got + 1] = pl[i].rect.width
  end
  return got
end

local allocate_cases = {
  { name = "fixed sizes are honored", specs = { 3, 4 }, avail = 10, want = { 3, 4 } },
  { name = "one flex takes the rest", specs = { 3, ui.flex(1) }, avail = 10, want = { 3, 7 } },
  { name = "flex shares by weight", specs = { ui.flex(1), ui.flex(2) }, avail = 9, want = { 3, 6 } },
  {
    name = "fractional cells go to the largest fraction",
    specs = { ui.flex(1), ui.flex(1), ui.flex(1) },
    avail = 10,
    want = { 4, 3, 3 },
  },
  { name = "min freezes a flex item", specs = { ui.flex(1, { min = 4 }), ui.flex(1) }, avail = 5, want = { 4, 1 } },
  {
    name = "max clamps a flex item and its share is redistributed",
    specs = { ui.flex(1, { max = 2 }), ui.flex(2) },
    avail = 10,
    want = { 2, 8 },
  },
  {
    name = "overfull flex is squeezed to min, then the last card pays",
    specs = { ui.flex(1, { min = 4 }), ui.flex(1, { min = 4 }) },
    avail = 5,
    want = { 4, 1 },
  },
  { name = "fixed overflow shrinks the last card", specs = { 8, 5 }, avail = 10, want = { 8, 2 } },
}
for _, case in ipairs(allocate_cases) do
  H.eq(widths(case.specs, case.avail), case.want, "allocate: " .. case.name)
end

-- fractional flex bounds are floored like fixed sizes: a rect that lands between
-- two canvas rows is never drawn, so the card used to collapse into an empty box
local frac = ui.card({
  layout = "column",
  children = {
    text_card({ id = "g1", height = ui.flex(1, { min = 5.5 }) }),
    text_card({ id = "g2", height = ui.flex(1) }),
  },
})
local fp = layout.compute(frac, geom.new(1, 1, 8, 20))
for _, p in ipairs(fp) do
  H.eq(p.rect.height, math.floor(p.rect.height), "rect height is whole: " .. p.path)
  H.eq(p.rect.row, math.floor(p.rect.row), "rect row is whole: " .. p.path)
  H.eq(p.inner.height, math.floor(p.inner.height), "inner height is whole: " .. p.path)
end
H.eq(fp[2].rect.height, 5, "fractional min is floored")
H.eq(fp[3].rect.height, 3, "the floor frees the rest for the other flex child")
H.eq(fp[2].rect.height + fp[3].rect.height, 8, "every row is still handed out")

local fracrow = ui.card({
  layout = "row",
  children = {
    text_card({ id = "g3", width = ui.flex(1, { max = 7.5 }) }),
    text_card({ id = "g4", width = ui.flex(1) }),
  },
})
local rw = layout.compute(fracrow, geom.new(1, 1, 6, 20))
H.eq(rw[2].rect.width, 7, "fractional max is floored")
H.eq(rw[3].rect.width, 13, "the remaining width is whole")
H.eq(rw[2].rect.width + rw[3].rect.width, 20, "every column is still handed out")
