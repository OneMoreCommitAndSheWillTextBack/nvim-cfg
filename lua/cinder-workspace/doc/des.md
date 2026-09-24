# cinder-workspace 设计

## 1. 工作区是什么

工作区是一个有名称、长期保留的目录，其中的符号链接把几个项目聚合成一棵目录树：

```text
<workspace-base>/rtl-sim/
├── .cinder-workspace
├── rtl       -> <projects>/rtl
└── simulator -> <projects>/simulator
```

**目录中的链接是工作区状态的唯一来源。** 内存只记录当前选中的工作区路径，
JSON 只用于显式导入、导出快照。三者之间没有后台同步。

- `attach/detach` 成功后，变更立即保留在磁盘上，不需要另一次 save。
- 关闭工作区、切换工作区或退出 Neovim 都不删除工作区目录。
- 工作区里的其他普通文件、真实目录不属于 folder 列表，插件不自动处理它们。
- 插件的目录操作只管理链接，不复制、移动或删除源项目内容。

这取代旧设计的“临时 runtime + 显式 save + 退出清理”。第一版只支持 POSIX。

## 2. 目录与当前工作区

`new/import` 在 `<workspace-base>/<name>` 创建工作区。base 按以下规则解析：

1. 非空 `CINDER_WORKSPACE` 优先；只有它未设置或为空时才使用 `HOME`。
2. 选中的值必须是绝对路径、已存在且可访问的目录。
3. 非空但无效的 `CINDER_WORKSPACE` 直接报错，不回退 HOME。

插件不创建 base，不使用其他兜底路径。创建操作仍需处理权限不足等实际失败。
`open(root)` 使用调用者明确给出的路径，不依赖 base 环境变量。
open/export/import 的输入路径支持 `~`，相对路径按调用时 cwd 解析。

工作区根目录必须是真实目录，包含有效的普通 marker 文件 `.cinder-workspace`：

```json
{ "plugin": "cinder-workspace", "version": 1 }
```

marker 只标识目录格式，不记录会话 token、folder 清单或进程信息。
工作区名称取根目录的 basename；路径才是打开已有工作区的依据。

整个 Neovim 只有一个当前工作区，各 tab 共用这一选择。`new/open/import` 成功后
替换当前选择，失败保留旧选择。没有未保存的工作区变更，因此无需先 close。

插件不自动执行 `cd/tcd/lcd`，不捕获、恢复 cwd，不绑定 tab，也不注册退出清理。
用户的编辑目录由原有操作决定；文件树通过第 4 节的包装 API 选择展示目录。

## 3. 一套公开 API

只提供模块函数，不提供 Workspace 类、实例方法或兼容别名：

```lua
local workspace = require("cinder_workspace")

local root = workspace.new("rtl-sim")
workspace.attach("~/project/rtl", { name = "rtl" })
workspace.attach("~/project/simulator")
workspace.export("~/workspaces/rtl-sim.json") -- 可选快照
workspace.close()

workspace.open(root)
```

以上展示正常流程；调用者在继续下一步前应处理返回的错误。

| API | 成功返回与行为 |
| --- | --- |
| `setup()` | 注册命令，可重复调用，不打开工作区 |
| `new(name)` | 创建空工作区，返回绝对 root；任何同名对象已存在都报错 |
| `open(root)` | 验证已有目录和 marker，返回绝对 root，不创建或修复链接 |
| `current()` | 从已选 root 读取新的 `{ name, root, folders }` 快照；未选择时返回 nil |
| `attach(path, opts?)` | 创建一个链接，返回 `{ name, path, type }`；path 为 nil 时取当前 cwd，alias 默认取输入路径 basename |
| `detach(name)` | 只删除指定链接，返回 true；链接不存在也成功，失效链接仍会被删除 |
| `close()` | 清空当前选择，返回 true；没有 current 时也成功 |
| `export(path)` | 原子写入 JSON 快照，返回绝对文件路径；path 必填 |
| `import(path)` | 从 JSON 创建新工作区并选中，返回绝对 root；同名 root 存在就报错 |

除 `setup` 外，操作失败统一返回 `nil, err`，err 为可操作的字符串；
`current()` 的“没有选择”返回 `nil`，当前 root 丢失或不可读则返回 `nil, err`。
核心 API 不调用 `vim.notify`，由命令或 explorer 包装入口通知一次。

