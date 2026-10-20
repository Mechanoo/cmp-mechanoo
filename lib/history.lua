-- Visit history of players: how often and when they were at the base.
-- Fed with "visit_end" events from the policy. Stored in /void-data/history.json.
local D = require("lib.duration")

local H = {}

H.KEEP = 20 -- visits kept per player (the count keeps going)

H.KEEP_DAYS = 60 -- days kept in the daily statistics

-- (times before 1970 only happen in tests; they count as 1970-01-01)
local function local_s(ms, offsetHours) return math.max(0, math.floor(ms / 1000 + (offsetHours or 0) * 3600)) end

local function dayKey(ms, offsetHours) return os.date("!%Y-%m-%d", local_s(ms, offsetHours)) end

-- hours are stored in the time zone that was set when the visit was recorded
local function hourOf(ms, offsetHours) return tonumber(os.date("!%H", local_s(ms, offsetHours))) end

-- Adds one visit to the per-player and daily statistics.
local function addStats(h, p, v, offsetHours)
  local ms = v.stop - v.start
  if not p.longestMs or ms > p.longestMs then p.longestMs = ms end
  if v.closest and (not p.closestEver or v.closest < p.closestEver) then p.closestEver = v.closest end
  if v.zone then p.zoneVisits = (p.zoneVisits or 0) + 1 end
  p.hours = p.hours or {}
  for i = 1, 24 do p.hours[i] = p.hours[i] or 0 end
  local hr = hourOf(v.start, offsetHours) + 1
  p.hours[hr] = p.hours[hr] + 1
  local k = dayKey(v.start, offsetHours)
  local d = h.days[k]
  if not d then
    d = { visits = 0, ms = 0, zone = 0, names = {} }
    h.days[k] = d
  end
  d.visits = d.visits + 1
  d.ms = d.ms + ms
  if v.zone then d.zone = d.zone + 1 end
  local seen = false
  for _, n in ipairs(d.names) do if n == p.name then seen = true end end
  if not seen then d.names[#d.names + 1] = p.name end
end

local function trimDays(h)
  local keys = {}
  for k in pairs(h.days) do keys[#keys + 1] = k end
  table.sort(keys)
  for i = 1, #keys - H.KEEP_DAYS do h.days[keys[i]] = nil end
end

function H.new(data, offsetHours)
  data = data or {}
  local h = { players = data.players or {}, days = data.days, dirty = false }
  -- histories from before the statistics: build them from the stored recent visits
  if not h.days then
    h.days = {}
    for _, p in pairs(h.players) do
      if not p.hours then
        for _, v in ipairs(p.recent or {}) do addStats(h, p, v, offsetHours) end
      end
    end
    trimDays(h)
  end
  return h
end

function H.data(h)
  return { players = h.players, days = h.days }
end

-- Records a finished visit. Only players with a name are recorded.
-- offsetHours: time zone for the daily and hourly statistics.
function H.record(h, ev, offsetHours)
  local t = ev.target
  if not t or t.kind ~= "player" or not t.name or not ev.start or not ev.stop then return false end
  local k = string.lower(t.name)
  local p = h.players[k]
  if not p then
    p = { name = t.name, visits = 0, first = ev.start, recent = {} }
    h.players[k] = p
  end
  p.name = t.name
  if not p.totalMs then -- entries from before this field: sum what is still stored
    p.totalMs = 0
    for _, v in ipairs(p.recent) do p.totalMs = p.totalMs + (v.stop - v.start) end
  end
  p.totalMs = p.totalMs + (ev.stop - ev.start)
  p.visits = p.visits + 1
  p.last = ev.stop
  p.lastList = t.cls
  local v = {
    start = ev.start, stop = ev.stop, list = t.cls,
    closest = ev.closest and math.floor(ev.closest + 0.5) or nil, zone = ev.enteredZone or nil,
  }
  table.insert(p.recent, 1, v)
  while #p.recent > H.KEEP do table.remove(p.recent) end
  addStats(h, p, v, offsetHours)
  trimDays(h)
  h.dirty = true
  return true
end

function H.get(h, name)
  return h.players[string.lower(name)]
end

-- Total time a player spent near the base, in ms.
function H.totalMs(p)
  if p.totalMs then return p.totalMs end
  local sum = 0
  for _, v in ipairs(p.recent or {}) do sum = sum + (v.stop - v.start) end
  return sum
end

-- Visitors sorted by total time (longest first): { {name, visits, totalMs, last}, ... }
function H.top(h, limit)
  local all = {}
  for _, p in pairs(h.players) do
    all[#all + 1] = { name = p.name, visits = p.visits, totalMs = H.totalMs(p), last = p.last }
  end
  table.sort(all, function(a, b)
    if a.totalMs ~= b.totalMs then return a.totalMs > b.totalMs end
    return a.name:lower() < b.name:lower()
  end)
  while limit and #all > limit do table.remove(all) end
  return all
end

-- Number of visits that started within the last `windowMs` (from the stored recent visits).
function H.recentCount(h, now, windowMs)
  local n = 0
  for _, p in pairs(h.players) do
    for _, v in ipairs(p.recent or {}) do
      if now - v.start <= windowMs then n = n + 1 end
    end
  end
  return n
end

-- Statistics of the last `days` days (today included), for the screen:
-- { days = { {key, visits, ms, zone, players}, ... oldest first }, visits, ms, zone, players,
--   hours = {24 counts, all time, all players}, avgMs }
function H.stats(h, now, days, offsetHours)
  local out = { days = {}, visits = 0, ms = 0, zone = 0, players = 0, hours = {} }
  local names = {}
  for i = days - 1, 0, -1 do
    local k = dayKey(now - i * 86400000, offsetHours)
    local d = h.days[k]
    local e = { key = k, visits = d and d.visits or 0, ms = d and d.ms or 0, zone = d and d.zone or 0,
      players = d and #d.names or 0 }
    out.days[#out.days + 1] = e
    out.visits, out.ms, out.zone = out.visits + e.visits, out.ms + e.ms, out.zone + e.zone
    if d then for _, n in ipairs(d.names) do names[n:lower()] = true end end
  end
  for _ in pairs(names) do out.players = out.players + 1 end
  for i = 1, 24 do out.hours[i] = 0 end
  for _, p in pairs(h.players) do
    for i = 1, 24 do out.hours[i] = out.hours[i] + ((p.hours and p.hours[i]) or 0) end
  end
  out.avgMs = out.visits > 0 and math.floor(out.ms / out.visits) or 0
  return out
end

-- Hour of day (0-23) with the most visits of a player, or nil.
function H.peakHour(p)
  local best, n = nil, 0
  for i = 1, 24 do
    local c = p.hours and p.hours[i] or 0
    if c > n then best, n = i - 1, c end
  end
  return best
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
  local lines = { ("%s: %d visit%s since %s, %s in total"):format(p.name, p.visits, p.visits == 1 and "" or "s",
    H.time(p.first, offsetHours), D.format(H.totalMs(p))) }
  for _, v in ipairs(p.recent) do
    lines[#lines + 1] = ("%s  %s  %s%s%s"):format(H.time(v.start, offsetHours), D.format(v.stop - v.start),
      v.list or "?", v.closest and (", closest " .. v.closest) or "", v.zone and ", in zone" or "")
  end
  return lines
end

return H
