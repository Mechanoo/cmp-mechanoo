-- radar: base watch. Merges the plane radars and the player detector, keeps the
-- friend/foe lists, runs the no-go zone countdown and reports to Discord.
-- Cannons are NOT controlled yet: "engage" is only reported.
--
--   void radar                 start (type "help" at the prompt)
--   void radar autostart on    start automatically when the computer boots
--   void radar autostart off
package.path = "/void/?.lua;" .. package.path

local store = require("lib.store")
local discord = require("lib.discord")
local lists = require("lib.lists")
local tracker = require("lib.tracker")
local policy = require("lib.policy")
local commands = require("lib.commands")
local alerts = require("lib.alerts")
local Z = require("lib.zone")
local D = require("lib.duration")
local probe = require("lib.probe_core")

local args = { ... }
local AUTOSTART = "/startup/void_radar.lua"

if args[1] == "autostart" then
  if args[2] == "on" then
    local h = fs.open(AUTOSTART, "w")
    h.write('-- installed by void: starts the radar on boot\nshell.run("/void/bin/void.lua", "radar")\n')
    h.close()
    print("The radar now starts when this computer boots.")
  elseif args[2] == "off" then
    fs.delete(AUTOSTART)
    print("Autostart removed.")
  else
    print("usage: void radar autostart on|off")
  end
  return
end

-- test mode: void radar --cycles N  (no screen, no prompt, stops after N cycles)
local maxCycles
for i, a in ipairs(args) do
  if a == "--cycles" then maxCycles = tonumber(args[i + 1]) end
end
local headless = maxCycles ~= nil

---------------------------------------------------------------- state
local CONFIG_FILE, LISTS_FILE = "radar.json", "lists.json"
local cfg = store.readJson(CONFIG_FILE, {})
cfg.visitorDefaultMs = cfg.visitorDefaultMs or 30 * 60000
cfg.intervalS = cfg.intervalS or 1
local ls = lists.new(store.readJson(LISTS_FILE, nil))
local tr = tracker.new(cfg.tracker)
local ps = policy.new(cfg.policy)
local queue = alerts.queue()
local logLines = {}
local devices = { radars = {}, detectors = {}, chat = nil, speaker = nil }
local radarCenter
local decisions = {}
local lastListsSave = 0
local serviceDone = false

local function now() return os.epoch("utc") end

---------------------------------------------------------------- screen
local W, H = term.getSize()
local root = term.current()
local statusWin, logWin, inputWin
local LOG_ROWS = math.max(3, math.floor(H / 4))

if not headless then
  term.clear()
  statusWin = window.create(root, 1, 1, W, H - LOG_ROWS - 1)
  logWin = window.create(root, 1, H - LOG_ROWS, W, LOG_ROWS)
  inputWin = window.create(root, 1, H, W, 1)
end

