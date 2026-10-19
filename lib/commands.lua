-- Console commands of the radar service. Pure logic: works on a context and
-- returns text lines, so it can be tested without a computer.
--
-- ctx = {
--   lists, tracker, config (zone, visitorDefaultMs), now,
--   radarCenter = {x,y,z} or nil,   -- average radar position, for "zone radars"
--   history,                          -- visit history (lib.history), optional
-- }
-- Returns { lines = {...}, events = {...}, configChanged = bool }
local lists = require("lib.lists")
local tracker = require("lib.tracker")
local Z = require("lib.zone")
local D = require("lib.duration")
local V = require("lib.vec")
local history = require("lib.history")
local clock = require("lib.clock")
local reference = require("lib.reference")

local C = {}

C.HELP = {
  "targets            what the radar sees now",
  "players            player lists",
  "ships              ships (seen now and listed)",
  "trust <name>       hostile <name>",
  "visitor <name> [time]   e.g. visitor Bob 45m",
  "forget <name>      back to unknown",
  "ship <id> trust|hostile|forget|visitor [time]",
  "label <id> <text>  name a ship",
  "zone               show the no-go zone",
  "zone center <x> <z> [chunks]",
  "zone radars [chunks]   centre on the radars",
  "history [name]     how often and when players were here",
  "timezone <hours>   e.g. timezone 2 for UTC+2",
  "basename <text>    name of the base in Discord",
  "detectrange <blocks>   player detector range (default 512)",
  "alarm              siren state",
  "alarm mute [time]  silence the siren (default 10m)",
  "alarm on | alarm test | alarm volume <0-3>",
  "commands           every command with an explanation",
  "help <command>     explain one command",
  "exit               stop the radar (back to the shell)",
}

