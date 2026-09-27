---The terminal pane: the real window that covers the terminal card content,
---its two modes (the job gets the keys, or the plugin does) and the attach
---dance that binds a provider session to that window.
local util = require("cinder_terminal.ui.util")

local api = vim.api

local scratch = util.scratch
local valid_buf = util.valid_buf
local valid_win = util.valid_win

---How long a second `<Esc>` may take to count as `<Esc><Esc>` in the pane.
---Only the gesture uses it: the first `<Esc>` is already on its way to the job
---when the window starts, so a lone one never waits.
local ESCAPE_WINDOW_MS = 300
local ATTACH_DEBOUNCE = 60

---@class CinderTerminal.UI
local M = {}

---The terminal card is chrome: keep the real terminal window exactly on its
---content area, so the card border and title stay visible around the job.
function M:sync_terminal_window()
  local state = self.state
  local win = state.win.terminal
  if not valid_win(win) or not state.app then
    return
  end
  local placement = state.app:placement("terminal")
  local inner = placement and placement.inner
  if not inner or inner.width < 1 or inner.height < 1 then
    return
  end
  pcall(api.nvim_win_set_config, win, {
    relative = "win",
    win = state.win.app,
    row = inner.row - 1,
    col = inner.col - 1,
    width = inner.width,
    height = inner.height,
    style = "minimal",
    border = "none",
    zindex = 45,
  })
end

---Hand the keyboard to the job. Headless Neovim cannot reach Terminal-Job
---mode, so the tests spy on this instead of asserting the mode itself.
function M:enter_terminal_insert()
  pcall(vim.cmd.startinsert)
end

---Leave the job for normal mode, the way Neovim's own `<C-\><C-n>` does.
function M:enter_terminal_normal()
  local keys = api.nvim_replace_termcodes("<C-\\><C-n>", true, false, true)
  pcall(api.nvim_feedkeys, keys, "n", false)
end

---Send raw bytes to the job. The mapping that calls this is buffer-local, so
---the job is the one in the buffer the keys arrived in, not necessarily the
---one on screen in the pane. A send that fails means the job is gone; saying
---so beats dropping the user's keystrokes without a trace.
---@param text string
function M:send_to_job(text)
  local buf = api.nvim_get_current_buf()
  if vim.bo[buf].buftype ~= "terminal" then
    local win = self.state.win.terminal
    buf = valid_win(win) and api.nvim_win_get_buf(win) or nil
  end
  local channel = buf and vim.bo[buf].channel or nil
  if channel and channel > 0 then
    local ok, err = pcall(api.nvim_chan_send, channel, text)
    if not ok then
      self:notify_failure(err, "could not send the keys to the terminal")
    end
  end
end

---The `<Esc><Esc>` gesture, implemented through one `<Esc>`.
---
---Bound literally, `<Esc><Esc>` makes Neovim hold every lone `<Esc>` for
---'timeoutlen' before the job receives it, and `<Esc>` is the key a TUI waits
---for. The pane maps a single `<Esc>` instead: it forwards the byte right away
---and only a second press inside `escape_window` leaves the job.
---@see CinderTerminal.Interaction.Translation
function M:terminal_escape()
  local state = self.state
  local now = (vim.uv or vim.loop).now()
  local last = state.escape_at
  if last and now - last <= (self.opts.escape_window or ESCAPE_WINDOW_MS) then
    state.escape_at = nil
    self:enter_terminal_normal()
    return
  end
  state.escape_at = now
  self:send_to_job("\27")
end

