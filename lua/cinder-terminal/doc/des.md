# cinder-terminal 设计

这份文档记录合并后的工作区设计：一套 UI，两个 backend。合并前的两个插件
（`cinder-terminal` 的 pty 会话、`cinder-tmux-manager` 的 tmux 管理）在这里
变成一个交互模型；tmux 管理现在住在 `providers/tmux.lua`，旧插件目录不再保留。

## 1. 心智模型

用户只有一棵两层的树，和三条规则：

```text
容器（顶栏）                终端（下栏）
local                     ← 本机的每个 shell
T  dev                    ← dev 里的 window
T  work
D  build-01               ← 以后扩展 docker
```

1. 光标在哪一行，右边就显示谁。
2. `n` 在光标所在的那一层新建。
3. `d` 删掉光标那一行，`r` 改名（local 终端是重启），`<CR>`/`l` 往下走一层。

顶栏的行 = 能装终端的东西；下栏的行 = 终端本身；右栏 = 光标指到的终端。
唯一的语义差别是存活范围，而且树上直接看得见：`local` 那一组随 Neovim 结束
而消失，`T`/`D` 那几组不受影响。

## 2. 面板与焦点

```text
root frame（唯一的外边框，focusable = false，zindex 40）
├── containers 面板  左上，rows 0..divider-1
├── items 面板       左下，rows divider+1..body-1
├── terminal 面板    右侧，整列，rows 0..body-1
└── help row         root buffer 的最后一行
```

- 区域坐标全部由 `layout.compute()` 一次算出（`lua/cinder_terminal/layout.lua`），
  面板是 relative = "win" 的子浮窗，外边框由 Neovim 画在 frame 之外，
  所以布局公式里没有边框格。
- 顶栏不用独立窗口：category 行是 containers 列表的一部分。
- 分隔符与 help 行由 frame buffer 绘制，只有 frame 拥有真正的 border。
- 焦点有三个位置：`containers` / `items` / `terminal`，但 `<Tab>` **不是**在三者
  之间轮转，而是在「侧栏」和「右栏」之间**交换**：侧栏任何一栏按 `<Tab>` 都把
  键盘交给终端，在终端里按 `<Tab>` 回到 shell 列表。容器面板刻意不在循环里 ——
  终端几乎总是在「已经选中的容器」的列表里挑的，让 `<Tab>` 先停一次树根，等于
  每次切换都要多按一次。树本身用 `h`（上一层）和 `l`（打开，下一层）走，
  提示行按当前所处的面写清楚 `<Tab>` 会去哪（`[Tab] terminal` / `[Tab] items`）。
- 聚焦的面板：标题用 `title` 高亮、相邻分隔符段变亮、cursorline 用 `selected`；
  失焦的面板标题降到 `title_inactive`、cursorline 用 `selected_inactive`。
  这就是 lazygit「活动面板边框发亮」的等价实现。
- `selected_inactive` 默认由 `CursorLine` 与 `Normal` 的背景按 55% 混合算出
  （`highlights.apply_inactive_cursorline()`），所以默认主题下「哪个面板有
  光标」也看得见；主题适配器仍然可以覆盖它。
- Neovim 0.12 没有 `CursorLineNC` 分组，失焦面板直接用 `winhighlight` 把
  `CursorLine` 映射到 `selected_inactive`。

## 3. 面板里的光标

列表是真正的 buffer，`j/k`、`gg/G`、`<C-d>/<C-u>`、`zz`、`/` 都是原生行为；
选择 = 光标位置的派生值（`CursorMoved` → 选中 id），不是插件自绘的选中态。
刷新时按 id 还原光标，所以轮询不会打断操作。

## 4. Provider 契约

```lua
P.name, P.mark, P.capabilities, P.create_labels
P:snapshot(cb)              -- cb(ok, containers: Node[])
P:show(node, cb)            -- cb(ok, buf) 决定右栏显示哪个 buffer
P:create_container(cb)
P:create_terminal(container, cb)
P:kill(node, cb)
P:rename(node, cb)
P:prepare()                 -- 首次 open（快照前）自备内容，local 用它开第一个 shell
P:on_change / P:on_buffer   -- 由 UI 注入
```

