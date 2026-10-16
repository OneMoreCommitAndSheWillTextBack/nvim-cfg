---Everything that turns workspace state into cinder-ui cards: the sidebar
---rows, the card titles, the hint row and the card tree handed to the app.
local ui = require("cinder_ui")
local util = require("cinder_terminal.ui.util")
local providers = require("cinder_terminal.providers")

local CARD_BORDER = util.CARD_BORDER
local fn = vim.fn

---@class CinderTerminal.UI
local M = {}

---Cut `text` to at most `width` display columns, marking the cut with one `…`
---that is part of the budget. Counting characters instead would split a CJK or
---emoji glyph in half and cost columns the row does not have.
---@param text string
---@param width number
---@return string
local function truncate(text, width)
  local chars = fn.strchars(text)
  local cut, used = 0, 0
  while cut < chars do
    local next_width = fn.strdisplaywidth(fn.strcharpart(text, cut, 1))
    if used + next_width > width - 1 then
      break
    end
    used = used + next_width
    cut = cut + 1
  end
  return fn.strcharpart(text, 0, cut) .. "…"
end

---@param text string
---@param width number
---@return string
local function display_text(text, width)
  text = tostring(text or "")
  if width <= 0 or fn.strdisplaywidth(text) <= width then
    return text
  end
  return truncate(text, width)
end

---@param node CinderTerminal.Node
---@param highlights CinderTerminal.HighlightGroups
---@return string
local function detail_group(node, highlights)
  local status = node.status or ""
  if status == "" or status == "running" or status == "active" or status == "attached" then
    return highlights.detail
  end
  return highlights.error
end

---@return string
function M:containers_title()
  return "Containers"
end

---@return string
function M:items_title()
  local container = self:selected_container()
  return (container and container.label) or "Terminals"
end

---Badge of the terminal card: the pane looks the same in both modes, so the
---card has to say which one the keys go to. It is a card tag rather than part
---of the title so it keeps a highlight group of its own, and it exists only
---while the pane really holds a terminal.
---@return string?
function M:terminal_mode()
  local state = self.state
  local win = state.win.terminal
  if not util.valid_win(win) or vim.bo[vim.api.nvim_win_get_buf(win)].buftype ~= "terminal" then
    return nil
  end
  return self:pane_normal_mode() and "normal" or "insert"
end

