# cinder-terminal.nvim

One floating workspace for every terminal you own. A containers card on top
left, the terminals of the selected container in the card below it, and the
terminal card on the right — the layout lazygit uses. The chrome is drawn with
the card library in `lua/cinder-ui` (no snacks.nvim dependency): the whole
workspace is one card tree in a single buffer, and the pane's real terminal
window covers the content area of the card it belongs to.

```text
╭─Containers──────────────╮╭─Terminal────────────────────────────────────╮
│  local  1 shell         ││                                             │
╰─────────────────────────╯│                                             │
╭─local───────────────────╮│                                             │
│1 ~/Code/task/nvim-c...  ││                                             │
│                         ││                                             │
╰─────────────────────────╯╰─────────────────────────────────────────────╯
 [C-\ / Esc Esc] normal mode  [C-b] items  [C-/] hide
```

Two providers supply the rows:

- `local` — Neovim pty sessions. One fixed row that holds every shell; the
  first open starts one (so the workspace opens on a job, not on an empty
  list) unless `providers.local.auto_shell = false`. Hiding the workspace
  keeps the shells alive, quitting Neovim does not.
- `tmux` — tmux sessions (rows) and their windows (items), driven by a single
  embedded tmux client. Quitting Neovim leaves the tmux server untouched.

The session that hosts Neovim is marked `current`. It can be browsed, but
attaching to it or killing it is refused: the embedded client would resize the
very pane Neovim runs in, and killing it would take the editor down.

Adding a backend later (docker, ssh) means adding a provider, not a panel.

## Keymaps

The plugin installs no global mappings; the panels use buffer-local ones.

| Context | Keys |
| --- | --- |
| Containers | `j`/`k` (counts), `gg`/`G`, `<C-d>`/`<C-u>` move, `l` or `<CR>` open, `n` new, `d` kill, `r` rename, `R` refresh/retry, `q` hide, `?` keys |
| Terminals | `j`/`k` (counts), `gg`/`G`, `<C-d>`/`<C-u>` move, `1`-`9`/`0` switch to that terminal, `h` containers, `l` or `<CR>` focus terminal, `n` new, `d` kill, `r` rename (tmux) or restart (local) |
| Terminal pane, typing | `<C-\>` or `<Esc><Esc>` leave the job; `<C-b>` brings the terminal list back |
| Terminal pane, normal mode | `i` back to the job, `j`/`k`, `gg`, `<C-d>` and every other native key (scroll, `v`/`y` select and yank, `/` search, `q` records a macro), `<Tab>` back to the list |
| Anywhere (not while typing) | `<Tab>`/`<S-Tab>` swap the sidebar and the terminal pane, `<C-/>` hide |

`<Tab>` is a *swap*, not a walk through every panel: it hands the keyboard to
the terminal from either sidebar panel, and comes back to the terminal list.
The containers panel is deliberately not a stop — a terminal is nearly always
picked from the list of the container that is already selected, so stopping on
the tree first cost a keystroke on every switch. The tree is still one key
away: `h` from the list goes up to the containers, `l` (or `<CR>`) opens the
container under the cursor and comes back down. Each hint row says where the
swap goes in that context.

The list is the fastest way between terminals: it wears the digit of each of
its first ten rows, and that digit switches to the terminal and hands it the
keyboard in one keystroke (`0` is the tenth). `<C-b>` in the pane does the
opposite trip — it leaves the job for the list, which is also where the tmux
prefix used to be spent; the provider does not intercept tmux keys any more.

The pane no longer spends `q`/`h` on the same jump: in normal mode `q` records
a macro and `h` is a motion, as they are in any other buffer. The action is
still in the table, just unbound — `keymaps = { items = "q" }` puts the old
jump back, and the hint row starts advertising it again.

The sidebar rows are card data, not a buffer cursor, so the familiar motions
are bound by the plugin instead of inherited: `j`/`k` take a count, `gg`/`G`
jump to the ends and `<C-d>`/`<C-u>` move half a card at a time. `R` re-reads
every provider and retries a terminal that failed to attach, which is also how
a tmux client that backed off after repeated failures comes back.

