local M = {}

local function open_explorer(root)
  return Snacks.explorer({ cwd = root })
end

function M.open(mode)
  mode = mode or "project"
  if mode ~= "project" and mode ~= "cwd" then
    vim.notify("未知 explorer 模式: " .. tostring(mode), vim.log.levels.ERROR)
    return nil
  end

  local workspace = require("cinder_workspace")
  local snapshot, err = workspace.current()
  if err then
    vim.notify(err, vim.log.levels.ERROR)
    return nil
  end

  local root
  if snapshot then
    root = snapshot.root
  elseif mode == "cwd" then
    root = vim.fn.getcwd()
  else
    root = LazyVim.root()
  end
  return open_explorer(root)
end

return M
