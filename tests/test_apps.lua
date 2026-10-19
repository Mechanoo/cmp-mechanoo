-- Runs the real app files with mocked peripherals/http/time.
local t = require("tests.t")

local function readAll(path)
  local h = fs.open(path, "r")
  local s = h.readAll()
  h.close()
  return s
end

local function loadApp(path)
  local fn, err = loadfile(path, "t", _ENV)
  t.truthy(fn, "loads " .. path .. ": " .. tostring(err))
  return fn
end

-- every shipped file must at least compile
for _, p in ipairs({ "/work/bin/cmp.lua", "/work/install.lua", "/work/lib/updater.lua",
                     "/work/apps/probe/main.lua", "/work/apps/discord-test/main.lua" }) do
  loadApp(p)
end

fs.delete("/cmp-data")

-- fake clock so the probe finishes instantly
local now = 1000000
os = setmetatable({ epoch = function() return now end }, { __index = os })
sleep = function(s) now = now + (s or 0) * 1000 end

-- fake peripherals: one plane radar (2 tracks), one player detector (1 player), one unrelated block
local step = 0
local P = {
  north = { types = { "create_radar:plane_radar" }, methods = { "getTracks", "getPosition", "getRange" } },
  det = { types = { "player_detector" }, methods = { "getPlayersInRange", "getPlayer" } },
  chest = { types = { "minecraft:chest" }, methods = { "list" } },
  gun = { types = { "cannon_mount" }, methods = { "setComputerControl", "setTargetAngles", "getInfo", "assemble", "fire" } },
}
local cannonCalls = {}
peripheral = {
  getNames = function() return { "north", "det", "chest", "gun" } end,
  getType = function(n) return table.unpack(P[n].types) end,
  getMethods = function(n) return P[n].methods end,
  call = function(n, m, ...)
    if n == "north" and m == "getTracks" then
      step = step + 1
      return {
        { id = "p1", position = { x = 100 + step, y = 70, z = 50 }, velocity = { x = 1, y = 0, z = 0 }, category = "PLAYER", entityType = "minecraft:player", scannedTime = step },
        { id = "s1", position = { x = 400, y = 90, z = 400 }, velocity = { x = 0, y = 0, z = 0 }, category = "VS2", entityType = "ship", scannedTime = step },
      }
    elseif n == "north" and m == "getRange" then return 512
    elseif n == "north" and m == "getPosition" then return { x = 0, y = 64, z = 0 }
    elseif n == "det" and m == "getPlayersInRange" then return { "Bob" }
    elseif n == "det" and m == "getPlayer" then return { x = 100 + step, y = 70, z = 50, name = "Bob" }
    elseif n == "gun" then
      cannonCalls[#cannonCalls + 1] = m
      if m == "getInfo" then return { assembled = true, yaw = 90, pitch = 5, x = 1, y = 2, z = 3 } end
    end
  end,
}

local posts = {}
http = {
  post = function(url, body)
    posts[#posts + 1] = textutils.unserialiseJSON(body).content
    return { getResponseCode = function() return 204 end, close = function() end }
  end,
}

-- discord-test: first run asks for URLs through read()
local answers = { "https://discord.com/api/webhooks/111/aaa", "https://discord.com/api/webhooks/222/bbb" }
local asked = 0
read = function() asked = asked + 1; return answers[asked] end
write = function() end
local dt = loadApp("/work/apps/discord-test/main.lua")
dt()
t.eq(asked, 2, "asked for two urls")
t.eq(#posts, 2, "sent two test messages")
t.contains(posts[1], "http.post works", "test message text")
local cfg = textutils.unserialiseJSON(readAll("/cmp-data/discord.json"))
t.eq(cfg.alerts, answers[1], "alerts url saved")
t.eq(cfg.log, answers[2], "log url saved")
posts = {}
dt() -- second run must not ask again
t.eq(asked, 2, "does not ask a second time")
t.eq(#posts, 2, "sends again")

-- probe, with report to discord
posts = {}
local probe = loadApp("/work/apps/probe/main.lua")
probe("10", "--discord")
local report = readAll("/cmp-data/probe-report.txt")
t.contains(report, "Found 1 radar(s), 1 player detector(s), 1 cannon mount(s).", "found devices")
t.contains(report, "cannon gun info=", "cannon info reported")
for _, m in ipairs(cannonCalls) do t.eq(m, "getInfo", "probe only reads the cannon") end
t.contains(report, "chest", "inventory lists the chest")
t.contains(report, "radar match", "pairing is reported")
t.contains(report, "STABLE", "stable id detected")
t.contains(report, "2 unique", "two track ids")
t.truthy(#posts >= 1, "report sent to discord")
t.contains(posts[1], "probe report", "discord title")

fs.delete("/cmp-data")
t.finish("apps")
