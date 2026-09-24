-- clangd: ask the real compiler for its system headers.
--
-- clangd discovers GCC's C++ headers by scanning /usr/lib/gcc/<triple>/<version>
-- and taking the highest version. This machine has a partial gcc-16 install
-- (crt*.o only, no libstdc++ headers) sitting next to the real gcc-15, so the
-- guess lands on /usr/include/c++/16 and every standard header goes missing
-- ("'cstdint' file not found"). --query-driver makes clangd run the actual
-- driver instead of guessing.
return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        clangd = {
          cmd = {
            "clangd",
            "--background-index",
            "--clang-tidy",
            "--header-insertion=iwyu",
            "--completion-style=detailed",
            "--function-arg-placeholders",
            "--fallback-style=llvm",
            "--query-driver=/usr/bin/g++,/usr/bin/gcc,/usr/bin/c++,/usr/bin/cc",
          },
        },
      },
    },
  },
}
