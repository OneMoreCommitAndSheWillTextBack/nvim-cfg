vim.api.nvim_create_autocmd("ColorScheme", {
  pattern = "blue",
  callback = function()
    local visual = {
      fg = "#000000",
      bg = "#ffd75f",
      ctermfg = 16,
      ctermbg = 221,
    }

    local fix = {
      fg = "#d84e00",
      bg = "#d84e00",
      cterm = 131,
    }

    vim.api.nvim_set_hl(0, "Visual", visual)
    vim.api.nvim_set_hl(0, "VisualNOS", visual)

    -- Native popupmenu completion, used by Snacks input's `completion = "dir"`.
    -- blink.cmp has its own window renderer, so terminal cwd prompts need these too.
    vim.api.nvim_set_hl(0, "Pmenu", { link = "NormalFloat" })
    vim.api.nvim_set_hl(0, "PmenuSel", { link = "Visual" })
    vim.api.nvim_set_hl(0, "PmenuSbar", { link = "Pmenu" })
    vim.api.nvim_set_hl(0, "PmenuThumb", { link = "Visual" })

    vim.api.nvim_set_hl(0, "TodoBgFIX", {
      fg = "#ffffff",
      bg = fix.bg,
      ctermfg = 231,
      ctermbg = fix.cterm,
      bold = true,
    })
    vim.api.nvim_set_hl(0, "TodoFgFIX", {
      fg = fix.fg,
      bg = "NONE",
      ctermfg = fix.cterm,
    })
    vim.api.nvim_set_hl(0, "TodoSignFIX", {
      fg = fix.fg,
      bg = "NONE",
      ctermfg = fix.cterm,
    })
  end,
})
