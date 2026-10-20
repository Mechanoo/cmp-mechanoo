local t = require("tests.t")
local tracker = require("lib.tracker")
local lists = require("lib.lists")

local function trk(id, cat, x, y, z, vx)
  return { id = id, category = cat, entityType = cat == "PLAYER" and "entity.minecraft.player" or "Sable:ship",
           position = { x = x, y = y, z = z }, velocity = { x = vx or 0, y = 0, z = 0 }, scannedTime = 1 }
end

local function count(events, type)
  local n = 0
  for _, e in ipairs(events) do if e.type == type then n = n + 1 end end
  return n
end

local function find(events, type)
  for _, e in ipairs(events) do if e.type == type then return e end end
end

local ls = lists.new()
local tr = tracker.new()
local now = 1000000

-- the same target from two radars counts once; players get their names from the detector
local ev = tracker.update(tr, now,
  { trk("u1", "PLAYER", 10, 64, 10, 0.5), trk("u1", "PLAYER", 10, 64, 10, 0.5), trk("ship1", "SABLE", 50, 70, 50) },
  { { name = "Bob", uuid = "u1", x = 10.2, y = 64, z = 10 } }, ls)
t.eq(count(ev, "new"), 2, "two new targets")
t.eq(tr.targets["u1"].name, "Bob", "name from detector")
t.eq(tr.targets["u1"].pos.x, 10.2, "detector position wins")
t.eq(tr.targets["u1"].vel.x, 0.5, "radar velocity kept")
t.eq(tr.targets["ship1"].kind, "ship", "SABLE is a ship")

t.eq(tr.targets["u1"].sightings, 1, "one sighting per update, even with two radars and the detector")

-- radar-only sighting keeps the name
now = now + 1000
tracker.update(tr, now, { trk("u1", "PLAYER", 12, 64, 10) }, {}, ls)
t.eq(tr.targets["u1"].name, "Bob", "name remembered for radar-only sightings")

t.eq(tr.targets["u1"].sightings, 2, "second update counts")

-- detector-only: velocity from movement (blocks per tick). 1 s = 20 ticks, moved 20 blocks -> 1 block/tick
now = now + 1000
tracker.update(tr, now, {}, { { name = "Bob", uuid = "u1", x = 32, y = 64, z = 10 } }, ls)
t.eq(tr.targets["u1"].vel.x, 1, "velocity from detector movement")

-- hold time: kept for 10 s after the last sighting, then lost
local lastSeen = now
now = lastSeen + 10000
ev = tracker.update(tr, now, {}, {}, ls)
t.truthy(tr.targets["u1"], "still held at exactly 10 s")
now = lastSeen + 10001
ev = tracker.update(tr, now, {}, {}, ls)
t.eq(tr.targets["u1"], nil, "lost after 10 s")
t.truthy(find(ev, "lost"), "lost event")

-- classification
lists.setPlayer(ls, "Bob", "hostile", now)
now = now + 1000
tracker.update(tr, now, {}, { { name = "Bob", uuid = "u1", x = 1, y = 64, z = 1 } }, ls)
t.eq(tracker.classify(tr.targets["u1"], ls), "hostile", "listed by name")
t.eq(lists.player(ls, "Bob").uuid, "u1", "uuid remembered on the entry")
t.eq(tracker.classify({ kind = "other", id = "x" }, ls), "other", "shells are other")

---------------------------------------------------------------- takeover
local ls2 = lists.new()
local tr2 = tracker.new()
now = 5000000
tracker.update(tr2, now, { trk("old", "SABLE", 100, 70, 100) }, {}, ls2)
lists.setShip(ls2, "old", "trusted", now, nil, { label = "Home", pos = { x = 100, y = 70, z = 100 }, seen = now })

