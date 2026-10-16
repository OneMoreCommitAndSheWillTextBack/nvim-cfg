-- cinder_ui.canvas: an in-memory character grid with styled spans.
-- Cells are indexed by display column (1-based); wide characters occupy two cells
-- (the second one is a `cont` marker). No window/buffer involved: everything here is
-- plain data so it can be golden-tested.
local M = {}

local BORDERS = {
  rounded = { tl = "╭", tr = "╮", bl = "╰", br = "╯", h = "─", v = "│" },
  single = { tl = "┌", tr = "┐", bl = "└", br = "┘", h = "─", v = "│" },
  double = { tl = "╔", tr = "╗", bl = "╚", br = "╝", h = "═", v = "║" },
}
M.BORDERS = BORDERS

local Canvas = {}
Canvas.__index = Canvas
M.Canvas = Canvas

function M.new(width, height)
  return setmetatable({ width = width or 0, height = height or 0, cells = {} }, Canvas)
end

function M.width(s)
  if s == nil or s == "" then
    return 0
  end
  return vim.fn.strdisplaywidth(s)
end

function M.chars(s)
  if s == nil or s == "" then
    return {}
  end
  return vim.fn.split(s, "\\zs")
end

-- truncate to at most `max_width` display columns
function M.truncate(s, max_width)
  if s == nil then
    return ""
  end
  if max_width <= 0 then
    return ""
  end
  if M.width(s) <= max_width then
    return s
  end
  local out, acc = {}, 0
  for _, ch in ipairs(M.chars(s)) do
    local w = M.width(ch)
    if acc + w > max_width then
      break
    end
    out[#out + 1] = ch
    acc = acc + w
  end
  return table.concat(out)
end

---Truncate to at most `max_width` display columns and mark the cut with a single
---`…`, which is part of that budget. Returns `s` unchanged when it fits.
function M.elide(s, max_width)
  if s == nil or s == "" or max_width <= 0 then
    return ""
  end
  if M.width(s) <= max_width then
    return s
  end
  local dots = "…"
  if max_width < M.width(dots) then
    return M.truncate(s, max_width)
  end
  return M.truncate(s, max_width - M.width(dots)) .. dots
end

local function row_of(self, row)
  local r = self.cells[row]
  if not r then
    r = {}
    self.cells[row] = r
  end
  return r
end

local function clear_cell(self, row, col)
  local r = self.cells[row]
  if not r then
    return
  end
  local c = r[col]
  if not c then
    return
  end
  if c.cont then
    r[col] = nil
    r[col - 1] = nil
  elseif c.wide then
    r[col] = nil
    r[col + 1] = nil
  else
    r[col] = nil
  end
end

function Canvas:put_char(row, col, ch, hl)
  if ch == nil or ch == "" then
    return
  end
  if row < 1 or row > self.height or col < 1 or col > self.width then
    return
  end
  local w = M.width(ch)
  if w == 0 then
    return
  end
  if col + w - 1 > self.width then
    return
  end
  clear_cell(self, row, col)
  if w > 1 then
    clear_cell(self, row, col + 1)
  end
  local r = row_of(self, row)
  r[col] = { ch = ch, hl = hl, wide = w > 1 }
  if w > 1 then
    r[col + 1] = { cont = true, hl = hl }
  end
end

-- Writes at most `max_width` display columns of `text` (default: up to the edge
-- of the canvas) and returns the display width actually written. Text that does
-- not fit is cut on a display-column boundary and marked with one `…`, so a wide
-- glyph is never split and the cut is never taken for a full row.
function Canvas:put_text(row, col, text, hl, max_width)
  if text == nil or text == "" then
    return 0
  end
  text = text:gsub("[\r\n]+", " ")
  local limit = self.width
  if max_width ~= nil and col + max_width - 1 < limit then
    limit = col + max_width - 1
  end
  if col > limit then
    return 0
  end
  if M.width(text) > limit - col + 1 then
    text = M.elide(text, limit - col + 1)
  end
  local c = col
  for _, ch in ipairs(M.chars(text)) do
    local w = M.width(ch)
    if w > 0 then
      if c + w - 1 > limit then
        break
      end
      self:put_char(row, c, ch, hl)
      c = c + w
    end
  end
  return c - col
end

-- value: string, a single segment { text = "...", hl = "..." },
-- or a list of segments. `transform(hl, seg)` can remap highlights per segment.
-- Returns the display width written.
function Canvas:put_rich(row, col, value, max_width, transform)
  if value == nil then
    return 0
  end
  if type(value) ~= "table" then
    value = { text = tostring(value) }
  end
  local segments = value.text ~= nil and { value } or value
  local c = col
  local limit = col + (max_width or (self.width - col + 1)) - 1
  if limit > self.width then
    limit = self.width
  end
  for _, seg in ipairs(segments) do
    if c > limit then
      break
    end
    if type(seg) ~= "table" then
      seg = { text = tostring(seg) }
    end
    local text = seg.text or ""
    local hl = seg.hl
    if transform then
      hl = transform(hl, seg)
    end
    c = c + self:put_text(row, c, text, hl, limit - c + 1)
  end
  return c - col
end

function Canvas:fill_row(row, col, len, hl)
  if len <= 0 or row < 1 or row > self.height then
    return
  end
  local stop = math.min(col + len - 1, self.width)
  for c = col, stop do
    self:put_char(row, c, " ", hl)
  end
end

function Canvas:hline(row, col, len, ch, hl)
  if len <= 0 then
    return
  end
  local stop = math.min(col + len - 1, self.width)
  for c = col, stop do
    self:put_char(row, c, ch, hl)
  end
end

function Canvas:vline(row, col, len, ch, hl)
  if len <= 0 then
    return
  end
  local stop = math.min(row + len - 1, self.height)
  for r = row, stop do
    self:put_char(r, col, ch, hl)
  end
end

-- Draw a framed card. o = { style, hl, title, title_hl, tag, tag_hl }
-- A title is rendered as `╭─[tag]─Title────╮` (tag optional).
function Canvas:box(r, o)
  o = o or {}
  if r.height < 1 or r.width < 1 then
    return
  end
  local b = BORDERS[o.style or "rounded"] or BORDERS.rounded
  local hl = o.hl
  if r.height >= 2 then
    self:hline(r.row, r.col + 1, r.width - 2, b.h, hl)
    self:hline(r.row + r.height - 1, r.col + 1, r.width - 2, b.h, hl)
    self:put_char(r.row, r.col, b.tl, hl)
    self:put_char(r.row, r.col + r.width - 1, b.tr, hl)
    self:put_char(r.row + r.height - 1, r.col, b.bl, hl)
    self:put_char(r.row + r.height - 1, r.col + r.width - 1, b.br, hl)
    if r.width >= 2 and r.height >= 3 then
      self:vline(r.row + 1, r.col, r.height - 2, b.v, hl)
      self:vline(r.row + 1, r.col + r.width - 1, r.height - 2, b.v, hl)
    end
  else
    self:hline(r.row, r.col, r.width, b.h, hl)
  end
  if (o.title ~= nil and o.title ~= "") or o.tag ~= nil then
    local col = r.col + 2
    local stop = r.col + r.width - 2
    if o.tag ~= nil then
      -- a tag that does not fit is truncated like the title: it must never
      -- write over the top-right corner of the frame
      local avail = stop - col + 1
      local tag = M.truncate("[" .. tostring(o.tag) .. "]", math.max(0, avail - 1))
      self:put_text(r.row, col, tag, o.tag_hl or hl)
      col = col + M.width(tag)
      if col <= stop then
        self:put_char(r.row, col, b.h, hl)
        col = col + 1
      end
    end
    if o.title ~= nil and o.title ~= "" and col <= stop then
      local avail = stop - col + 1
      local text = M.truncate(o.title, math.max(0, avail - 1))
      self:put_text(r.row, col, text, o.title_hl or hl)
    end
  end
end

-- Returns { text = "...", spans = { { col = <0-based display col>, text, hl } } }
function Canvas:row_runs(row)
  local cells = self.cells[row]
  local line, spans = {}, {}
  local run_text, run_hl, run_start = {}, nil, nil
  local function flush()
    if #run_text > 0 and run_hl ~= nil then
      spans[#spans + 1] = { col = run_start - 1, text = table.concat(run_text), hl = run_hl }
    end
    run_text, run_hl, run_start = {}, nil, nil
  end
  local col = 1
  while col <= self.width do
    local cell = cells and cells[col]
    local ch, w, hl
    if cell == nil or cell.cont then
      ch, w, hl = " ", 1, nil
    else
      ch = cell.ch or " "
      w = math.max(1, M.width(ch))
      hl = cell.hl
    end
    if hl ~= run_hl then
      flush()
    end
    if run_start == nil then
      run_start, run_hl = col, hl
    end
    run_text[#run_text + 1] = ch
    line[#line + 1] = ch
    col = col + w
  end
  flush()
  return { text = table.concat(line), spans = spans }
end

function Canvas:lines()
  local out = {}
  for row = 1, self.height do
    out[row] = self:row_runs(row)
  end
  return out
end

function Canvas:to_string(trim_right)
  local out = {}
  for row = 1, self.height do
    local text = self:row_runs(row).text
    if trim_right ~= false then
      text = text:gsub(" +$", "")
    end
    out[row] = text
  end
  return table.concat(out, "\n")
end

return M
