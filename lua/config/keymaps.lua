-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

local map = vim.keymap.set

-- Ctrl+Z = Redo
map("n", "<C-z>", "<C-r>", { desc = "Redo" })
map("x", "<C-z>", "<Esc><C-r>", { desc = "Redo" })
map("i", "<C-z>", "<C-g>u<C-o><C-r>", { desc = "Redo" })

pcall(vim.keymap.del, "n", "<leader>l")
map("n", "<leader>ll", "<cmd>Lazy<cr>", { desc = "Lazy" })

local function terminal()
  return require("config.terminal")
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

map("n", "<BS>", function()
  terminal().add()
end, { desc = "Add Terminal Session" })

map("n", "<Leader>tc", function()
  terminal().copy_current()
end, { desc = "Copy Current Session" })

map("n", "<leader>tr", function()
  terminal().restart_current()
end, { desc = "Restart Terminal Session" })

map("n", "<leader>tx", function()
  terminal().close_current()
end, { desc = "Close Terminal Session" })

map("n", "<leader>tn", function()
  terminal().next()
end, { desc = "Next Terminal" })

map({ "t", "n" }, "<C-S-Right>", function()
  terminal().next()
end, { desc = "Next Terminal" })

map("n", "<leader>tp", function()
  terminal().prev()
end, { desc = "Previous Terminal" })

map({ "n", "t" }, "<C-S-Left>", function()
  terminal().prev()
end, { desc = "Previous Terminal" })
