# cinder-workspace 实现计划

行为契约以 [des.md](des.md) 为准。本计划按文件列出要实现的函数、参数、返回值和作用，
并规定交付顺序与验收。只规划现有职责需要的函数，不增加类型层级或逐模块测试框架。

## 1. 最小结构

```text
lua/cinder-workspace/
├── lua/cinder_workspace/
│   ├── init.lua
│   ├── view.lua
│   ├── config.lua
│   └── commands.lua
├── doc/
│   ├── des.md
│   ├── plan.md
│   └── cinder_workspace.txt
├── tests/
│   └── run.lua
└── README.md

lua/config/explorer.lua          # 唯一 explorer 包装 API
lua/plugins/cinder-workspace.lua # Lazy 加载与 Snacks 按键接线
```

| 模块 | 职责 |
| --- | --- |
| `init.lua` | 公开 API、当前 root、顺序调用 view/config；不实现 Workspace 类 |
| `view.lua` | root/marker、名称与路径校验、读取链接、attach/detach、创建及失败回滚 |
| `config.lua` | JSON schema、路径序列化、读写快照；不接收或修改全局状态 |
| `commands.lua` | 命令参数、补全、列表显示、入口错误通知 |
| 配置侧 explorer | 根据 current 和 mode 选目录，把目录交给原 explorer |

`init` 调用 `view/config`，setup 把公开 API 交给 commands 注册命令，
commands 不反向 require init。config 解析后的 folders 交给 view 统一验证目标和 alias。
原子文件写入留在 config，marker 操作留在 view，环境变量解析作为 view 的私有函数。
只提取真正重复的规则，不为 `stat/lstat/unlink` 逐个制作包装函数。

由 Lazy 的 `main = "cinder_workspace"`、`opts = {}` 调用 setup，首版 `lazy = false`。
setup 只注册命令，不创建目录；不增加只有 require 语句的 plugin 入口或生命周期 autocmd。

## 2. 状态与操作原则

业务状态只保存一项：

```lua
local current_root = nil -- string?，选中的工作区绝对路径
```

current 每次读取目录，返回独立快照；修改返回值不改变内部状态。
没有 folders 缓存、两个去重索引、实例集合、active/persisted 标志或历史 config_path。
名称、链接路径等能够从 root 和目录项推导的信息不再分别保存。

操作保持直接的顺序流程，具体调用关系见第 3 节。只有 new/open/import 成功后才更新
current_root；失败保留旧选择。attach/detach 直接修改链接，close 只清空选择。

root 最后一层和 marker 必须分别是真实目录、普通文件，不能用符号链接替代。
读取目录时只扫描直接子项；失效链接保留名称和目标，列表可标注“目标不可用”。
外部加入的真实文件/目录不计入 folders；同名对象仍会阻止 attach/detach。

新建时使用局部列表记录本次创建物，足够处理失败回滚，不建立事务类或资源 registry。
清理只 unlink 仍为预期目标的链接、删除本次写入的 marker、rmdir 空 root；
遇到外部对象或清理失败，保留残留并把路径附加到原始错误。

核心函数返回成功值或 `nil, err`，不通知。命令和 explorer 入口各自负责通知一次；
回滚错误合并到返回字符串，不增加错误类型、错误码和错误包装器。

## 3. 按文件实现的函数

下面的表格列出成功返回值。除另行说明的入口、回调外，预期失败统一返回
`nil, err`，err 为字符串，不抛出业务异常、不调用 `vim.notify`。
“无返回值”表示调用者不消费结果；`?` 表示可省略的参数。

参数和返回值中的几个名称只是普通 Lua table 的简称，不定义类：

| 名称 | 内容 |
| --- | --- |
| `Folder` | `{ name = string, path = string }`；path 是绝对目标路径 |
| `Snapshot` | `{ name = string, root = string, folders = Folder[] }`；从目录读取的独立快照 |
| `Document` | `{ version = 1, name = string, folders = { { name = string, path = string }, ... } }`；JSON 文档对应的 table |

`Snapshot` 中的链接目标可能失效；需要有效目录的操作再调用 view 校验。
普通路径参数支持 `~`，相对路径按调用时 cwd 解析；JSON 内部的相对路径按配置文件目录解析。
只有 init 的 `M.*` 是插件公开 API；view/config 的 `M.*` 是模块间接口，其余标为私有的函数使用 local。

### 3.1 `lua/cinder_workspace/init.lua`

文件最后返回模块表 `M`，只持有 current_root，负责组合操作。

