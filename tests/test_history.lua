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
local ch, emb = alerts.format(ev, { now = base, tz = 2 })
local text = emb.title .. "\n" .. emb.description
t.eq(ch, "log", "visit summary goes to the log")
t.eq(emb.title, "VISIT ENDED: Steve", "title")
t.contains(text, "<t:" .. math.floor(base / 1000) .. ":t> (16:02 UTC+2)", "Discord time and own zone")
t.contains(text, "(7m00s)", "duration")
t.contains(text, "Was in the no-go zone", "zone")
t.contains(text, "Visits so far: 3", "count")
t.eq(alerts.format(visit("Me", 0, 5, "trusted")), nil, "trusted visits are not posted")

t.finish("history")
