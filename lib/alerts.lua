-- Turns events into Discord embeds (coloured cards) and batches them.
-- Channels: "alerts" (needs attention) and "log" (record).
-- Text is ASCII only, so the JSON encoding in CC cannot garble anything.
--
-- ctx = { now = ms, baseName = "Void base", level = { n = 3, label = "ELEVATED" } or nil }
-- Times are Discord timestamps only: Discord shows them in each reader's own zone.
local V = require("lib.vec")
local D = require("lib.duration")
local C = require("lib.clock")
local tracker = require("lib.tracker")

local A = {}

A.COLOR = {
  red = 0xE74C3C, orange = 0xE67E22, yellow = 0xF1C40F,
  green = 0x2ECC71, blue = 0x3498DB, gray = 0x95A5A6,
}
A.MAX_EMBEDS = 10   -- Discord limit per message
A.MAX_CHARS = 5500  -- Discord allows 6000 characters of embeds per message

-- Name for titles: "Steve", "ship 8c98841d 'Home'"
local function name(t)
  if not t then return "?" end
  if t.kind == "player" then return t.name or ("player " .. tracker.short(t.id)) end
  if t.kind == "ship" then
    return "ship " .. tracker.short(t.id) .. (t.label and (" '" .. t.label .. "'") or "")
  end
  return tostring(t.kind) .. " " .. tracker.short(t.id)
end

local function kindWord(t)
  return (t and t.kind == "ship") and "ship" or "player"
end

local function at(ms)
  return C.discord(ms, "t")
end

local function position(t)
  if not t or not t.pos then return nil end
  local s = "Position: `" .. V.round(t.pos) .. "`"
  if t.dist then s = s .. ", " .. math.floor(t.dist + 0.5) .. " blocks from base" end
  return s
end

local function levelLine(ctx)
  if not ctx.level then return nil end
  return "Base level: **" .. ctx.level.n .. " " .. ctx.level.label .. "**"
end

local function hint(t)
  if not t then return nil end
  if t.kind == "player" and t.name then
    return "In game: `trust " .. t.name .. "`, `visitor " .. t.name .. " 30m`, `hostile " .. t.name .. "`"
  elseif t.kind == "ship" then
    local s = tracker.short(t.id)
    return "In game: `ship " .. s .. " trust`, `ship " .. s .. " visitor 30m`, `ship " .. s .. " hostile`"
  end
  return nil
end

local function shipName(id, label)
  return "ship `" .. tracker.short(id) .. "`" .. (label and (" '" .. label .. "'") or "")
end

