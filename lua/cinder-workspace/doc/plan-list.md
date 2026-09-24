# cinder-workspace list 重构规划

本规划只覆盖 `:CinderWorkspace list` 的重构：把它从"用 notify 展示当前工作区"
改为"打开浮窗选单，选择并打开记录在 list 文件中的工作区"。行为契约以
[des.md](des.md) 为准；本规划完成并实现后，des.md / plan.md / help 需按本文
第 6 节同步修订。

## 1. 已确认的决策

| 事项 | 决策 |
| --- | --- |
| 记录时机 | **保持不变**：仅在 export 时记录。root 是快照的一次物化，JSON 才是长期保存的真相 |
| 记录格式 | 从 `{name, path}` 升级为 `{name, root, snapshot}`，root 供快速 open，snapshot 供重建兜底 |
| 失效处理 | 记录不会"失效"：root 存在直接 open；root 缺失用 snapshot import 重建；两者都缺失才报错 |
| UI 技术栈 | **Snacks.picker**（复用 LazyVim 的选单组件），由 `ui.lua` 唯一封装 |
| New 选项 | 列表首行放哨兵条目 `+ New workspace`，`focus = "list"` 使其成为默认选项 |
| 名称输入 | `Snacks.input`（与 picker 风格统一） |
| New 后的记录 | **不自动记录**。创建成功后 notify 提示"export 后才会出现在 list" |

与列表无直接关系但作为前提被接受的既有改动：`view.create` 对已存在的同名
工作区 root 改为"校验 marker 后删除重建"（不再拒绝覆盖）。这使得"选中记录 →
import 重建"的流程在 root 残留时也能工作，但同时要求 fallback 逻辑必须精确
区分"root 不存在"与"open 失败"（见 4.2），避免误删。

## 2. 数据层：config.lua

### 2.1 记录仓库（registry）

- 路径：`$CINDER_WORKSPACE/workspace-list.txt`（不变）。环境变量未设置时视为无记录。
- 格式：JSONL，每行一个 JSON 对象：

```json
{"name":"rtl-sim","root":"/tmp/rtl-sim","snapshot":"/tmp/ws/rtl-sim.json"}
```

- `snapshot` 可为 null；旧格式行 `{"name":"...","path":"..."}` 兼容读取：
  `path` 映射为 `snapshot`，`root` 为 nil（表示只能走 import 重建）。

### 2.2 接口变更

| 函数 | 返回值 | 作用 |
| --- | --- | --- |
| `M.record_entry(entry)` | `true`；失败 `nil, err` | 追加一行 JSONL。entry 为 `{name, root?, snapshot?}`；root/snapshot 至少其一 |
| `M.read_registry()` | `Entry[]`，失败 `nil, err` | 读取并解析；坏行跳过；按 root 去重保留最后一条（root 为 nil 的旧行按 snapshot 去重）；每条附加 `exists = uv.fs_stat(root) ~= nil`（root 为 nil 时为 false）；文件不存在返回 `{}` |
| `list_path()`（私有） | `string?` | 统一派生 registry 路径；env 未设置返回 nil |

`Entry = { name = string, root = string?, snapshot = string?, exists = boolean }`。

### 2.3 职责迁移

- **删除 `config.write` 末尾的 registry append 块**：`write` 回归"只写快照文件"。
- `init.export` 在 `config.write` 成功后显式调用
  `config.record_entry({ name = document.name, root = current_root, snapshot = 导出绝对路径 })`。
  记录失败时：export 本身已成功，仅 notify 提示记录失败，不影响返回值语义。

## 3. UI 层：ui.lua（本次核心）

`lua/cinder_workspace/lua/cinder_workspace/ui.lua`（已存在，当前为空）实现为
Snacks.picker 的薄封装。**ui.lua 不 require init/commands**；它只接收数据与回调，
窗口生命周期与错误通知归它管。

### 3.1 接口

| 函数 | 返回值 | 作用 |
| --- | --- | --- |
| `M.open(opts)` | 打开的 picker 实例；失败 `nil, err` | 构造并打开选单。重复调用时先关闭旧 picker（单例） |
| `M.close()` | 无 | 关闭当前 picker 并清空状态 |
| `M.is_open()` | `boolean` | 是否有存活的 picker |

`opts`：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `entries` | `Entry[]` | registry 读出的记录 |
| `current_root` | `string?` | 当前工作区 root，用于行首 `*` 标记 |
| `on_open(entry)` | `→ true | nil, err` | 选中真实记录时执行（成功才关窗） |
| `on_new(name)` | `→ true | nil, err` | New 哨兵选中后拿到名称时执行 |
| `new_hint` | `string?` | on_new 成功后展示的提示（默认"已创建并选中；export 后才会出现在 list"） |

### 3.2 窗口形态与行为

```text
┌─ Workspaces ───────────────────────────┐
│ + New workspace                        │ ← 哨兵，第一行，默认光标位置
│ * rtl-sim           /tmp/rtl-sim       │ ← * 当前工作区
│   scala-tool        /tmp/scala-tool    │
│ ! old-ws            /tmp/old-ws（缺失）│ ← ! root 不存在，回车将重建
└────────────────────────────────────────┘
```

- `focus = "list"`：打开时光标落在哨兵上（New 是默认选项）；按 `/` 进入输入框过滤。
- `show_empty = true`：无记录时窗口只有哨兵一行。
- `auto_close = false`：焦点被 `Snacks.input` 抢走时 picker 不自动关闭，
  失败可留在原地重试；成功时显式 `picker:close()`。
- `title = " Workspaces "`，使用 picker 默认布局与高亮。

