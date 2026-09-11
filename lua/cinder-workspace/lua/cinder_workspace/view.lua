local uv = vim.uv

local M = {}

local MARKER_NAME = ".cinder-workspace"
local MARKER_PLUGIN = "cinder-workspace"
local MARKER_VERSION = 1
local DIRECTORY_MODE = 493 -- 0755
local FILE_MODE = 420 -- 0644

local function fail(message, ...)
  return nil, message:format(...)
end

local function is_missing(err)
  return tostring(err):find("ENOENT", 1, true) ~= nil
end

local function is_absolute(path)
  return path:sub(1, 1) == "/"
end

local function expand_home(path)
  if path == "~" or vim.startswith(path, "~/") then
    local home = vim.env.HOME
    if type(home) ~= "string" or home == "" then
      return fail("无法展开 ~：HOME 未设置")
    end
    return home .. path:sub(2)
  end
  return path
end

local function normalize_path(path, base)
  if type(path) ~= "string" or path == "" then
    return fail("路径必须是非空字符串")
  end
  if path:find("\0", 1, true) then
    return fail("路径不能包含 NUL 字符")
  end

  local expanded, err = expand_home(path)
  if not expanded then
    return nil, err
  end
  if not is_absolute(expanded) then
    base = base or vim.fn.getcwd()
    expanded = vim.fs.joinpath(base, expanded)
  end
  return vim.fs.normalize(expanded)
end

local function lstat(path)
  local stat, err = uv.fs_lstat(path)
  return stat, err
end

local function read_file(path)
  local fd, open_err = uv.fs_open(path, "r", 0)
  if not fd then
    return fail("无法读取 %s：%s", path, tostring(open_err))
  end

  local stat, stat_err = uv.fs_fstat(fd)
  if not stat then
    uv.fs_close(fd)
    return fail("无法读取 %s：%s", path, tostring(stat_err))
  end

  local content, read_err = uv.fs_read(fd, stat.size, 0)
  local closed, close_err = uv.fs_close(fd)
  if not content then
    return fail("无法读取 %s：%s", path, tostring(read_err))
  end
  if not closed then
    return fail("无法关闭 %s：%s", path, tostring(close_err))
  end
  return content
end

local function write_file(path, content)
  local fd, open_err = uv.fs_open(path, "wx", FILE_MODE)
  if not fd then
    return fail("无法写入 %s：%s", path, tostring(open_err))
  end

  local written, write_err = uv.fs_write(fd, content, 0)
  local closed, close_err = uv.fs_close(fd)
  if not written or written ~= #content then
    return fail("无法写入 %s：%s", path, tostring(write_err))
  end
  if not closed then
    return fail("无法关闭 %s：%s", path, tostring(close_err))
  end
  return true
end

local function validate_name(name, is_alias)
  if type(name) ~= "string" or name == "" then
    return fail("名称必须是非空字符串")
  end
  if name == "." or name == ".." then
    return fail("名称不能是 %s", name)
  end
  if name:find("\0", 1, true) or name:find("/", 1, true) or name:find("\\", 1, true) then
    return fail("名称必须是单层目录名：%s", name)
  end
  if is_alias and name == MARKER_NAME then
    return fail("%s 是工作区保留名称", MARKER_NAME)
  end
  return true
end

local function validate_base(path, variable_name)
  if not is_absolute(path) then
    return fail("%s 必须是绝对路径：%s", variable_name, path)
  end

  local normalized = vim.fs.normalize(path)
  local stat, stat_err = uv.fs_stat(normalized)
  if not stat then
    return fail("%s 不可访问：%s", variable_name, tostring(stat_err))
  end
  if stat.type ~= "directory" then
    return fail("%s 必须指向目录：%s", variable_name, normalized)
  end
  if not uv.fs_access(normalized, "R") or not uv.fs_access(normalized, "X") then
    return fail("%s 当前不可访问：%s", variable_name, normalized)
  end
  return normalized
end

