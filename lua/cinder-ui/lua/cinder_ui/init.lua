-- cinder_ui: a small card-based TUI component library for Neovim floats.
--
--   local ui = require("cinder_ui")
--   ui.setup()
--   local app = ui.App.new({ width = 0.9, height = 0.9 })
--   local root = ui.card{ layout = "column", children = {
--     ui.card{ id = "status", tag = "1", title = "Status", height = 3,
--              body = ui.text{ get = function() return { "main" } end } },
--     ui.card{ id = "files", tag = "2", title = "Files", height = ui.flex(1, { min = 4 }),
--              body = ui.tree{ get = function() return { items = rows, cursor = 1, top = 0 } end } },
--   } }
--   assert(ui.validate(root) == nil)
--   app:open(root)
--   app:focus("files")
--   app:invalidate()
local card = require("cinder_ui.card")
local app = require("cinder_ui.app")
local theme = require("cinder_ui.theme")
local render = require("cinder_ui.render")
local list = require("cinder_ui.widgets.list")
local geom = require("cinder_ui.geom")

local M = {}

M.version = "0.1.0"
M.setup = theme.setup
M.theme = theme
M.geom = geom
M.App = app.App
M.card = card.card
M.flex = card.flex
M.text = card.text
M.list = card.list
M.tree = card.tree
M.validate = card.validate
M.ensure_visible = list.ensure_visible
M.variant = theme.variant
M.render_string = render.to_string

return M
