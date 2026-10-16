-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

-- Format only when requested with <leader>cf.
vim.g.autoformat = false

vim.opt.autoread = true

-- 统一浮窗边框：LSP hover、diagnostic、mason、lazy 等没有自带 border 的窗口都会用上。
vim.o.winborder = "rounded"

-- "nv"：normal/visual 保留滚轮与点击聚焦，insert 模式不响应鼠标，避免误点。
-- 想要完整鼠标支持用 "a"（LazyVim 默认）；彻底关闭用 ""。
vim.opt.mouse = "nv"

-- 原生补全菜单（Snacks input 的 completion = "dir" 等）。
-- 注意：这比 LazyVim 默认的 "menu,menuone,noselect" 少了 menu、多了 noinsert，
-- 是刻意保留的既有行为；想回到默认值直接删掉这行。
vim.opt.completeopt = { "menuone", "noinsert", "noselect" }

-- autoread 只是「允许」重读；真正触发重读由 config/autocmds.lua 的 checktime 负责。
-- updatetime / timeoutlen / clipboard 交给 LazyVim 默认值（200 / 300 / SSH 感知），
-- 之前覆盖成 500 / 800 / unnamedplus 会让 hover、which-key 变慢并丢掉 SSH 下的 OSC52 兜底。
