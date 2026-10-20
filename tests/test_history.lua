local t = require("tests.t")
local history = require("lib.history")
local alerts = require("lib.alerts")

local h = history.new()
local base = 1760882520000 -- 2025-10-19 14:02:00 UTC
local function visit(name, startMin, minutes, cls, zone)
  return { type = "visit_end", target = { kind = "player", name = name, cls = cls or "unknown", id = "u-" .. name },
           start = base + startMin * 60000, stop = base + (startMin + minutes) * 60000, closest = 42.4, enteredZone = zone }
end

t.truthy(history.record(h, visit("Steve", 0, 7, "unknown", true)), "recorded")
history.record(h, visit("Steve", 120, 3))
t.eq(history.get(h, "steve").name, "Steve", "lookup is case-insensitive")
history.record(h, visit("Ann", 60, 30, "visitor"))
t.eq(history.record(h, { type = "visit_end", target = { kind = "ship", id = "s" }, start = 1, stop = 2 }), false, "ships not recorded")
t.eq(history.record(h, { type = "visit_end", target = { kind = "player" }, start = 1, stop = 2 }), false, "nameless not recorded")

local s = history.get(h, "STEVE")
t.eq(s.visits, 2, "two visits, case-insensitive")
t.eq(s.recent[1].start, base + 120 * 60000, "newest first")
t.eq(s.recent[2].closest, 42, "closest rounded")
t.truthy(s.recent[2].zone, "zone flag kept")
t.truthy(h.dirty, "dirty")

t.eq(history.time(base), "2025-10-19 14:02", "UTC time")
t.eq(history.time(base, 2), "2025-10-19 16:02", "UTC+2")

local sum = table.concat(history.summary(h, 0), "\n")
t.contains(sum, "Steve", "summary has Steve")
t.contains(sum, "2 visits", "visit count")
t.truthy(sum:find("Steve") < sum:find("Ann"), "sorted by last visit")
local det = table.concat(history.details(h, "steve", 2), "\n")
t.contains(det, "2 visits since 2025-10-19 16:02", "details header in UTC+2")
t.contains(det, "7m00s", "duration")
t.contains(det, "in zone", "zone note")
t.contains(table.concat(history.details(h, "nobody"), ""), "no visits", "unknown name")

for i = 1, 30 do history.record(h, visit("Many", i * 10, 1)) end
t.eq(#history.get(h, "Many").recent, history.KEEP, "only the newest visits are kept")
t.eq(history.get(h, "Many").visits, 30, "but all are counted")

local copy = history.new(textutils.unserialiseJSON(textutils.serialiseJSON(history.data(h))))
t.eq(history.get(copy, "Steve").visits, 2, "survives JSON")

-- Discord text
local ev = visit("Steve", 0, 7, "unknown", true)
ev.visits = 3
local ch, emb = alerts.format(ev, { now = base })
local text = emb.title .. "\n" .. emb.description
t.eq(ch, "log", "visit summary goes to the log")
t.eq(emb.title, "VISIT ENDED: Steve", "title")
t.contains(text, "From <t:" .. math.floor(base / 1000) .. ":t> to <t:", "Discord timestamps")
t.eq(text:find("UTC", 1, true), nil, "no zone text")
t.contains(text, "(7m00s)", "duration")
t.contains(text, "Was in the no-go zone", "zone")
t.contains(text, "Visits so far: 3", "count")
t.eq(alerts.format(visit("Me", 0, 5, "trusted")), nil, "trusted visits are not posted")


-- statistics: per day, per hour, per player
local hs = history.new()
local DAY = 86400000
local base = 20000 * DAY -- a midnight (UTC)
history.record(hs, { target = { kind = "player", name = "Ann", cls = "unknown" }, start = base + 14 * 3600000, stop = base + 14 * 3600000 + 600000, closest = 30, enteredZone = true })
history.record(hs, { target = { kind = "player", name = "Ann", cls = "unknown" }, start = base + DAY + 14 * 3600000, stop = base + DAY + 14 * 3600000 + 60000, closest = 80 })
history.record(hs, { target = { kind = "player", name = "Ben", cls = "visitor" }, start = base + DAY + 20 * 3600000, stop = base + DAY + 20 * 3600000 + 120000 })
local st = history.stats(hs, base + DAY + 21 * 3600000, 14)
t.eq(#st.days, 14, "14 days")
t.eq(st.days[14].visits, 2, "two visits today")
t.eq(st.days[13].visits, 1, "one yesterday")
t.eq(st.days[13].zone, 1, "yesterday's visit was in the zone")
t.eq(st.visits, 3, "visits in 14 days")
t.eq(st.players, 2, "two different players")
t.eq(st.zone, 1, "zone visits")
t.eq(st.hours[15], 2, "two visits at 14 h")
t.eq(st.hours[21], 1, "one at 20 h")
t.eq(st.avgMs, math.floor((600000 + 60000 + 120000) / 3), "average visit")
local ann = history.get(hs, "Ann")
t.eq(ann.longestMs, 600000, "longest visit")
t.eq(ann.closestEver, 30, "closest approach ever")
t.eq(ann.zoneVisits, 1, "zone visits per player")
t.eq(history.peakHour(ann), 14, "peak hour")
local hz = history.new()
history.record(hz, { target = { kind = "player", name = "Ann", cls = "unknown" }, start = base + 14 * 3600000, stop = base + 14 * 3600000 + 1000 }, 2)
t.eq(history.stats(hz, base + 15 * 3600000, 14, 2).hours[17], 1, "hours follow the time zone")
-- saved and loaded again
local again = history.new(textutils.unserialiseJSON(textutils.serialiseJSON(history.data(hs))))
t.eq(history.stats(again, base + DAY + 21 * 3600000, 14).visits, 3, "days survive saving")
-- old file without statistics: rebuilt from the recent visits
local old = textutils.unserialiseJSON(textutils.serialiseJSON(history.data(hs)))
old.days = nil
for _, p in pairs(old.players) do p.hours, p.longestMs, p.closestEver, p.zoneVisits = nil, nil, nil, nil end
local mig = history.new(old)
t.eq(history.stats(mig, base + DAY + 21 * 3600000, 14).visits, 3, "statistics rebuilt for old files")
t.eq(history.get(mig, "Ann").longestMs, 600000, "longest rebuilt")
-- only KEEP_DAYS days are kept
local hk = history.new()
for i = 1, history.KEEP_DAYS + 5 do
  history.record(hk, { target = { kind = "player", name = "X", cls = "unknown" }, start = base + i * DAY, stop = base + i * DAY + 1000 })
end
local nd = 0
for _ in pairs(hk.days) do nd = nd + 1 end
t.eq(nd, history.KEEP_DAYS, "old days dropped")
t.finish("history")