-- ship disassembled: old id gone; 20 s later a new id appears 5 blocks away
now = now + 20000
ev = tracker.update(tr2, now, { trk("new", "SABLE", 104, 70, 103) }, {}, ls2)
local to = find(ev, "takeover")
t.truthy(to, "takeover happened")
t.eq(to and to.from, "old", "from old")
t.eq(to and to.to, "new", "to new")
t.eq(lists.effective(lists.ship(ls2, "new")), "trusted", "new ship inherits trusted")
t.eq(lists.ship(ls2, "new").label, "Home", "label inherited")

-- old one never comes back: after the window it is removed
now = now + 61000
tracker.update(tr2, now, { trk("new", "SABLE", 104, 70, 103) }, {}, ls2)
t.eq(lists.ship(ls2, "old"), nil, "old entry removed after the window")
t.eq(lists.ship(ls2, "new").takenFrom, nil, "takeover final")

-- revoke: old ship was only flickering
local ls3 = lists.new()
local tr3 = tracker.new()
now = 7000000
tracker.update(tr3, now, { trk("a", "SABLE", 0, 70, 0) }, {}, ls3)
lists.setShip(ls3, "a", "trusted", now, nil, { pos = { x = 0, y = 70, z = 0 }, seen = now })
now = now + 3000
ev = tracker.update(tr3, now, { trk("b", "SABLE", 6, 70, 0) }, {}, ls3)
t.truthy(find(ev, "takeover"), "b took over a")
now = now + 3000
ev = tracker.update(tr3, now, { trk("a", "SABLE", 0, 70, 0), trk("b", "SABLE", 6, 70, 0) }, {}, ls3)
t.truthy(find(ev, "takeover_revoked"), "a came back -> revoked")
t.eq(lists.ship(ls3, "b"), nil, "b is unknown again")
t.eq(lists.effective(lists.ship(ls3, "a")), "trusted", "a still trusted")

-- too far away or too late: no takeover
local ls4 = lists.new()
local tr4 = tracker.new()
now = 9000000
lists.setShip(ls4, "far", "hostile", now, nil, { pos = { x = 0, y = 70, z = 0 }, seen = now })
ev = tracker.update(tr4, now + 1000, { trk("n1", "SABLE", 40, 70, 0) }, {}, ls4)
t.eq(find(ev, "takeover"), nil, "40 blocks away: no takeover")
ev = tracker.update(tr4, now + 61000, { trk("n2", "SABLE", 2, 70, 0) }, {}, ls4)
t.eq(find(ev, "takeover"), nil, "61 s later: no takeover")

-- two new ships at once: no takeover, ambiguous event
local ls5 = lists.new()
local tr5 = tracker.new()
now = 11000000
lists.setShip(ls5, "s", "hostile", now, nil, { pos = { x = 0, y = 70, z = 0 }, seen = now })
ev = tracker.update(tr5, now + 2000, { trk("x1", "SABLE", 3, 70, 0), trk("x2", "SABLE", -3, 70, 0) }, {}, ls5)
t.eq(find(ev, "takeover"), nil, "two candidates: no takeover")
t.truthy(find(ev, "takeover_ambiguous"), "ambiguous reported")
t.eq(lists.ship(ls5, "x1"), nil, "x1 stays unknown")

-- a hostile ship that is reassembled stays hostile
local ls6 = lists.new()
local tr6 = tracker.new()
now = 13000000
lists.setShip(ls6, "enemy", "hostile", now, nil, { pos = { x = 0, y = 70, z = 0 }, seen = now })
tracker.update(tr6, now + 5000, { trk("enemy2", "SABLE", 1, 70, 1) }, {}, ls6)
t.eq(lists.effective(lists.ship(ls6, "enemy2")), "hostile", "reassembled enemy stays hostile")

-- a visible listed ship is no takeover candidate
local ls7 = lists.new()
local tr7 = tracker.new()
now = 15000000
lists.setShip(ls7, "home", "trusted", now, nil, { pos = { x = 0, y = 70, z = 0 }, seen = now })
ev = tracker.update(tr7, now + 1000, { trk("home", "SABLE", 0, 70, 0), trk("intruder", "SABLE", 4, 70, 0) }, {}, ls7)
t.eq(find(ev, "takeover"), nil, "new ship next to a visible trusted ship takes nothing")
t.eq(lists.ship(ls7, "intruder"), nil, "intruder unknown")

