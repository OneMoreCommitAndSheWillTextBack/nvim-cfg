-- LazyVim + conform use LSP as the Scala formatter when no CLI formatter is set.
-- Without .scalafmt.conf, Metals asks an interactive question (showMessageRequest), which
-- blocks and often hits LSP timeout. When the config file exists, LSP formatting is fine.
local function has_scalafmt_conf(bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    return false
  end
  local root = vim.fs.root(path, { ".git", "build.sbt", "build.sc", "pom.xml", "mvnw", "mill" })
  if not root then
    return false
  end
  return vim.uv.fs_stat(root .. "/.scalafmt.conf") ~= nil
end

---@param bufnr integer
---@return conform.FiletypeFormatterInternal
local function scala_formatters(bufnr)
  if has_scalafmt_conf(bufnr) then
    return {}
  end
  return {
    lsp_format = "never",
    quiet = true,
  }
end

return {
  {
    "stevearc/conform.nvim",
    optional = true,
    opts = function(_, opts)
      opts.formatters_by_ft = opts.formatters_by_ft or {}
      opts.formatters_by_ft.scala = scala_formatters
      opts.formatters_by_ft.sbt = scala_formatters
      return opts
    end,
  },
}