local function words(line)
  local w = {}
  for p in line:gmatch("%S+") do w[#w + 1] = p end
  return w
end

local function validName(n)
  return type(n) == "string" and n:match("^[%w_]+$") ~= nil and #n <= 16
end

local function describeTarget(t, ls, zone)
  local cls = tracker.classify(t, ls)
  local who
  if t.kind == "player" then
    who = t.name or ("player " .. tracker.short(t.id))
  elseif t.kind == "ship" then
    local e = ls.ships[t.id]
    who = "ship " .. tracker.short(t.id) .. ((e and e.label) and (" '" .. e.label .. "'") or "")
  else
    who = tostring(t.category or "?") .. " " .. tracker.short(t.id)
  end
  local dist = zone and ("%4d"):format(math.floor(Z.distance(zone, t.pos) + 0.5)) or "   ?"
  local inside = Z.contains(zone, t.pos) and " ZONE" or ""
  return ("%-8s %s %s%s"):format(cls, dist, who, inside)
end

-- Finds a ship by id prefix among current targets and listed ships.
local function findShip(ctx, prefix)
  prefix = (prefix or ""):lower()
  if #prefix < 3 then return nil, "give at least 3 characters of the ship id" end
  local found = {}
  for id, t in pairs(ctx.tracker.targets) do
    if t.kind == "ship" and id:lower():sub(1, #prefix) == prefix then found[id] = t end
  end
  for id in pairs(ctx.lists.ships) do
    if id:lower():sub(1, #prefix) == prefix then found[id] = found[id] or true end
  end
  local ids = {}
  for id in pairs(found) do ids[#ids + 1] = id end
  if #ids == 0 then return nil, "no ship with id " .. prefix .. "..." end
  if #ids > 1 then return nil, "several ships start with " .. prefix .. ", give more characters" end
  local t = found[ids[1]]
  return ids[1], (t ~= true) and t or nil
end

function C.run(ctx, line)
  local out = { lines = {}, events = {}, configChanged = false }
  local function say(s) out.lines[#out.lines + 1] = s end
  local function changed(text, extra)
    local ev = { type = "list_change", text = text }
    for k, v in pairs(extra or {}) do ev[k] = v end
    out.events[#out.events + 1] = ev
  end
  local off = ctx.config.timeOffsetHours
  local function untilText(expires)
    return clock.hm(expires, off) .. " " .. clock.tzName(off)
  end

  local w = words(line or "")
  local cmd = (w[1] or ""):lower()
  local ls, cfg, now = ctx.lists, ctx.config, ctx.now

  if cmd == "" then
    return out
  elseif cmd == "help" or cmd == "?" then
    if w[2] then
      local hits = reference.find(w[2])
      if #hits == 0 then
        say("no command '" .. w[2] .. "', type commands for the full list")
      end
      for _, it in ipairs(hits) do
        say(it[1])
        for _, l in ipairs(reference.wrap(it[2], 50, "  ")) do say(l) end
      end
    else
      for _, l in ipairs(C.HELP) do say(l) end
    end

  elseif cmd == "commands" or cmd == "cmds" then
    if (w[2] or ""):lower() == "discord" then
      for _, e in ipairs(reference.embeds()) do
        out.events[#out.events + 1] = { type = "reference", title = e.title, text = e.description }
      end
      say("command list sent to the Discord log channel")
    else
      out.pager = true
    end

  elseif cmd == "targets" or cmd == "t" then
    local all = tracker.all(ctx.tracker)
    if #all == 0 then say("nothing in range") end
    for _, t in ipairs(all) do say(describeTarget(t, ls, cfg.zone)) end

  elseif cmd == "players" then
    local keys = {}
    for k in pairs(ls.players) do keys[#keys + 1] = k end
    table.sort(keys)
    if #keys == 0 then say("no players listed (everyone is unknown)") end
    for _, k in ipairs(keys) do
      local e = ls.players[k]
      local extra = ""
      if e.list == "visitor" then
        extra = " (until " .. untilText(e.expires) .. ", " .. D.format(e.expires - now) .. " left, then "
          .. (e.prev or "unknown") .. ")"
      end
      say(("%-8s %s%s"):format(e.list, e.name, extra))
    end

  elseif cmd == "trust" or cmd == "hostile" or cmd == "forget" or cmd == "unknown" or cmd == "visitor" then
    local name = w[2]
    if not validName(name) then
      say("usage: " .. cmd .. " <player name>")
      return out
    end
    if cmd == "visitor" then
      local ms = cfg.visitorDefaultMs or 30 * 60000
      if w[3] then
        ms = D.parse(w[3])
        if not ms then
          say("bad time '" .. w[3] .. "', use e.g. 30m, 2h, 1h30m")
          return out
        end
      end
      lists.setPlayer(ls, name, "visitor", now, ms)
      local text = name .. " is a visitor until " .. untilText(now + ms) .. " (" .. D.format(ms) .. ")"
      say(text)
      changed(text, { who = name, list = "visitor", expires = now + ms })
    elseif cmd == "forget" or cmd == "unknown" then
      if lists.setPlayer(ls, name, nil, now) then
        say(name .. " is unknown again")
        changed(name .. " removed from the lists (unknown)")
      else
        say(name .. " was not on a list")
      end
    else
      local list = cmd == "trust" and "trusted" or "hostile"
      lists.setPlayer(ls, name, list, now)
      say(name .. " is now " .. list)
      changed(name .. " is now " .. list)
    end

  elseif cmd == "ships" then
    local any = false
    for _, t in ipairs(tracker.all(ctx.tracker)) do
      if t.kind == "ship" then
        say("seen   " .. describeTarget(t, ls, cfg.zone) .. "  id " .. t.id)
        any = true
      end
    end
    for id, e in pairs(ls.ships) do
      if not ctx.tracker.targets[id] then
        local label = e.label and (" '" .. e.label .. "'") or ""
        if e.replacedBy then
          -- the old id of a reassembled ship, kept for a while in case it was only radar flicker
          local window = ctx.tracker.cfg.takeoverWindowMs or 60000
          local left = window - (now - (e.replacedAt or now))
          say(("old    ship %s%s -> now %s, gone in %s"):format(tracker.short(id), label,
            tracker.short(e.replacedBy), D.format(left > 0 and left or 0)))
        else
          local extra = e.lastSeen and (" last seen " .. D.format(now - e.lastSeen) .. " ago") or ""
          say(("listed %-8s ship %s%s%s"):format(e.list, tracker.short(id), label, extra))
        end
        any = true
      end
    end
    if not any then say("no ships seen or listed") end

  elseif cmd == "ship" then
    local id, t = findShip(ctx, w[2])
    if not id then
      say(t)
      return out
    end
    local action = (w[3] or ""):lower()
    local info = t and { pos = V.copy(t.pos), seen = now } or nil
    local short = tracker.short(id)
    if action == "trust" or action == "hostile" then
      local list = action == "trust" and "trusted" or "hostile"
      lists.setShip(ls, id, list, now, nil, info)
      say("ship " .. short .. " is now " .. list)
      changed("ship " .. short .. " is now " .. list)
    elseif action == "visitor" then
      local ms = cfg.visitorDefaultMs or 30 * 60000
      if w[4] then
        ms = D.parse(w[4])
        if not ms then
          say("bad time '" .. w[4] .. "'")
          return out
        end
      end
      lists.setShip(ls, id, "visitor", now, ms, info)
      local text = "ship " .. short .. " is a visitor until " .. untilText(now + ms) .. " (" .. D.format(ms) .. ")"
      say(text)
      changed(text, { who = "ship " .. short, list = "visitor", expires = now + ms })
    elseif action == "forget" or action == "unknown" then
      lists.setShip(ls, id, nil, now)
      say("ship " .. short .. " is unknown again")
      changed("ship " .. short .. " removed from the lists")
    else
      say("usage: ship <id> trust|hostile|visitor [time]|forget")
    end

  elseif cmd == "label" then
    local id, t = findShip(ctx, w[2])
    if not id then
      say(t)
      return out
    end
    local text = table.concat(w, " ", 3)
    if text == "" or #text > 24 then
      say("usage: label <id> <text up to 24 characters>")
      return out
    end
    local e = ls.ships[id]
    if not e then
      say("list the ship first (ship " .. tracker.short(id) .. " trust|hostile|visitor)")
      return out
    end
    e.label = text
    ls.dirty = true
    say("ship " .. tracker.short(id) .. " is now called '" .. text .. "'")

  elseif cmd == "zone" then
    local sub = (w[2] or ""):lower()
    if sub == "" then
      say("zone: " .. Z.describe(cfg.zone))
    elseif sub == "center" or sub == "centre" then
      local x, z, n = tonumber(w[3]), tonumber(w[4]), tonumber(w[5] or "10")
      if not (x and z and n) or n < 1 or n > 64 or n % 1 ~= 0 then
        say("usage: zone center <x> <z> [chunks 1-64]")
        return out
      end
      cfg.zone = Z.fromCenter(x, z, n)
      out.configChanged = true
      say("zone: " .. Z.describe(cfg.zone))
    elseif sub == "radars" then
      local n = tonumber(w[3] or "10")
      if not ctx.radarCenter then
        say("no radar position known")
        return out
      end
      if not n or n < 1 or n > 64 or n % 1 ~= 0 then
        say("usage: zone radars [chunks 1-64]")
        return out
      end
      cfg.zone = Z.fromCenter(ctx.radarCenter.x, ctx.radarCenter.z, n)
      out.configChanged = true
      say("zone: " .. Z.describe(cfg.zone))
    else
      say("usage: zone | zone center <x> <z> [chunks] | zone radars [chunks]")
    end

  elseif cmd == "history" then
    if not ctx.history then
      say("no history available")
      return out
    end
    local off = cfg.timeOffsetHours or 0
    say("times in " .. (off == 0 and "UTC" or ("UTC" .. (off > 0 and "+" or "") .. off)))
    local lines = w[2] and history.details(ctx.history, w[2], off) or history.summary(ctx.history, off, 30)
    for _, l in ipairs(lines) do say(l) end

  elseif cmd == "exit" or cmd == "quit" then
    out.exit = true
    say("stopping the radar")

  elseif cmd == "alarm" then
    local sub = (w[2] or ""):lower()
    if sub == "" then
      local state = (cfg.alarmMuteUntil and now < cfg.alarmMuteUntil)
        and ("muted until " .. untilText(cfg.alarmMuteUntil)) or "on"
      say("alarm " .. state .. ", volume " .. tostring(cfg.alarmVolume or 3)
        .. (ctx.speakers and (", " .. ctx.speakers .. " speaker(s)") or ""))
    elseif sub == "mute" then
      local ms = 10 * 60000
      if w[3] then
        ms = D.parse(w[3])
        if not ms then
          say("bad time '" .. w[3] .. "', use e.g. 10m, 1h")
          return out
        end
      end
      cfg.alarmMuteUntil = now + ms
      out.configChanged = true
      say("siren muted until " .. untilText(now + ms) .. " (Discord keeps reporting)")
    elseif sub == "on" or sub == "unmute" then
      cfg.alarmMuteUntil = nil
      out.configChanged = true
      say("siren on")
    elseif sub == "test" then
      out.alarmTest = true
      say("siren test for 3 seconds")
    elseif sub == "volume" then
      local v = tonumber(w[3])
      if not v or v < 0 or v > 3 then
        say("usage: alarm volume <0-3>")
        return out
      end
      cfg.alarmVolume = v
      out.configChanged = true
      say("siren volume " .. v)
    else
      say("usage: alarm | alarm mute [time] | alarm on | alarm test | alarm volume <0-3>")
    end

  elseif cmd == "detectrange" then
    local n = tonumber(w[2])
    if not n or n < 16 or n > 512 or n % 1 ~= 0 then
      say("usage: detectrange <16-512>, now " .. tostring(cfg.detectRange or 512))
      return out
    end
    cfg.detectRange = n
    out.configChanged = true
    say("player detector range is " .. n .. " blocks now")

  elseif cmd == "basename" then
    local text = table.concat(w, " ", 2)
    if text == "" or #text > 32 or text:find("[^%w _%-']") then
      say("usage: basename <name, up to 32 letters, digits, spaces>")
      return out
    end
    cfg.baseName = text
    out.configChanged = true
    say("the base is called '" .. text .. "' in Discord now")

  elseif cmd == "timezone" then
    local n = tonumber(w[2])
    if not n or n < -12 or n > 14 then
      say("usage: timezone <hours from UTC>, e.g. timezone 2")
      return out
    end
    cfg.timeOffsetHours = n
    out.configChanged = true
    say("times are now shown in UTC" .. (n >= 0 and "+" or "") .. n)

  else
    say("unknown command '" .. cmd .. "', type help")
  end
  return out
end

return C