---@return string
function M:terminal_title()
  local state = self.state
  local label = state.terminal_title ~= "" and state.terminal_title or "Terminal"
  -- The card spends one cell per border and two more before the title, and the
  -- mode badge sits in front of it: the label gives up its width so a long
  -- terminal name never costs the badge.
  local mode = self:terminal_mode()
  local budget = (state.metrics and state.metrics.terminal_width or 60) - 4 - (mode and (#mode + 3) or 0)
  return display_text(label, math.max(1, budget))
end

---Text budget of a row: the card content minus the mark/digit column and the
---two spaces that separate it from the label.
---@return number
function M:row_text_width()
  local d = self.state.metrics
  local inner = math.max(8, (d and d.sidebar_width or 30) - CARD_BORDER)
  return inner - 4
end

---@return table[]
function M:containers_rows()
  local state = self.state
  local hl = self:highlights()
  local width = self:row_text_width()
  local rows = {}
  for _, node in ipairs(state.containers) do
    rows[#rows + 1] = {
      segments = {
        { text = node.mark and (node.mark .. " ") or "  ", hl = node.mark and hl.mark or nil },
        { text = display_text(node.label, width) },
        { text = node.detail and ("  " .. node.detail) or "", hl = hl.detail },
      },
    }
  end
  return rows
end

---The digit is part of the list, not of the hint row: it says which key
---reaches this terminal, and only the ten a digit can address wear one.
---@return table[]
function M:items_rows()
  local state = self.state
  local hl = self:highlights()
  local width = self:row_text_width()
  local rows = {}
  for index, node in ipairs(state.items) do
    local digit = index <= 10 and ((index % 10) .. " ") or "  "
    rows[#rows + 1] = {
      segments = {
        { text = digit, hl = hl.detail },
        { text = display_text(node.label, width) },
        { text = node.detail and ("  " .. node.detail) or "", hl = detail_group(node, hl) },
      },
    }
  end
  return rows
end

---@return string
function M:items_empty()
  local provider = self:provider(self:selected_container())
  if provider and provider.capabilities.create_terminal then
    return "  n  new terminal"
  end
  return "  empty"
end

---@return table
function M:containers_data()
  return {
    items = self:containers_rows(),
    cursor = self:selected_index("containers") or 0,
    top = self.state.scroll.containers,
    empty = "  no containers",
  }
end

---@return table
function M:items_data()
  return {
    items = self:items_rows(),
    cursor = self:selected_index("items") or 0,
    top = self.state.scroll.items,
    empty = self:items_empty(),
  }
end

---The hint row, straight out of `interaction`; a pending message wins.
---
---One segment per entry instead of one flat line: the key reads as a key, its
---description as prose, and a dim `│` separates entries. Widening is handled by
---dropping trailing entries whole, because a hint cut mid-word reads as a key
---that does not exist.
---@return { text: string, hl: string? }[]
function M:hint_line()
  local state = self.state
  local hl = self:highlights()
  local width = math.max(8, (state.metrics and state.metrics.inner_width or 80) - 1)
  if state.message then
    local group = state.message_level == "error" and hl.error or hl.help
    return { { text = " " .. display_text(state.message, width), hl = group } }
  end
  local segments, used = { { text = " " } }, 1
  for index, entry in ipairs(self:context_keys()) do
    local key = "[" .. entry.key .. "] "
    local separator = index > 1 and " │ " or ""
    local entry_width = fn.strdisplaywidth(separator .. key .. entry.desc)
    if used + entry_width > width then
      break
    end
    used = used + entry_width
    if separator ~= "" then
      segments[#segments + 1] = { text = separator, hl = hl.detail }
    end
    segments[#segments + 1] = { text = key, hl = hl.title }
    segments[#segments + 1] = { text = entry.desc, hl = hl.help }
  end
  return segments
end

---The card tree of the workspace: the sidebar column (containers over items),
---the terminal card whose content area the real terminal window covers, and
---the hint card under both.
---@return table
function M:build_tree()
  local state = self.state
  local d = state.metrics
  return ui.card({
    layout = "column",
    children = {
      ui.card({
        border = false,
        layout = "row",
        height = ui.flex(1),
        children = {
          ui.card({
            border = false,
            layout = "column",
            width = d.sidebar_width,
            children = {
              ui.card({
                id = "containers",
                title = self:containers_title(),
                height = d.container_rows,
                body = ui.list({
                  get = function()
                    return self:containers_data()
                  end,
                }),
              }),
              ui.card({
                id = "items",
                title = self:items_title(),
                height = ui.flex(1, { min = 4 }),
                body = ui.list({
                  get = function()
                    return self:items_data()
                  end,
                }),
              }),
            },
          }),
          ui.card({
            id = "terminal",
            title = self:terminal_title(),
            tag = self:terminal_mode(),
            width = ui.flex(1, { min = 25 }),
            body = ui.text({
              get = function()
                return {}
              end,
            }),
          }),
        },
      }),
      ui.card({
        border = false,
        height = 1,
        body = ui.text({
          get = function()
            return { self:hint_line() }
          end,
        }),
      }),
    },
  })
end

function M:render()
  if not self:is_open() then
    return
  end
  local state = self.state
  state.metrics = self:dimensions()
  self:sync_scroll()
  state.app:focus(state.focus, { redraw = false })
  state.app:open(self:build_tree())
  self:sync_terminal_window()
  self:render_terminal()
end

---@param text string
---@param level? string `"error"` paints the message like a failure; anything
---else (or nil) is an ordinary notice.
function M:notify(text, level)
  if not text or text == "" then
    return
  end
  self.state.message = text
  self.state.message_level = level
  self:render()
  vim.defer_fn(function()
    if self.state.message == text then
      self.state.message, self.state.message_level = nil, nil
      if self:is_open() then
        self:render()
      end
    end
  end, 5000)
end

---Report a failed provider call in the hint row. Providers are allowed to
---fail without a message, but not to fail silently: the caller knows what it
---asked for, so it names the action. `SILENT` is the one exception - the user
---dismissed a prompt or the provider is retrying on its own - and it never
---reaches the row.
---@param error? CinderTerminal.Silent|string
---@param fallback string
function M:notify_failure(error, fallback)
  if providers.is_silent(error) then
    return
  end
  self:notify(error or fallback, "error")
end

return M
