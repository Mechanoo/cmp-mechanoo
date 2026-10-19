-- probe: measures what the radars and the player detector really return.
--   cmp probe [seconds] [--discord]
-- Run it with a player (or ship) moving around in range, then look at the report.
-- With --discord the report goes to your log channel (see discord-test).
package.path = "/cmp/?.lua;" .. package.path
local core = require("lib.probe_core")
local store = require("lib.store")

local args = { ... }
local seconds, toDiscord = 60, false
for _, a in ipairs(args) do
  if a == "--discord" then toDiscord = true
  elseif tonumber(a) then seconds = tonumber(a) end
end

-- 1. inventory of everything attached
local report = {}
local function out(line)
  print(line)
  report[#report + 1] = line
end

local radars, detectors, cannons = {}, {}, {}
out("Peripherals:")
for _, name in ipairs(peripheral.getNames()) do
  local types = table.concat({ peripheral.getType(name) }, ",")
  local methods = peripheral.getMethods(name) or {}
  out(("  %s [%s] %d methods"):format(name, types, #methods))
  local kind = core.classify({ peripheral.getType(name) }, methods)
  if kind == "radar" then radars[#radars + 1] = name end
  if kind == "detector" then detectors[#detectors + 1] = name end
  if kind == "cannon" then cannons[#cannons + 1] = name end
end
out(("Found %d radar(s), %d player detector(s), %d cannon mount(s)."):format(#radars, #detectors, #cannons))
-- cannon mounts are only read (getInfo), never moved or fired
for _, name in ipairs(cannons) do
  local ok, info = pcall(peripheral.call, name, "getInfo")
  out(("  cannon %s info=%s"):format(name, ok and textutils.serialise(info, { compact = true }) or ("error: " .. tostring(info))))
end
if #radars == 0 and #detectors == 0 then
  printError("Nothing to measure: no radar (getTracks) and no player detector (getPlayersInRange) found.")
  printError("Checklist: every device needs its own wired modem, each modem must be right-clicked until it shows red, and the computer needs a modem on the same cable network.")
  store.writeText("probe-peripherals.txt", table.concat(report, "\n"))
  return
end

for _, name in ipairs(radars) do
  local ok, range = pcall(peripheral.call, name, "getRange")
  local ok2, pos = pcall(peripheral.call, name, "getPosition")
  out(("  radar %s range=%s pos=%s"):format(name, ok and tostring(range) or "?", ok2 and textutils.serialise(pos, { compact = true }) or "?"))
end

-- 2. sampling
local function readPlayers(det)
  local ok, list = pcall(peripheral.call, det, "getPlayersInRange", 512)
  if not ok or type(list) ~= "table" then return {} end
  local players = {}
  for _, e in ipairs(list) do
    local name = type(e) == "table" and e.name or e
    local info = (type(e) == "table" and e.x) and e or select(2, pcall(peripheral.call, det, "getPlayer", name))
    if type(info) == "table" and info.x then
      players[#players + 1] = { name = tostring(name), uuid = info.uuid, x = info.x, y = info.y, z = info.z }
    end
  end
  return players
end

local stats = core.new()
local started = os.epoch("utc")
print(("Sampling for %d s. Move around. Ctrl+T stops early and still prints the report."):format(seconds))

local ok, err = pcall(function()
  while (os.epoch("utc") - started) / 1000 < seconds do
    core.beginSample(stats, (os.epoch("utc") - started) / 1000)
    local nTracks, nPlayers = 0, 0
    for _, name in ipairs(radars) do
      local ok, tracks = pcall(peripheral.call, name, "getTracks")
      if ok and type(tracks) == "table" then
        core.addTracks(stats, name, tracks)
        nTracks = nTracks + #tracks
      end
    end
    for _, det in ipairs(detectors) do
      local players = readPlayers(det)
      core.addPlayers(stats, players)
      nPlayers = nPlayers + #players
    end
    core.endSample(stats)
    print(("t=%3ds  tracks=%d  players=%d"):format((os.epoch("utc") - started) / 1000, nTracks, nPlayers))
    sleep(2)
  end
end)
if not ok then print("Stopped: " .. tostring(err)) end

-- 3. report
out("")
out("Report:")
for _, line in ipairs(core.summarize(stats)) do out(line) end
store.writeText("probe-report.txt", table.concat(report, "\n"))
print("Saved to /cmp-data/probe-report.txt")

if toDiscord then
  local discord = require("lib.discord")
  local sent, e = discord.sendChunks("log", "probe report", table.concat(report, "\n"))
  print(sent and "Report sent to Discord (log)." or ("Discord failed: " .. tostring(e)))
end
