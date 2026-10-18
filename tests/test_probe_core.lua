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
t.eq(core.classify({ "minecraft:chest" }, { "list" }), nil, "chest is nothing")

t.finish("probe_core")