`attach/detach/export` 需要有效的当前工作区。folders 是目录直接子项中的符号链接，
每项有 `name/path`，attach 的返回值另带 `type`（`directory` 或 `file`）；
path 是解析链接文本得到的绝对目标路径，不缓存第二套索引。
失效链接仍可列出、detach；export 要求所有链接目标当前都是有效目录或文件。

## 4. Explorer 包装 API

在配置侧提供 `require("config.explorer").open(mode)`，mode 为 `"project"`
或 `"cwd"`，默认 `"project"`。原来的 `Snacks.explorer` 调用封装成一个私有函数。

| 按键 | 有当前工作区 | 没有当前工作区 |
| --- | --- | --- |
| `<leader>e` → `open("project")` | 打开 workspace root | 沿用 `LazyVim.root()` |
| `<leader>E` → `open("cwd")` | 打开 workspace root | 沿用当前 cwd |

存在当前选择但目录读取失败时，通知错误并结束，不悄悄回退到其他目录。
close 后再次调用恢复上表的默认行为；已打开的文件树不由插件自动刷新或关闭。

包装层只选择 root，然后调用原 explorer。它不修改 `LazyVim.root`，不管理 LSP、
搜索器、buffer 或 session，也不扩展 provider/adapter 注册机制。
`cinder_workspace` 本身不依赖 Snacks 或 LazyVim；替换文件树时只改配置侧包装函数。

## 5. 链接操作与保护边界

- name/alias 拒绝空字符串、完整的 `.`、`..`、路径分隔符和 NUL；alias 另保留
  `.cinder-workspace`。允许名称中正常的点，例如 `rtl.v2`。
- attach 的相对路径按调用时 cwd 解析，支持 `~`；path 为 nil 时取 cwd。目标必须是现有
  目录或普通文件，链接使用 `realpath` 得到的绝对路径；原输入若是符号链接，之后改向不会
  改变已绑定的目标。
- 先检查 alias：被其他目标或真实对象占用时失败。alias 无冲突但真实目标已经绑定时，
  返回已有 folder，不额外创建别名。
- 对已有工作区的读写都检查 root 和 marker。新增链接不覆盖已有对象；detach 先用 `lstat`
  确认对象是链接，再 unlink 链接本身，不要求链接目标仍存在。
- root 中未知的真实文件、真实目录和异常 marker 不被删除或覆盖。
- 不提供工作区删除、强制覆盖、自动修复或扫描清理功能。

不使用 shell 拼接 `ln/mkdir/rm`。创建失败时只回滚本次创建且仍符合预期的对象；
回滚无法完成时保留残留物并在错误中指出路径，不递归删除陌生内容。
第一版不支持多个进程同时修改同一工作区，不增加锁、watcher 或后台协调服务。

## 6. JSON 是快照

保留原来的小型格式，便于迁移目录或分享项目组合：

```json
{
  "version": 1,
  "name": "rtl-sim",
  "folders": [
    { "name": "rtl", "path": "../project/rtl" },
    { "name": "simulator", "path": "../project/simulator" }
  ]
}
```

- 校验 version 为整数 1、name 合法、folders 为数组、每项 name/path 是非空字符串。
- 相对 path 以 JSON 文件所在目录为基准；导出优先使用相对路径，按 alias 排序。
- 导入前验证全部目录、alias 和真实路径不重复，然后才创建 root 和链接。
- import 不合并、不覆盖已有工作区。恢复已存在的工作区用 open，不重放 JSON。
- export 只写显式指定的文件，可创建其父目录，采用同目录临时文件加原子 rename。
  失败保留旧文件；不会更新内部 config_path，因为插件不保存此状态。
  允许覆盖普通快照文件，但拒绝 marker 保留文件名、已有符号链接或目录。
- 修改 JSON 不影响已有工作区；attach/detach 也不更新任何旧快照。

## 7. 实施边界

实现目录聚合、上述 API、薄命令层和 explorer 包装；实施顺序与验收见 [plan.md](plan.md)。

不实现实例 registry、dirty 状态、自动保存、退出拦截、cwd/tab/session 生命周期、
`rebuild(force)`、通用文件系统包装层、配置自动发现、LSP 多根配置和 Windows 兼容层。
不保留旧 `add/remove/save/connect/disconnect/shutdown` 别名，避免首版就维护两套语义。
