-- Visit history of players: how often and when they were at the base.
-- Fed with "visit_end" events from the policy. Stored in /void-data/history.json.
local D = require("lib.duration")

local H = {}

H.KEEP = 20 -- visits kept per player (the count keeps going)

function H.new(data)
  data = data or {}
  return { players = data.players or {}, dirty = false }
end

function H.data(h)
  return { players = h.players }
end

-- Records a finished visit. Only players with a name are recorded.
function H.record(h, ev)
  local t = ev.target
  if not t or t.kind ~= "player" or not t.name or not ev.start or not ev.stop then return false end
  local k = string.lower(t.name)
  local p = h.players[k]
  if not p then
    p = { name = t.name, visits = 0, first = ev.start, recent = {} }
    h.players[k] = p
  end
  p.name = t.name
  p.visits = p.visits + 1
  p.last = ev.stop
  p.lastList = t.cls
  table.insert(p.recent, 1, {
    start = ev.start, stop = ev.stop, list = t.cls,
    closest = ev.closest and math.floor(ev.closest + 0.5) or nil, zone = ev.enteredZone or nil,
  })
  while #p.recent > H.KEEP do table.remove(p.recent) end
  h.dirty = true
  return true
end

function H.get(h, name)
  return h.players[string.lower(name)]
end

-- "2026-10-19 14:02" in UTC, or with an offset in hours.
function H.time(ms, offsetHours)
  return os.date("!%Y-%m-%d %H:%M", math.floor(ms / 1000 + (offsetHours or 0) * 3600))
end

-- Text lines for the console.
function H.summary(h, offsetHours, limit)
  local all = {}
  for _, p in pairs(h.players) do all[#all + 1] = p end
  table.sort(all, function(a, b) return (a.last or 0) > (b.last or 0) end)
  local lines = {}
  for i, p in ipairs(all) do
    if limit and i > limit then break end
    lines[#lines + 1] = ("%-16s %3d visit%s, last %s"):format(p.name, p.visits, p.visits == 1 and " " or "s",
      H.time(p.last, offsetHours))
  end
  if #lines == 0 then lines[1] = "no visits recorded yet" end
  return lines
end

function H.details(h, name, offsetHours)
  local p = H.get(h, name)
  if not p then return { "no visits of " .. name } end
  local lines = { ("%s: %d visit%s since %s"):format(p.name, p.visits, p.visits == 1 and "" or "s", H.time(p.first, offsetHours)) }
  for _, v in ipairs(p.recent) do
    lines[#lines + 1] = ("%s  %s  %s%s%s"):format(H.time(v.start, offsetHours), D.format(v.stop - v.start),
      v.list or "?", v.closest and (", closest " .. v.closest) or "", v.zone and ", in zone" or "")
  end
  return lines
end

return H
