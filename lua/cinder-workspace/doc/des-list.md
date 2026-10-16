# cinder-workspace list 功能设计（函数级）

本文档是 `:CinderWorkspace list` 浮窗选单功能的函数级接口契约，粒度到每个
函数：签名、参数、成功/失败返回值、行为与边界条件。实施顺序与验收见
[plan-list.md](plan-list.md)；本文档以行为为准。

错误协议与现有核心一致：可预期失败返回 `nil, err`，err 为非空字符串；不抛业务
异常；通知归属见第 6 节。

## 0. 数据类型

| 类型 | 定义 |
| --- | --- |
| `Entry` | `{ name = string, root = string?, snapshot = string?, exists = boolean }`。name 非空；root/snapshot 至少其一；exists 为读取时计算结果 |
| `ui.OpenOpts` | `{ entries = Entry[], current_root = string?, on_open = fun(entry), on_new = fun(name), new_hint = string? }` |
| `on_open` 契约 | 成功返回 `true`；失败返回 `nil, err`。ui 据此决定关窗或保留 |
| `on_new` 契约 | 同 on_open。成功另触发 `new_hint` 提示 |
| 记录 JSONL 行 | `{"name":"...","root":"...","snapshot":"..."}`；root/snapshot 可为 null；旧行 `{"name":"...","path":"..."}` 兼容 |

## 1. config.lua（数据层）

### 1.1 私有 `list_path()`

| 项 | 内容 |
| --- | --- |
| 参数 | 无 |
| 成功返回 | `string`：`$CINDER_WORKSPACE/workspace-list.txt`（joinpath 拼接） |
| 环境未设置 | 返回 `nil`（视为"没有记录仓库"，不是错误） |
| 作用 | registry 路径的唯一派生点；所有读写都必须经此函数，不允许散落拼接 |

### 1.2 `M.record_entry(entry)`

| 项 | 内容 |
| --- | --- |
| 参数 | `entry = { name = string, root = string?, snapshot = string? }`；name 非空；root/snapshot 至少其一；root/snapshot 存在时必须是非空字符串 |
| 成功返回 | `true` |
| 失败返回 | `nil, err`（参数非法、打开/写入 list 文件失败） |
| 特殊规则 | `list_path()` 为 nil（env 未设置）时直接返回 `true`，不写任何东西 |
| 作用 | 将 entry 编码为一行 JSON + "\n"，以 append 模式写入 registry。**不做去重**（去重在读取时做）。不修改输入表 |

### 1.3 `M.read_registry()`

| 项 | 内容 |
| --- | --- |
| 参数 | 无 |
| 成功返回 | `Entry[]`。文件不存在（ENOENT）、list_path 为 nil、文件为空均返回 `{}` |
| 失败返回 | `nil, err`（读取/解析系统级失败） |
| 解析规则 | 按行切分；空白行跳过；单行 `pcall(vim.json.decode)` 失败 → 静默跳过该行 |
| 兼容规则 | 旧行含 `path` 无 `root`：`snapshot = path`，`root = nil`；`name` 非空才接受；root/snapshot 全缺的行跳过 |
| 去重规则 | 键 = `root`（root 为 nil 时用 `snapshot`）。后出现的行覆盖先出现的值，但**保留首次出现的位置**（顺序稳定） |
| exists 计算 | `root ~= nil and uv.fs_stat(root) ~= nil`；root 为 nil 时 `exists = false` |
| 作用 | 为 ui 提供"已导出的工作区"清单；不在本函数内做任何 UI/通知 |

### 1.4 私有 `decode_entry_line(line)`

| 项 | 内容 |
| --- | --- |
| 参数 | `line = string` |
| 成功返回 | `Entry?`；格式非法返回 `nil`（调用方跳过，不视为错误） |
| 作用 | 单行 JSON 解码 + 字段校验 + 旧格式映射，集中 1.3 的解析规则 |

### 1.5 既有 `M.write(path, document)` 的变更

删除函数末尾的 registry append 块。其余行为（校验、原子写、排序、相对路径）不变。

## 2. init.lua（组合层）

### 2.1 既有 `M.export(path)` 的行为变更

