-- cinder-terminal.nvim runtime entry point.
if vim.g.loaded_cinder_terminal then
  return
end
vim.g.loaded_cinder_terminal = true
require("cinder_terminal")