local function log(text)
  logLines[#logLines + 1] = text
  if #logLines > 200 then table.remove(logLines, 1) end
  if headless then
    print(text)
    return
  end
  logWin.setTextColor(colors.lightGray)
  local rest = text
  repeat -- wrap long lines instead of cutting them off
    logWin.scroll(1)
    logWin.setCursorPos(1, LOG_ROWS)
    logWin.write(rest:sub(1, W))
    rest = rest:sub(W + 1)
  until rest == ""
  inputWin.restoreCursor()
end

---------------------------------------------------------------- devices
local function scan()
  devices.radars, devices.detectors, devices.chat, devices.speaker = {}, {}, nil, nil
  for _, name in ipairs(peripheral.getNames()) do
    local methods = peripheral.getMethods(name) or {}
    local kind = probe.classify({ peripheral.getType(name) }, methods)
    local has = {}
    for _, m in ipairs(methods) do has[m] = true end
    if kind == "radar" then devices.radars[#devices.radars + 1] = name
    elseif kind == "detector" then devices.detectors[#devices.detectors + 1] = name
    elseif has.sendMessageToPlayer then devices.chat = name
    elseif has.playSound then devices.speaker = name end
  end
  table.sort(devices.radars)
  -- average radar position = default zone centre
  local sx, sz, n = 0, 0, 0
  for _, r in ipairs(devices.radars) do
    local ok, p = pcall(peripheral.call, r, "getPosition")
    if ok and type(p) == "table" and p.x then
      sx, sz, n = sx + p.x, sz + p.z, n + 1
    end
  end
  radarCenter = n > 0 and { x = sx / n, y = 0, z = sz / n } or nil
end

local function readDetector(det)
  local ok, list = pcall(peripheral.call, det, "getPlayersInRange", cfg.detectRange or 512)
  if not ok or type(list) ~= "table" then return {} end
  local players, tasks = {}, {}
  for _, e in ipairs(list) do
    if type(e) == "table" and e.x and e.name then
      players[#players + 1] = { name = e.name, uuid = e.uuid, x = e.x, y = e.y, z = e.z }
    else
      local name = type(e) == "table" and e.name or e
      tasks[#tasks + 1] = function()
        local ok2, info = pcall(peripheral.call, det, "getPlayer", name)
        if ok2 and type(info) == "table" and info.x then
          players[#players + 1] = { name = tostring(info.name or name), uuid = info.uuid, x = info.x, y = info.y, z = info.z }
        end
      end
    end
  end
  if #tasks > 0 then parallel.waitForAll(table.unpack(tasks)) end
  return players
end

local function sample()
  local tracks, players, tasks = {}, {}, {}
  for _, r in ipairs(devices.radars) do
    tasks[#tasks + 1] = function()
      local ok, list = pcall(peripheral.call, r, "getTracks")
      if ok and type(list) == "table" then
        for _, tk in ipairs(list) do tracks[#tracks + 1] = tk end
      end
    end
  end
  for _, d in ipairs(devices.detectors) do
    tasks[#tasks + 1] = function()
      for _, p in ipairs(readDetector(d)) do players[#players + 1] = p end
    end
  end
  if #tasks > 0 then parallel.waitForAll(table.unpack(tasks)) end
  return tracks, players
end

---------------------------------------------------------------- outputs
local function saveLists(force)
  local t = now()
  if ls.dirty or force or (ls.touched and t - lastListsSave > 15000) then
    store.writeJson(LISTS_FILE, lists.data(ls))
    ls.dirty, ls.touched, lastListsSave = false, false, t
  end
end

local function saveConfig()
  store.writeJson(CONFIG_FILE, cfg)
end

local function sound()
  if devices.speaker then
    pcall(peripheral.call, devices.speaker, "playSound", "minecraft:block.note_block.bell", 3, 1)
  end
end

local function warnPlayer(name, text)
  if devices.chat and name then
    pcall(peripheral.call, devices.chat, "sendMessageToPlayer", text, name, "Void")
  end
end

local function handle(ev)
  local ch = alerts.push(queue, ev)
  local _, text = alerts.format(ev)
  if text then log((ch == "alerts" and "! " or "  ") .. text:gsub("%*%*", ""):gsub("`", "")) end
  local t = ev.target
  if ev.type == "zone_enter" then
    sound()
    if t and t.kind == "player" then
      warnPlayer(t.name, "You are in a no-go zone. Leave within " .. D.format(ev.countdownMs) .. " or you will be fired upon.")
    end
  elseif ev.type == "engage" or ev.type == "hostile" then
    sound()
  end
end

local function applyAlarm()
  if not cfg.alarmSide then return end
  local on = false
  for _, d in pairs(decisions) do
    if d.action == "warn" or d.action == "engage" then on = true end
  end
  pcall(redstone.setOutput, cfg.alarmSide, on)
end

---------------------------------------------------------------- screen drawing
local ORDER = { engage = 1, warn = 2, watch = 3, friendly = 4, ignore = 5 }
local SHORT = { engage = "ENG", warn = "WARN", watch = "SEEN", friendly = "OK", ignore = "--" }
local NARROW = W < 40
local COLOR = { engage = colors.red, warn = colors.orange, watch = colors.yellow, friendly = colors.lime, ignore = colors.gray }

local function drawStatus()
  if headless then return end
  local w = statusWin
  w.setBackgroundColor(colors.black)
  w.clear()
  w.setCursorPos(1, 1)
  w.setTextColor(colors.white)
  local zoneText = cfg.zone and (cfg.zone.chunks .. "x" .. cfg.zone.chunks) or "-"
  if NARROW then
    w.write(("VOID  R%d D%d zone %s"):format(#devices.radars, #devices.detectors, zoneText):sub(1, W))
  else
    w.write(("VOID RADAR  radars %d  det %d  zone %s"):format(#devices.radars, #devices.detectors, zoneText):sub(1, W))
  end
  local all = tracker.all(tr)
  table.sort(all, function(a, b)
    local da, db = decisions[a.id], decisions[b.id]
    local oa, ob = ORDER[da and da.action or "ignore"], ORDER[db and db.action or "ignore"]
    if oa ~= ob then return oa < ob end
    return (cfg.zone and Z.distance(cfg.zone, a.pos) or 0) < (cfg.zone and Z.distance(cfg.zone, b.pos) or 0)
  end)
  local _, rows = w.getSize()
  local line = 2
  for _, t in ipairs(all) do
    if line > rows then break end
    local d = decisions[t.id] or { action = "ignore", cls = "?" }
    local label
    if t.kind == "player" then label = t.name or tracker.short(t.id)
    elseif t.kind == "ship" then
      local e = ls.ships[t.id]
      label = "ship " .. ((e and e.label) or tracker.short(t.id))
    else label = tostring(t.category or "?"):lower() end
    local dist = cfg.zone and math.floor(Z.distance(cfg.zone, t.pos) + 0.5) or 0
    local extra = d.action == "warn" and (" " .. D.format(d.remainingMs)) or ""
    w.setCursorPos(1, line)
    w.setTextColor(COLOR[d.action] or colors.white)
    local inside = Z.contains(cfg.zone, t.pos)
    if NARROW then
      -- 26 columns: "WARN Stranger    41 Z 8s"
      local name = label:sub(1, W - 15)
      w.write(("%-4s %-" .. (W - 15) .. "s%5d%s%s"):format(SHORT[d.action] or "?", name, dist,
        inside and " Z" or "", extra):sub(1, W))
    else
      w.write(("%-8s %-16s %5d%s%s"):format(d.action, label:sub(1, 16), dist,
        inside and " ZONE" or "", extra):sub(1, W))
    end
    line = line + 1
  end
  if #all == 0 then
    w.setCursorPos(1, 2)
    w.setTextColor(colors.gray)
    w.write("nothing in range")
  end
  inputWin.restoreCursor()
end

---------------------------------------------------------------- loops
local function cycle()
  local t = now()
  local tracks, players = sample()
  t = now()
  for _, ev in ipairs(tracker.update(tr, t, tracks, players, ls)) do
    if ev.type == "lost" then policy.lost(ps, ev.id, t)
    elseif ev.type ~= "new" then handle(ev) end
  end
  for _, ev in ipairs(lists.expire(ls, t)) do handle(ev) end
  local evs
  decisions, evs = policy.update(ps, t, tracker.all(tr), ls, cfg.zone)
  for _, ev in ipairs(evs) do handle(ev) end
  applyAlarm()
  saveLists()
  drawStatus()
end

local function serviceLoop()
  local n, lastScan = 0, now()
  while true do
    local started = now()
    if started - lastScan > 30000 then
      scan()
      lastScan = started
    end
    cycle()
    n = n + 1
    if maxCycles and n >= maxCycles then
      serviceDone = true
      return
    end
    local rest = cfg.intervalS - (now() - started) / 1000
    sleep(rest > 0.05 and rest or 0.05)
  end
end

local function discordLoop()
  local cfgD = discord.config()
  local enabled = cfgD.alerts or cfgD.log
  while true do
    for _, m in ipairs(alerts.drain(queue)) do
      if enabled then
        local ok, err, code = discord.send(m[1], m[2])
        if not ok then
          log("discord " .. m[1] .. " failed: " .. tostring(err))
          if code == 429 then sleep(5) end
        end
        sleep(1)
      end
    end
    if maxCycles and serviceDone and (#queue.alerts + #queue.log) == 0 then return end
    sleep(2)
  end
end

local function inputLoop()
  while true do
    term.redirect(inputWin)
    inputWin.clear()
    inputWin.setCursorPos(1, 1)
    inputWin.setTextColor(colors.white)
    write("> ")
    local line = read()
    term.redirect(root)
    local r = commands.run({ lists = ls, tracker = tr, config = cfg, now = now(), radarCenter = radarCenter }, line)
    for _, l in ipairs(r.lines) do log(l) end
    for _, ev in ipairs(r.events) do alerts.push(queue, ev) end
    if r.configChanged then saveConfig() end
    saveLists()
    drawStatus()
  end
end

---------------------------------------------------------------- start
scan()
if not cfg.zone and radarCenter then
  cfg.zone = Z.fromCenter(radarCenter.x, radarCenter.z, 10)
  saveConfig()
end

if not headless and next(ls.players) == nil and next(ls.ships) == nil then
  term.redirect(root)
  term.clear()
  term.setCursorPos(1, 1)
  print("First start. Lists are empty, so everyone is unknown.")
  print("Your Minecraft name (it will be trusted),")
  write("or empty to skip: ")
  local name = read()
  if name:match("^[%w_]+$") and #name <= 16 then
    lists.setPlayer(ls, name, "trusted", now())
    saveLists(true)
  end
  term.clear()
end

local count = 0
for _ in pairs(ls.players) do count = count + 1 end
local shipCount = 0
for _ in pairs(ls.ships) do shipCount = shipCount + 1 end
handle({ type = "online", text = ("Radar online on computer %d: %d radar(s), %d detector(s), zone %s. Lists: %d player(s), %d ship(s)."):format(
  os.getComputerID(), #devices.radars, #devices.detectors, cfg.zone and (cfg.zone.chunks .. "x" .. cfg.zone.chunks .. " chunks") or "not set",
  count, shipCount) })
if not cfg.zone then log("No zone yet: type 'zone center <x> <z>'") end
if #devices.radars == 0 and #devices.detectors == 0 then log("No radar or detector found. Check the wired modems (red).") end
log("Type 'help' for commands.")

if headless then
  parallel.waitForAll(serviceLoop, discordLoop)
else
  drawStatus()
  parallel.waitForAny(serviceLoop, discordLoop, inputLoop)
end
saveLists(true)
