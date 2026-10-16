local uv = vim.uv

local M = {}

local MARKER_NAME = ".cinder-workspace"
local FILE_MODE = 420 -- 0644

local function fail(message, ...)
  return nil, message:format(...)
end

local function normalize_path(path)
  if type(path) ~= "string" or path == "" then
    return fail("快照路径必须是非空字符串")
  end
  if path:find("\0", 1, true) then
    return fail("快照路径不能包含 NUL 字符")
  end
  if path == "~" or vim.startswith(path, "~/") then
    local home = vim.env.HOME
    if type(home) ~= "string" or home == "" then
      return fail("无法展开快照路径中的 ~：HOME 未设置")
    end
    path = home .. path:sub(2)
  end
  if path:sub(1, 1) ~= "/" then
    path = vim.fs.joinpath(vim.fn.getcwd(), path)
  end
  return vim.fs.normalize(path)
end

local function is_missing(err)
  return tostring(err):find("ENOENT", 1, true) ~= nil
end

local function read_file(path)
  local fd, open_err = uv.fs_open(path, "r", 0)
  if not fd then
    return fail("无法读取快照 %s：%s", path, tostring(open_err))
  end
  local stat, stat_err = uv.fs_fstat(fd)
  if not stat then
    uv.fs_close(fd)
    return fail("无法读取快照 %s：%s", path, tostring(stat_err))
  end
  local content, read_err = uv.fs_read(fd, stat.size, 0)
  local closed, close_err = uv.fs_close(fd)
  if not content then
    return fail("无法读取快照 %s：%s", path, tostring(read_err))
  end
  if not closed then
    return fail("无法关闭快照 %s：%s", path, tostring(close_err))
  end
  return content
end

local function mkdir_parent(path)
  local parent = vim.fs.dirname(path)
  if parent == path or parent == "" then
    return true
  end
  local stat = uv.fs_stat(parent)
  if stat then
    if stat.type ~= "directory" then
      return fail("快照父路径不是目录：%s", parent)
    end
    return true
  end

  local ready, parent_err = mkdir_parent(parent)
  if not ready then
    return nil, parent_err
  end
  local made, mkdir_err = uv.fs_mkdir(parent, 493)
  if not made then
    local existing = uv.fs_stat(parent)
    if existing and existing.type == "directory" then
      return true
    end
    return fail("无法创建快照父目录 %s：%s", parent, tostring(mkdir_err))
  end
  return true
end

local function write_fd(fd, content, path)
  local written, write_err = uv.fs_write(fd, content, 0)
  if not written or written ~= #content then
    uv.fs_close(fd)
    return fail("无法写入快照 %s：%s", path, tostring(write_err))
  end
  local closed, close_err = uv.fs_close(fd)
  if not closed then
    return fail("无法关闭快照 %s：%s", path, tostring(close_err))
  end
  return true
end

local function write_atomic(path, content)
  local base = vim.fs.basename(path)
  if base == MARKER_NAME then
    return fail("快照不能使用工作区 marker 文件名：%s", path)
  end

  local existing, existing_err = uv.fs_lstat(path)
  if existing then
    if existing.type ~= "file" then
      return fail("快照目标必须是普通文件：%s", path)
    end
  elseif not is_missing(existing_err) then
    return fail("无法检查快照目标 %s：%s", path, tostring(existing_err))
  end

  local parent_ready, parent_err = mkdir_parent(path)
  if not parent_ready then
    return nil, parent_err
  end

  local template = vim.fs.joinpath(vim.fs.dirname(path), "." .. base .. ".tmp-XXXXXX")
  local fd, temporary = uv.fs_mkstemp(template)
  if not fd then
    return fail("无法创建快照临时文件：%s", tostring(temporary))
  end

  local written, write_err = write_fd(fd, content, temporary)
  if not written then
    uv.fs_unlink(temporary)
    return nil, write_err
  end

  local renamed, rename_err = uv.fs_rename(temporary, path)
  if not renamed then
    uv.fs_unlink(temporary)
    return fail("无法替换快照 %s：%s", path, tostring(rename_err))
  end
  return true
end

local function copy_document(document)
  local folders = {}
  for index, folder in ipairs(document.folders) do
    folders[index] = { name = folder.name, path = folder.path }
  end
  return { version = document.version, name = document.name, folders = folders }
end

local function is_dense_array(value)
  if type(value) ~= "table" then
    return false
  end
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return false
    end
    count = count + 1
  end
  if count == 0 then
    return vim.islist(value)
  end
  for index = 1, count do
    if value[index] == nil then
      return false
    end
  end
  return true
end

