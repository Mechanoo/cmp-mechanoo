-- Runs the real radar app for 16 cycles against mocked devices and a fake clock.
local t = require("tests.t")

local function readAll(path)
  local h = fs.open(path, "r")
  local s = h.readAll()
  h.close()
  return s
end
local function writeAll(path, s)
  local h = fs.open(path, "w")
  h.write(s)
  h.close()
end

fs.delete("/void-data")
writeAll("/void-data/discord.json", textutils.serialiseJSON({
  alerts = "https://discord.com/api/webhooks/1/a", log = "https://discord.com/api/webhooks/2/b" }))
writeAll("/void-data/radar.json", textutils.serialiseJSON({ alarmSide = "top", detectRange = 300 }))
writeAll("/void-data/lists.json", textutils.serialiseJSON({
  players = { mechanoo = { name = "Mechanoo", list = "trusted" }, enemy = { name = "Enemy", list = "hostile" } },
  ships = { ["s-old"] = { id = "s-old", list = "trusted", label = "Home", lastPos = { x = 10, y = 70, z = 10 }, lastSeen = 0 } },
}))

-- fake clock
local clock = 1000000
os = setmetatable({ epoch = function() return clock end, getComputerID = function() return 7 end }, { __index = os })
sleep = function(s) clock = clock + math.floor((s or 0) * 1000) end
local function sec() return (clock - 1000000) / 1000 end

