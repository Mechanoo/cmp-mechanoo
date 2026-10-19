local t = require("tests.t")
local core = require("lib.probe_core")

local s = core.new()

local function sample(time, tracks, players)
  core.beginSample(s, time)
  core.addTracks(s, "north", tracks)
  core.addPlayers(s, players)
  core.endSample(s)
end

local function track(id, x, z, cat)
  return { id = id, position = { x = x, y = 64, z = z }, velocity = { x = 0, y = 0, z = 0 },
           category = cat or "PLAYER", entityType = "minecraft:player", scannedTime = 1 }
end

sample(0, { track("a1", 100, 100), track("ship9", 300, 300, "VS2") }, { { name = "Bob", uuid = "a1", x = 101, y = 64, z = 100 } })
sample(2, { track("a1", 102, 100) }, { { name = "Bob", x = 102, y = 64, z = 101 } })
sample(4, { track("a1", 104, 100) }, { { name = "Bob", x = 104, y = 64, z = 100 } })
sample(6, { track("a1", 106, 100), track("ship9", 310, 300, "VS2") }, { { name = "Bob", x = 106, y = 64, z = 100 } })

t.eq(s.samples, 4, "sample count")
t.eq(#s.order, 2, "unique ids")
t.eq(s.tracks["a1"].n, 4, "a1 seen in every sample")
t.eq(s.tracks["ship9"].n, 2, "ship9 seen twice")
t.eq(s.tracks["ship9"].reappear, 1, "ship9 came back after a gap")
t.eq(s.tracks["a1"].reappear, 0, "a1 never had a gap")
t.eq(s.pairs["Bob"].matched, 4, "Bob matched in all samples")
t.eq(s.pairs["Bob"].ids["a1"], 4, "Bob always maps to a1")

local text = table.concat(core.summarize(s), "\n")
t.contains(text, "2 unique", "summary unique ids")
t.contains(text, "STABLE", "summary says id is stable")
t.contains(text, "raw PLAYER:", "summary has raw track per category")
t.contains(text, "raw VS2:", "summary has raw ship track")
t.contains(text, "detector uuid == track id in 1/4", "uuid comparison reported")

-- an id that changes must be reported as changed
local s2 = core.new()
for i = 1, 4 do
  core.beginSample(s2, i)
  core.addTracks(s2, "east", { track("id" .. i, 10, 10) })
  core.addPlayers(s2, { { name = "Eve", x = 10, y = 64, z = 10 } })
  core.endSample(s2)
end
t.contains(table.concat(core.summarize(s2), "\n"), "CHANGED", "changing ids are reported")

-- two radars seeing the same id count once per sample
local s3 = core.new()
core.beginSample(s3, 0)
core.addTracks(s3, "north", { track("dup", 0, 0) })
core.addTracks(s3, "south", { track("dup", 0, 0) })
core.endSample(s3)
t.eq(s3.tracks["dup"].n, 1, "duplicate across radars counted once")

-- classification by methods, independent of the type name
t.eq(core.classify({ "whatever" }, { "getTracks", "getRange" }), "radar", "radar by methods")
t.eq(core.classify({ "playerDetector" }, { "getPlayersInRange", "getPlayer" }), "detector", "detector by methods")
t.eq(core.classify({ "create_radar:monitor" }, { "getTracks", "getSelectedTrack" }), nil, "monitor is not a radar")
t.eq(core.classify({ "cannon_mount" }, { "setTargetAngles", "getInfo", "fire" }), "cannon", "cannon mount by methods")
t.eq(core.classify({ "minecraft:chest" }, { "list" }), nil, "chest is nothing")

-- a ship next to the player must not be taken for the player
local s4 = core.new()
for i = 1, 3 do
  core.beginSample(s4, i * 2)
  core.addTracks(s4, "west", { track("ship", 10, 10, "SABLE"), track("me", 13, 10, "PLAYER") })
  core.addPlayers(s4, { { name = "Me", uuid = "me", x = 10.5, y = 64, z = 10 } })
  core.endSample(s4)
end
t.eq(s4.pairs["Me"].ids["me"], 3, "player matched to own uuid, not to the closer ship")
t.eq(s4.pairs["Me"].ids["ship"], nil, "ship never matched as player")
t.eq(s4.pairs["Me"].uuidMatches, 3, "uuid equal in all samples")

-- gaps are measured in seconds
local s5 = core.new()
for _, tt in ipairs({ 0, 2, 10, 12 }) do
  core.beginSample(s5, tt)
  core.addTracks(s5, "n", (tt == 0 or tt == 10) and { track("g", 0, 0, "SABLE") } or {})
  core.endSample(s5)
end
t.eq(s5.tracks["g"].maxGap, 10, "longest gap 10 s")
t.contains(table.concat(core.summarize(s5), "\n"), "longest gap 10s", "gap in summary")

t.finish("probe_core")
