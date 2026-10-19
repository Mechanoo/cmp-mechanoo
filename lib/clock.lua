-- Time helpers. All times are os.epoch("utc") milliseconds.
local C = {}

function C.tzName(offsetHours)
  if not offsetHours or offsetHours == 0 then return "UTC" end
  return "UTC" .. (offsetHours > 0 and "+" or "-") .. tostring(math.abs(offsetHours))
end

-- "14:02" in the given offset from UTC
function C.hm(ms, offsetHours)
  return os.date("!%H:%M", math.floor(ms / 1000 + (offsetHours or 0) * 3600))
end

-- "2026-10-19T14:02:00Z" for Discord embeds
function C.iso(ms)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(ms / 1000))
end

-- Discord timestamp markup. Discord shows it in the reader's own time zone.
-- style: "t" = 14:02, "R" = "in 5 minutes" (counts down live), "f" = date and time
function C.discord(ms, style)
  return "<t:" .. math.floor(ms / 1000) .. ":" .. (style or "t") .. ">"
end

return C