-- scenario, by time in seconds
local function players()
  local p = { { name = "Mechanoo", uuid = "u-me", x = 2, y = 64, z = 2 } }
  local s = sec()
  p[#p + 1] = { name = "Stranger", uuid = "u-str", x = s < 2 and 300 or 40, y = 64, z = 0 }
  if s >= 4 then p[#p + 1] = { name = "Enemy", uuid = "u-en", x = 400, y = 64, z = 0 } end
  if s < 3 then p[#p + 1] = { name = "Passerby", uuid = "u-pb", x = 200, y = 64, z = 200 } end
  return p
end
local function tracks()
  local s = sec()
  local list = {}
  if s < 5 then
    list[#list + 1] = { id = "s-old", category = "SABLE", entityType = "Sable:ship", position = { x = 10, y = 70, z = 10 }, velocity = { x = 0, y = 0, z = 0 } }
  elseif s >= 7 then
    list[#list + 1] = { id = "s-new", category = "SABLE", entityType = "Sable:ship", position = { x = 12, y = 70, z = 10 }, velocity = { x = 0, y = 0, z = 0 } }
  end
  if s >= 1 and s < 2 then -- ghost objects for one sample, like after a chunk load
    for g = 1, 6 do
      list[#list + 1] = { id = "ghost-" .. g, category = "SABLE", entityType = "Sable:ship", position = { x = 30 + g, y = 70, z = -30 }, velocity = { x = 0, y = 0, z = 0 } }
    end
  end
  list[#list + 1] = { id = "u-ghost", category = "PLAYER", entityType = "entity.minecraft.player", position = { x = 150, y = 64, z = 150 }, velocity = { x = 0, y = 0, z = 0 } }
  return list
end

local chatCalls, soundCalls, rsCalls, rangesAsked = {}, 0, {}, {}
local P = {
  r0 = { types = { "create_radar:plane_radar" }, methods = { "getTracks", "getPosition", "getRange" } },
  r1 = { types = { "create_radar:plane_radar" }, methods = { "getTracks", "getPosition", "getRange" } },
  det = { types = { "player_detector" }, methods = { "getPlayersInRange", "getPlayer" } },
  chat = { types = { "chat_box" }, methods = { "sendMessage", "sendMessageToPlayer" } },
  spk = { types = { "speaker" }, methods = { "playNote", "playSound" } },
}
peripheral = {
  getNames = function() return { "r0", "r1", "det", "chat", "spk" } end,
  getType = function(n) return table.unpack(P[n].types) end,
  getMethods = function(n) return P[n].methods end,
  call = function(n, m, ...)
    local a = { ... }
    if m == "getPosition" then return { x = n == "r0" and 0 or 2, y = 64, z = 0 } end
    if m == "getRange" then return 250 end
    if m == "getTracks" then return n == "r0" and tracks() or {} end
    if m == "getPlayersInRange" then
      rangesAsked[#rangesAsked + 1] = a[1]
      local names = {}
      for _, p in ipairs(players()) do names[#names + 1] = p.name end
      return names
    end
    if m == "getPlayer" then
      -- like the real Player Detector: "name" is the entity type, the player name is "displayName"
      for _, p in ipairs(players()) do
        if p.name == a[1] or p.uuid == a[1] then
          return { name = "minecraft:player", displayName = p.name, uuid = p.uuid, x = p.x, y = p.y, z = p.z }
        end
      end
      if a[1] == "u-ghost" then return { name = "minecraft:player", displayName = "Ghost", uuid = "u-ghost", x = 150, y = 64, z = 150 } end
    end
    if m == "sendMessageToPlayer" then chatCalls[#chatCalls + 1] = { msg = a[1], to = a[2] } return true end
    if m == "playSound" then soundCalls = soundCalls + 1 return true end
  end,
}
redstone = { setOutput = function(side, on) rsCalls[#rsCalls + 1] = { side, on } end }

local posts = {}
http = {
  post = function(url, body)
    local payload = textutils.unserialiseJSON(body)
    local parts = {}
    for _, e in ipairs(payload.embeds or {}) do parts[#parts + 1] = e.title .. "\n" .. e.description end
    posts[#posts + 1] = { url = url, content = table.concat(parts, "\n"), embeds = #(payload.embeds or {}) }
    return { getResponseCode = function() return 204 end, close = function() end }
  end,
}

local fn = assert(loadfile("/work/apps/radar/main.lua", "t", _ENV))
fn("--cycles", "80")

local alertsText, logText = {}, {}
for _, p in ipairs(posts) do
  if p.url:find("/1/a") then alertsText[#alertsText + 1] = p.content else logText[#logText + 1] = p.content end
end
local A, L = table.concat(alertsText, "\n"), table.concat(logText, "\n")

t.contains(L, "Radar online on computer 7: 2 radar(s), 1 detector(s), zone 10x10 chunks", "online message")
t.contains(A, "CONTACT: Stranger", "stranger detected")
t.contains(A, "Visit #1", "visit number")
t.contains(A, "Base level: **", "base level")
t.contains(A, "CONTACT: Ghost", "name of a radar-only player looked up by uuid")
t.eq(A:find("CONTACT: player ", 1, true), nil, "every player got a name")
t.eq(A:find("minecraft:player", 1, true), nil, "the entity type is never used as a name")
t.contains(A, "NO-GO ZONE", "stranger entered the zone")
t.eq(A:find("APPROACH: Stranger", 1, true), nil, "no ring alert when jumping straight into the zone")
t.contains(A, "Base level: **5 ENGAGE**", "level 5 once something is engaged")
t.contains(A, "ENGAGE: Stranger", "engaged after the countdown")
t.contains(A, "HOSTILE: Enemy", "hostile reported")
t.eq(A:find("Mechanoo", 1, true), nil, "trusted owner never reported")
t.contains(L, "SHIP REASSEMBLED", "ship takeover logged")
t.contains(L, "took over the list **trusted**", "takeover text")
t.eq(A:find("s-new", 1, true), nil, "reassembled ship is not an alert")
t.eq(A:find("ghost-", 1, true), nil, "one-sample ghost ships cause no alert")
t.eq(L:find("ghost-", 1, true), nil, "and no visit record")

t.eq(#chatCalls, 1, "one chat warning")
t.eq(chatCalls[1] and chatCalls[1].to, "Stranger", "warning to the stranger")
t.contains(chatCalls[1] and chatCalls[1].msg or "", "no-go zone", "warning text")
t.truthy(soundCalls >= 2, "alarm sound played")
local sawOn = false
for _, c in ipairs(rsCalls) do if c[1] == "top" and c[2] == true then sawOn = true end end
t.truthy(sawOn, "redstone alarm on")

t.eq(rangesAsked[1], 300, "configured detector range is used")
local saved = textutils.unserialiseJSON(readAll("/void-data/lists.json"))
t.eq(saved.ships["s-new"] and saved.ships["s-new"].list, "trusted", "takeover saved")
t.eq(saved.ships["s-new"] and saved.ships["s-new"].label, "Home", "label saved")
t.eq(saved.players.mechanoo.uuid, "u-me", "uuid remembered")
t.contains(L, "VISIT ENDED: Passerby", "visit summary in the log")
t.contains(L, "Visits so far: 1", "visit count in the log")
t.contains(L, "From <t:1000:t> to <t:1002:t> (2s)", "visit length without the hold time")
local hist = textutils.unserialiseJSON(readAll("/void-data/history.json"))
t.eq(hist.players.passerby and hist.players.passerby.visits, 1, "history saved")
local logText = readAll("/void-data/radar.log")
t.contains(logText, "CONTACT Stranger (unknown player)", "events written to radar.log")
t.contains(logText, "1970-01-01 00:16:40 ", "UTC timestamp in radar.log")
local rcfg = textutils.unserialiseJSON(readAll("/void-data/radar.json"))
t.eq(rcfg.zone and rcfg.zone.x1, -80, "zone created around the radars")

fs.delete("/void-data")
t.finish("radar app")
