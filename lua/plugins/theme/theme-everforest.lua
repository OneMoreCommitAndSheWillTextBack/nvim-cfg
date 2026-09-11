return {
  "sainnhe/everforest",
  lazy = false,

  init = function()
    require("config.cinder_terminal_themes").register("everforest", function(hl)
      local colors_override = vim.g.everforest_colors_override
      if colors_override == nil then
        colors_override = vim.empty_dict()
      end
      local palette = vim.fn["everforest#get_palette"](vim.g.everforest_background or "medium", colors_override)

      local function color(name)
        return palette[name][1]
      end

      vim.api.nvim_set_hl(0, hl.normal, {
        fg = color("fg"),
        bg = color("bg_dim"),
      })
      vim.api.nvim_set_hl(0, hl.sidebar, {
        fg = color("fg"),
        bg = color("bg1"),
      })
      vim.api.nvim_set_hl(0, hl.selected, {
        fg = color("fg"),
        bg = color("bg2"),
        bold = true,
      })
      vim.api.nvim_set_hl(0, hl.border, {
        fg = color("green"),
        bg = color("bg_dim"),
      })
      vim.api.nvim_set_hl(0, hl.title, {
        fg = color("green"),
        bg = color("bg_dim"),
        bold = true,
      })
    end)
  end,
}
