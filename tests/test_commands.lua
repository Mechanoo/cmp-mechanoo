local t = require("tests.t")
local commands = require("lib.commands")
local lists = require("lib.lists")
local tracker = require("lib.tracker")
local alerts = require("lib.alerts")
local Z = require("lib.zone")

local ls = lists.new()
local tr = tracker.new()
local cfg = { zone = Z.fromCenter(0, 0, 10), visitorDefaultMs = 30 * 60000 }
local now = 1000000
tracker.update(tr, now, {
  { id = "8c98841d-1a03", category = "SABLE", position = { x = 20, y = 70, z = 0 }, velocity = { x = 0, y = 0, z = 0 } },
  { id = "8c11aaaa-0000", category = "SABLE", position = { x = 500, y = 70, z = 0 }, velocity = { x = 0, y = 0, z = 0 } },
}, { { name = "Steve", uuid = "u-steve", x = 30, y = 64, z = 0 } }, ls)

local ctx = { lists = ls, tracker = tr, config = cfg, now = now, radarCenter = { x = 160, y = 64, z = 160 } }
local function run(line)
  local r = commands.run(ctx, line)
  return table.concat(r.lines, "\n"), r
end

local out, r = run("help")
t.contains(out, "visitor <name>", "help lists visitor")

out = run("targets")
t.contains(out, "Steve", "targets shows the player")
t.contains(out, "ZONE", "targets shows zone flag")
t.contains(out, "unknown", "targets shows the list")

out, r = run("hostile Steve")
t.contains(out, "Steve is now hostile", "hostile")
t.eq(lists.player(ls, "steve").list, "hostile", "stored")
t.eq(r.events[1].type, "list_change", "list change event for the log")

out = run("visitor Steve 45m")
t.contains(out, "45m00s", "visitor with time")
t.eq(lists.player(ls, "Steve").expires, now + 45 * 60000, "expires in 45 min")
t.eq(lists.player(ls, "Steve").prev, "hostile", "prev hostile")
out = run("players")
t.contains(out, "then hostile", "players shows what comes after the visit")

out = run("visitor Bob")
t.contains(out, "30m00s", "default visitor time")
out = run("visitor Bob 10q")
t.contains(out, "bad time", "bad time rejected")
out = run("trust")
t.contains(out, "usage", "missing name")
out = run("trust bad-name!")
t.contains(out, "usage", "invalid name rejected")
out = run("forget Bob")
t.contains(out, "unknown again", "forget")
out = run("forget Bob")
t.contains(out, "was not on a list", "forget twice")

-- ships by id prefix
out = run("ship 8c trust")
t.contains(out, "at least 3", "prefix too short")
out = run("ship 8c9 trust")
t.contains(out, "is now trusted", "ship trusted by prefix")
t.eq(lists.ship(ls, "8c98841d-1a03").list, "trusted", "ship stored")
t.eq(lists.ship(ls, "8c98841d-1a03").lastPos.x, 20, "position stored for takeover")
out = run("ship 8c1 hostile")
t.contains(out, "is now hostile", "second ship hostile")
out = run("ship 8c hostile")
t.contains(out, "at least 3", "still too short")
lists.setShip(ls, "8c9xxxxx", "trusted", now)
out = run("ship 8c9 forget")
t.contains(out, "several ships", "ambiguous prefix")
lists.setShip(ls, "8c9xxxxx", nil, now)

out = run("label 8c98 Flagship")
t.contains(out, "Flagship", "label")
t.eq(lists.ship(ls, "8c98841d-1a03").label, "Flagship", "label stored")
out = run("ships")
t.contains(out, "Flagship", "ships shows label")
out = run("ship 8c98 visitor 1h")
t.contains(out, "1h00m", "ship visitor")
-- an old id after a reassembly is shown as replaced, not as a lost ship
ls.ships["oldship1"] = { id = "oldship1", list = "trusted", label = "Home", replacedBy = "newship1-xyz",
  replacedAt = now - 20000, lastSeen = now - 25000 }
out = run("ships")
t.contains(out, "old    ship oldship1 'Home' -> now newship1, gone in 40s", "old id marked as replaced")
ls.ships["oldship1"] = nil
out = run("ship zzz trust")
t.contains(out, "no ship", "unknown ship")

-- zone
out = run("zone")
t.contains(out, "10x10 chunks", "zone shows size")
out, r = run("zone center 100 200 4")
t.truthy(r.configChanged, "zone change saves config")
t.eq(cfg.zone.chunks, 4, "4 chunks")
t.eq(cfg.zone.x1, 64, "x1 for centre 100")
out = run("zone center 1 2 0")
t.contains(out, "usage", "0 chunks rejected")
out = run("zone radars")
t.eq(cfg.zone.x1, 80, "zone around the radars")
-- history / timezone
local history = require("lib.history")
ctx.history = history.new()
history.record(ctx.history, { type = "visit_end", target = { kind = "player", name = "Steve", cls = "unknown" },
  start = 1760882520000, stop = 1760882940000 })
out = run("history")
t.contains(out, "times in UTC", "history header")
t.contains(out, "Steve", "history lists Steve")
out, r = run("timezone 2")
t.truthy(r.configChanged, "timezone saved")
out = run("history steve")
t.contains(out, "UTC+2", "offset shown")
t.contains(out, "16:02", "time shifted")
out = run("timezone 99")
t.contains(out, "usage", "bad offset")
out = run("nonsense")
t.contains(out, "unknown command", "unknown command")