### 3.3 confirm 分发逻辑

```
<CR> 选中的条目：
  哨兵（is_new）:
    Snacks.input({ prompt = "Workspace name: " })
      ├─ nil / ""          → 忽略（取消）
      └─ name:
          on_new(name) == true → close + notify(new_hint)
          on_new 返回 nil, err  → notify(err) 一次，picker 保持打开可重试
  真实记录:
    on_open(entry) == true → close
    失败 → notify(err) 一次，picker 保持打开
```

错误通知统一由 ui 执行一次；回调内部不得再 notify。

### 3.4 私有函数

| 函数 | 作用 |
| --- | --- |
| `build_items(entries, current_root)` | 哨兵 + 真实条目（含 `*`/`!` 标记与 text 字段） |
| `format_item(entry, current_root)` | 行文本 `" %-20s %s"`，缺失追加"（缺失，回车将重建）" |
| `confirm(picker, item)` | 3.3 的分发实现 |
| `new_workspace(picker)` | Snacks.input 的封装与 on_new 调用 |

## 4. 命令层：commands.lua

### 4.1 list 分支

```lua
elseif subcommand == "list" then
  local entries, err = config.read_registry()
  if err then notify_error(err) else
    local snapshot = api.current()            -- 当前 root，仅用于 * 标记
    ui.open({
      entries = entries,
      current_root = snapshot and snapshot.root or nil,
      on_open = function(entry)
        -- 4.2 的 open_or_restore
      end,
      on_new = function(name)
        local _, err = api.new(name)
        if err then return nil, err end
        return true
      end,
    })
  end
```

`api.current()` 读取失败不阻断：仅通知一次后继续打开选单（current 标记缺失）。

### 4.2 open_or_restore（选中记录的行为）

```
entry.root 存在（uv.fs_stat）:
    api.open(root) 成功 → true
    api.open 失败    → nil, err（不落 import；避免权限/损坏等误触发删除重建）
entry.root 为 nil 或不存在:
    snapshot 存在 → api.import(snapshot) 成功 → true；失败 → nil, err
    snapshot 缺失 → nil, "记录既无可用 root 也无可用快照"
```

关键边界：**只有 root 确实不存在才走 import**。`view.create` 现在是"同名 root
删除重建"，若把任何 open 失败都 fallback 到 import，一次瞬时的权限错误就可能
删掉一个完好的工作区。

### 4.3 旧的"当前工作区详情"展示

- `print_snapshot` 不再由 list 使用，改挂到新子命令 `:CinderWorkspace current`：
  与旧 list 行为完全一致（读取 `api.current()`，notify 展示）。
- `SUBCOMMANDS` 与补全增加 `current`（无参数，与 list 同组返回空补全）。

## 5. 插件接线与依赖

- `lua/plugins/cinder-workspace.lua`：cinder-workspace 插件规格增加
  `dependencies = { "folke/snacks.nvim" }`。
- `doc/plan.md` 的既有约束"cinder_workspace 本身不依赖 Snacks 或 LazyVim"
  修订为：**init/view/config 不依赖 Snacks；ui.lua 依赖 Snacks，仅在 list 命令
  执行时通过 `require("snacks")` 按需加载**。

## 6. 涉及文件清单

| 文件 | 改动 |
| --- | --- |
| `lua/cinder_workspace/ui.lua` | 全新实现（第 3 节） |
| `lua/cinder_workspace/config.lua` | 增 `record_entry` / `read_registry` / `list_path`；移除 `write` 内 append 块 |
| `lua/cinder_workspace/init.lua` | `M.export` 成功后调用 `record_entry` |
| `lua/cinder_workspace/commands.lua` | list 改接 ui；新增 `current` 子命令与补全 |
| `lua/plugins/cinder-workspace.lua` | 增加 Snacks 依赖 |
| `tests/run.lua` | 增 registry 用例（见第 7 节） |
| `doc/des.md` `doc/plan.md` `doc/cinder_workspace.txt` `README.md` | 同步 list 语义、current 子命令、依赖约束修订 |
| `doc/update-log/260911.txt` | 新增当日条目 |

## 7. 测试与验收

headless 测试（`nvim --headless -u NONE -i NONE -l tests/run.lua`，无 Snacks，
只覆盖数据层与命令分发）：

- record_entry 追加格式正确；read_registry 去重（同 root 保留最后一条）；
- 坏行跳过不炸；文件不存在返回空；env 未设置返回空；
- 旧格式行兼容（path → snapshot，root 为 nil）；
- list 分发改为调用 ui 时，ui 不存在 Snacks 环境下的行为不进入 headless 断言。

真实环境手测：

- 空 env：list 打开只有 New 一行的窗口，Enter 输名可创建；
- 有记录：j/k 移动，`*` 标当前，`!` 标缺失；回车 open 成功并关窗；
- 删除某工作区 root 后选中该记录：走 import 重建并选中；
- open 失败（如 root 被占用的损坏状态）只 notify 一次且**不触发删除重建**；
- New 输名失败（重名/非法）时窗口不关可重试；成功后 notify export 提示；
- 重复执行 `:CinderWorkspace list` 不叠窗。

测试结束以后将test文件删除

## 8. 明确的非目标

- 不把记录时机扩展到 new/import（保持仅 export 记录）。
- 不实现 `CINDERWORKHOME` / `CINDERWORKDIR` 环境变量改名（update-log 的历史
  愿望单独另立任务）。
- 不实现"export 不带参数存默认目录"。
- 不把 list 路由到 `vim.ui.select` / Telescope / fzf；固定用 Snacks.picker。
- 不实现条目的删除、编辑、置顶等管理动作。
