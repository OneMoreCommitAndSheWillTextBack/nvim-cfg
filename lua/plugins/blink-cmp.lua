return {
  "saghen/blink.cmp",
  opts = {
    appearance = {
      nerd_font_variant = "mono", -- font align
    },
    completion = {
      menu = {
        border = "rounded",
        max_height = 12,
        min_width = 15,
        winblend = 0,
        scrollbar = true,
        draw = {
          columns = {
            { "kind_icon" },
            { "label", "label_description", gap = 1 },
            { "kind" },
          },
        },
        -- 图表 提示名 描述 来源
      },
      documentation = {
        auto_show = true,
        auto_show_delay_ms = 400,
        window = {
          border = "rounded",
        },
      },
      ghost_text = {
        enabled = true,
      },
    },
  },
}