Node 的字段见 `lua/cinder_terminal/providers/init.lua`。keymap、help 行和
`?` 弹出菜单都出自 `lua/cinder_terminal/interaction.lua`：每个动作声明自己
属于哪张操作面、用哪个键、能力不满足时提示行怎么写。`local` 行没有
`d`/`r`，`tmux` 没有 `restart`，都是同一张表推出来的。

## 5. tmux 只用一个 client

- 插件在 Neovim 里只保留一个 `tmux attach` 进程，右栏永远复用它。
- 切换目标用 `switch-client -c <client_tty> -t '<session>:@<window>'`。
  tmux 的 current window 是 per-client 的，所以浏览侧栏不会移动其他终端里
  同一个 session 的画面；旧的 `select-window` 是 session 级的，会误伤。
- client tty 由 `jobpid(job)` 与 `list-clients -F '#{client_pid} #{client_tty}'`
  匹配得到；attach 之后可能还没注册，所以带重试。
- 依次回退：`switch-client`（session + window）→ 同 session 时 `select-window`
  → 重连 client 再切。
- 隐藏工作区不杀 client（重开即时可用），插件卸载时才释放。
- `C-b` 归工作区：typing 模式下按它直接回终端列表（见 §6.6），字节不会再
  送进 tmux，所以 pane 里不再使用 tmux 前缀，窗口切换走面板（列表里的数字键
  一键直达）。焦点在右栏时，侧栏跟随 tmux 的 active window（焦点在列表时不
  跟随，避免操作被抢走）。

## 6. 生命周期

- 隐藏工作区：只关窗口，pty job 与 tmux client 都活着。
- `local` 会话：`bufhidden = hide`，job 存活；退出 Neovim 随之结束。
- tmux 会话：所有权在 tmux server，Neovim 只是客户端。
- 轮询只发生在工作区可见且 tmux provider 可用时（默认 1500ms）；pty 的变化
  由 job 的 `on_exit` 事件驱动，不轮询。

### 6.1 删除 buffer 前先腾出右栏

右栏窗口带 `winfixbuf`，而 Neovim 会**直接关掉**「唯一显示某 buffer、且该
buffer 被删除」的窗口 —— 所以 kill/restart 当前显示的终端时，右栏会跟着
消失，`is_open()` 变 false，之后所有操作静默失效。规则：

1. provider 通过可选的 `P:buffer(node)` 报告「删掉这个 node 时会删哪个
   buffer」；
2. UI 在 `kill` / `restart` 之前调用 `release_buffer()`，把右栏切回占位
   buffer（`bufhidden = hide`，否则它自己会被 wipe 掉，切换直接失败）；
3. 之后再让 provider 删旧 buffer。

`WinClosed` 兜底：任何面板窗口意外消失（`:q`、`:bd`、外部关闭）时隐藏整个
工作区，而不是留下半死状态。tmux client 每次 attach 都换一个新 buffer
（`termopen` 拒绝复用 `buftype=terminal` 的 buffer），旧的在没人显示后由
`snapshot` 的 sweep 回收。

### 6.2 tmux client 失败退避

attach 立刻失败（socket 不对、server 没了）时，client 会在
`focus → restart → on_exit → on_change → 再 attach` 之间死循环。因此：

- socket 从 `$TMUX` 继承，和其余命令保持一致（`attach-session` 之前会
  `env -u TMUX`，所以必须显式传 `-S`）；
- 连续 3 次「启动后很快退出」进入退避（2s、4s……上限 30s），退避期间
  `cb(false, nil, nil)` 静默失败、不再刷错误；
- 存活超过 1.5s 的 client 视为健康，清零计数；
- 用户按 `R` 时 UI 传 `opts.force`，provider 清零计数并立即重试。

### 6.3 `on_exit` 的第三个参数形状不固定

