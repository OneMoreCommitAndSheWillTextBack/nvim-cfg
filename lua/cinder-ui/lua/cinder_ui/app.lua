-- cinder_ui.app: owns one floating window, the focused card id and redraw scheduling.
-- Policy (keymaps, what moves where) stays in the plugin that uses this library.
local geom = require("cinder_ui.geom")
local layout = require("cinder_ui.layout")
local render = require("cinder_ui.render")
local card = require("cinder_ui.card")
local Canvas = require("cinder_ui.canvas")
local theme = require("cinder_ui.theme")

local M = {}
local App = {}
App.__index = App
M.App = App

function App.new(o)
  o = o or {}
  local self = setmetatable({}, App)
  self.opts = o
  self.width = o.width or 0.9
  self.height = o.height or 0.9
  self.border = o.border
  self.zindex = o.zindex or 50
  self.focused_id = o.focus
  self.ns = vim.api.nvim_create_namespace("cinder_ui")
  self.prev = {}
  self.is_open = false
  return self
end

local function axis_size(v, total)
  if v <= 1 then
    return math.max(1, math.floor(total * v + 0.5))
  end
  return math.max(1, math.floor(v))
end

function App:_dims()
  local cols, lines = vim.o.columns, vim.o.lines
  local w = math.min(axis_size(self.width, cols), cols)
  local h = math.min(axis_size(self.height, lines), lines)
  local row = math.max(0, math.floor((lines - h) / 2))
  local col = math.max(0, math.floor((cols - w) / 2))
  return w, h, row, col
end

function App:_open()
  local w, h, row, col = self:_dims()
  local border = self.border
  if border == nil and self.root and type(self.root.border) == "string" then
    border = self.root.border
  end
  border = border or "rounded"

  self.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.buf].bufhidden = "wipe"
  vim.bo[self.buf].filetype = "cinderui"
  self.win = vim.api.nvim_open_win(self.buf, self.opts.enter ~= false, {
    relative = "editor",
    width = w,
    height = h,
    row = row,
    col = col,
    style = "minimal",
    border = border,
    zindex = self.zindex,
    title = self.root and self.root.title or nil,
    title_pos = (self.root and self.root.title) and "left" or nil,
    footer = self.footer,
    footer_pos = self.footer and "right" or nil,
  })
  vim.wo[self.win].winhighlight = table.concat({
    "Normal:NormalFloat",
    "FloatBorder:" .. theme.border,
    "FloatTitle:" .. theme.title,
    "FloatFooter:" .. theme.dim,
  }, ",")
  self.is_open = true

  self.augroup = vim.api.nvim_create_augroup("CinderUiApp" .. self.buf, { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = self.augroup,
    callback = function()
      self:resize()
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = self.augroup,
    pattern = tostring(self.win),
    callback = function()
      self.is_open = false
      if self.augroup then
        pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
        self.augroup = nil
      end
    end,
  })
end

function App:open(root)
  self.root = root
  local errors = card.validate(root)
  if errors then
    error("[cinder-ui] invalid ui tree:\n  " .. table.concat(errors, "\n  "), 0)
  end
  if self.is_open and not (self.win and vim.api.nvim_win_is_valid(self.win)) then
    self.is_open = false
  end
  if not self.is_open then
    self:_open()
  end
  self:_draw()
  return self
end

App.render = App.open

-- synchronous redraw (mostly for tests / immediate feedback)
function App:redraw()
  self:_draw()
end

function App:_draw()
  if not (self.is_open and self.win and vim.api.nvim_win_is_valid(self.win)) then
    return
  end
  local cfg = vim.api.nvim_win_get_config(self.win)
  local w, h = cfg.width, cfg.height
  if not (self.buf and vim.api.nvim_buf_is_valid(self.buf)) then
    return
  end
  local canvas = Canvas.new(w, h)
  local placements = layout.compute(self.root, geom.new(1, 1, h, w))
  self.placements = placements
  render.render(placements, canvas, { focused_id = self.focused_id, theme = theme })
  vim.bo[self.buf].modifiable = true
  self.prev = render.flush(self.buf, self.ns, canvas, self.prev)
  vim.bo[self.buf].modifiable = false
  self:_park_cursor()
end

function App:_park_cursor()
  local best
  for _, p in ipairs(self.placements or {}) do
    if p.id ~= nil and p.id == self.focused_id and p.cursor_row then
      best = p
    end
  end
  if best then
    local last = vim.api.nvim_buf_line_count(self.buf)
    local row = math.max(1, math.min(best.cursor_row, last))
    pcall(vim.api.nvim_win_set_cursor, self.win, { row, 0 })
  end
end

function App:invalidate()
  if self._pending then
    return
  end
  self._pending = true
  vim.schedule(function()
    self._pending = false
    self:_draw()
  end)
end

function App:focus(id)
  self.focused_id = id
  self:invalidate()
end

function App:placement(id)
  for _, p in ipairs(self.placements or {}) do
    if p.id == id then
      return p
    end
  end
end

function App:find(id)
  local p = self:placement(id)
  return p and p.card or nil
end

function App:focusables()
  local out = {}
  for _, p in ipairs(self.placements or {}) do
    if p.id ~= nil and p.card.body and p.card.focusable ~= false and not geom.empty(p.rect) then
      out[#out + 1] = p.id
    end
  end
  return out
end

function App:cycle(dir)
  local ids = self:focusables()
  if #ids == 0 then
    return nil
  end
  dir = dir or 1
  local cur
  for i, id in ipairs(ids) do
    if id == self.focused_id then
      cur = i
    end
  end
  local nxt = cur and (((cur - 1 + dir) % #ids) + 1) or 1
  self:focus(ids[nxt])
  return ids[nxt]
end

function App:card_at(row, col)
  local best
  for _, p in ipairs(self.placements or {}) do
    if geom.contains(p.rect, row, col) then
      best = p
    end
  end
  return best
end

function App:set_footer(text)
  self.footer = text
  if self.is_open and self.win and vim.api.nvim_win_is_valid(self.win) then
    pcall(vim.api.nvim_win_set_config, self.win, {
      footer = text or "",
      footer_pos = "right",
    })
  end
end

function App:resize()
  if not (self.is_open and self.win and vim.api.nvim_win_is_valid(self.win)) then
    return
  end
  local w, h, row, col = self:_dims()
  pcall(vim.api.nvim_win_set_config, self.win, {
    relative = "editor",
    width = w,
    height = h,
    row = row,
    col = col,
  })
  self.prev = {}
  self:invalidate()
end

function App:close()
  if self.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
    self.augroup = nil
  end
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    pcall(vim.api.nvim_win_close, self.win, true)
  end
  self.win, self.buf, self.is_open, self.placements = nil, nil, false, nil
end

return M
