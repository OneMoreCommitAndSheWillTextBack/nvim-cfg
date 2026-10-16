-- LazyVim 自带 Snacks.lazygit（<leader>gg = 项目根、<leader>gG = cwd）以及
-- snacks 的 lazygit UI，因此不再需要 kdheepak/lazygit.nvim + plenary。
-- 这里只保留 <leader>lg 这个习惯用法作为别名，映射到同一个 Snacks.lazygit。
return {
  {
    "folke/snacks.nvim",
    optional = true,
    keys = {
      {
        "<leader>lg",
        function()
          Snacks.lazygit({ cwd = LazyVim.root.git() })
        end,
        desc = "Lazygit (Root Dir)",
      },
    },
  },
}
