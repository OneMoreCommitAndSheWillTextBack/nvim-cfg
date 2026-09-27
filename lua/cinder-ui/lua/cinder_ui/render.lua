-- cinder_ui.render: draw placements onto a canvas and flush the canvas into a buffer.
local Canvas = require("cinder_ui.canvas")
local geom = require("cinder_ui.geom")
local layout = require("cinder_ui.layout")
local widgets = require("cinder_ui.widgets")
local theme = require("cinder_ui.theme")

local M = {}
M.Canvas = Canvas

local SCROLLBAR = "▐"

local function draw_scrollbar(canvas, p, scroll, th)
  local r = p.rect
  if r.height < 3 or r.width < 2 then
    return
  end
  local col = r.col + r.width - 1
  local view = r.height - 2
  local total = scroll.total or 0
  local top = scroll.top or 0
  if total <= view or view <= 0 then
    return
  end
  local size = math.max(1, math.floor(view * view / total))
  local max_top = total - view
  local start = 0
  if max_top > 0 and view - size > 0 then
    start = math.floor(top * (view - size) / max_top + 0.5)
  end
  for i = 0, size - 1 do
    canvas:put_char(r.row + 1 + start + i, col, SCROLLBAR, th.scrollbar)
  end
end

-- placements: from layout.compute; ctx = { focused_id, theme }
function M.render(placements, canvas, ctx)
  ctx = ctx or {}
  local th = ctx.theme or theme
  for _, p in ipairs(placements) do
    local card = p.card
    if p.path ~= "root" and card.border ~= false then
      local hl = th.border
      if p.id ~= nil and p.id == ctx.focused_id then
        hl = th.border_focused
      end
      canvas:box(p.rect, {
        style = type(card.border) == "string" and card.border or "rounded",
        hl = hl,
        title = card.title,
        tag = card.tag,
        title_hl = th.title,
        tag_hl = th.tag,
      })
    end
    if card.body and not geom.empty(p.inner) then
      local out = widgets.render(card.body, canvas, p.inner, {
        focused = p.id ~= nil and p.id == ctx.focused_id,
        theme = th,
      })
      if out then
        p.scroll = out.scroll
        p.cursor_row = out.cursor_row
        if out.scroll then
          draw_scrollbar(canvas, p, out.scroll, th)
        end
      end
    end
  end
end

-- Render a complete frame *including* the root frame border (for tests / previews).
function M.render_frame(root, width, height, ctx)
  ctx = ctx or {}
  local th = ctx.theme or theme
  local canvas = Canvas.new(width, height)
  local rect = geom.new(1, 1, height, width)
  local hl = (root.id ~= nil and root.id == ctx.focused_id) and th.border_focused or th.border
  canvas:box(rect, {
    style = type(root.border) == "string" and root.border or "rounded",
    hl = hl,
    title = root.title,
    tag = root.tag,
    title_hl = th.title,
    tag_hl = th.tag,
  })
  local placements = layout.compute(root, geom.inset(rect, 1))
  M.render(placements, canvas, ctx)
  return canvas, placements
end

function M.to_string(root, o)
  o = o or {}
  local canvas = M.render_frame(root, o.width or 80, o.height or 24, o)
  return canvas:to_string()
end

local function row_key(row)
  if row == nil then
    return nil
  end
  local parts = { row.text }
  for i, s in ipairs(row.spans) do
    parts[#parts + 1] = string.format("%d:%s:%s", s.col, s.hl, s.text)
  end
  return table.concat(parts, "\1")
end

-- Flush a canvas into a buffer. Text lines are diffed and only changed runs are
-- written, but extmark spans are rebuilt for the whole frame: `nvim_buf_set_lines`
-- relocates extmarks that sit inside a replaced region onto the following line,
-- which makes per-line span diffing unsound.
-- `prev` is the previous list of { text, spans } (reused and returned).
function M.flush(buf, ns, canvas, prev)
  local lines = canvas:lines()
  local height = canvas.height

  local dirty = #prev ~= height
  if not dirty then
    for i = 1, height do
      if row_key(prev[i]) ~= row_key(lines[i]) then
        dirty = true
        break
      end
    end
  end
  if not dirty then
    return prev
  end

  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  local i = 1
  while i <= height do
    local same = prev[i] ~= nil and prev[i].text == lines[i].text
    if same then
      i = i + 1
    else
      local j = i
      while j + 1 <= height and (prev[j + 1] == nil or prev[j + 1].text ~= lines[j + 1].text) do
        j = j + 1
      end
      local texts = {}
      for k = i, j do
        texts[#texts + 1] = lines[k].text
      end
      vim.api.nvim_buf_set_lines(buf, i - 1, j, false, texts)
      i = j + 1
    end
  end

  if #prev > height then
    vim.api.nvim_buf_set_lines(buf, height, #prev, false, {})
  end

  for k = 1, height do
    for _, span in ipairs(lines[k].spans) do
      vim.api.nvim_buf_set_extmark(buf, ns, k - 1, 0, {
        virt_text = { { span.text, span.hl } },
        virt_text_pos = "overlay",
        virt_text_win_col = span.col,
      })
    end
  end

  for k = 1, height do
    prev[k] = lines[k]
  end
  for k = height + 1, #prev do
    prev[k] = nil
  end
  return prev
end

return M