-- Returns channel, embed, gameText   or nil if the event is not reported.
function A.format(ev, ctx)
  ctx = ctx or {}
  local now = ctx.now or os.epoch("utc")
  local base = ctx.baseName or "Void base"
  local t = ev.target
  local ty = ev.type
  local ch, color, title, lines, game

  if ty == "detected" then
    ch, color, title = "alerts", A.COLOR.yellow, "CONTACT: " .. name(t)
    lines = { "Unknown " .. kindWord(t) .. " near **" .. base .. "** at " .. at(now, ctx), position(t),
      ev.visit and ("Visit #" .. ev.visit) or nil, levelLine(ctx), hint(t) }
    game = "CONTACT " .. name(t) .. " (unknown " .. kindWord(t) .. ")"
  elseif ty == "hostile" then
    ch, color, title = "alerts", A.COLOR.red, "HOSTILE: " .. name(t)
    lines = { "Hostile " .. kindWord(t) .. " near **" .. base .. "** at " .. at(now, ctx), position(t),
      ev.visit and ("Visit #" .. ev.visit) or nil, levelLine(ctx), "Engage." }
    game = "HOSTILE " .. name(t)
  elseif ty == "approach" then
    ch, color, title = "alerts", A.COLOR.yellow, "APPROACH: " .. name(t)
    lines = { "Unknown " .. kindWord(t) .. " within **" .. ev.ring .. " blocks** of **" .. base .. "** at " .. at(now, ctx),
      position(t), levelLine(ctx) }
    game = "APPROACH " .. name(t) .. " within " .. ev.ring
  elseif ty == "zone_enter" then
    local fireAt = now + (ev.countdownMs or 0)
    ch, color, title = "alerts", A.COLOR.orange, "NO-GO ZONE: " .. name(t)
    lines = { "Unknown " .. kindWord(t) .. " entered the no-go zone of **" .. base .. "** at " .. at(now, ctx),
      position(t), "Engaging " .. C.discord(fireAt, "R") .. " unless marked trusted or visitor.", levelLine(ctx), hint(t) }
    game = "NO-GO ZONE " .. name(t) .. ", engaging in " .. D.format(ev.countdownMs)
  elseif ty == "zone_leave" then
    ch, color, title = "alerts", A.COLOR.gray, "LEFT ZONE: " .. name(t)
    lines = { "Left the no-go zone at " .. at(now, ctx), levelLine(ctx) }
    game = "LEFT ZONE " .. name(t)
  elseif ty == "zone_cleared" then
    ch, color, title = "log", A.COLOR.green, "CLEARED: " .. name(t)
    lines = { "Now " .. tostring(t and t.cls) .. ", countdown stopped at " .. at(now, ctx) }
    game = "CLEARED " .. name(t) .. ", countdown stopped"
  elseif ty == "engage" then
    ch, color, title = "alerts", A.COLOR.red, "ENGAGE: " .. name(t)
    lines = { "Countdown over at " .. at(now, ctx) .. ", " .. kindWord(t) .. " is still in the no-go zone.",
      position(t), levelLine(ctx), "Cannons: not connected yet." }
    game = "ENGAGE " .. name(t)
  elseif ty == "visitor_expired" then
    local who = ev.target == "ship" and shipName(ev.id, ev.label) or ("**" .. tostring(ev.name) .. "**")
    ch, color, title = "log", A.COLOR.gray, "VISITOR TIME OVER"
    lines = { who .. " is " .. ev.to .. " again since " .. at(now, ctx) }
    game = "VISITOR TIME OVER " .. tostring(ev.name or tracker.short(ev.id or "")) .. ", now " .. ev.to
  elseif ty == "visit_end" then
    if not t or t.kind == "other" or t.cls == "trusted" then return nil end
    ch, color, title = "log", A.COLOR.blue, "VISIT ENDED: " .. name(t)
    lines = { "From " .. at(ev.start, ctx) .. " to " .. at(ev.stop, ctx) .. " (" .. D.format(ev.stop - ev.start) .. ")",
      "List: " .. tostring(t.cls),
      ev.closest and ("Closest: " .. math.floor(ev.closest + 0.5) .. " blocks") or nil,
      ev.enteredZone and "Was in the no-go zone" or nil,
      ev.visits and ("Visits so far: " .. ev.visits) or nil }
    game = "VISIT ENDED " .. name(t) .. ", " .. D.format(ev.stop - ev.start)
  elseif ty == "takeover" then
    ch, color, title = "log", A.COLOR.blue, "SHIP REASSEMBLED"
    lines = { shipName(ev.to, ev.label) .. " took over the list **" .. tostring(ev.list) .. "** of " .. shipName(ev.from) }
    game = "SHIP " .. tracker.short(ev.to) .. " took over " .. tostring(ev.list) .. " from " .. tracker.short(ev.from)
  elseif ty == "takeover_revoked" then
    ch, color, title = "log", A.COLOR.gray, "TAKEOVER UNDONE"
    lines = { shipName(ev.from, ev.label) .. " is back; " .. shipName(ev.to) .. " is unknown again." }
    game = "TAKEOVER UNDONE " .. tracker.short(ev.from)
  elseif ty == "takeover_ambiguous" then
    ch, color, title = "alerts", A.COLOR.orange, "SHIP UNCLEAR"
    lines = { "New ship `" .. tracker.short(ev.id) .. "` appeared next to " .. shipName(ev.near, ev.label)
      .. ", but more than one ship could be the reassembled one.", "No takeover; list it by hand." }
    game = "SHIP UNCLEAR " .. tracker.short(ev.id)
  elseif ty == "list_change" then
    if ev.list == "visitor" and ev.expires then
      ch, color, title = "log", A.COLOR.green, "VISITOR: " .. tostring(ev.who)
      lines = { "Visitor until " .. at(ev.expires, ctx) .. ", ends " .. C.discord(ev.expires, "R") }
    else
      ch, color, title = "log", A.COLOR.gray, "LISTS"
      lines = { ev.text }
    end
    game = ev.text
  elseif ty == "reference" then
    ch, color, title = "log", A.COLOR.blue, ev.title
    lines = { ev.text }
    game = nil
  elseif ty == "online" then
    ch, color, title = "log", A.COLOR.green, "RADAR ONLINE"
    lines = { ev.text }
    game = ev.text
  else
    return nil
  end

  local desc = {}
  for i = 1, 10 do
    if lines[i] then desc[#desc + 1] = lines[i] end
  end
  local embed = {
    title = title:sub(1, 256),
    description = table.concat(desc, "\n"):sub(1, 4000),
    color = color,
    timestamp = C.iso(now),
    footer = { text = base },
  }
  return ch, embed, game
end

local function size(e)
  return #e.title + #e.description + #(e.footer and e.footer.text or "")
end

function A.queue()
  return { alerts = {}, log = {} }
end

-- Returns channel, gameText (nil, nil if not reported)
function A.push(q, ev, ctx)
  local ch, embed, game = A.format(ev, ctx)
  if ch then q[ch][#q[ch] + 1] = embed end
  return ch, game
end

-- Returns { {channel, payload}, ... } and empties the queue.
-- A payload holds up to 10 embeds and stays under the size limit.
function A.drain(q)
  local out = {}
  for _, ch in ipairs({ "alerts", "log" }) do
    local cur, chars = {}, 0
    for _, e in ipairs(q[ch]) do
      if #cur > 0 and (#cur >= A.MAX_EMBEDS or chars + size(e) > A.MAX_CHARS) then
        out[#out + 1] = { ch, { embeds = cur } }
        cur, chars = {}, 0
      end
      cur[#cur + 1] = e
      chars = chars + size(e)
    end
    if #cur > 0 then out[#out + 1] = { ch, { embeds = cur } } end
    q[ch] = {}
  end
  return out
end

return A
