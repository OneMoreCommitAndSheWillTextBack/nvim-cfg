-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

local map = vim.keymap.set

-- Ctrl+Z = Redo
map("n", "<C-z>", "<C-r>", { desc = "Redo" })
map("x", "<C-z>", "<Esc><C-r>", { desc = "Redo" })
map("i", "<C-z>", "<C-g>u<C-o><C-r>", { desc = "Redo" })

-- LazyVim 把 <leader>l 绑到 :Lazy，这里只补一个 <leader>ll 别名。
-- 不再删除上游映射：删除只是把 pcall 的错误吞掉，换不来任何好处。
map("n", "<leader>ll", "<cmd>Lazy<cr>", { desc = "Lazy" })

local function terminal()
  return require("cinder_terminal")
end

map({ "n", "t" }, "<C-/>", function()
  terminal().toggle()
end, { desc = "Terminal Workspace" })

map({ "n", "t" }, "<C-_>", function()
  terminal().toggle()
end, { desc = "which_key_ignore" })

map("n", "<leader>ft", function()
  terminal().toggle()
end, { desc = "Terminal Workspace" })

map("n", "<leader>fT", function()
  terminal().focus()
end, { desc = "Focus Terminal Workspace" })

map("n", "<leader>ts", function()
  terminal().select()
end, { desc = "Select Terminal" })

map("n", "<leader>tf", function()
  terminal().open()
end, { desc = "New Terminal Session" })

map("n", "<leader>ta", function()
  terminal().add()
end, { desc = "Add Terminal Session" })

-- 不再全局占用 <BS>：它会吞掉 normal 模式左移，并在 picker/dashboard 里
-- 变成「误开新终端」。加终端统一用 <leader>ta。

map("n", "<Leader>tc", function()
  terminal().copy_current()
end, { desc = "Copy Current Session" })

map("n", "<leader>tr", function()
  terminal().restart_current()
end, { desc = "Restart Terminal Session" })

map("n", "<leader>tm", function()
  terminal().open_tmux()
end, { desc = "tmux Manager" })

map("n", "<leader>tx", function()
  terminal().close_current()
end, { desc = "Close Terminal Session" })

map("n", "<leader>tn", function()
  terminal().next()
end, { desc = "Next Terminal" })

-- <C-S-Right>/<C-S-Left> 需要终端把修饰键传成 CSI-u（kitty 键盘协议）。
-- ghostty/tmux 场景下还要在 ~/.tmux.conf 写 `set -g extended-keys on`，
-- 否则 shift+方向键到不了 Neovim（键位本身仍可用 <leader>tn / <leader>tp）。
map({ "t", "n" }, "<C-S-Right>", function()
  terminal().next()
end, { desc = "Next Terminal" })

map("n", "<leader>tp", function()
  terminal().prev()
end, { desc = "Previous Terminal" })

map({ "n", "t" }, "<C-S-Left>", function()
  terminal().prev()
end, { desc = "Previous Terminal" })
