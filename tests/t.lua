-- Minimal assertion helper for the tests.
local t = { passes = 0, fails = 0 }

local function show(v)
  if type(v) == "table" then return textutils.serialise(v, { compact = true }) end
  return tostring(v)
end

function t.eq(actual, expected, msg)
  if actual == expected then
    t.passes = t.passes + 1
  else
    t.fails = t.fails + 1
    print("FAIL " .. (msg or "") .. ": expected " .. show(expected) .. ", got " .. show(actual))
  end
end

function t.truthy(v, msg) t.eq(not not v, true, msg) end

function t.contains(haystack, needle, msg)
  if type(haystack) == "string" and haystack:find(needle, 1, true) then
    t.passes = t.passes + 1
  else
    t.fails = t.fails + 1
    print("FAIL " .. (msg or "") .. ": '" .. tostring(needle) .. "' not found in " .. show(haystack))
  end
end

function t.finish(name)
  print((name or "tests") .. ": " .. t.passes .. " passed, " .. t.fails .. " failed")
  if t.fails > 0 then error(t.fails .. " test(s) failed", 0) end
end

return t