| 项 | 内容 |
| --- | --- |
| 签名 | 不变：`M.export(path) -> string | nil, err` |
| 新增步骤 | `config.write` 成功后调用 `config.record_entry({ name = document.name, root = state.current_root, snapshot = 写入绝对路径 })` |
| 记录失败语义 | export 本身已成功：仍返回写入路径（成功）。记录错误由 init **直接 `vim.notify(WARN)` 一次**——这是对"核心层不 notify"的唯一豁免，命令层不再二次通知 |
| 记录时机 | 仅此处。`new/open/import/attach/detach` 不产生记录 |

### 2.2 其余函数

`setup/new/open/current/attach/detach/close/import` 签名与行为不变。

## 3. ui.lua（UI 层，本次核心新实现）

模块内部持有唯一状态 `state = { picker = nil }`。依赖 Snacks 的
`picker` 与 `input` 两个子模块；`require("snacks")` 在**函数内部延迟执行**，
不在模块顶层。

### 3.1 私有 `snacks()`

| 项 | 内容 |
| --- | --- |
| 参数 | 无 |
| 返回 | snacks 模块表：`_G.Snacks` 或 `require("snacks")` |
| 作用 | 统一的延迟加载入口 |

### 3.2 `M.open(opts)`

| 项 | 内容 |
| --- | --- |
| 参数 | `opts = ui.OpenOpts`（见第 0 节）。entries 必须是数组；on_open/on_new 必须是函数 |
| 成功返回 | picker 实例 |
| 失败返回 | `nil, err`（opts 缺回调/类型非法、Snacks 不可用、picker 打开失败） |
| 行为 | 1) 若 `state.picker` 存在且未关闭 → 先 `M.close()`（单例，不叠窗）；2) `build_items` 构造条目；3) `Snacks.picker({...})` 打开并存入 `state.picker`；4) `on_close` 回调清空 `state.picker` |
| picker 选项 | `title = " Workspaces "`、`focus = "list"`、`show_empty = true`、`auto_close = false`、`confirm = confirm`（私有回调） |
| 约束 | 不读取 registry、不调用 core API、不做通知之外的业务 |

### 3.3 `M.close()`

| 项 | 内容 |
| --- | --- |
| 参数 | 无 |
| 成功返回 | `true`（无 picker 时也成功） |
| 行为 | `state.picker:close()`（on_close 会清状态）；防御性：即使 close 抛错也置 `state.picker = nil` |

### 3.4 `M.is_open()`

| 项 | 内容 |
| --- | --- |
| 参数 | 无 |
| 返回 | `boolean`：`state.picker ~= nil` |
| 作用 | 供命令层判断是否需要切换/聚焦 |

### 3.5 私有 `build_items(entries, current_root)`

| 项 | 内容 |
| --- | --- |
| 参数 | `entries = Entry[]`、`current_root = string?` |
| 返回 | items 数组：第一项为哨兵 `{ text = "+ New workspace", is_new = true }`，其后每项 `{ text = format_item(...), entry = e }` |
| 作用 | 把业务数据转成 picker 可消费的条目；哨兵恒在首位 |

### 3.6 私有 `format_item(entry, current_root)`

| 项 | 内容 |
| --- | --- |
| 参数 | `entry = Entry`、`current_root = string?` |
| 返回 | `string`，形状 `" %-20s %s"`（name + root 显示文本） |
| 标记规则 | 行首 `*`：entry.root == current_root；行首 `!`：exists == false 或 root == nil；root 为 nil 时路径位显示 `(快照重建)`；exists == false 且 root 存在时追加 `（缺失，回车将重建）` |

### 3.7 私有 `confirm(picker, item)`

| 项 | 内容 |
| --- | --- |
| 参数 | picker 实例、被选中条目 |
| 行为 | `item.is_new == true` → `new_workspace(picker)`；否则 `item.entry` 存在 → `run_open(picker, item.entry)`；两者皆非 → 忽略 |
| 返回 | 无 |

### 3.8 私有 `run_open(picker, entry)`

| 项 | 内容 |
| --- | --- |
| 参数 | picker 实例、`entry = Entry` |
| 行为 | 调 `opts.on_open(entry)`：返回真 → `picker:close()`；返回 `nil, err` → `vim.notify(err, ERROR)` 一次，picker 保持打开 |
| 返回 | 无 |

