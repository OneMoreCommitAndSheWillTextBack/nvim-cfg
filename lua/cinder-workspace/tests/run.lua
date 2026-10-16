local source = debug.getinfo(1, "S").source:sub(2)
local plugin_root = vim.fn.fnamemodify(source, ":h:h")
vim.opt.rtp:prepend(plugin_root)

local uv = vim.uv
local workspace = require("cinder_workspace")
local config = require("cinder_workspace.config")
local view = require("cinder_workspace.view")

local original_cinder_workspace = vim.env.CINDER_WORKSPACE
local original_home = vim.env.HOME
local passed = 0
local failed = 0

local function mkdir(path)
  assert(vim.fn.mkdir(path, "p") == 1 or uv.fs_stat(path), "无法创建目录：" .. path)
  return path
end

local function write(path, content)
  local parent = vim.fs.dirname(path)
  mkdir(parent)
  local fd, err = uv.fs_open(path, "w", 420)
  assert(fd, tostring(err))
  assert(uv.fs_write(fd, content, 0) == #content)
  assert(uv.fs_close(fd))
end

local function remove(path)
  if uv.fs_lstat(path) then
    assert(vim.fn.delete(path, "rf") == 0, "无法清理测试目录：" .. path)
  end
end

local function expect_failure(value, err)
  assert(value == nil, "操作本应失败")
  assert(type(err) == "string" and err ~= "", "失败必须返回错误字符串")
end

local function with_temp_workspace(callback)
  local root = vim.fn.tempname()
  local base = mkdir(root .. "/base")
  local home = mkdir(root .. "/home")
  local sources = mkdir(root .. "/sources")
  local snapshot_dir = root .. "/snapshots"
  local paths = {
    root = root,
    base = base,
    home = home,
    sources = sources,
    snapshot_dir = snapshot_dir,
    alpha = mkdir(sources .. "/alpha"),
    beta = mkdir(sources .. "/beta"),
  }

  workspace.close()
  vim.env.CINDER_WORKSPACE = base
  vim.env.HOME = home
  local ok, err = xpcall(function()
    callback(paths)
  end, debug.traceback)
  workspace.close()
  vim.env.CINDER_WORKSPACE = original_cinder_workspace
  vim.env.HOME = original_home
  remove(root)
  if not ok then
    error(err)
  end
end

local function run_case(name, callback)
  local ok, err = xpcall(callback, debug.traceback)
  if ok then
    passed = passed + 1
    print("PASS " .. name)
  else
    failed = failed + 1
    print("FAIL " .. name .. "\n" .. err)
  end
end

run_case("new/open/current", function()
  with_temp_workspace(function(paths)
    local root, err = workspace.new("demo")
    assert(root, err)
    assert(root == paths.base .. "/demo")
    local snapshot, read_err = workspace.current()
    assert(snapshot, read_err)
    assert(snapshot.name == "demo")
    assert(snapshot.root == root)
    assert(#snapshot.folders == 0)
    assert(uv.fs_stat(root .. "/.cinder-workspace"))
    workspace.close()
    local opened, open_err = workspace.open(root)
    assert(opened, open_err)
    assert(workspace.current())
  end)
end)

run_case("attach/detach conflicts and source protection", function()
  with_temp_workspace(function(paths)
    local root, err = workspace.new("links")
    assert(root, err)
    local folder, attach_err = workspace.attach(paths.alpha, { name = "rtl" })
    assert(folder, attach_err)
    local duplicate, duplicate_err = workspace.attach(paths.alpha, { name = "other" })
    assert(duplicate, duplicate_err)
    assert(duplicate.name == "rtl")
    assert(not uv.fs_lstat(root .. "/other"))

    local conflict, conflict_err = workspace.attach(paths.beta, { name = "rtl" })
    expect_failure(conflict, conflict_err)
    write(root .. "/occupied", "keep")
    local occupied, occupied_err = workspace.attach(paths.beta, { name = "occupied" })
    expect_failure(occupied, occupied_err)

    assert(workspace.detach("missing"))
    assert(workspace.detach("rtl"))
    assert(not uv.fs_lstat(root .. "/rtl"))
    assert(uv.fs_stat(paths.alpha))
    assert(uv.fs_stat(root .. "/occupied"))
  end)
end)

run_case("attach file targets and cwd default", function()
  with_temp_workspace(function(paths)
    local root, err = workspace.new("files")
    assert(root, err)
    local file = paths.sources .. "/notes.md"
    write(file, "hello\n")
    local real_file = uv.fs_realpath(file)

    local entry, attach_err = workspace.attach(file)
    assert(entry, attach_err)
    assert(entry.name == "notes.md")
    assert(entry.type == "file")
    assert(uv.fs_readlink(root .. "/notes.md") == real_file)

    local duplicate, duplicate_err = workspace.attach(file)
    assert(duplicate, duplicate_err)
    assert(duplicate.name == "notes.md")

    local snapshot, read_err = workspace.current()
    assert(snapshot, read_err)
    assert(#snapshot.folders == 1)
    assert(snapshot.folders[1].name == "notes.md")

    workspace.setup()
    local original_cwd = vim.fn.getcwd()
    vim.cmd("cd " .. vim.fn.fnameescape(paths.beta))
    local command_ok = pcall(vim.cmd, "CinderWorkspace attach")
    local default, default_err = workspace.attach()
    vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
    assert(command_ok)
    assert(uv.fs_readlink(root .. "/beta") == uv.fs_realpath(paths.beta))
    assert(default, default_err)
    assert(default.name == "beta")

    local snapshot_path = paths.snapshot_dir .. "/files.json"
    local written, write_err = workspace.export(snapshot_path)
    assert(written, write_err)

    workspace.close()
    local second_base = mkdir(paths.root .. "/file-base")
    vim.env.CINDER_WORKSPACE = second_base
    local imported, import_err = workspace.import(snapshot_path)
    assert(imported, import_err)
    assert(uv.fs_readlink(imported .. "/notes.md") == real_file)

    assert(workspace.detach("notes.md"))
    assert(not uv.fs_lstat(imported .. "/notes.md"))
  end)
end)

run_case("invalid CINDER_WORKSPACE does not fall back", function()
  with_temp_workspace(function(paths)
    vim.env.CINDER_WORKSPACE = paths.root .. "/missing"
    vim.env.HOME = paths.home
    local root, err = workspace.new("should-fail")
    expect_failure(root, err)
    assert(not uv.fs_lstat(paths.home .. "/should-fail"))
  end)
end)

run_case("default base is created when CINDER_WORKSPACE is unset", function()
  with_temp_workspace(function(paths)
    vim.env.CINDER_WORKSPACE = nil
    local name = "cinder-test-" .. (paths.root:gsub("[^%w]", "-"))
    local root, err = workspace.new(name)
    assert(root == "/tmp/.cinder-workspace/" .. name, tostring(err))
    assert(uv.fs_stat(root .. "/.cinder-workspace"))
    local snapshot, read_err = workspace.current()
    assert(snapshot, read_err)
    assert(snapshot.root == root)
    assert(vim.fn.delete(root, "rf") == 0)
  end)
end)

run_case("snapshot export and import", function()
  with_temp_workspace(function(paths)
    local root, err = workspace.new("exported")
    assert(root, err)
    assert(workspace.attach(paths.alpha, { name = "alpha" }))
    assert(workspace.attach(paths.beta, { name = "beta" }))
    local snapshot_path = paths.snapshot_dir .. "/exported.json"
    local written, write_err = workspace.export(snapshot_path)
    assert(written, write_err)
    local document, read_err = config.read(snapshot_path)
    assert(document, read_err)
    assert(document.version == 1)
    assert(#document.folders == 2)

    workspace.close()
    local second_base = mkdir(paths.root .. "/second-base")
    vim.env.CINDER_WORKSPACE = second_base
    local imported, import_err = workspace.import(snapshot_path)
    assert(imported, import_err)
    assert(imported == second_base .. "/exported")
    local current, current_err = workspace.current()
    assert(current, current_err)
    assert(#current.folders == 2)
  end)
end)

run_case("invalid links remain readable and detachable", function()
  with_temp_workspace(function(paths)
    local root, err = workspace.new("broken")
    assert(root, err)
    assert(workspace.attach(paths.alpha, { name = "alpha" }))
    assert(uv.fs_rmdir(paths.alpha))
    local snapshot, read_err = workspace.current()
    assert(snapshot, read_err)
    assert(#snapshot.folders == 1)
    assert(snapshot.folders[1].name == "alpha")
    assert(workspace.detach("alpha"))
    assert(not uv.fs_lstat(root .. "/alpha"))
  end)
end)

run_case("command setup is idempotent", function()
  workspace.setup()
  workspace.setup()
  assert(vim.fn.exists(":CinderWorkspace") == 2)
end)

local function main()
  vim.env.CINDER_WORKSPACE = original_cinder_workspace
  vim.env.HOME = original_home
  print(("%d passed, %d failed"):format(passed, failed))
  if failed > 0 then
    vim.cmd("cquit 1")
  end
end

main()
