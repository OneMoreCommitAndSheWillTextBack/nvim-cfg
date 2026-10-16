local view = require("cinder_workspace.view")
local config = require("cinder_workspace.config")

local M = {}
local state = {
  configured = false,
  current_root = nil,
}

local function fail(message)
  return nil, message
end

local function current_root()
  if not state.current_root then
    return fail("当前没有打开的工作区")
  end
  return state.current_root
end

function M.setup()
  if state.configured then
    return M
  end
  require("cinder_workspace.commands").setup(M)
  state.configured = true
  return M
end

function M.new(name)
  local root, err = view.create(name)
  if not root then
    return nil, err
  end
  state.current_root = root
  return root
end

function M.open(root)
  local snapshot, err = view.read(root)
  if not snapshot then
    return nil, err
  end
  state.current_root = snapshot.root
  return snapshot.root
end

function M.current()
  if not state.current_root then
    return nil
  end
  return view.read(state.current_root)
end

function M.attach(path, opts)
  local root, err = current_root()
  if not root then
    return nil, err
  end
  return view.attach(root, path, opts)
end

function M.detach(name)
  local root, err = current_root()
  if not root then
    return nil, err
  end
  return view.detach(root, name)
end

function M.close()
  state.current_root = nil
  return true
end

function M.export(path)
  local root, err = current_root()
  if not root then
    return nil, err
  end
  local snapshot, read_err = view.read(root)
  if not snapshot then
    return nil, read_err
  end
  local folders, folders_err = view.validate_folders(snapshot.folders)
  if not folders then
    return nil, folders_err
  end

  -- 无参 export 时落到 CINDER_WORKSPACE 下并按工作区名命名快照
  -- （这里必须拼出文件路径：config.write 只接受普通文件目标）。
  if path == nil and vim.env.CINDER_WORKSPACE ~= nil then
    path = vim.fs.joinpath(vim.env.CINDER_WORKSPACE, snapshot.name .. ".json")
  end

  return config.write(path, {
    version = 1,
    name = snapshot.name,
    folders = folders,
  })
end

function M.import(path)
  local document, err = config.read(path)
  if not document then
    return nil, err
  end
  local root, create_err = view.create(document.name, document.folders)
  if not root then
    return nil, create_err
  end
  state.current_root = root
  return root
end

return M
