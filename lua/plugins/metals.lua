-------------------------------------------------------------------------------
-- These are example settings to use with nvim-metals and the nvim built-in
-- LSP. Be sure to thoroughly read the `:help nvim-metals` docs to get an
-- idea of what everything does. Again, these are meant to serve as an example.
-- If you just copy pasta them, they should work, but hopefully after time
-- goes on you'll cater them to your own liking especially since some of the stuff
-- in here is just an example, not what you probably want your setup to be.
--
-- Unfamiliar with Lua and Neovim?
--  - Check out `:help lua-guide`
--
-- The below configuration also makes use of the following plugins besides
-- nvim-metals, and therefore is a bit opinionated:
--
-- - https://github.com/saghen/blink.cmp (LazyVim default; nvim-cmp is disabled)
--   Use blink.cmp LSP capabilities instead of cmp-nvim-lsp.
--
-- - https://github.com/folke/lazy.nvim for package management
-- - https://github.com/mfussenegger/nvim-dap for debugging
-- - https://github.com/j-hui/fidget.nvim for progress notifications
-------------------------------------------------------------------------------
local map = vim.keymap.set

-- 全局 completeopt 已在 lua/config/options.lua 设置：插件 spec 在解析期改全局选项
-- 依赖加载顺序，容易和 options.lua 互相覆盖。

----------------------------------
-- PLUGINS (lazy.nvim spec) ------
----------------------------------
return {
  {
    "scalameta/nvim-metals",
    dependencies = {
      -- Ensure blink.cmp is on rtp before Metals opts runs (LazyVim uses blink, not nvim-cmp).
      "saghen/blink.cmp",
      {
        "j-hui/fidget.nvim",
        opts = {},
      },
      {
        "mfussenegger/nvim-dap",
        config = function(self, opts)
          -- Debug settings if you're using nvim-dap
          local dap = require("dap")

          dap.configurations.scala = {
            {
              type = "scala",
              request = "launch",
              name = "RunOrTest",
              metals = {
                runType = "runOrTestFile",
                --args = { "firstArg", "secondArg", "thirdArg" }, -- here just as an example
              },
            },
            {
              type = "scala",
              request = "launch",
              name = "Test Target",
              metals = {
                runType = "testTarget",
              },
            },
          }
        end,
      },
    },
    ft = { "scala", "sbt", "java" },
    opts = function()
      local metals_config = require("metals").bare_config()

      -- Example of settings
      metals_config.settings = {
        showImplicitArguments = true,
        excludedPackages = { "akka.actor.typed.javadsl", "com.github.swagger.akka.javadsl" },
      }

      -- *READ THIS*
      -- I *highly* recommend setting statusBarProvider to either "off" or "on"
      --
      -- "off" will enable LSP progress notifications by Metals and you'll need
      -- to ensure you have a plugin like fidget.nvim installed to handle them.
      --
      -- "on" will enable the custom Metals status extension and you *have* to have
      -- a have settings to capture this in your statusline or else you'll not see
      -- any messages from metals. There is more info in the help docs about this
      metals_config.init_options.statusBarProvider = "off"

      -- Match blink.cmp LSP completion capabilities (do not use cmp-nvim-lsp; nvim-cmp is off in LazyVim).
      metals_config.capabilities = require("blink.cmp").get_lsp_capabilities(nil, true)

      metals_config.on_attach = function(client, bufnr)
        require("metals").setup_dap()

        -- 只保留 metals 特有的绑定。通用 LSP 键位交给 LazyVim
        -- （gd/gr/gI/gy/gD/K/<leader>ca/<leader>cc/<leader>cr/<leader>cR/
        -- <leader>cl = LSP Info/[d/]d…），在这里重复绑定只会覆盖上游语义：
        -- gD 变 definition、gi 抢掉内置「上次插入位置」、<leader>cl 抢掉 LSP
        -- Info、<leader>sh 抢掉帮助页、[c/]c 抢掉 diff 导航。
        local bo = { buffer = bufnr }

        map("n", "<leader>ws", function()
          require("metals").hover_worksheet()
        end, bo)

        -- Example mappings for usage with nvim-dap. If you don't use that, you can
        -- skip these
        map("n", "<leader>dc", function()
          require("dap").continue()
        end, bo)

        map("n", "<leader>dr", function()
          require("dap").repl.toggle()
        end, bo)

        map("n", "<leader>dK", function()
          require("dap.ui.widgets").hover()
        end, bo)

        map("n", "<leader>dt", function()
          require("dap").toggle_breakpoint()
        end, bo)

        map("n", "<leader>dso", function()
          require("dap").step_over()
        end, bo)

        map("n", "<leader>dsi", function()
          require("dap").step_into()
        end, bo)

        map("n", "<leader>dl", function()
          require("dap").run_last()
        end, bo)
      end

      return metals_config
    end,
    config = function(self, metals_config)
      local nvim_metals_group = vim.api.nvim_create_augroup("nvim-metals", { clear = true })
      vim.api.nvim_create_autocmd("FileType", {
        pattern = self.ft,
        callback = function()
          require("metals").initialize_or_attach(metals_config)
        end,
        group = nvim_metals_group,
      })
    end,
  },

  -- metals 需要 scala 解析器；LazyVim 的 nvim-treesitter spec 声明了
  -- opts_extend = { "ensure_installed" }，这里追加不会覆盖已有列表。
  {
    "nvim-treesitter/nvim-treesitter",
    opts = { ensure_installed = { "scala" } },
  },
}
