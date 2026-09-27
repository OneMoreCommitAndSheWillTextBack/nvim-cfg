# cinder_ui

一个给 Neovim 浮窗用的「卡片式 TUI 组件库」。为 cinder-terminal 的侧边栏而生，
不依赖任何外部插件：一个 `App`（浮窗）+ 一棵 `card` 树 + 若干 `widget`。

Lua 模块名是 `cinder_ui`（目录 `lua/cinder_ui/`）。

## 设计模型

- **卡片只有两种形态**
  - 容器卡：有 `children`（可选 `layout = "column" | "row"`），没有 `body`
  - 内容卡：有 `body`（widget），没有 `children`
- **root 卡是隐式的**：最外层由 `App` 的浮窗边框充当它的框，因此 root 只负责
  `children`（可选 `title` / `padding`），不要再套一层，否则白吃两行两列。
- **一切尺寸在构造期定死**：`height` / `width` 是 `number` 或
  `ui.flex(weight, { min = n, max = n })`。column 布局里每个孩子必须有 `height`，
  row 布局里必须有 `width`（漏了 `ui.validate` 会直接报路径）。
- **构造期校验**：`ui.validate(root)` 返回 `nil`（合法）或
  `{ "root.children[1]: height required in column layout", ... }`。
  能查的都在这里查：容器/内容混用、缺尺寸、重复 id、复用的卡片对象、
  `flex.min > max`、带边框但 `height < 2`、无 id 却 `focusable`、未知 widget 等。
  布局期算不下（空间不足）属于「降级」而不是错误，只在 `layout.compute`
  的第二个返回值里给 warning。
- **widget 无状态**：每次渲染通过 `get()` 闭包重新取数据；插件改完自己的状态
  调 `app:invalidate()`，库用 `vim.schedule` 合并成一次重绘。
- **键位策略归插件**：库不注册任何按键。谁用谁负责 `vim.keymap.set(..., {buffer = app.buf})`。

## 最小示例

```lua
local ui = require("cinder_ui")
ui.setup() -- 定义高亮组，可从现有 colorscheme 推导

local app = ui.App.new({ width = 0.9, height = 0.9, focus = "files" })

local root = ui.card{ layout = "row", children = {
  ui.card{ layout = "column", border = false, width = ui.flex(1, { min = 24, max = 40 }), children = {
    ui.card{ id = "status", tag = "1", title = "Status", height = 3, focusable = false,
             body = ui.text{ get = function() return { "main" } end } },
    ui.card{ id = "files",  tag = "2", title = "Files", height = ui.flex(1, { min = 5 }),
             body = ui.tree{ get = function()
               return { items = rows, cursor = 1, top = 0, empty = "no files" }
             end } },
  } },
  ui.card{ id = "diff", tag = "0", title = "Unstaged", width = ui.flex(2),
           body = ui.text{ get = function() return diff_lines end } },
} }

assert(ui.validate(root) == nil)
app:open(root)
app:focus("files")
app:set_footer("  j/k move  q quit  ")
```

## API

| 名称 | 说明 |
| --- | --- |
| `ui.setup({ hl = {...} })` | 定义/覆盖 `CinderUiBorder(-Focus)`、`CinderUiTitle`、`CinderUiTag`、`CinderUiCursor`、`CinderUiDim`、`CinderUiScrollbar`；默认值从 `FloatBorder` / `CursorLine` / `NormalFloat` 推导 |
| `ui.card{...}` | 建卡。字段：`id` `title` `tag` `height` `width` `border` `padding` `layout` `children` `body` `focusable` |
| `ui.flex(w, {min, max})` | 弹性尺寸标记 |
| `ui.text{ get | lines }` | 文本 widget，行可以是字符串或 `{ {text, hl}, ... }` 段 |
| `ui.list{ get | items, item_render, empty }` | 列表；`get()` 返回 `{ items, cursor, top, empty }` |
| `ui.tree{ get | items }` | 展平后的树行；item = `{ text, depth, glyph, glyph_hl, hl }` 或 `{ segments }` |
| `ui.validate(root)` | 构造期校验，见上 |
| `ui.App.new{ width, height, border, zindex, focus, enter }` | `width/height <= 1` 视为屏幕比例 |
| `app:open(root)` / `app:redraw()` | 打开/立即重绘（`open` 也会做校验） |
| `app:invalidate()` | 合并重绘（`vim.schedule`） |
| `app:focus(id)` / `app:cycle(dir)` / `app:focusables()` | 焦点管理，`cycle` 跳过 `focusable = false` 的卡 |
| `app:placement(id)` / `app:find(id)` / `app:card_at(row, col)` | 查布局（`placement` 带 `rect` / `inner`） |
| `app:set_footer(text)` / `app:close()` | 浮窗 footer / 关闭 |
| `ui.ensure_visible(cursor, top, height, total)` | 滚动跟随小工具（写你自己的 j/k 时用） |
| `ui.variant(base_hl, { bg = ... })` | 生成并缓存派生高亮组（选中行就是 `base + cursor bg`） |
| `ui.render_string(root, { width, height, focused_id })` | 离屏渲染成 ASCII（golden 测试/demo 调试用） |

## 渲染实现要点

- 单浮窗 + 一块内存画布（`canvas.lua`，纯数据、可 golden 测试）：边框、标题
  （`╭─[2]─Files────╮`）、CJK 宽度、span 都在画布层完成。
- 着色用 `virt_text` + `virt_text_win_col` 覆盖在真实文本上；光标行不是 `cursorline`，
  而是给该行每段文本拼上「原高亮 + 光标底色」的派生组，所以选中条只覆盖卡片内部宽度。
- 落盘时**文本按行 diff**、**span 整帧重建**。原因：`nvim_buf_set_lines` 会把被替换行
  里的 extmark 挪到后一行，按行 diff span 会残留重叠（这个 bug 有专门的回归测试）。
- 空间不足时从最大的 flex 开始压缩；实在塞不下就 clip 并给 warning，绝不画到框外。

## 测试与 demo

```sh
# 88 项单测（geom / canvas / validate / layout / golden / headless App 集成）
# 在插件根目录（本目录）下执行
nvim --headless -u NONE -i NONE -l tests/run.lua

# lazygit 风格 demo
nvim -u NONE --cmd "set rtp+=$PWD" -c "luafile $PWD/demo/init.lua"
#   <Tab> 换卡片  j/k 移动  h/l 折叠/展开  <CR> 开合  0-5 按 tag 跳转  @ 日志  space/c/s/d 假动作  q 退出

# 想在 tmux 里跑/截图（私有 tmux server，不影响你正在用的 tmux）
./tm.sh new-session -d -s demo -x 180 -y 48 -e TERM=xterm-256color
./tm.sh send-keys -t demo "nvim -u NONE --cmd 'set rtp+=$PWD' -c 'luafile $PWD/demo/init.lua'" Enter
./tm.sh capture-pane -p -t demo
```

## 目录

```
lua/cinder_ui/
  init.lua        公共 API
  geom.lua        纯矩形运算
  canvas.lua      字符画布（宽字符/span/边框/标题）
  card.lua        卡片构造 + 构造期校验
  layout.lua      尺寸分配 + 递归摆放
  render.lua      画布 -> 浮窗落盘（diff/flush）
  app.lua         浮窗、焦点、重绘调度
  theme.lua       高亮组 + 派生高亮
  widgets/        text / list / tree
demo/init.lua     lazygit 风格示例
tests/            单测 + golden + headless 集成测试
tm.sh             私有 tmux server（demo 验证用）
```
