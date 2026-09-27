---Small helpers the workspace modules share: window/buffer lifetime and the
---few layout constants more than one module has to agree on.
local api = vim.api

local M = {}

---The cell a card spends on each side; card content widths subtract it.
M.CARD_BORDER = 2

---Both sidebar cards live in one buffer, so every lookup names the card it
---means through this list instead of repeating the same pair of names.
M.SIDEBAR_PANELS = { "containers", "items" }

---@param win? number
---@return boolean
function M.valid_win(win)
  return win ~= nil and api.nvim_win_is_valid(win)
end

---@param buf? number
---@return boolean
function M.valid_buf(buf)
  return buf ~= nil and api.nvim_buf_is_valid(buf)
end

---@param filetype string
---@param bufhidden? string Defaults to `wipe`; the terminal placeholder needs
---`hide`, otherwise it dies as soon as the pane leaves it and can no longer be
---restored.
---@return number
function M.scratch(filetype, bufhidden)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = bufhidden or "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = filetype
  return buf
end

return M
