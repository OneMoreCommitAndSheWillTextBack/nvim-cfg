local M = {}

local SUBCOMMANDS = {
  "new",
  "open",
  "attach",
  "detach",
  "close",
  "list",
  "export",
  "import",
}

local function notify_error(err)
  if err and err ~= "" then
    vim.notify(err, vim.log.levels.ERROR)
  end
end

local function split_args(args)
  local result = {}
  for _, value in ipairs(args.fargs or {}) do
    result[#result + 1] = value
  end
  return result
end

local function require_arg(args, index, usage)
  local value = args[index]
  if not value or value == "" then
    vim.notify("用法：" .. usage, vim.log.levels.ERROR)
    return nil
  end
  return value
end

local function print_snapshot(snapshot)
  local lines = {
    ("工作区: %s"):format(snapshot.name),
    ("根目录: %s"):format(snapshot.root),
  }
  if #snapshot.folders == 0 then
    lines[#lines + 1] = "目录: （空）"
  else
    lines[#lines + 1] = "目录:"
    for _, folder in ipairs(snapshot.folders) do
      lines[#lines + 1] = ("  %s -> %s"):format(folder.name, folder.path)
    end
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

local function execute(api, command)
  local args = split_args(command)
  local subcommand = args[1]
  if subcommand == "new" then
    local name = require_arg(args, 2, ":CinderWorkspace new {name}")
    if not name then
      return
    end
    local _, err = api.new(name)
    notify_error(err)
  elseif subcommand == "open" then
    local root = require_arg(args, 2, ":CinderWorkspace open {root}")
    if not root then
      return
    end
    local _, err = api.open(root)
    notify_error(err)
  elseif subcommand == "attach" then
    local path = args[2] ~= "" and args[2] or nil
    local opts = args[3] and { name = args[3] } or nil
    local _, err = api.attach(path, opts)
    notify_error(err)
  elseif subcommand == "detach" then
    local name = require_arg(args, 2, ":CinderWorkspace detach {name}")
    if not name then
      return
    end
    local _, err = api.detach(name)
    notify_error(err)
  elseif subcommand == "close" then
    api.close()
  elseif subcommand == "list" then
    local snapshot, err = api.current()
    if err then
      notify_error(err)
    elseif snapshot then
      print_snapshot(snapshot)
    else
      vim.notify("当前没有打开的工作区", vim.log.levels.INFO)
    end
  elseif subcommand == "export" then
    local path = require_arg(args, 2, ":CinderWorkspace export {path}")
    if not path then
      return
    end
    local _, err = api.export(path)
    notify_error(err)
  elseif subcommand == "import" then
    local path = require_arg(args, 2, ":CinderWorkspace import {path}")
    if not path then
      return
    end
    local _, err = api.import(path)
    notify_error(err)
  else
    vim.notify("用法：:CinderWorkspace " .. table.concat(SUBCOMMANDS, "|") .. " ...", vim.log.levels.ERROR)
  end
end

local function complete(api, arglead, cmdline, cursorpos)
  local parts = vim.split(cmdline:sub(1, cursorpos), "%s+", { trimempty = true })
  local trailing_space = cmdline:sub(1, cursorpos):match("%s$") ~= nil
  if #parts == 1 or (#parts == 2 and not trailing_space) then
    return vim.tbl_filter(function(value)
      return vim.startswith(value, arglead)
    end, SUBCOMMANDS)
  end

  local subcommand = parts[2]
  if subcommand == "detach" then
    local snapshot = api.current()
    if not snapshot then
      return {}
    end
    return vim.tbl_map(function(folder)
      return folder.name
    end, snapshot.folders)
  end
  if subcommand == "new" or subcommand == "close" or subcommand == "list" then
    return {}
  end
  return vim.fn.getcompletion(arglead, "file")
end

function M.setup(api)
  pcall(vim.api.nvim_del_user_command, "CinderWorkspace")
  vim.api.nvim_create_user_command("CinderWorkspace", function(command)
    execute(api, command)
  end, {
    nargs = "+",
    complete = function(arglead, cmdline, cursorpos)
      return complete(api, arglead, cmdline, cursorpos)
    end,
    desc = "Manage cinder workspaces",
  })
end

return M
