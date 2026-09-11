# cinder-workspace

# cinder-workspace

Aggregate several project directories under one workspace directory using
directory symlinks. The workspace directory is persistent; `attach` and
`detach` update its links immediately.

```lua
local workspace = require("cinder_workspace")

workspace.new("rtl-sim")
workspace.attach("~/project/rtl", { name = "rtl" })
workspace.attach("~/project/simulator")
```

Set `CINDER_WORKSPACE` to an existing absolute directory to choose the parent
for new workspaces. If it is empty, `HOME` is used.

The `:CinderWorkspace` command dispatches `new`, `open`, `attach`, `detach`,
`close`, `list`, `export`, and `import`.

When a workspace is selected, `<leader>e` and `<leader>E` open the Snacks
explorer at its root. Without a selected workspace they retain the project-root
and cwd behaviors from LazyVim.

See [`doc/des.md`](doc/des.md) for behavior and [`doc/plan.md`](doc/plan.md)
for implementation details.