local function validate_document(document)
  if type(document) ~= "table" or vim.islist(document) then
    return fail("快照根必须是对象")
  end
  if document.version ~= 1 then
    return fail("不支持的快照版本：%s", tostring(document.version))
  end
  if type(document.name) ~= "string" or document.name == "" then
    return fail("快照 name 必须是非空字符串")
  end
  -- Neovim decodes a nested JSON [] as an untagged empty table. Treat every
  -- dense numeric table as an array so empty workspace snapshots remain valid.
  if not is_dense_array(document.folders) then
    return fail("快照 folders 必须是数组")
  end
  for index, folder in ipairs(document.folders) do
    if type(folder) ~= "table" or vim.islist(folder) then
      return fail("快照 folders[%d] 必须是对象", index)
    end
    if type(folder.name) ~= "string" or folder.name == "" then
      return fail("快照 folders[%d].name 必须是非空字符串", index)
    end
    if type(folder.path) ~= "string" or folder.path == "" then
      return fail("快照 folders[%d].path 必须是非空字符串", index)
    end
    if folder.path:find("\0", 1, true) then
      return fail("快照 folders[%d].path 不能包含 NUL 字符", index)
    end
  end
  return true
end

local function make_absolute_folder_path(config_dir, path)
  if path == "~" or vim.startswith(path, "~/") then
    local home = vim.env.HOME
    if type(home) ~= "string" or home == "" then
      return fail("无法展开快照 folder 路径中的 ~：HOME 未设置")
    end
    path = home .. path:sub(2)
  end
  if path:sub(1, 1) ~= "/" then
    path = vim.fs.joinpath(config_dir, path)
  end
  return vim.fs.normalize(path)
end

function M.read(path)
  local normalized, path_err = normalize_path(path)
  if not normalized then
    return nil, path_err
  end
  local stat, stat_err = uv.fs_lstat(normalized)
  if not stat then
    return fail("快照不存在：%s（%s）", normalized, tostring(stat_err))
  end
  if stat.type ~= "file" then
    return fail("快照必须是普通文件：%s", normalized)
  end

  local content, read_err = read_file(normalized)
  if not content then
    return nil, read_err
  end
  local ok, document = pcall(vim.json.decode, content)
  if not ok then
    return fail("快照 JSON 无效：%s", tostring(document))
  end
  local valid, validation_err = validate_document(document)
  if not valid then
    return nil, validation_err
  end

  local resolved = copy_document(document)
  local config_dir = vim.fs.dirname(normalized)
  for _, folder in ipairs(resolved.folders) do
    local absolute, absolute_err = make_absolute_folder_path(config_dir, folder.path)
    if not absolute then
      return nil, absolute_err
    end
    folder.path = absolute
  end
  return resolved
end

function M.write(path, document)
  local normalized, path_err = normalize_path(path)
  if not normalized then
    return nil, path_err
  end
  local valid, validation_err = validate_document(document)
  if not valid then
    return nil, validation_err
  end

  local copy = copy_document(document)
  table.sort(copy.folders, function(left, right)
    return left.name < right.name
  end)
  local config_dir = vim.fs.dirname(normalized)
  for _, folder in ipairs(copy.folders) do
    local absolute, absolute_err = make_absolute_folder_path(config_dir, folder.path)
    if not absolute then
      return nil, absolute_err
    end
    local relative = vim.fs.relpath(config_dir, absolute)
    folder.path = relative or absolute
  end

  local ok, encoded_or_err = pcall(vim.json.encode, copy)
  if not ok then
    return fail("无法编码快照 JSON：%s", tostring(encoded_or_err))
  end
  local written, write_err = write_atomic(normalized, encoded_or_err .. "\n")
  if not written then
    return nil, write_err
  end

  if vim.env.CINDER_WORKSPACE ~= nil then
    local list_path = vim.env.CINDER_WORKSPACE .. "/workspace-list.txt"
    -- `mode` 只在文件被创建时生效；之前的 0 会让新文件以 0000 落盘，
    -- 于是第二次 append 一律 EACCES。
    local fd, open_err = uv.fs_open(list_path, "a", FILE_MODE)
    if not fd then
      return fail("无法打开list文件 %s：%s", list_path, tostring(open_err))
    end
    local record = vim.json.encode({ name = document.name, path = normalized })
    local content = record .. "\n"
    local written_list, write_err_list = uv.fs_write(fd, content)
    if not written_list or written_list ~= #content then
      uv.fs_close(fd)
      return fail("无法写入list文件 %s：%s", list_path, tostring(write_err_list))
    end
    uv.fs_close(fd)
  end

  return normalized
end

function M.read_list()
  if vim.env.CINDER_WORKSPACE == nil then
    return fail("请指定CINDER_WORKSPACE环境变量，list文件被创建当且仅当此变量被设置")
  end
end

return M