| 函数与参数 | 成功返回值 | 作用 |
| --- | --- | --- |
| `M.setup()` | 无返回值 | 调用 `commands.setup(M)` 注册命令，允许重复调用；不创建或打开工作区 |
| `M.new(name)` | `string`：绝对 root | 调用 `view.create(name)` 创建空工作区，成功后选中它 |
| `M.open(root)` | `string`：绝对 root | 调用 `view.read(root)` 验证已有工作区，成功后保存返回快照中的 root |
| `M.current()` | `Snapshot`；未选择时为 `nil` | 未选择时直接返回 nil，否则调用 `view.read(current_root)`；读取失败返回 `nil, err` |
| `M.attach(path, opts?)` | `Folder` | opts 只接受可选的 `name`；path 省略时由 `view.attach` 取当前 cwd；取得当前 root 后调用 `view.attach` |
| `M.detach(name)` | `true` | 取得当前 root 后调用 `view.detach`，不更新 JSON 或其他内存状态 |
| `M.close()` | `true` | 将 current_root 置为 nil；重复调用也成功，不访问磁盘 |
| `M.export(path)` | `string`：快照文件绝对路径 | 读取当前快照，用 `view.validate_folders` 校验目标，组装 Document 后调用 `config.write` |
| `M.import(path)` | `string`：绝对 root | 调用 `config.read`，再用文档的 name/folders 调用 `view.create`，成功后选中新工作区 |
| `get_current_root()`（私有） | `string`：当前 root | 当前没有选择时返回 `nil, err`；只检查是否已选择，目录有效性由后续 view 操作检查 |

`setup` 是注册入口，不定义业务失败返回值。`new/open/import` 不要求先 close，
也不删除旧工作区。`export` 不把快照文件路径保存到状态中。

### 3.2 `lua/cinder_workspace/view.lua`

负责目录与链接操作，所有函数均不读写 init 的 current_root。

| 函数与参数 | 成功返回值 | 作用 |
| --- | --- | --- |
| `M.create(name, folders?)` | `string`：绝对 root | folders 默认空数组；校验名称、base 和全部 folders，创建 root、链接，最后写 marker；中途失败调用局部回滚 |
| `M.read(root)` | `Snapshot` | 规范化 root，验证真实目录和普通 marker，读取直接子项中的链接；失效链接仍保留在结果中 |
| `M.attach(root, path, opts?)` | `Folder` | 读取已有工作区，解析输入路径和 alias，path 为 nil 时取当前 cwd；先检查 alias 冲突再按真实目标去重，返回已有项或创建一个链接 |
| `M.detach(root, name)` | `true` | 验证 root/marker 和 alias；链接不存在时成功，存在时只允许 unlink 符号链接 |
| `M.validate_folders(folders)` | `Folder[]`：新的规范化数组 | 校验 alias、目标（目录或文件）及重复名称/真实路径；将目标转成 realpath，不修改输入数组、不写磁盘 |
| `resolve_base()`（私有） | `string`：绝对 base | 非空 CINDER_WORKSPACE 交给 validate_base；否则使用默认目录 `/tmp/.cinder-workspace`，缺失时按 0755 创建 |
| `validate_name(name, is_alias?)`（私有） | `true` | 检查单层安全名称；is_alias 为 true 时额外拒绝 marker 保留名称 |
| `resolve_target(path, alias?)`（私有） | `Folder` | alias 缺省时先取输入路径的 basename，再展开、规范化并解析 realpath，目标可以是目录或文件，最后校验得到的 alias |
| `rollback_created(root, links, marker_created)`（私有） | `true` | links 为本次成功创建的 Folder 数组；只撤销仍匹配的链接、本次 marker 和空 root，失败返回含残留路径的错误 |

`create` 接收的 folders 已有显式 name 和绝对 path，可直接调用 validate_folders；
`attach` 使用 resolve_target 支持默认 alias 和默认 cwd。查重直接遍历列表，不长期保存索引。
读取已有链接时不能调用 resolve_target 强制校验目标存在，否则失效链接无法列出和删除。

root 和 marker 的验证逻辑在 view 内复用；目录扫描、marker 读写直接使用现成 API，
不再逐个导出文件系统包装函数。rollback_created 只由 create 的失败分支调用，
清理失败的字符串由 create 合并到原始错误后返回。

### 3.3 `lua/cinder_workspace/config.lua`

负责快照格式与文件写入，不判断 current，不验证源项目是否存在。

