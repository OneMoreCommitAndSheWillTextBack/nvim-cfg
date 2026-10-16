-- LazyVim 的 lazyvim_checktime 已经负责 FocusGained / TermClose / TermLeave，
-- 这里只补「进入缓冲区」与「空闲」两种情形，并加上 nofile 保护，
-- 避免对 dashboard / lazy / nofile 缓冲做无意义的 checktime。
local group = vim.api.nvim_create_augroup("auto_read_external_files", { clear = true })

vim.api.nvim_create_autocmd({ "BufEnter", "CursorHold", "CursorHoldI" }, {
  group = group,
  callback = function()
    if vim.o.buftype ~= "nofile" then
      vim.cmd("checktime")
    end
  end,
})
