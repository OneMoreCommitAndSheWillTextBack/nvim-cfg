local plugin_dir = vim.fn.stdpath("config") .. "/lua/cinder-terminal"

return {
  {
    dir = plugin_dir,
    name = "cinder-terminal.nvim",
    main = "cinder_terminal",
    -- The workspace is drawn with the card library.
    dependencies = { "cinder-ui.nvim" },
    lazy = false,
    opts = {},
    config = function(_, opts)
      local terminal = require("cinder_terminal")
      terminal.setup(opts)
      require("config.cinder_terminal_themes").apply(terminal)
    end,
  },
}