-- ragdoll: six body parts appear as new SABLE tracks within a few blocks
local function ragdollTracks(x, n, missing)
  local out = {}
  local off = { { 0, 1.5, 0 }, { 0, 0.8, 0 }, { 0.4, 0.8, 0 }, { -0.4, 0.8, 0 }, { 0.2, 0, 0 }, { -0.2, 0, 0 } }
  for i = 1, n do
    if i ~= missing then
      out[#out + 1] = trk("rd" .. x .. "-" .. i, "SABLE", x + off[i][1], 70 + off[i][2], off[i][3])
    end
  end
  return out
end
local ls8 = lists.new()
local tr8 = tracker.new()
now = 17000000
local tracks8 = ragdollTracks(100, 6, 3) -- one part missed by the radars in the first sample
tracks8[#tracks8 + 1] = trk("realship", "SABLE", 140, 70, 0)
ev = tracker.update(tr8, now, tracks8, {}, ls8)
local rd = find(ev, "ragdoll")
t.truthy(rd, "ragdoll event")
t.eq(rd and rd.parts, 5, "five parts seen in the first sample")
t.eq(tr8.targets["rd100-1"].kind, "ragdoll", "part marked ragdoll")
t.eq(tr8.targets["realship"].kind, "ship", "a ship 40 blocks away is no part of it")
local all8 = tracker.all(tr8)
t.eq(#all8, 1, "ragdoll parts are left out of tracker.all")
t.eq(all8[1] and all8[1].id, "realship", "only the real ship is listed")
now = now + 500
ev = tracker.update(tr8, now, { trk("rd100-3", "SABLE", 100.4, 70.8, 0), trk("rd100-1", "SABLE", 100, 71.5, 0) }, {}, ls8)
t.eq(tr8.targets["rd100-3"].kind, "ragdoll", "a late part seen next to one known part joins the ragdoll")
now = now + 500
ev = tracker.update(tr8, now, ragdollTracks(100, 6), {}, ls8)
t.eq(tr8.targets["rd100-3"].kind, "ragdoll", "the late part joins the known ragdoll")
t.eq(find(ev, "ragdoll"), nil, "no second ragdoll event for the same ragdoll")
t.eq(#tracker.all(tr8), 1, "only the (held) real ship is listed")

-- two ships close together are no ragdoll (fewer than ragdollParts)
local ls9 = lists.new()
local tr9 = tracker.new()
now = 19000000
ev = tracker.update(tr9, now, { trk("a", "SABLE", 0, 70, 0), trk("b", "SABLE", 2, 70, 0) }, {}, ls9)
t.eq(find(ev, "ragdoll"), nil, "two new ships are no ragdoll")
t.eq(tr9.targets["a"].kind, "ship", "they stay ships")
-- an old ship next to a burst of new parts stays a ship
now = now + 10000 - 1
ev = tracker.update(tr9, now, { trk("a", "SABLE", 0, 70, 0), trk("p1", "SABLE", 1, 70, 0), trk("p2", "SABLE", 1.5, 70, 0),
  trk("p3", "SABLE", 1, 71, 0) }, {}, ls9)
t.truthy(find(ev, "ragdoll"), "three new parts are a ragdoll")
t.eq(tr9.targets["a"].kind, "ship", "the old ship next to it stays a ship")
-- a listed ship is never taken as a part
local ls10 = lists.new()
local tr10 = tracker.new()
now = 21000000
lists.setShip(ls10, "l1", "trusted", now)
ev = tracker.update(tr10, now, { trk("l1", "SABLE", 0, 70, 0), trk("n1", "SABLE", 1, 70, 0), trk("n2", "SABLE", 2, 70, 0) }, {}, ls10)
t.eq(find(ev, "ragdoll"), nil, "a listed ship does not count as a part")
t.eq(tr10.targets["l1"].kind, "ship", "listed ship stays a ship")

t.finish("tracker")
