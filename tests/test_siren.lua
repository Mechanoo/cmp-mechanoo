local t = require("tests.t")
local siren = require("lib.siren")

local wail = siren.build("wail")
local yelp = siren.build("yelp")
t.eq(#wail, 48000, "wail 1 s")
t.eq(#yelp, 48000, "yelp 1 s")
t.eq(siren.build("nope"), nil, "unknown mode")

local function check(buf, name)
  local min, max, ok = 0, 0, true
  for _, v in ipairs(buf) do
    if v % 1 ~= 0 then ok = false end
    if v < min then min = v end
    if v > max then max = v end
  end
  t.truthy(ok, name .. ": whole numbers")
  t.truthy(min >= -128 and max <= 127, name .. ": in range")
  t.truthy(max >= 90 and min <= -90, name .. ": loud")
end
check(wail, "wail")
check(yelp, "yelp")

-- the pitch really sweeps: count zero crossings per 1/8 s
local function crossings(buf, from, to)
  local n = 0
  for i = from + 1, to do
    if (buf[i - 1] < 0) ~= (buf[i] < 0) then n = n + 1 end
  end
  return n
end
local low = crossings(wail, 1, 6000)          -- start of the cycle: low pitch
local high = crossings(wail, 21000, 27000)    -- middle of the cycle: high pitch
t.truthy(high > low * 1.5, "wail rises: " .. low .. " -> " .. high)

-- which siren for which situation
t.eq(siren.modeFor({}), nil, "nothing -> silent")
t.eq(siren.modeFor({ a = { action = "watch" }, b = { action = "friendly" } }), nil, "watch -> silent")
t.eq(siren.modeFor({ a = { action = "warn" } }), "wail", "countdown -> wail")
t.eq(siren.modeFor({ a = { action = "warn" }, b = { action = "engage" } }), "yelp", "engage wins")
t.eq(siren.modeFor({ a = { action = "pending" } }), nil, "pending -> silent")

t.finish("siren")
