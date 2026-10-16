-- cinder_ui.card: card constructors and construct-time validation.
--
-- A card is either a *container* (has `children`, optional `layout`) or a *content*
-- card (has `body`, a widget). The root card is implicit: the app window's own border
-- acts as its frame, so the root only holds `children` (+ optional `title`/`padding`).
local M = {}

local VALID_BORDER = { rounded = true, single = true, double = true }
local VALID_WIDGET = { text = true, list = true, tree = true }

local function copy(o)
  local t = {}
  for k, v in pairs(o or {}) do
    t[k] = v
  end
  return t
end

function M.card(o)
  local c = copy(o)
  c.__card = true
  return c
end

-- size spec: height/width = ui.flex(weight, { min = n, max = n })
function M.flex(weight, o)
  return {
    __flex = true,
    weight = weight or 1,
    min = o and o.min or nil,
    max = o and o.max or nil,
  }
end

function M.text(o)
  local w = copy(o)
  w.__widget = "text"
  return w
end

function M.list(o)
  local w = copy(o)
  w.__widget = "list"
  return w
end

function M.tree(o)
  local w = copy(o)
  w.__widget = "tree"
  return w
end

-- Returns nil when the tree is valid, otherwise a list of `path: message` strings.
function M.validate(root)
  local errors = {}
  local seen_cards = {}
  local seen_ids = {}

  local function err(path, msg)
    errors[#errors + 1] = path .. ": " .. msg
  end

  local function check_widget(body, path, node)
    if type(body) ~= "table" or not body.__widget then
      err(path, "body must be a widget (ui.text{}/ui.list{}/ui.tree{})")
      return
    end
    if not VALID_WIDGET[body.__widget] then
      err(path, "unknown widget '" .. tostring(body.__widget) .. "'")
      return
    end
    if body.get ~= nil and type(body.get) ~= "function" then
      err(path, "widget get must be a function")
    elseif body.get == nil then
      if body.__widget == "text" and type(body.lines) ~= "table" then
        err(path, "text widget needs get() or lines")
      elseif body.__widget ~= "text" and type(body.items) ~= "table" then
        err(path, body.__widget .. " widget needs get() or items")
      end
    end
    if node.layout ~= nil then
      err(path, "layout is only valid on container cards")
    end
  end

  local function check_size(node, path)
    for _, field in ipairs({ "height", "width" }) do
      local v = node[field]
      if v ~= nil then
        if type(v) == "number" then
          if v < 1 then
            err(path, field .. " must be >= 1")
          elseif node.border ~= false and v < 2 then
            err(path, field .. " < 2 with a border: no room for the frame")
          end
        elseif type(v) == "table" and v.__flex then
          if v.weight ~= nil and v.weight <= 0 then
            err(path, field .. " flex weight must be > 0")
          end
          if v.min ~= nil and v.min < 1 then
            err(path, field .. " flex min must be >= 1")
          end
          if v.min ~= nil and v.max ~= nil and v.min > v.max then
            err(path, field .. " flex min > max")
          end
        else
          err(path, field .. " must be a number or ui.flex()")
        end
      end
    end
  end

  local function check_padding(node, path)
    local p = node.padding
    if p == nil then
      return
    end
    if type(p) == "number" then
      if p < 0 then
        err(path, "padding must be >= 0")
      end
      return
    end
    if type(p) ~= "table" then
      err(path, "padding must be a number or { top, right, bottom, left }")
      return
    end
    for _, side in ipairs({ "top", "right", "bottom", "left" }) do
      local v = p[side]
      if type(v) ~= "number" then
        err(path, "padding." .. side .. " must be a number (got " .. type(v) .. ")")
      elseif v < 0 then
        err(path, "padding." .. side .. " must be >= 0")
      end
    end
  end

  local function walk(node, path, is_root)
    if type(node) ~= "table" or not node.__card then
      err(path, "not a card (use ui.card{})")
      return
    end
    if seen_cards[node] then
      err(path, "card object reused (a card must be unique per position)")
      return
    end
    seen_cards[node] = true

    if node.id ~= nil then
      if type(node.id) ~= "string" then
        err(path, "id must be a string")
      elseif seen_ids[node.id] then
        err(path, "duplicate id '" .. node.id .. "'")
      else
        seen_ids[node.id] = true
      end
    end
    if node.focusable == true and node.id == nil then
      err(path, "focusable card needs an id")
    end

    local children, body = node.children, node.body
    if children ~= nil and body ~= nil then
      err(path, "cannot have both children and body")
    end
    if children == nil and body == nil and not is_root then
      err(path, "card has neither children nor body")
    end
    if body ~= nil then
      check_widget(body, path, node)
    end

    if children ~= nil then
      if type(children) ~= "table" then
        err(path, "children must be a list")
      elseif #children == 0 then
        err(path, "children must not be empty")
      else
        local layout = node.layout or "column"
        if layout ~= "column" and layout ~= "row" then
          err(path, "invalid layout '" .. tostring(layout) .. "'")
        end
        for i, ch in ipairs(children) do
          local cpath = string.format("%s.children[%d]", path, i - 1)
          if type(ch) ~= "table" or not ch.__card then
            err(cpath, "not a card (use ui.card{})")
          else
            local size
            if layout == "row" then
              size = ch.width
            else
              size = ch.height
            end
            if size == nil then
              err(cpath, (layout == "row" and "width" or "height") .. " required in " .. layout .. " layout")
            end
            walk(ch, cpath, false)
          end
        end
      end
    end

    check_size(node, path)
    check_padding(node, path)

    if node.border ~= nil and node.border ~= true and node.border ~= false and not VALID_BORDER[node.border] then
      err(path, "unknown border style '" .. tostring(node.border) .. "'")
    end
    if node.title ~= nil then
      if type(node.title) ~= "string" then
        err(path, "title must be a string")
      elseif node.border == false then
        err(path, "title requires a border")
      end
    end
    if node.tag ~= nil and node.title == nil then
      err(path, "tag requires a title")
    end
  end

  if root == nil then
    return { "root: missing root card" }
  end
  if type(root) ~= "table" or not root.__card then
    return { "root: not a card (use ui.card{})" }
  end
  if root.body ~= nil then
    errors[#errors + 1] = "root: root card cannot have a body"
  end
  if root.children == nil then
    errors[#errors + 1] = "root: root card must be a container with children"
  end
  if root.height ~= nil or root.width ~= nil then
    errors[#errors + 1] = "root: height/width on root are ignored (the app sizes the window)"
  end
  walk(root, "root", true)

  if #errors > 0 then
    return errors
  end
  return nil
end

return M
