-- cinder_ui: the card based TUI component library used by cinder-terminal.
local plugin_dir = vim.fn.stdpath("config") .. "/lua/cinder-ui"

return {
  {
    dir = plugin_dir,
    name = "cinder-ui.nvim",
    main = "cinder_ui",
    lazy = false,
    opts = {},
    config = function(_, opts)
      require("cinder_ui").setup(opts)
    end,
  },
}
