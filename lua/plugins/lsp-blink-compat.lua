-- blink.cmp 的 LSP 能力注入。
--
-- 为什么不能只靠 blink 自己：blink 在 plugin/blink-cmp.lua 里 patch
-- vim.lsp.config("*")，但它 event = { "InsertEnter", "CmdlineEnter" } 才加载，
-- 而 LazyVim 的 lspconfig 在 BufReadPre 就已经启动服务器 —— 服务器启动那一刻
-- capabilities 里没有 snippetSupport / resolveSupport / labelDetailsSupport 这些。
-- 所以要在服务器启动前把它们并进 servers["*"]。
--
-- （之前这里还有一条 { "hrsh7th/cmp-nvim-lsp", enabled = false }：该插件根本没装，
-- LazyVim 的 blink extra 已经替我们关掉了 nvim-cmp，属于空操作，已删除。）
return {
  {
    "neovim/nvim-lspconfig",
    opts = function(_, opts)
      local blink = require("blink.cmp")
      local all = opts.servers["*"] or {}
      -- get_lsp_capabilities(override, include_nvim_defaults)：第二个参数会把
      -- Neovim 默认能力一起并进来，override 里已有的键（如 LazyVim 设的
      -- workspace.fileOperations）保持优先。
      all.capabilities = blink.get_lsp_capabilities(all.capabilities, true)
      opts.servers["*"] = all
    end,
  },
}
