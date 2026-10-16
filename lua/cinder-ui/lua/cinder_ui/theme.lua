-- cinder_ui.theme: highlight groups + dynamic highlight variants.
-- Defaults are derived from common groups (FloatBorder, CursorLine, ...) so the UI
-- blends into the user's colorscheme; everything can be overridden via setup().
local M = {
  border = "CinderUiBorder",
  border_focused = "CinderUiBorderFocus",
  title = "CinderUiTitle",
  title_inactive = "CinderUiTitleInactive",
  tag = "CinderUiTag",
  cursor = "CinderUiCursor",
  cursor_inactive = "CinderUiCursorInactive",
  dim = "CinderUiDim",
  scrollbar = "CinderUiScrollbar",
}

local variant_cache = {}
-- Monotonic, never reset: every derived group keeps its own name for the whole
-- session, so two variants can never end up sharing one `nvim_set_hl` target.
local variant_seq = 0

local function resolve(name)
  if not name then
    return {}
  end
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if ok and type(hl) == "table" then
    return hl
  end
  return {}
end

-- A cached highlight group that is `base` with `overrides` applied, e.g.
-- variant("CinderUiDemoDiffAdd", { bg = <cursor bg> }) for the selected row.
function M.variant(base, overrides)
  if not base and not overrides then
    return nil
  end
  local parts = {}
  for k, v in pairs(overrides or {}) do
    parts[#parts + 1] = k .. "=" .. tostring(v)
  end
  table.sort(parts)
  local key = (base or "") .. "|" .. table.concat(parts, ",")
  if variant_cache[key] then
    return variant_cache[key]
  end
  local spec = resolve(base)
  for k, v in pairs(overrides or {}) do
    spec[k] = v
  end
  variant_seq = variant_seq + 1
  local name = "CinderUiVar" .. variant_seq
  vim.api.nvim_set_hl(0, name, spec)
  variant_cache[key] = name
  return name
end

---The cursor-row highlight for `base`: `M.cursor` when the card is focused,
---`M.cursor_inactive` when it is not. Without a background of its own the
---inactive group is undefined and `base` is returned unchanged, so an
---unfocused card simply shows no selection bar.
function M.cursor_variant(base, inactive)
  local bg = resolve(inactive and M.cursor_inactive or M.cursor).bg
  if bg == nil then
    return base
  end
  return M.variant(base, { bg = bg })
end

---Fade `from` towards `to`, one channel at a time (0 keeps `from`, 1 gives `to`).
local function mix(from, to, ratio)
  local out = 0
  for shift = 0, 16, 8 do
    local a = math.floor(from / 2 ^ shift) % 256
    local b = math.floor(to / 2 ^ shift) % 256
    local v = math.max(0, math.min(255, math.floor(a + (b - a) * ratio + 0.5)))
    out = out + v * 2 ^ shift
  end
  return out
end

function M.setup(o)
  o = o or {}
  local hl = o.hl or {}
  variant_cache = {}

  local cursor_bg = (hl[M.cursor] or {}).bg or resolve("CursorLine").bg or "#313244"
  local border_fg = (hl[M.border] or {}).fg or resolve("FloatBorder").fg or "#585b70"
  local focus_fg = (hl[M.border_focused] or {}).fg or resolve("Function").fg or "#89b4fa"
  local normal_fg = (hl[M.title] or {}).fg or resolve("NormalFloat").fg or resolve("Normal").fg or "#cdd6f4"
  local dim_fg = (hl[M.dim] or {}).fg or resolve("Comment").fg or "#6c7086"

  -- An unfocused card only wears a selection bar when the theme actually has a
  -- cursor background to fade towards the float background; nothing loud is
  -- invented, so without one the group stays undefined and no bar is drawn.
  local cursor_src = (hl[M.cursor] or {}).bg or resolve("CursorLine").bg
  local normal_bg = resolve("NormalFloat").bg or resolve("Normal").bg
  local inactive_cursor_bg = cursor_src ~= nil and normal_bg ~= nil and mix(cursor_src, normal_bg, 0.55) or nil

  local defs = {
    [M.border] = { fg = border_fg },
    [M.border_focused] = { fg = focus_fg },
    [M.title] = { fg = normal_fg, bold = true },
    [M.title_inactive] = { fg = dim_fg },
    [M.tag] = { fg = "#f9e2af", bold = true },
    [M.cursor] = { bg = cursor_bg },
    [M.dim] = { fg = "#6c7086" },
    [M.scrollbar] = { fg = focus_fg },
  }
  if inactive_cursor_bg ~= nil or hl[M.cursor_inactive] ~= nil then
    defs[M.cursor_inactive] = { bg = inactive_cursor_bg }
  end
  for name, spec in pairs(defs) do
    local merged = {}
    for k, v in pairs(spec) do
      merged[k] = v
    end
    for k, v in pairs(hl[name] or {}) do
      merged[k] = v
    end
    merged.default = true
    vim.api.nvim_set_hl(0, name, merged)
  end
end

return M
