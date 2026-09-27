local H = require("tests.h")
local canvas = require("cinder_ui.canvas")
local geom = require("cinder_ui.geom")

-- plain text + spans
local c = canvas.new(10, 1)
c:put_text(1, 1, "hi", "Err")
H.eq(c:to_string(), "hi", "plain text")
H.eq(c:row_runs(1).spans[1].hl, "Err", "span hl")
H.eq(c:row_runs(1).spans[1].col, 0, "span col is 0-based")

-- wide characters occupy two display columns
local w = canvas.new(10, 1)
w:put_text(1, 1, "变更", nil)
w:put_text(1, 7, "x", nil)
H.eq(w:to_string(), "变更  x", "cjk display columns")
H.eq(canvas.truncate("变更abc", 5), "变更a", "truncate cjk")
H.eq(canvas.truncate("变更abc", 4), "变更", "truncate cjk exact")
H.eq(canvas.truncate("变更abc", 1), "", "truncate too narrow")

-- overwriting half of a wide char clears both cells
local o = canvas.new(6, 1)
o:put_text(1, 1, "变更", nil)
o:put_text(1, 2, "ab", nil)
H.eq(o:to_string(), " ab", "wide char overwrite")

-- a wide char that does not fit is dropped
local f = canvas.new(3, 1)
f:put_text(1, 3, "变", nil)
H.eq(f:to_string(), "", "wide char clipped at right edge")

-- box with tag + title
local b = canvas.new(12, 3)
b:box(geom.new(1, 1, 3, 12), { style = "rounded", title = "Hi", tag = "2" })
H.eq(
  b:to_string(),
  "╭─[2]─Hi───╮\n│          │\n╰──────────╯",
  "box with tag and title"
)

-- long titles are truncated to keep the frame intact
local t = canvas.new(10, 3)
t:box(geom.new(1, 1, 3, 10), { title = "0123456789" })
H.eq(t:row_runs(1).text, "╭─012345─╮", "title truncation")
H.eq(canvas.width(t:row_runs(3).text), 10, "frame width preserved")

-- spans merge per highlight
local s = canvas.new(8, 1)
s:put_text(1, 1, "aa", nil)
s:put_text(1, 3, "bb", "Err")
s:put_text(1, 5, "cc", "Err")
local spans = s:row_runs(1).spans
H.eq(#spans, 1, "contiguous same-hl spans merge")
H.eq(spans[1].text, "bbcc", "merged span text")
H.eq(spans[1].col, 2, "merged span col")

-- rich segments advance by display width
local r = canvas.new(12, 1)
r:put_rich(1, 1, { { text = "变更", hl = "A" }, { text = " ok", hl = "B" } }, 12)
H.eq(r:to_string(), "变更 ok", "rich segments")
H.eq(#r:row_runs(1).spans, 2, "rich segment count")
