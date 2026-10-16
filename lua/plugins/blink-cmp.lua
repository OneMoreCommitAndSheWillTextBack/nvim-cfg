return {
  "saghen/blink.cmp",
  opts = {
    -- appearance.nerd_font_variant 由 LazyVim 的 blink extra 设为 "mono"，不再重复。
    completion = {
      menu = {
        border = "rounded",
        max_height = 12,
        min_width = 15,
        winblend = 0,
        scrollbar = true,
        draw = {
          -- 图标 | 提示名+描述 | 类型 | 来源（minuet / lsp / path / buffer…）
          columns = {
            { "kind_icon" },
            { "label", "label_description", gap = 1 },
            { "kind" },
            { "source_name" },
          },
        },
      },
      documentation = {
        auto_show = true,
        auto_show_delay_ms = 400,
        window = {
          border = "rounded",
        },
      },
      ghost_text = {
        -- 注意：这里的 true 会盖掉 LazyVim 的 `ghost_text = vim.g.ai_cmp` 开关，
        -- 也就是幽灵文本常显（minuet 的预测也是这样显示的）。想跟随 AI 开关就删掉本项。
        enabled = true,
      },
    },
  },
}