同一个 `termopen` 回调，Neovim 可能传**输出行数组**，也可能只传字符串
`"exit"`。内部 kill 掉被 attach 的 tmux 会话时恰好是后者：
`table.concat("exit", " ")` 直接抛错，错误发生在 job 回调里，Neovim 停在
`Press ENTER` 提示上 —— 表面症状是「界面卡住、右栏和列表都停在旧数据、
刷新定时器不再跑」。规则：解析统一走 `providers.exit_reason()`，数组、字符串、
nil、以及混了非字符串元素的数组都要能吃下；事件名 `"exit"` 本身算「没有原因」。

### 6.4 宿主会话：只展示，不 attach、不 kill

`$TMUX` 的第三个字段是 Neovim 自己所在的 session id，provider 记住它（以及
`$TMUX_PANE`）。把内嵌 client attach 到宿主会话会形成尺寸回环：client 让
tmux 把该 session resize 成 client 的尺寸 → 托管 Neovim 的 pane 变小 →
client 再变小…… 实测 200x55 的界面几次重绘后塌成 35x1。所以：

- 该 session 的行尾显示 `· current`；
- `show()` 直接拒绝，右栏显示 `cannot attach: Neovim runs inside this session`；
- `kill()` 也拒绝（杀宿主 session 或 Neovim 所在的 pane 等于自杀），
  node 上带 `locked` 原因，UI 在弹确认框**之前**就提示，不消耗一次确认。

### 6.5 面板高度与 frame 的 chrome

两个布局问题都会让「看不见」变成 bug：

1. 左侧容器面板的高度由容器数量决定，但 `reflow()` 原先只在 `VimResized`
   时调用 —— 工作区开着时新出现的 session 会被裁掉。现在
   `apply_snapshot` 后调 `fit_panels()`，容器数量变化就重排。
2. 每个面板都在自己的窗口里画一行 winbar（标题），所以「显示 n 行」需要
   `n + 1` 行窗口；`layout.compute` 用 `TITLE_ROWS` 统一留出这一行。
   frame 窗口是背景，不能有 winbar —— 否则它的 49 行内容挤进 48 行，
   最后一行（帮助行：按键提示与 `notify` 消息）永远不会显示。

### 6.6 两种模式：terminal mode 属于 job，normal mode 属于 Neovim

判据只有一条：**normal mode 是 Neovim 的，terminal mode（`t`）是 job 的。**

- terminal mode：除逃生键和回列表的 `<C-b>` 以外一律交给 job。所以帮助行
  **只列真正被拦截的键**（逃生键、`<C-b>`、用户自己全局绑的 `<C-/>`）；
  `<Tab>`、`?` 会被 job 收下，就不列 —— 提示行说谎正是「按键被吞掉」的
  体感来源。
- normal mode（`nt`）：terminal buffer 就是一个普通的只读 buffer，
  `v`、`y`、`d`、`gg`、`/` 全部保持原生语义，选区和复制直接用用户已有的
  肌肉记忆；插件不抢任何 operator 前缀、motion、宏录制键 —— 离开 pane 只靠
  `<Tab>`（面板里 `q`/`h` 的旧含义留给 normal mode 自己）。
- 逃生键：`<C-\>` 一键回 normal（Neovim 内置的 `<C-\><C-n>` 不再等第二个
  键），外加 `<Esc><Esc>`。`<Esc><Esc>` **不按字面绑定**：字面的两键映射会让
  Neovim 把每一个落单的 `<Esc>` 扣住 'timeoutlen' 才转发给 job，而 `<Esc>`
  恰好是 TUI 最常用的键。所以这里绑的是**单个 `<Esc>`**：按下即把字节转给
  job，只有 `escape_window`（默认 300ms）内的第二次按下才算手势（`translate`
  字段 + `ui:terminal_escape()`）。单个 `<Esc>` 因此零延迟，也和 'timeoutlen'
  彻底脱钩。要改逃生键照旧用 `keymaps.terminal_normal`：字符串、列表或 `false`
  （`false` 只剩 Neovim 自己的两键序列）。

