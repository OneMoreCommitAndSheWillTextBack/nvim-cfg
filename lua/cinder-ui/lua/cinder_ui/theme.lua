-- cinder_ui.theme: highlight groups + dynamic highlight variants.
-- Defaults are derived from common groups (FloatBorder, CursorLine, ...) so the UI
-- blends into the user's colorscheme; everything can be overridden via setup().
local M = {
  border = "CinderUiBorder",
  border_focused = "CinderUiBorderFocus",
  title = "CinderUiTitle",
  tag = "CinderUiTag",
  cursor = "CinderUiCursor",
  dim = "CinderUiDim",
  scrollbar = "CinderUiScrollbar",
}

local variant_cache = {}

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
  local name = "CinderUiVar" .. tostring(#variant_cache + 1)
  vim.api.nvim_set_hl(0, name, spec)
  variant_cache[key] = name
  return name
end

function M.cursor_variant(base)
  local bg = resolve(M.cursor).bg
  if bg == nil then
    return base
  end
  return M.variant(base, { bg = bg })
end

function M.setup(o)
  o = o or {}
  local hl = o.hl or {}
  variant_cache = {}

  local cursor_bg = (hl[M.cursor] or {}).bg or resolve("CursorLine").bg or "#313244"
  local border_fg = (hl[M.border] or {}).fg or resolve("FloatBorder").fg or "#585b70"
  local focus_fg = (hl[M.border_focused] or {}).fg or resolve("Function").fg or "#89b4fa"
  local normal_fg = (hl[M.title] or {}).fg or resolve("NormalFloat").fg or resolve("Normal").fg or "#cdd6f4"

  local defs = {
    [M.border] = { fg = border_fg },
    [M.border_focused] = { fg = focus_fg },
    [M.title] = { fg = normal_fg, bold = true },
    [M.tag] = { fg = "#f9e2af", bold = true },
    [M.cursor] = { bg = cursor_bg },
    [M.dim] = { fg = "#6c7086" },
    [M.scrollbar] = { fg = focus_fg },
  }
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