### 3.9 私有 `new_workspace(picker)`

| 项 | 内容 |
| --- | --- |
| 参数 | picker 实例 |
| 行为 | `Snacks.input({ prompt = "Workspace name: " }, cb)`；`cb` 收到 nil/空串 → 忽略（取消）；否则调 `opts.on_new(name)`：真 → `picker:close()` + `vim.notify(opts.new_hint 或默认提示, INFO)`；`nil, err` → `vim.notify(err, ERROR)` 一次，picker 保持打开可重试 |
| 返回 | 无 |
| 说明 | 输入过程由 Snacks.input 自带浮窗完成；picker 因 `auto_close = false` 不因焦点转移而关闭 |

## 4. commands.lua（命令层）

### 4.1 私有 `open_or_restore(entry)`

| 项 | 内容 |
| --- | --- |
| 参数 | `entry = Entry` |
| 成功返回 | `true`（工作区已打开/重建并选中） |
| 失败返回 | `nil, err` |
| 分支规则 | 1) `entry.root ~= nil` 且 `uv.fs_stat(root)` 存在 → `api.open(root)`，失败即返回该 err（**绝不落 import**）；2) 否则 `entry.snapshot ~= nil` → `api.import(snapshot)`；3) 都不可用 → `nil, "该记录既无可用 root 也无可用快照"` |
| 动机 | `view.create` 同名一律报错、绝不覆盖（早先版本的"同名 root 删除重建"已回退），所以 import 永远不会删除既有工作区；"root 存在就 open、绝不落 import" 这条规则仍然成立，且比当初更安全 |

### 4.2 `execute(api, command)` 的 list 分支

| 项 | 内容 |
| --- | --- |
| 行为 | 1) `config.read_registry()` 失败 → `notify_error` 一次并返回；2) `api.current()` 取当前 root，失败只 `notify_error` 一次、不阻断（current_root 置 nil）；3) `ui.open({ entries, current_root, on_open = open_or_restore, on_new = 创建包装 })`；4) `on_new(name)` 内部：`api.new(name)`，成功 `true`，失败 `nil, err`（err 原样上抛给 ui 通知，不再自行 notify） |
| require 时机 | `cinder_workspace.config` 与 `cinder_workspace.ui` 在 list 分支内 require，避免插件 setup 阶段加载 Snacks |

### 4.3 新增 `current` 子命令

- `SUBCOMMANDS` 增加 `"current"`；补全规则与 `list` 同组（返回 `{}`）。
- 分支行为 = 旧 list 行为：`api.current()` 成功 → `print_snapshot(snapshot)`；nil → notify "当前没有打开的工作区"；err → `notify_error` 一次。
- `print_snapshot(snapshot)` 私有函数保持原样（改名不必要，行为不变）。

### 4.4 其余函数

`M.setup(api)`、`require_arg`、`notify_error`、`split_args` 签名不变；`complete` 仅增加 current 分支。

## 5. 插件规格（lua/plugins/cinder-workspace.lua）

无新函数。cinder-workspace 规格增加 `dependencies = { "folke/snacks.nvim" }`。
Snacks 的 explorer 按键规格不变。

## 6. 通知归属规则（notify exactly once）

| 错误/提示 | 通知方 | 次数 |
| --- | --- | --- |
| read_registry 失败 | commands（ERROR） | 1 |
| api.current 失败（仅标记丢失） | commands（ERROR），列表仍打开 | 1 |
| on_open 失败（open/import 失败） | ui（ERROR），窗口保留 | 1 |
| on_new 失败 | ui（ERROR），窗口保留 | 1 |
| on_new 成功提示 | ui（INFO，new_hint） | 1 |
| record_entry 失败 | init（WARN，唯一豁免） | 1 |
| 其余旧子命令错误 | commands（ERROR），行为不变 | 1 |

## 7. 模块依赖方向

```text
commands ──► config.read_registry / record_entry
         ──► ui.open
         ──► api（init，经 setup 注入，不反向 require）

ui       ──► Snacks.picker / Snacks.input（函数内延迟 require）
         ✗ 不依赖 config / init / commands

init     ──► config.record_entry（仅 export 内）
config   ✗ 不依赖任何上层
```
