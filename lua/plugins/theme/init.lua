-- Lazy.nvim discovers this directory through its init.lua. Theme specs use the
-- `theme-<name>.lua` convention and are returned as one importable spec.
--
-- 当前真正生效的只有 everforest：theme-default.lua 把 colorscheme 设成它，
-- theme-everforest.lua 提供插件 + cinder-terminal 终端配色适配。
-- blue / nord / gruvbox / monokai 是「切过去才用得上」的备用配色：
-- 它们只注册对应 colorscheme 的终端配色适配（blue）或声明配色插件（其余三个），
-- 平时不会渲染、也不占用启动时间（实测启动只 source everforest）。
return {
  require("plugins.theme.theme-blue"),
  require("plugins.theme.theme-default"),
  require("plugins.theme.theme-everforest"),
  require("plugins.theme.theme-gruvbox"),
  require("plugins.theme.theme-monokai"),
  require("plugins.theme.theme-nord"),
}
