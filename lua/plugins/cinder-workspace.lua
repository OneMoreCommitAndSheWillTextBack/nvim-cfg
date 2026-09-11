-- Register the local plugin with Lazy before its implementation is added.
local plugin_dir = vim.fn.stdpath("config") .. "/lua/cinder-workspace"

return {
  {
    dir = plugin_dir,
    name = "cinder-workspace.nvim",
    main = "cinder_workspace",
    lazy = false,
    opts = {},
    config = function(_, opts)
      require("cinder_workspace").setup(opts)
    end,
  },
  {
    "folke/snacks.nvim",
    optional = true,
    opts = { explorer = {} },
    keys = {
      {
        "<leader>e",
        function()
          require("config.explorer").open("project")
        end,
        desc = "Explorer (workspace or project)",
      },
      {
        "<leader>E",
        function()
          require("config.explorer").open("cwd")
        end,
        desc = "Explorer (workspace or cwd)",
      },
    },
  },
}
