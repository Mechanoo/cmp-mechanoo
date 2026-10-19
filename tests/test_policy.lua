local t = require("tests.t")
local Z = require("lib.zone")
local policy = require("lib.policy")
local lists = require("lib.lists")

---------------------------------------------------------------- zone
local z = Z.fromCenter(-384, 356, 10)
t.eq(z.x1, -464, "x1 on a chunk border")
t.eq(z.x2, -304, "x2 = x1 + 160")
t.eq(z.z1, 272, "z1 on a chunk border")
t.eq(z.z2, 432, "z2 = z1 + 160")
t.eq((z.x1 % 16) + (z.z1 % 16), 0, "aligned to chunks")
t.truthy(Z.contains(z, { x = -464, y = 0, z = 272 }), "first block inside")
t.eq(Z.contains(z, { x = -304, y = 0, z = 300 }), false, "x2 is outside")
t.truthy(Z.contains(z, { x = -305, y = 400, z = 431.9 }), "high above still inside")
t.eq(Z.contains(nil, { x = 0, y = 0, z = 0 }), false, "no zone -> never inside")
local odd = Z.fromCenter(8, 8, 3)
t.eq(odd.x1, -16, "odd size centred on the chunk")
t.eq(odd.x2, 32, "odd size width 48")

---------------------------------------------------------------- policy
local zone = Z.fromCenter(0, 0, 10) -- x/z -80..79
local ls = lists.new()
local ps = policy.new()
local now = 1000

local function target(id, kind, name, x, z2)
  return { id = id, kind = kind, name = name, pos = { x = x, y = 64, z = z2 } }
end

