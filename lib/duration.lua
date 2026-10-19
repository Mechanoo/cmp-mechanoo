-- Durations like "45m", "2h", "1h30m", "90s". A bare number means minutes.
local D = {}

local UNIT = { s = 1000, m = 60000, h = 3600000, d = 86400000 }

-- Returns milliseconds, or nil if the text is not a duration.
function D.parse(text)
  if type(text) ~= "string" or text == "" then return nil end
  local s = text:lower()
  if s:match("^%d+$") then
    local n = tonumber(s) * UNIT.m
    return n > 0 and n or nil
  end
  if (s:gsub("%d+[smhd]", "")) ~= "" then return nil end
  local total = 0
  for num, unit in s:gmatch("(%d+)([smhd])") do
    total = total + tonumber(num) * UNIT[unit]
  end
  if total <= 0 then return nil end
  return total
end

function D.format(ms)
  if not ms or ms < 0 then ms = 0 end
  local sec = math.floor(ms / 1000 + 0.5)
  local h = math.floor(sec / 3600)
  local m = math.floor(sec % 3600 / 60)
  local s = sec % 60
  if h > 0 then return ("%dh%02dm"):format(h, m) end
  if m > 0 then return ("%dm%02ds"):format(m, s) end
  return s .. "s"
end

return D