| 函数与参数 | 成功返回值 | 作用 |
| --- | --- | --- |
| `M.read(path)` | `Document`：folders.path 已转为绝对路径 | 读取和解码 JSON，调用 validate_document；将文档中的相对路径按 JSON 所在目录解析，不访问源目录 |
| `M.write(path, document)` | `string`：快照文件绝对路径 | document.folders 中的 path 必须是绝对目标路径；验证结构，复制并排序、生成相对路径、编码后调用 write_atomic，不修改输入 |
| `validate_document(document)`（私有） | `true` | 验证顶层对象、整数 version、非空 name、folders 数组及条目的非空 name/path 字符串；安全名称和真实路径规则交给 view |
| `write_atomic(path, content)`（私有） | `true` | path 已规范化；拒绝 marker 名称及已有非普通文件，创建父目录，同目录临时文件写入并 rename，失败尽力清理本次临时文件 |

`init.export` 传给 write 的 Document 来自已选工作区及 validate_folders 的结果；
`init.import` 把 read 返回的文档交给 view.create 完成名称、目标和去重校验。
已有快照仅在最后 rename 成功后被替换，临时文件清理失败附加到原始错误中。

### 3.4 `lua/cinder_workspace/commands.lua`

仅 `M.setup` 供 init 调用，其他函数为命令回调使用的私有函数。
api 参数是 setup 收到的公开模块表，不在 commands 中反向 require init。

| 函数与参数 | 返回值 | 作用 |
| --- | --- | --- |
| `M.setup(api)` | 无返回值 | 注册或替换 `:CinderWorkspace` 命令及补全回调，重复 setup 不重复注册 |
| `execute(api, cmd)`（私有） | 无返回值 | 从 Neovim 命令参数中读取子命令和参数，调用对应 API；失败通知一次，list 读取 current 并展示快照 |
| `complete(api, arglead, cmdline, cursorpos)`（私有） | `string[]` | 补全子命令、目录、快照路径或当前 alias；没有候选或读取失败时返回空数组，不在补全时通知 |

execute 只分发 `new/open/attach/detach/close/list/export/import`，不为每个子命令
再建立一个模块或一套公开函数。list 没有当前工作区时显示“未选择工作区”。

### 3.5 配置侧 `lua/config/explorer.lua`

| 函数与参数 | 返回值 | 作用 |
| --- | --- | --- |
| `M.open(mode?)` | 原 explorer 返回值；提前结束时为 `nil` | mode 默认 project；优先选择当前 workspace root，否则按 project/cwd 使用原目录来源；参数或工作区读取错误在此通知 |
| `open_explorer(root)`（私有） | 原 explorer 返回值，直接透传 | 只执行 `Snacks.explorer({ cwd = root })`，保留原文件树行为 |

这两个函数不把原 explorer 的返回值转换成核心 API 的 `nil, err` 协议。
按键只触发打开行为，不根据返回值分支。完整包装代码见第 4 节。

### 3.6 配置侧 `lua/plugins/cinder-workspace.lua`

文件返回 Lazy 的插件规格数组，不定义新的模块 API。插件规格通过 opts 调用
`cinder_workspace.setup()`，Snacks 规格只增加以下匿名按键回调：

| 回调 | 返回值 | 作用 |
| --- | --- | --- |
| `<leader>e` 的 `function()` | 无返回值 | 调用 `require("config.explorer").open("project")` |
| `<leader>E` 的 `function()` | 无返回值 | 调用 `require("config.explorer").open("cwd")` |

不再增加一个只转发 setup 的 config 函数，也不在插件规格里维护 workspace 状态。

### 3.7 `tests/run.lua`

只规划三个本地辅助函数；验收场景直接使用断言和匿名回调，不建立测试类或套件加载器。

| 函数与参数 | 返回值 | 作用 |
| --- | --- | --- |
| `with_temp_workspace(callback)`（私有） | 无返回值；失败在清理后重新抛出 | 创建隔离的 base、source、快照目录，把路径 table 交给 callback；结束时清理临时内容并恢复测试进程环境 |
| `run_case(name, callback)`（私有） | `boolean`：该用例是否通过 | 捕获断言错误，输出用例名称及失败信息；失败后仍能运行其他用例 |
| `main()`（私有） | 无普通返回值 | 设置测试 runtimepath，逐项调用 run_case，累计结果并以成功或失败退出 headless Neovim |

入口在文件末尾调用 main。异常只用于测试断言，不改变生产 API 的返回值协议。
README、des、plan 和 help 文件只承载文档，不定义函数。

## 4. Explorer 包装与按键

`lua/config/explorer.lua` 的接口保持只有一个 `open(mode)`。实现形状如下：

