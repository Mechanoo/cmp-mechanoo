-- Turns events into Discord messages and batches them.
-- Channels: "alerts" (needs attention) and "log" (record). ASCII only, so the
-- JSON encoding in CC cannot garble anything.
local V = require("lib.vec")
local D = require("lib.duration")
local tracker = require("lib.tracker")

local A = {}

local function who(t)
  if not t then return "?" end
  if t.kind == "player" then return "player **" .. (t.name or tracker.short(t.id)) .. "**" end
  if t.kind == "ship" then return "ship `" .. tracker.short(t.id) .. "`" end
  return tostring(t.kind) .. " `" .. tracker.short(t.id) .. "`"
end

local function where(t)
  if not t or not t.pos then return "" end
  local s = " at (" .. V.round(t.pos) .. ")"
  if t.dist then s = s .. ", " .. math.floor(t.dist + 0.5) .. " blocks from base" end
  return s
end

local function shipName(id, label)
  return "ship `" .. tracker.short(id) .. "`" .. (label and (" '" .. label .. "'") or "")
end

-- Returns channel, text   or nil if the event is not reported.
function A.format(ev)
  local t = ev.target
  local ty = ev.type
  if ty == "detected" then
    return "alerts", "Unknown " .. who(t) .. " detected" .. where(t) .. "."
  elseif ty == "approach" then
    return "alerts", "Unknown " .. who(t) .. " is within " .. ev.ring .. " blocks of the base" .. where(t) .. "."
  elseif ty == "zone_enter" then
    return "alerts", "**NO-GO ZONE**: unknown " .. who(t) .. " entered" .. where(t)
      .. ". Engaging in " .. D.format(ev.countdownMs) .. " unless marked trusted or visitor."
  elseif ty == "zone_leave" then
    return "alerts", "Unknown " .. who(t) .. " left the no-go zone."
  elseif ty == "zone_cleared" then
    return "log", who(t) .. " is " .. tostring(t.cls) .. " now, countdown stopped."
  elseif ty == "engage" then
    return "alerts", "**ENGAGE** unknown " .. who(t) .. where(t) .. "."
  elseif ty == "hostile" then
    return "alerts", "**HOSTILE** " .. who(t) .. " detected" .. where(t) .. ". Engage."
  elseif ty == "visitor_expired" then
    local name = ev.target == "ship" and shipName(ev.id, ev.label) or ("player **" .. tostring(ev.name) .. "**")
    return "log", "Visitor time of " .. name .. " is over, back to " .. ev.to .. "."
  elseif ty == "takeover" then
    return "log", shipName(ev.to, ev.label) .. " took over the list '" .. tostring(ev.list)
      .. "' of " .. shipName(ev.from) .. " (reassembled)."
  elseif ty == "takeover_revoked" then
    return "log", shipName(ev.from, ev.label) .. " is back; " .. shipName(ev.to) .. " is unknown again."
  elseif ty == "takeover_ambiguous" then
    return "alerts", "New ship `" .. tracker.short(ev.id) .. "` appeared next to " .. shipName(ev.near, ev.label)
      .. ", but more than one ship could be the reassembled one. No takeover; list it by hand."
  elseif ty == "visit_end" then
    if not t or t.kind == "other" or t.cls == "trusted" then return nil end
    local start, stop = math.floor(ev.start / 1000), math.floor(ev.stop / 1000)
    local s = "Visit of " .. who(t) .. " (" .. tostring(t.cls) .. ") ended: <t:" .. start .. ":t> to <t:" .. stop
      .. ":t>, " .. D.format(ev.stop - ev.start)
    if ev.closest then s = s .. ", closest " .. math.floor(ev.closest + 0.5) .. " blocks" end
    if ev.enteredZone then s = s .. ", was in the no-go zone" end
    if ev.visits then s = s .. ". Visits so far: " .. ev.visits end
    return "log", s .. "."
  elseif ty == "list_change" then
    return "log", ev.text .. "."
  elseif ty == "online" then
    return "log", ev.text
  end
  return nil
end

-- Batching queue: one message per channel per flush, at most maxChars long.
function A.queue()
  return { alerts = {}, log = {} }
end

function A.push(q, ev)
  local ch, text = A.format(ev)
  if ch then q[ch][#q[ch] + 1] = text end
  return ch
end

-- Returns { {channel, text}, ... } and empties the queue.
function A.drain(q, maxChars)
  maxChars = maxChars or 1900
  local out = {}
  for _, ch in ipairs({ "alerts", "log" }) do
    local cur = ""
    for _, line in ipairs(q[ch]) do
      if #cur > 0 and #cur + #line + 1 > maxChars then
        out[#out + 1] = { ch, cur }
        cur = ""
      end
      cur = (#cur > 0) and (cur .. "\n" .. line) or line
    end
    if #cur > 0 then out[#out + 1] = { ch, cur } end
    q[ch] = {}
  end
  return out
end

return A