provider 是异步 attach 的，`set_focus("terminal", { insert = true })` 往往
跑在真实 terminal buffer 换入之前；所以 `set_terminal_buffer` 在「占位
buffer 换成 terminal buffer、且这次进入的意图是 insert」时补一次
`startinsert`（`state.terminal_insert`）。否则面板会停在 normal mode，
用户以为在打字，按键却当成 normal 命令执行 —— 这是「terminal 吞键」的
另一半来源。用户已经在 normal mode 里看过的 pane 不会被重新插回 insert。

两种模式下面板长得一模一样，所以状态放在 chrome 上：normal 时右栏标题追加
`normal`，帮助行切到当前模式真正生效的键。`ModeChanged` 里同时刷新 winbar
和帮助行。标题里的标记是跟 buffer 走的：`state.terminal_insert` 记录 pane
自己的模式，所以光标移到列表后标记不会消失（`pane_normal_mode()`），而
帮助行仍然只看焦点（`terminal_normal_mode()`），它描述的是「现在按键去哪」。

### 6.7 键位只有一张表

`lua/cinder_terminal/interaction.lua` 是键位的唯一来源。每个动作声明：

- `surfaces`：`sidebar`（两个不可编辑的列表 buffer，全部动词）、`pane`
  （右栏 normal mode，只放导航和模式切换，**不抢 operator 前缀/motion**）、
  `typing`（右栏 terminal mode，除逃生键外全是 job 的）；
- `keys` / `option`：默认键，以及 `keymaps` 里覆盖它的条目；`panels` 在
  同一 surface 里再限定面板（数字切换只属于 items）；
- `run` 或 `rhs`：回调，或者直接给一个按键序列（逃生键用它）；
- `translate`：手上按的手势和实际绑定的键不是同一个东西时用它（目前只有
  `<Esc><Esc>`）；提示行里显示的始终是手势；
- `desc` / `help_desc`：提示行和 `?` 弹出菜单里怎么写，返回 `nil` 就是
  「当前能力不支持，别显示」。

`bindings()` 生成 `vim.keymap.set`（每个键一条，`lhs` 才是实际映射的键），
`hints()` 生成帮助行，`help_rows()` 生成 `?` 弹出菜单，三者不会再各写一份
而互相漂移；提示行可以缩写（`Tab` 代表 `Tab`/`S-Tab`），弹出菜单有地方，
就把键全拼出来。两条不变式由测试守着：
提示行里非 native 的键必须真的有 buffer-local 绑定；`NATIVE_PANE_KEYS`
里的键永远不许在 `pane` 面被绑定。

能力只过滤显示，不过滤绑定：一个列表面板同时服务 local 和 tmux，绑定时
无法知道用户会选中哪一行，所以处理器仍然自己检查能力并给出提示。

## 7. 高亮与主题

`lua/cinder_terminal/highlights.lua` 是唯一的配色层：默认 link 到语义组，
可以叠加用户 overrides，也可以按 colorscheme 注册适配器
（`config/cinder_terminal_themes.lua`）。分组：

```text
CinderTerminal.Normal / Sidebar / Selected / Border / Title
CinderTerminal.TitleInactive / SelectedInactive
CinderTerminal.Help / Mark / Detail / Error
```

前五个与合并前同名，`plugins/theme/*.lua` 里的适配器不用改。

## 8. 有意不做的事

- **pane 不进侧栏**：右栏里的窗口/终端切换由 `<C-b>` 回列表再按数字完成，
  不另做一套 pane 内快捷键，也不把 tmux 前缀让回给 tmux。
- **不做 `preview` 模式**：合并前 `tmux-manager` 的 `capture-pane` 只读预览
  没有迁移过来；如果以后需要，可以作为 `providers.tmux.mode = "preview"`
  加回，不影响现在的面板结构。
- **不做第三方 UI 依赖**：浮窗、边框、help 行全部用 `nvim_open_win` 与
  buffer 自绘。