```lua
local M = {}

local function open_explorer(root)
  return Snacks.explorer({ cwd = root })
end

function M.open(mode)
  mode = mode or "project"
  if mode ~= "project" and mode ~= "cwd" then
    vim.notify("未知 explorer 模式: " .. tostring(mode), vim.log.levels.ERROR)
    return
  end

  local ws, err = require("cinder_workspace").current()
  if err then
    vim.notify(err, vim.log.levels.ERROR)
    return
  end

  local root
  if ws then
    root = ws.root
  elseif mode == "cwd" then
    root = vim.fn.getcwd()
  else
    root = LazyVim.root()
  end
  return open_explorer(root)
end

return M
```

在现有 `lua/plugins/cinder-workspace.lua` 中增加 Snacks spec，将 `opts = { explorer = {} }`
和下面 keys 挂在 `"folke/snacks.nvim"` 上，使按键按原有 Lazy 机制加载 Snacks，再调用包装函数：

```lua
keys = {
  {
    "<leader>e",
    function() require("config.explorer").open("project") end,
    desc = "Explorer (workspace or project)",
    remap = false,
  },
  {
    "<leader>E",
    function() require("config.explorer").open("cwd") end,
    desc = "Explorer (workspace or cwd)",
    remap = false,
  },
}
```

两键直接调用同一个 API，不再依赖原 `<leader>fe/fE` 的间接映射。
显式传入 root 后不需要 tcd、覆盖 LazyVim.root 或自动跟踪 tab。
文件树的开关和导航行为继续由原 explorer 处理；包装层不增加 UI 状态。
搜索器遍历符号链接是独立集成需求，不在本次包装中顺带实现。

## 5. 三步交付

### 第一步：跑通工作区与 explorer

补齐 init 的模块返回值和幂等 setup，实现 `new/open/current/close`、root/marker
校验及配置侧包装。先用两个真实目录的符号链接验证浏览流程，再继续实现其他操作。

验收：

- 没有工作区时，e/E 分别使用项目根和 cwd。
- 有工作区时，两键都传 workspace root；打开其中某个项目文件后仍如此。
- 切换 tab 继续使用同一个 current；显式 close 后两键恢复默认选择。
- 工作区不可读时只通知一次，不调用 explorer；操作前后的 cwd 不变。
- 退出重开 Neovim 后目录仍存在，open 可以再次使用；setup 不创建目录。

### 第二步：安全管理链接

加入 attach/detach 和薄命令层。使用一个 `:CinderWorkspace` 命令分发
`new/open/attach/detach/close/list`，避免每个操作再维护模块、实例、别名三套入口。
参数与路径补全使用 Neovim 的现成能力，不另写参数框架。

验收：

- attach 默认 alias、自定义 alias、重复真实路径和同名冲突符合 des。
- 非空无效 CINDER_WORKSPACE 不回退默认目录；未设置或为空时使用
  `/tmp/.cinder-workspace`（缺失则按 0755 创建），已有 root 不覆盖。
- 空名称、`.`、`..`、路径穿越和 marker alias 被拒绝，`rtl.v2` 正常使用。
- 相对路径、`~`、含空格路径正确解析；目标本身是符号链接时绑定到 realpath。
- detach 失效链接或重复 detach 都安全；同名真实文件/目录被保留。
- close 或重启后链接变更仍在；源目录和其中的文件内容保持完整。

### 第三步：快照与完整验收

实现 config 和 `export/import`，接入同名子命令。文档示例说明 JSON 只是快照，
通过 open 恢复已有目录，通过 import 在不存在的目标 root 创建工作区。

验收：

- 空工作区与多个 folder 均能导出、导入；JSON 对象和 folders 数组类型正确。
- 相对路径以快照位置为基准，导出顺序稳定；迁移整个示例目录后仍可导入。
- 非法 JSON/version、重复 alias/真实路径、失效目标在创建 root 前被拒绝。
- 同名 root 存在时 import 失败，内容和旧 current 保持原样。
- 注入中途创建失败，确认只撤销本次创建的内容；未知对象和源项目不受影响。
- 注入写入/rename 失败，旧快照不被破坏；任何失败不产生重复通知。
- export 不覆盖 marker、符号链接或目录。
- 导出后继续 attach/detach，旧 JSON 内容不变，工作区仍按实际链接工作。

测试从一个独立 headless 入口开始，直接验证上述可观察行为；不按生产文件一一建立
测试套件，不为简单转发函数写测试。临时目录和测试环境变量仅作用于测试进程，
不加载用户 LazyVim 或修改真实项目；故障注入只覆盖创建和原子写入等关键失败点。

```text
nvim --headless -u NONE -i NONE -l tests/run.lua
```

run.lua 自行加入插件 runtimepath，必要时再拆出测试助手。真实 LazyVim 中完成
explorer 按键验收；README/help 复用同一套 API 和示例，不重复内部实现规划。
