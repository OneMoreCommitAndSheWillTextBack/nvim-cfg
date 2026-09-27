local H = require("tests.h")
local geom = require("cinder_ui.geom")

local r = geom.new(1, 1, 10, 20)
H.eq(geom.inset(r, 1).height, 8, "inset(1) height")
H.eq(geom.inset(r, 1).width, 18, "inset(1) width")

local part = geom.inset(r, { top = 1, bottom = 2 })
H.eq(part.row, 2, "inset partial row")
H.eq(part.height, 7, "inset partial height")

H.ok(geom.contains(r, 1, 1), "contains top-left")
H.ok(geom.contains(r, 10, 20), "contains bottom-right")
H.ok(not geom.contains(r, 11, 20), "outside below")
H.ok(not geom.contains(r, 0, 1), "outside above")

local q = geom.intersect(geom.new(5, 5, 10, 10), geom.new(1, 1, 8, 8))
H.eq(q.row, 5, "intersect row")
H.eq(q.col, 5, "intersect col")
H.eq(q.height, 4, "intersect height")
H.eq(q.width, 4, "intersect width")

H.ok(geom.empty(geom.new(1, 1, 0, 5)), "empty height")
H.ok(not geom.empty(r), "not empty")
