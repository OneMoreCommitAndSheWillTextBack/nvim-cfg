return {
  {
    "hrsh7th/cmp-nvim-lsp",
    enabled = false,
  },
  {
    "neovim/nvim-lspconfig",
    opts = function(_, opts)
      local blink = require("blink.cmp")
      local all = opts.servers["*"] or {}
      all.capabilities = blink.get_lsp_capabilities(all.capabilities, true)
      opts.servers["*"] = all
    end,
  },
}
