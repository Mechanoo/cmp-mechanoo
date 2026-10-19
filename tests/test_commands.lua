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
out = run("nonsense")
t.contains(out, "unknown command", "unknown command")

---------------------------------------------------------------- alerts
local q = alerts.queue()
alerts.push(q, { type = "zone_enter", countdownMs = 10000,
  target = { id = "u", kind = "player", name = "Steve", pos = { x = 1.4, y = 64, z = -2.6 }, dist = 3.2 } })
alerts.push(q, { type = "takeover", from = "aaaaaaaa1", to = "bbbbbbbb2", list = "trusted", label = "Home" })
alerts.push(q, { type = "new", id = "x" }) -- not reported
local msgs = alerts.drain(q)
t.eq(#msgs, 2, "one message per channel")
t.eq(msgs[1][1], "alerts", "zone enter goes to alerts")
t.contains(msgs[1][2], "NO-GO ZONE", "zone text")
t.contains(msgs[1][2], "(1, 64, -3)", "rounded position")
t.contains(msgs[1][2], "10s", "countdown in text")
t.eq(msgs[2][1], "log", "takeover goes to log")
t.contains(msgs[2][2], "'Home'", "label in takeover")
t.eq(#alerts.drain(q), 0, "queue empty after drain")
for i = 1, 100 do
  alerts.push(q, { type = "detected", target = { id = "p" .. i, kind = "player", name = "Player" .. i, pos = { x = i, y = 0, z = 0 } } })
end
msgs = alerts.drain(q)
t.truthy(#msgs >= 2, "long batches split")
for _, m in ipairs(msgs) do t.truthy(#m[2] <= 1900, "each part short enough") end
for _, m in ipairs(msgs) do
  t.eq(m[2]:find("[\128-\255]"), nil, "ASCII only")
end

t.finish("commands")