local function resolve_base()
  local cinder_workspace = vim.env.CINDER_WORKSPACE
  if type(cinder_workspace) == "string" and cinder_workspace ~= "" then
    return validate_base(cinder_workspace, "CINDER_WORKSPACE")
  end

  return "/tmp/.cinder-workspace"
end

local function marker_content()
  return vim.json.encode({ plugin = MARKER_PLUGIN, version = MARKER_VERSION }) .. "\n"
end

local function marker_is_valid(path)
  local stat, stat_err = lstat(path)
  if not stat then
    return fail("工作区 marker 不存在：%s", tostring(stat_err))
  end
  if stat.type ~= "file" then
    return fail("工作区 marker 必须是普通文件：%s", path)
  end

  local content, read_err = read_file(path)
  if not content then
    return nil, read_err
  end
  local ok, marker = pcall(vim.json.decode, content)
  if not ok or type(marker) ~= "table" then
    return fail("工作区 marker 格式无效：%s", path)
  end
  if marker.plugin ~= MARKER_PLUGIN or marker.version ~= MARKER_VERSION then
    return fail("工作区 marker 不属于 cinder-workspace：%s", path)
  end
  return true
end

local function validate_workspace(root)
  local normalized, normalize_err = normalize_path(root)
  if not normalized then
    return nil, normalize_err
  end

  local stat, stat_err = lstat(normalized)
  if not stat then
    return fail("工作区目录不存在：%s", tostring(stat_err))
  end
  if stat.type ~= "directory" then
    return fail("工作区 root 必须是实际目录：%s", normalized)
  end
  if not uv.fs_access(normalized, "R") or not uv.fs_access(normalized, "X") then
    return fail("工作区目录当前不可访问：%s", normalized)
  end

  local valid_name, name_err = validate_name(vim.fs.basename(normalized), false)
  if not valid_name then
    return nil, name_err
  end

  local marker_ok, marker_err = marker_is_valid(vim.fs.joinpath(normalized, MARKER_NAME))
  if not marker_ok then
    return nil, marker_err
  end
  return normalized
end

local function resolve_link_target(link_path, target)
  return normalize_path(target, vim.fs.dirname(link_path))
end