local function types(events)
  local s = {}
  for _, e in ipairs(events) do s[#s + 1] = e.type end
  return table.concat(s, ",")
end

-- unknown far away: detected once
local d, ev = policy.update(ps, now, { target("u", "player", "Stranger", 300, 0) }, ls, zone)
t.eq(d.u.action, "watch", "far unknown -> watch")
t.eq(types(ev), "detected", "detected event")
d, ev = policy.update(ps, now + 1000, { target("u", "player", "Stranger", 290, 0) }, ls, zone)
t.eq(#ev, 0, "no repeat")

-- rings
d, ev = policy.update(ps, now + 2000, { target("u", "player", "Stranger", 200, 0) }, ls, zone)
t.eq(types(ev), "approach", "crossed 256")
t.eq(ev[1].ring, 256, "ring 256")
d, ev = policy.update(ps, now + 3000, { target("u", "player", "Stranger", 100, 0) }, ls, zone)
t.eq(ev[1] and ev[1].ring, 128, "crossed 128")

-- enters the zone: 10 s warning, then engage
now = 10000
d, ev = policy.update(ps, now, { target("u", "player", "Stranger", 50, 0) }, ls, zone)
t.eq(types(ev), "zone_enter", "zone enter")
t.eq(d.u.action, "warn", "warn first")
t.eq(d.u.remainingMs, 10000, "10 s left")
d = policy.update(ps, now + 9999, { target("u", "player", "Stranger", 50, 0) }, ls, zone)
t.eq(d.u.action, "warn", "still warn at 9.999 s")
d, ev = policy.update(ps, now + 10000, { target("u", "player", "Stranger", 50, 0) }, ls, zone)
t.eq(d.u.action, "engage", "engage at 10 s")
t.eq(types(ev), "engage", "engage event")
d, ev = policy.update(ps, now + 11000, { target("u", "player", "Stranger", 50, 0) }, ls, zone)
t.eq(#ev, 0, "engage reported once")

-- leaves and comes back: the countdown starts again
d, ev = policy.update(ps, now + 12000, { target("u", "player", "Stranger", 150, 0) }, ls, zone)
t.eq(types(ev), "zone_leave", "zone leave")
t.eq(d.u.action, "watch", "watch outside")
d, ev = policy.update(ps, now + 13000, { target("u", "player", "Stranger", 50, 0) }, ls, zone)
t.eq(d.u.action, "warn", "new countdown")

-- marked visitor during the countdown: stops
lists.setPlayer(ls, "Stranger", "visitor", now, 60000)
d, ev = policy.update(ps, now + 14000, { target("u", "player", "Stranger", 50, 0) }, ls, zone)
t.eq(d.u.action, "friendly", "visitor is friendly")
t.eq(types(ev), "zone_cleared", "countdown cleared")

-- hostile: engage anywhere, immediately
lists.setPlayer(ls, "Enemy", "hostile", now)
d, ev = policy.update(ps, now + 15000, { target("e", "player", "Enemy", 500, 500) }, ls, zone)
t.eq(d.e.action, "engage", "hostile far away -> engage")
t.eq(types(ev), "hostile", "hostile event")

-- trusted never warned
lists.setPlayer(ls, "Me", "trusted", now)
d, ev = policy.update(ps, now + 16000, { target("m", "player", "Me", 0, 0) }, ls, zone)
t.eq(d.m.action, "friendly", "trusted in zone -> friendly")
t.eq(#ev, 0, "no events for trusted")

-- shells are ignored
d, ev = policy.update(ps, now + 17000, { { id = "shell", kind = "other", pos = { x = 0, y = 64, z = 0 } } }, ls, zone)
t.eq(d.shell.action, "ignore", "shells ignored")
t.eq(#ev, 0, "no events for shells")

-- escort: unknown ship with a trusted player aboard is friendly
local ps2 = policy.new()
d, ev = policy.update(ps2, 50000, {
  target("me", "player", "Me", 10, 10),
  target("ship", "ship", nil, 12, 10),
}, ls, zone)
t.eq(d.ship.action, "friendly", "escorted ship friendly")
t.truthy(d.ship.escorted, "marked as escorted")
-- the same ship alone in the zone is warned
d = policy.update(ps2, 51000, { target("ship", "ship", nil, 12, 10) }, ls, zone)
t.eq(d.ship.action, "warn", "unescorted ship warned")

-- visits: a short gap is the same visit, a long gap starts a new one, every visit is announced
local ps3 = policy.new()
d, ev = policy.update(ps3, 0, { target("q", "player", "Quiet", 50, 0) }, ls, zone)
t.eq(types(ev), "detected,zone_enter", "first sight inside the zone: no ring alerts")
policy.lost(ps3, "q", 5000)
d, ev = policy.update(ps3, 20000, { target("q", "player", "Quiet", 50, 0) }, ls, zone)
t.eq(types(ev), "zone_enter", "back after 15 s: same visit, only the zone countdown again")
t.eq(d.q.remainingMs, 10000, "full countdown after coming back")
policy.lost(ps3, "q", 21000)
d, ev = policy.update(ps3, 21000 + 60000, {}, ls, zone)
t.eq(#ev, 0, "visit still open at exactly 60 s")
d, ev = policy.update(ps3, 21000 + 60001, {}, ls, zone)
t.eq(types(ev), "visit_end", "visit ends after 60 s away")
t.eq(ev[1].start, 0, "visit start")
t.eq(ev[1].stop, 20000, "last seen")
t.truthy(ev[1].enteredZone, "was in the zone")
t.eq(math.floor(ev[1].closest), 50, "closest distance")
t.eq(ev[1].target.name, "Quiet", "name in summary")
d, ev = policy.update(ps3, 200000, { target("q", "player", "Quiet", 300, 0) }, ls, zone)
t.eq(types(ev), "detected", "next visit is announced again")

-- trusted players also get visit records (for the history), shells do not
local ps4 = policy.new()
policy.update(ps4, 0, { target("m", "player", "Me", 0, 0), { id = "sh", kind = "other", pos = { x = 0, y = 0, z = 0 } } }, ls, zone)
policy.lost(ps4, "m", 1000)
policy.lost(ps4, "sh", 1000)
d, ev = policy.update(ps4, 70000, {}, ls, zone)
t.eq(types(ev), "visit_end", "only the player visit ends")
t.eq(ev[1].target.cls, "trusted", "trusted visit recorded")
t.eq(#policy.closeAll(policy.new()), 0, "closeAll on empty")

-- confirmation: a ghost ship seen once causes nothing
local psG = policy.new()
local ghost = target("g", "ship", nil, 10, 10)
ghost.sightings = 1
d, ev = policy.update(psG, 0, { ghost }, ls, zone)
t.eq(d.g.action, "pending", "ship seen once is pending")
t.eq(#ev, 0, "no alert for a single sighting")
policy.lost(psG, "g", 10000)
d, ev = policy.update(psG, 80000, {}, ls, zone)
t.eq(#ev, 0, "no visit record for a ghost")
t.eq(psG.per.g, nil, "ghost forgotten")
-- a real ship: second sighting confirms it, the countdown starts then
local real = target("r", "ship", nil, 10, 10)
real.sightings = 1
d, ev = policy.update(psG, 100000, { real }, ls, zone)
t.eq(d.r.action, "pending", "first sighting pending")
real.sightings = 2
d, ev = policy.update(psG, 103000, { real }, ls, zone)
t.eq(types(ev), "detected,zone_enter", "confirmed on the second sighting")
t.eq(d.r.remainingMs, 10000, "countdown starts at confirmation")
-- a named player is confirmed at once, a radar-only unnamed player is not
local named = target("n", "player", "Named", 10, 10)
named.sightings = 1
local nameless = target("x", "player", nil, 10, 10)
nameless.sightings = 1
d, ev = policy.update(psG, 104000, { named, nameless }, ls, zone)
t.eq(d.n.action, "warn", "named player counts at once")
t.eq(d.x.action, "pending", "nameless radar player waits")
-- a listed hostile ship is engaged at the first sighting
lists.setShip(ls, "h", "hostile", 0)
local hs = target("h", "ship", nil, 400, 0)
hs.sightings = 1
d = policy.update(psG, 105000, { hs }, ls, zone)
t.eq(d.h.action, "engage", "listed hostile ship needs no confirmation")
t.eq(policy.level(psG, { g = { action = "pending" } }, { ghost }, zone).n, 1, "pending does not raise the level")

-- base level
local psL = policy.new()
local function lvl(targets, now2)
  local dd = policy.update(psL, now2, targets, ls, zone)
  return policy.level(psL, dd, targets, zone)
end
t.eq(lvl({}, 0).label, "CLEAR", "nothing -> CLEAR")
t.eq(lvl({ target("m", "player", "Me", 0, 0) }, 1000).n, 1, "only trusted -> 1")
t.eq(lvl({ target("w", "player", "Walker", 300, 0) }, 2000).label, "WATCH", "unknown far -> WATCH")
t.eq(lvl({ target("w", "player", "Walker", 100, 0) }, 3000).label, "ELEVATED", "unknown within 128 -> ELEVATED")
t.eq(lvl({ target("w", "player", "Walker", 10, 0) }, 4000).label, "HIGH", "countdown -> HIGH")
t.eq(lvl({ target("w", "player", "Walker", 10, 0) }, 14000).label, "ENGAGE", "engaged -> ENGAGE")
t.eq(lvl({ target("e", "player", "Enemy", 600, 0) }, 15000).n, 5, "hostile anywhere -> 5")

t.finish("policy")
