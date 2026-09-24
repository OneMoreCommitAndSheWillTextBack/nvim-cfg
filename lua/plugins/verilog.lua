return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        -- crashes on large SystemVerilog projects and spams the LSP log
        svlangserver = { enabled = false },
        -- semantic features: definitions, references, hover, inlay hints, diagnostics
        slang_server = {},
        -- style diagnostics, formatting and symbols
        verible = {
          cmd = {
            "verible-verilog-ls",
            "--rules=-parameter-name-style,-explicit-parameter-storage-type,"
              .. "-always-comb,-macro-name-style,-line-length",
          },
        },
      },
    },
  },
  {
    "stevearc/conform.nvim",
    opts = {
      formatters_by_ft = {
        systemverilog = { "verible" },
        verilog = { "verible" },
      },
    },
  },
  -- No lint-on-edit linter for RTL: verilator needs the whole file list, so
  -- single-file runs report packages/modules as "not found". Use <leader>cL.
  {
    "LazyVim/LazyVim",
    init = function()
      -- RTL is often generated or scaffolded: format on demand with <leader>cf
      vim.api.nvim_create_autocmd("FileType", {
        pattern = { "verilog", "systemverilog" },
        callback = function()
          vim.b.autoformat = false
        end,
      })

      -- project-wide verilator lint: nearest Makefile with a `lint` target
      local function lint_dirs(dir)
        local found = {}
        for _, pat in ipairs({ "", "*/", "*/*/", "*/*/*/" }) do
          for _, makefile in ipairs(vim.fn.glob(dir .. "/" .. pat .. "Makefile", false, true)) do
            for _, line in ipairs(vim.fn.readfile(makefile)) do
              if line:match("^lint:") then
                found[#found + 1] = vim.fn.fnamemodify(makefile, ":h")
                break
              end
            end
          end
        end
        return found
      end

      vim.keymap.set("n", "<leader>cL", function()
        local file = vim.api.nvim_buf_get_name(0)
        local dir = file ~= "" and vim.fn.fnamemodify(file, ":h") or vim.fn.getcwd()
        local candidates = {}
        local levels = { dir }
        local guard = 0
        while guard < 6 do
          local parent = vim.fn.fnamemodify(levels[#levels], ":h")
          if parent == levels[#levels] or parent == vim.fn.expand("~") then
            break
          end
          levels[#levels + 1] = parent
          guard = guard + 1
        end
        for _, ancestor in ipairs(levels) do
          candidates = lint_dirs(ancestor)
          if #candidates > 0 then
            break
          end
        end
        if #candidates == 0 then
          LazyVim.warn("no Makefile with a `lint` target found")
          return
        end
        local function run(choice)
          if choice then
            Snacks.terminal.open({ "make", "lint" }, { cwd = choice })
          end
        end
        if #candidates == 1 then
          run(candidates[1])
        else
          vim.ui.select(candidates, { prompt = "make lint in:" }, run)
        end
      end, { desc = "Verilator Lint (make lint)" })
    end,
  },
}