local function read_folders(root)
  local scan, scan_err = uv.fs_scandir(root)
  if not scan then
    return fail("无法读取工作区目录 %s：%s", root, tostring(scan_err))
  end

  local folders = {}
  while true do
    local name = uv.fs_scandir_next(scan)
    if not name then
      break
    end
    if name ~= MARKER_NAME then
      local link_path = vim.fs.joinpath(root, name)
      local stat, stat_err = lstat(link_path)
      if not stat then
        return fail("无法读取工作区条目 %s：%s", link_path, tostring(stat_err))
      end
      if stat.type == "link" then
        local target, link_err = uv.fs_readlink(link_path)
        if not target then
          return fail("无法读取链接 %s：%s", link_path, tostring(link_err))
        end
        local resolved, resolve_err = resolve_link_target(link_path, target)
        if not resolved then
          return nil, resolve_err
        end
        folders[#folders + 1] = { name = name, path = resolved }
      end
    end
  end

  table.sort(folders, function(left, right)
    return left.name < right.name
  end)
  return folders
end

local function resolve_folder(path, alias)
  local normalized, normalize_err = normalize_path(path)
  if not normalized then
    return nil, normalize_err
  end
  alias = alias or vim.fs.basename(normalized)
  local valid_name, name_err = validate_name(alias, true)
  if not valid_name then
    return nil, name_err
  end

  local real_path, real_err = uv.fs_realpath(normalized)
  if not real_path then
    return fail("绑定目录不存在或不可访问：%s（%s）", normalized, tostring(real_err))
  end
  local stat, stat_err = uv.fs_stat(real_path)
  if not stat then
    return fail("无法检查绑定目录 %s：%s", real_path, tostring(stat_err))
  end
  if stat.type ~= "directory" then
    return fail("绑定目标必须是目录：%s", normalized)
  end
  if not uv.fs_access(real_path, "R") or not uv.fs_access(real_path, "X") then
    return fail("绑定目录当前不可访问：%s", real_path)
  end
  return { name = alias, path = real_path }
end

local function assert_dense_array(value, label)
  if type(value) ~= "table" then
    return fail("%s 必须是数组", label)
  end
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return fail("%s 必须是连续数组", label)
    end
    count = count + 1
  end
  for index = 1, count do
    if value[index] == nil then
      return fail("%s 必须是连续数组", label)
    end
  end
  return count
end

function M.validate_folders(folders)
  local count, count_err = assert_dense_array(folders, "folders")
  if not count then
    return nil, count_err
  end

  local result = {}
  local by_name = {}
  local by_path = {}
  for index = 1, count do
    local item = folders[index]
    if type(item) ~= "table" then
      return fail("folders[%d] 必须是对象", index)
    end
    if type(item.name) ~= "string" or item.name == "" then
      return fail("folders[%d].name 必须是非空字符串", index)
    end
    if type(item.path) ~= "string" or item.path == "" then
      return fail("folders[%d].path 必须是非空字符串", index)
    end
    local folder, folder_err = resolve_folder(item.path, item.name)
    if not folder then
      return nil, folder_err
    end
    if by_name[folder.name] then
      return fail("folder 名称重复：%s", folder.name)
    end
    if by_path[folder.path] then
      return fail("同一目录不能重复绑定：%s", folder.path)
    end
    by_name[folder.name] = true
    by_path[folder.path] = true
    result[#result + 1] = folder
  end
  return result
end

local function link_points_to(link_path, expected_path)
  local target = uv.fs_readlink(link_path)
  if not target then
    return false
  end
  local resolved = resolve_link_target(link_path, target)
  return resolved == expected_path
end

local function rollback_created(root, links, marker_created)
  local leftovers = {}

  for index = #links, 1, -1 do
    local folder = links[index]
    local link_path = vim.fs.joinpath(root, folder.name)
    local stat = lstat(link_path)
    if stat then
      if stat.type == "link" and link_points_to(link_path, folder.path) and uv.fs_unlink(link_path) then
        -- The link still belongs to this failed create operation.
      else
        leftovers[#leftovers + 1] = link_path
      end
    end
  end

  local marker_path = vim.fs.joinpath(root, MARKER_NAME)
  if marker_created then
    local marker_ok = marker_is_valid(marker_path)
    if marker_ok then
      if not uv.fs_unlink(marker_path) then
        leftovers[#leftovers + 1] = marker_path
      end
    else
      leftovers[#leftovers + 1] = marker_path
    end
  end

  local removed, remove_err = uv.fs_rmdir(root)
  if not removed then
    leftovers[#leftovers + 1] = root
    return nil, ("回滚未完成：%s（%s）"):format(table.concat(leftovers, ", "), tostring(remove_err))
  end
  if #leftovers > 0 then
    return nil, "回滚未完成：" .. table.concat(leftovers, ", ")
  end
  return true
end

function M.create(name, folders)
  local valid_name, name_err = validate_name(name, false)
  if not valid_name then
    return nil, name_err
  end
  folders = folders or {}
  local normalized_folders, folders_err = M.validate_folders(folders)
  if not normalized_folders then
    return nil, folders_err
  end

  local base, base_err = resolve_base()
  if not base then
    return nil, base_err
  end
  local root = vim.fs.joinpath(base, name)
  local existing, existing_err = lstat(root)
  if existing then
    if existing.type == "directory" then
      local valid = marker_is_valid(vim.fs.joinpath(root,MARKER_NAME))
      if not valid then
        return fail("base目录之中存在同名非工作区文件夹，拒绝创建")
      end
      local ok, rm_err = pcall(vim.fs.rm, root, { recursive = true })
      if not ok then
        return fail("无法删除已存在的工作区 root %s：%s", root, tostring(rm_err))
      end else
      return fail("base目录之中存在同名文件，无法创建工作区")
    end
  end
  if not is_missing(existing_err) then
    return fail("无法检查工作区 root %s：%s", root, tostring(existing_err))
  end

  local made_root, mkdir_err = uv.fs_mkdir(root, DIRECTORY_MODE)
  if not made_root then
    return fail("无法创建工作区 root %s：%s", root, tostring(mkdir_err))
  end

  local marker_path = vim.fs.joinpath(root, MARKER_NAME)
  local marker_ok, marker_err = write_file(marker_path, marker_content())
  if not marker_ok then
    local _, rollback_err = rollback_created(root, {}, true)
    local message = marker_err
    if rollback_err then
      message = message .. "；" .. rollback_err
    end
    return nil, message
  end

  local created_links = {}
  for _, folder in ipairs(normalized_folders) do
    local link_path = vim.fs.joinpath(root, folder.name)
    local linked, link_err = uv.fs_symlink(folder.path, link_path)
    if not linked then
      local _, rollback_err = rollback_created(root, created_links, true)
      local message = ("无法创建链接 %s：%s"):format(link_path, tostring(link_err))
      if rollback_err then
        message = message .. "；" .. rollback_err
      end
      return nil, message
    end
    created_links[#created_links + 1] = folder
  end
  return root
end

function M.read(root)
  local normalized, workspace_err = validate_workspace(root)
  if not normalized then
    return nil, workspace_err
  end
  local folders, folders_err = read_folders(normalized)
  if not folders then
    return nil, folders_err
  end
  return {
    name = vim.fs.basename(normalized),
    root = normalized,
    folders = folders,
  }
end

function M.attach(root, path, opts)
  if opts ~= nil and type(opts) ~= "table" then
    return fail("attach 的 opts 必须是 table")
  end
  opts = opts or {}
  for key in pairs(opts) do
    if key ~= "name" then
      return fail("attach 不支持 opts.%s", tostring(key))
    end
  end

  local workspace, workspace_err = M.read(root)
  if not workspace then
    return nil, workspace_err
  end
  local folder, folder_err = resolve_folder(path, opts.name)
  if not folder then
    return nil, folder_err
  end

  for _, existing in ipairs(workspace.folders) do
    if existing.name == folder.name then
      local existing_real = uv.fs_realpath(existing.path)
      if existing_real == folder.path then
        return existing
      end
      return fail("folder 名称已被其他目标使用：%s", folder.name)
    end
  end
  for _, existing in ipairs(workspace.folders) do
    local existing_real = uv.fs_realpath(existing.path)
    if existing_real == folder.path then
      return existing
    end
  end

  local link_path = vim.fs.joinpath(workspace.root, folder.name)
  local existing, existing_err = lstat(link_path)
  if existing then
    return fail("目标位置已被占用，拒绝覆盖：%s", link_path)
  end
  if not is_missing(existing_err) then
    return fail("无法检查链接位置 %s：%s", link_path, tostring(existing_err))
  end

  local linked, link_err = uv.fs_symlink(folder.path, link_path)
  if not linked then
    return fail("无法创建链接 %s：%s", link_path, tostring(link_err))
  end
  return folder
end

function M.detach(root, name)
  local valid_name, name_err = validate_name(name, true)
  if not valid_name then
    return nil, name_err
  end
  local workspace_root, workspace_err = validate_workspace(root)
  if not workspace_root then
    return nil, workspace_err
  end

  local link_path = vim.fs.joinpath(workspace_root, name)
  local stat, stat_err = lstat(link_path)
  if not stat then
    if is_missing(stat_err) then
      return true
    end
    return fail("无法检查链接 %s：%s", link_path, tostring(stat_err))
  end
  if stat.type ~= "link" then
    return fail("只能删除工作区链接，拒绝删除 %s", link_path)
  end
  local removed, remove_err = uv.fs_unlink(link_path)
  if not removed then
    return fail("无法删除链接 %s：%s", link_path, tostring(remove_err))
  end
  return true
end

return M