---@param buf number
---@param title string
function M:set_terminal_buffer(buf, title)
  local state = self.state
  local win = state.win.terminal
  if not valid_win(win) then
    return
  end
  state.terminal_title = title or ""
  local previous = api.nvim_win_get_buf(win)
  local had_terminal = valid_buf(previous) and vim.bo[previous].buftype == "terminal"
  vim.wo[win].winfixbuf = false
  if valid_buf(buf) and api.nvim_win_get_buf(win) ~= buf then
    pcall(api.nvim_win_set_buf, win, buf)
  end
  vim.wo[win].winfixbuf = true
  -- `show()` is asynchronous, so the pane can receive its first real terminal
  -- after `set_focus` already decided to type into it. Without this the pane
  -- would settle in normal mode and the first keystrokes would be commands
  -- instead of shell input. A pane that already held a terminal keeps the
  -- mode the user left it in.
  if
    not had_terminal
    and state.focus == "terminal"
    and state.terminal_insert
    and valid_buf(buf)
    and vim.bo[buf].buftype == "terminal"
  then
    self:enter_terminal_insert()
  end
  if valid_buf(buf) and not state.mapped_buffers[buf] then
    state.mapped_buffers[buf] = true
    self:map_terminal_buffer(buf)
  end
  self:render()
end

---True while the pane holds a job that Neovim currently drives in normal
---mode, focused or not. The title uses it so the marker does not vanish when
---the cursor moves to a list — that is still the mode the pane comes back in.
---@return boolean
function M:pane_normal_mode()
  local state = self.state
  local win = state.win.terminal
  if not valid_win(win) then
    return false
  end
  local buf = api.nvim_win_get_buf(win)
  return vim.bo[buf].buftype == "terminal" and not state.terminal_insert
end

---True while the focused pane takes keys for the plugin instead of the job,
---which is what the hint row has to follow.
---@return boolean
function M:terminal_normal_mode()
  local state = self.state
  if state.focus ~= "terminal" then
    return false
  end
  local win = state.win.terminal
  if not valid_win(win) then
    return false
  end
  local buf = api.nvim_win_get_buf(win)
  return vim.bo[buf].buftype == "terminal" and api.nvim_get_mode().mode ~= "t"
end

---Force the next render to re-show the selected terminal. Called after the
---embedded tmux client exits.
function M:invalidate_terminal()
  self.state.attached_item_id = nil
  self.state.attach_generation = self.state.attach_generation + 1
  self:schedule_attach()
end

function M:schedule_attach()
  local state = self.state
  if state.attach_timer then
    pcall(state.attach_timer.stop, state.attach_timer)
    pcall(state.attach_timer.close, state.attach_timer)
    state.attach_timer = nil
  end
  local uv = vim.uv or vim.loop
  local timer = uv.new_timer()
  state.attach_timer = timer
  timer:start(
    ATTACH_DEBOUNCE,
    0,
    vim.schedule_wrap(function()
      pcall(timer.stop, timer)
      pcall(timer.close, timer)
      if state.attach_timer == timer then
        state.attach_timer = nil
      end
      if self:is_open() then
        self:attach_selected()
      end
    end)
  )
end

function M:render_terminal()
  local node = self:selected_item()
  local id = node and node.id or nil
  if id == self.state.attached_item_id then
    return
  end
  self:schedule_attach()
end

---Show placeholder text in the terminal pane (no session, attach failure).
---@param lines string[]
function M:show_hint(lines)
  local state = self.state
  local buf = state.buf.hint
  if not valid_buf(buf) then
    buf = scratch("cinder_terminal_terminal", "hide")
    state.buf.hint = buf
    vim.bo[buf].modifiable = true
  end
  self:set_terminal_buffer(buf, "")
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

function M:attach_selected()
  local state = self.state
  local node = self:selected_item()
  local generation = state.attach_generation + 1
  state.attach_generation = generation
  local force = state.attach_force
  state.attach_force = false

  state.attached_item_id = node and node.id or nil
  if not node then
    self:show_hint({ "", "  select a terminal with l" })
    return
  end

  local provider = self:provider(node)
  if not provider then
    return
  end
  provider:show(node, function(ok, buf, error)
    if not self:is_open() or state.attach_generation ~= generation then
      return
    end
    if not ok or not buf then
      local fallback = "could not attach the terminal"
      local reason = error or fallback
      self:notify_failure(error, fallback)
      self:show_hint({ "", "  " .. reason })
      return
    end
    local label = node.label
    local container = self:selected_container()
    if container and container.id ~= node.id then
      label = container.label .. " › " .. node.label
    end
    self:set_terminal_buffer(buf, label)
  end, { force = force })
end

return M
