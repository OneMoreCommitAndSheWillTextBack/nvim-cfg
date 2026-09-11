-- Lazy.nvim discovers this directory through its init.lua. Theme specs use the
-- `theme-<name>.lua` convention and are returned as one importable spec.
return {
  require("plugins.theme.theme-blue"),
  require("plugins.theme.theme-default"),
  require("plugins.theme.theme-everforest"),
  require("plugins.theme.theme-gruvbox"),
  require("plugins.theme.theme-monokai"),
  require("plugins.theme.theme-nord"),
}