---------------------------------------------------------------- alerts
local actx = { now = 1760882520000, baseName = "Void base", level = { n = 4, label = "HIGH" } }
local q = alerts.queue()
local ch, game = alerts.push(q, { type = "zone_enter", countdownMs = 10000,
  target = { id = "u", kind = "player", name = "Steve", cls = "unknown", pos = { x = 1.4, y = 64, z = -2.6 }, dist = 3.2 } }, actx)
t.eq(ch, "alerts", "zone enter goes to alerts")
t.contains(game, "NO-GO ZONE Steve", "in-game text")
alerts.push(q, { type = "takeover", from = "aaaaaaaa1", to = "bbbbbbbb2", list = "trusted", label = "Home" }, actx)
t.eq(alerts.push(q, { type = "new", id = "x" }, actx), nil, "new is not reported")
local msgs = alerts.drain(q)
t.eq(#msgs, 2, "one message per channel")
local e = msgs[1][2].embeds[1]
t.eq(msgs[1][1], "alerts", "alerts first")
t.eq(e.title, "NO-GO ZONE: Steve", "title")
t.eq(e.color, alerts.COLOR.orange, "orange")
t.contains(e.description, "`1, 64, -3`", "rounded position")
t.contains(e.description, "at <t:1760882520:t>", "Discord time")
t.eq(e.description:find("UTC", 1, true), nil, "only Discord timestamps, no zone text")
t.contains(e.description, "<t:1760882530:R>", "live countdown to firing")
t.contains(e.description, "Base level: **4 HIGH**", "base level")
t.contains(e.description, "`trust Steve`", "command hint")
t.eq(e.timestamp, "2025-10-19T14:02:00Z", "embed timestamp")
t.eq(e.footer.text, "Void base", "footer")
t.eq(msgs[2][1], "log", "takeover goes to log")
t.contains(msgs[2][2].embeds[1].description, "'Home'", "label in takeover")
t.eq(#alerts.drain(q), 0, "queue empty after drain")

-- visitor with end time and live countdown
local _, ve = alerts.format({ type = "list_change", text = "Bob is a visitor", who = "Bob", list = "visitor",
  expires = actx.now + 45 * 60000 }, actx)
t.eq(ve.title, "VISITOR: Bob", "visitor title")
t.contains(ve.description, "until <t:" .. math.floor((actx.now + 45 * 60000) / 1000) .. ":t>", "until time")
t.eq(ve.description:find("UTC", 1, true), nil, "no zone text")
t.contains(ve.description, "<t:" .. math.floor((actx.now + 45 * 60000) / 1000) .. ":R>", "live countdown")

-- without a timezone only the Discord time
local _, ne = alerts.format({ type = "detected", visit = 3,
  target = { id = "u", kind = "player", name = "Steve", cls = "unknown" } }, { now = actx.now })
t.eq(ne.title, "CONTACT: Steve", "contact title")
t.contains(ne.description, "Visit #3", "visit number")
t.eq(ne.description:find("UTC", 1, true), nil, "no zone text without timezone")
t.eq(ne.footer.text, "Void base", "default base name")
local _, se = alerts.format({ type = "detected", target = { id = "8c98841d-xx", kind = "ship", cls = "unknown", label = nil } }, actx)
t.eq(se.title, "CONTACT: ship 8c98841d", "ship title")
t.contains(se.description, "`ship 8c98841d trust`", "ship hint")

-- batching: at most 10 embeds per message, ASCII only
for i = 1, 25 do
  alerts.push(q, { type = "detected", target = { id = "p" .. i, kind = "player", name = "Player" .. i, cls = "unknown",
    pos = { x = i, y = 0, z = 0 } } }, actx)
end
msgs = alerts.drain(q)
t.eq(#msgs, 3, "25 embeds -> 3 messages")
for _, m in ipairs(msgs) do
  t.truthy(#m[2].embeds <= 10, "max 10 embeds")
  local json = textutils.serialiseJSON(m[2])
  t.eq(json:find("[\128-\255]"), nil, "ASCII only")
end

-- visitor command text with the time zone, basename
cfg.timeOffsetHours = 2
out, r = run("visitor Dan 45m")
t.contains(out, "until", "visitor until")
t.contains(out, "UTC+2", "until in UTC+2")
t.eq(r.events[1].expires, now + 45 * 60000, "event carries the end time")
t.eq(r.events[1].who, "Dan", "event carries the name")
out = run("players")
t.contains(out, "Dan (until", "players shows until")
out, r = run("detectrange 200")
t.truthy(r.configChanged, "detectrange saved")
t.eq(cfg.detectRange, 200, "range set")
out = run("detectrange 5000")
t.contains(out, "usage", "range limited to 512")
t.eq(cfg.detectRange, 200, "bad value ignored")
out, r = run("basename Void Sky Fortress")
t.truthy(r.configChanged, "basename saved")
t.eq(cfg.baseName, "Void Sky Fortress", "base name")
out = run("basename")
t.contains(out, "usage", "basename needs text")

t.finish("commands")
