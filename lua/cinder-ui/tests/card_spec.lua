local H = require("tests.h")
local ui = require("cinder_ui")

local function text_card(o)
  o.body = ui.text({ lines = {} })
  return ui.card(o)
end

-- a valid tree of every shape: container, content, nested borderless container
local good = ui.card({
  layout = "column",
  children = {
    text_card({ id = "a", tag = "1", title = "A", height = 3 }),
    ui.card({
      id = "wrap",
      layout = "column",
      border = false,
      height = ui.flex(1),
      children = {
        text_card({ id = "b", title = "B", height = 3 }),
      },
    }),
  },
})
H.eq(ui.validate(good), nil, "valid tree passes")

local function errors_of(root)
  return ui.validate(root)
end

H.has(
  errors_of(ui.card({
    layout = "column",
    children = {
      ui.card({ height = 3, children = { text_card({ height = 3 }) }, body = ui.text({ lines = {} }) }),
    },
  })),
  "both children and body",
  "children+body rejected"
)

H.has(
  errors_of(ui.card({ layout = "column", children = {
    text_card({}),
  } })),
  "height required in column layout",
  "missing height in column"
)

H.has(
  errors_of(ui.card({ layout = "row", children = {
    text_card({ height = 3 }),
  } })),
  "width required in row layout",
  "missing width in row"
)

H.has(
  errors_of(ui.card({
    layout = "column",
    children = {
      text_card({ id = "x", height = 3 }),
      text_card({ id = "x", height = 3 }),
    },
  })),
  "duplicate id 'x'",
  "duplicate ids rejected"
)

local shared = text_card({ id = "s", height = 3 })
H.has(
  errors_of(ui.card({ layout = "column", children = { shared, shared } })),
  "card object reused",
  "shared card object rejected"
)

H.has(
  errors_of(ui.card({
    layout = "column",
    children = {
      ui.card({ height = 3, focusable = true, body = ui.text({ lines = {} }) }),
    },
  })),
  "focusable card needs an id",
  "focusable card without id rejected"
)

H.has(
  errors_of(ui.card({
    layout = "column",
    children = {
      text_card({ id = "z", height = ui.flex(1, { min = 5, max = 2 }) }),
    },
  })),
  "flex min > max",
  "flex min>max rejected"
)

H.has(
  errors_of(ui.card({
    layout = "column",
    children = {
      ui.card({ id = "nb", border = false, title = "nope", height = 3, body = ui.text({ lines = {} }) }),
    },
  })),
  "title requires a border",
  "title without border rejected"
)

H.has(
  errors_of(ui.card({ layout = "column", body = ui.text({ lines = {} }) })),
  "root card cannot have a body",
  "root with body rejected"
)

H.has(
  errors_of(ui.card({ layout = "column", children = { text_card({}) } })),
  "height required",
  "root children follow root layout"
)

H.has(
  errors_of(ui.card({ layout = "diagonal", children = { text_card({ height = 3 }) } })),
  "invalid layout",
  "unknown layout rejected"
)

H.has(
  errors_of(ui.card({
    layout = "column",
    children = {
      ui.card({ id = "w", height = 3, body = { __widget = "chart" } }),
    },
  })),
  "unknown widget",
  "unknown widget rejected"
)

H.has(
  errors_of(ui.card({ layout = "column", children = {
    ui.card({ id = "n", height = 3 }),
  } })),
  "neither children nor body",
  "empty card rejected"
)

H.has(
  errors_of(ui.card({
    layout = "column",
    children = {
      ui.card({ id = "h", height = 1, border = true, body = ui.text({ lines = {} }) }),
    },
  })),
  "< 2 with a border",
  "tiny bordered card rejected"
)

H.has(
  errors_of(ui.card({ layout = "column", children = {
    ui.card({ id = "q", height = 3, body = ui.text({}) }),
  } })),
  "text widget needs get() or lines",
  "text widget without data rejected"
)

-- padding reaches geom.inset: an unvalidated value killed the render inside a
-- vim.schedule callback instead of failing at construct time
H.has(
  errors_of(ui.card({
    layout = "column",
    children = {
      ui.card({ id = "p1", height = 3, padding = true, body = ui.text({ lines = {} }) }),
    },
  })),
  "padding must be a number or { top, right, bottom, left }",
  "non-numeric padding rejected"
)

H.has(
  errors_of(ui.card({
    layout = "column",
    children = {
      ui.card({ id = "p2", height = 3, padding = -1, body = ui.text({ lines = {} }) }),
    },
  })),
  "padding must be >= 0",
  "negative padding rejected"
)

H.has(
  errors_of(ui.card({
    layout = "column",
    children = {
      ui.card({
        id = "p3",
        height = 3,
        padding = { top = 1, right = "2", bottom = 0, left = 0 },
        body = ui.text({ lines = {} }),
      }),
    },
  })),
  "padding.right must be a number",
  "non-numeric padding side rejected"
)

H.has(
  errors_of(ui.card({
    layout = "column",
    children = {
      ui.card({ id = "p4", height = 3, padding = { top = 1 }, body = ui.text({ lines = {} }) }),
    },
  })),
  "padding.right must be a number",
  "incomplete padding table rejected"
)

H.has(
  errors_of(ui.card({
    layout = "column",
    children = {
      ui.card({
        id = "p5",
        height = 3,
        padding = { top = 0, right = 0, bottom = -1, left = 0 },
        body = ui.text({ lines = {} }),
      }),
    },
  })),
  "padding.bottom must be >= 0",
  "negative padding side rejected"
)

H.eq(
  ui.validate(ui.card({
    layout = "column",
    children = {
      ui.card({ id = "ok1", height = 3, padding = 2, body = ui.text({ lines = {} }) }),
    },
  })),
  nil,
  "numeric padding accepted"
)

H.eq(
  ui.validate(ui.card({
    padding = { top = 0, right = 1, bottom = 1, left = 1 },
    layout = "column",
    children = {
      ui.card({
        id = "ok2",
        height = 3,
        padding = { top = 1, right = 0, bottom = 1, left = 0 },
        body = ui.text({ lines = {} }),
      }),
    },
  })),
  nil,
  "padding table accepted on the root and on a child"
)