Every key above is declared once in `lua/cinder_terminal/interaction.lua`: the
same table generates the buffer-local mappings, the hint row and the `?` popup,
which is why the row can only ever advertise a key the current mode really
binds.

The pane has the two modes Neovim users expect. **Typing** sends every key to
the job, and the pane reserves nothing but the escape keys. **Normal mode** is
a real normal mode: `v`, `y`, `d`, per-cent, `/`, `gg` are Neovim's own, so
selecting and yanking scrollback works with the muscle memory you already have,
and the buffer is read-only like any other terminal buffer. `q`, `h` and the
rest are left alone, so the pane never costs you a motion or the record key:
`<Tab>` is the one key that leaves it.

`<C-\>` leaves the job in one key, and `<Esc><Esc>` does the same, because
that is the gesture people reach for. The pane binds a *single* `<Esc>`,
forwards that byte to the job itself, and only a second press within
`escape_window` (300ms) counts as the gesture: a literal `<Esc><Esc>` mapping
would make Neovim hold every lone `<Esc>` for `timeoutlen` before the job saw
it, and `<Esc>` is the key a TUI waits for, so `timeoutlen` plays no part
here. The price is exact and worth knowing: the gesture sends one `<Esc>` to
the job, so a program that treats `<Esc>` as a prefix (readline, emacs) reads
it as Meta and applies it to the next key typed. `<C-\>` is consumed by
Neovim and is the one to use when the job must not see an `<Esc>` at all.
`keymaps.terminal_normal` replaces the escape list (a string, a list, or
`false` to keep only Neovim's own sequence), so a pane that needs `<C-\>`
literally — a nested editor — can turn it off.

The pane looks identical in both modes, so the title gains `normal`, and the
hint row only ever names keys that really work right now: while typing it shows
the escape keys and the way back to the list (`<C-b>`), never `<Tab>` or `?`,
which the job would receive as input instead.

Killing or restarting the terminal shown in the right panel never takes the
workspace down with it: the pane is released before the old buffer goes away,
and `WinClosed` hides the workspace instead of leaving half of it on screen if
a panel window is closed from the outside. The workspace itself is a card tree
(`lua/cinder_terminal/ui/render.lua` `build_tree()`): sidebar column, terminal
card and a one-row hint card, redrawn into the app buffer on every change; only
the terminal pane is a second, real window. The `ui/` directory splits the
workspace by responsibility — `workspace.lua` (lifecycle and windows),
`selection.lua`, `render.lua`, `terminal.lua` (pane modes and attach),
`refresh.lua`, `actions.lua`, `keys.lua` (mapping) and `util.lua`; each module
returns a method table that `init.lua` merges into `CinderTerminal.UI`.

## Commands

`:CinderTerminalToggle`, `:CinderTerminalFocus`, `:CinderTerminalFocusSidebar`,
`:CinderTerminalSelect`, `:CinderTerminalNew`, `:CinderTerminalTmux`,
`:CinderTerminalRefresh`, `:CinderTerminalNext`, `:CinderTerminalPrev`,
`:CinderTerminalClose`.

## Tests

```sh
nvim --headless -u NONE -i NONE -l tests/run.lua   # fast, no terminal emulator
python3 tests/e2e_modes.py                         # real pty: Terminal-Job mode
python3 tests/e2e_modes.py --tmux                  # the same, through tmux
```

The headless suite cannot hold Terminal-Job mode, so `tests/e2e_modes.py`
drives Neovim in a pty to check what only a real terminal can show: the pane
lands in the job on focus, the hint row follows the mode, a lone `<Esc>`
reaches the job without waiting for `timeoutlen`, and `<Esc><Esc>` leaves it
for a normal mode where `v`/`y`/`gg` are Neovim's own. `--tmux` runs the
whole set again through a tmux client, against a private server in a throwaway
`TMUX_TMPDIR` — it never touches the tmux sessions you are working in.

See [`doc/cinder_terminal.txt`](doc/cinder_terminal.txt) for the full option and
API reference and [`doc/des.md`](doc/des.md) for the design.
