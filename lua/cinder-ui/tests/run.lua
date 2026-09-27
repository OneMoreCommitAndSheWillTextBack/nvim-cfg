-- usage: cd /tmp/cinder-ui && nvim --headless -u NONE -i NONE -l tests/run.lua
local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(script, ":p:h:h")
vim.opt.rtp:append(root)
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  root .. "/?.lua",
  package.path,
}, ";")

local H = require("tests.h")
local specs = vim.fn.glob(root .. "/tests/*_spec.lua", false, true)
table.sort(specs)
for _, file in ipairs(specs) do
  io.write("== " .. vim.fn.fnamemodify(file, ":t") .. "\n")
  local ok, err = pcall(dofile, file)
  if not ok then
    H.failed = H.failed + 1
    H.failures[#H.failures + 1] = "error in " .. vim.fn.fnamemodify(file, ":t") .. ": " .. tostring(err)
  end
end
print(string.format("%d passed, %d failed", H.passed, H.failed))
for _, f in ipairs(H.failures) do
  print("FAIL " .. f)
end
os.exit(H.failed == 0 and 0 or 1)
