-- tiny test helpers shared by all specs
local H = { passed = 0, failed = 0, failures = {} }

function H.ok(cond, msg)
  if cond then
    H.passed = H.passed + 1
  else
    H.failed = H.failed + 1
    H.failures[#H.failures + 1] = msg or "ok() failed"
  end
end

function H.eq(actual, expected, msg)
  if actual == expected then
    H.passed = H.passed + 1
  else
    H.failed = H.failed + 1
    H.failures[#H.failures + 1] = string.format(
      "%s\n    expected: %s\n    actual:   %s",
      msg or "eq failed",
      vim.inspect(expected),
      vim.inspect(actual)
    )
  end
end

function H.has(list, needle, msg)
  if type(list) == "table" then
    for _, e in ipairs(list) do
      if type(e) == "string" and e:find(needle, 1, true) then
        H.passed = H.passed + 1
        return
      end
    end
  end
  H.failed = H.failed + 1
  H.failures[#H.failures + 1] = string.format(
    "%s\n    expected an entry containing: %s\n    in: %s",
    msg or "has failed",
    vim.inspect(needle),
    vim.inspect(list)
  )
end

return H
