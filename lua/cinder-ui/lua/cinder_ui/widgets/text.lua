-- text widget: opts = { get = fn() -> lines } or { lines = { ... } }
-- Every line may be a string or a list of { text, hl } segments.
local M = {}

local function call(v)
  if type(v) == "function" then
    return v()
  end
  return v
end

function M.render(w, canvas, rect, _env)
  local lines = call(w.get) or w.lines or {}
  for i = 1, math.min(#lines, rect.height) do
    canvas:put_rich(rect.row + i - 1, rect.col, lines[i], rect.width)
  end
  return nil
end

return M
