-- Decides what to do about every target and keeps track of visits.
--
--   trusted / visitor  -> "friendly"
--   hostile            -> "engage" as soon as it is seen, anywhere
--   unknown, outside   -> "watch"   (alerts when a visit starts and when it crosses a ring)
--   unknown, in zone   -> "warn" for countdownMs, then "engage"
--   other (shells ...) -> "ignore"
--
-- Escort rule: an unknown ship with a trusted or visitor player within
-- escortDist is treated as friendly (a friend flying an unlisted ship).
--
-- Confirmation: radars can report short-lived objects (ragdoll parts are filtered
-- by the tracker; this catches anything else seen only once). An unknown target
-- that the detector does not know by name must be seen in confirmSightings
-- updates before it causes alerts, a countdown or a visit record ("pending").
--
-- Visits: a visit starts when a player or ship shows up and ends when it has
-- been gone for visitGapMs. Shorter gaps (radar flicker, edge of range) belong
-- to the same visit. Every visit is announced; its end is reported with a
-- summary ("visit_end").
local V = require("lib.vec")
local Z = require("lib.zone")
local tracker = require("lib.tracker")

local P = {}

P.DEFAULTS = {
  countdownMs = 10000,
  rings = { 256, 128 },
  escortDist = 8,
  visitGapMs = 60000,
  confirmSightings = 2,
}

function P.new(cfg)
  local c = {}
  for k, v in pairs(P.DEFAULTS) do c[k] = v end
  for k, v in pairs(cfg or {}) do c[k] = v end
  local rings = {}
  for i, r in ipairs(c.rings) do rings[i] = r end
  table.sort(rings, function(a, b) return a > b end)
  c.rings = rings
  return { cfg = c, per = {} }
end

-- The tracker lost a target. The zone countdown stops; the visit stays open
-- for visitGapMs in case the target comes back.
function P.lost(ps, id, now)
  local st = ps.per[id]
  if st then
    st.lostAt = now
    st.zoneSince, st.engaged = nil, false
  end
end

local function snapshot(t, cls, zone, ls)
  local e = t.kind == "ship" and ls and ls.ships[t.id] or nil
  return {
    id = t.id, kind = t.kind, name = t.name, cls = cls, label = e and e.label or nil,
    pos = V.copy(t.pos), dist = zone and Z.distance(zone, t.pos) or nil,
  }
end

P.LEVELS = { "CLEAR", "WATCH", "ELEVATED", "HIGH", "ENGAGE" }

-- Overall base level from the decisions of one update:
-- 5 ENGAGE (something is engaged), 4 HIGH (countdown running), 3 ELEVATED
-- (unknown within the inner ring), 2 WATCH (unknown in range), 1 CLEAR.
function P.level(ps, decisions, targets, zone)
  local n = 1
  local inner = ps.cfg.rings[#ps.cfg.rings]
  for _, t in ipairs(targets) do
    local d = decisions[t.id]
    local l = 1
    if d then
      if d.action == "engage" then l = 5
      elseif d.action == "warn" then l = 4
      elseif d.action == "watch" then
        l = (zone and inner and Z.distance(zone, t.pos) <= inner) and 3 or 2
      end
    end
    if l > n then n = l end
  end
  return { n = n, label = P.LEVELS[n] }
end

local function confirmed(t, cls, cfg)
  if cls ~= "unknown" then return true end          -- listed targets are known
  if t.kind == "player" and t.name then return true end -- the detector knows the name
  return t.sightings == nil or t.sightings >= cfg.confirmSightings
end

local function visitEnd(id, st)
  return {
    type = "visit_end",
    target = { id = id, kind = st.kind, name = st.name, cls = st.cls },
    start = st.visitStart, stop = st.lastSeenAt, closest = st.closest, enteredZone = st.enteredZone,
  }
end

-- Ends every open visit (for example when the service stops).
function P.closeAll(ps)
  local events = {}
  for id, st in pairs(ps.per) do
    if st.kind ~= "other" and st.confirmed then events[#events + 1] = visitEnd(id, st) end
  end
  ps.per = {}
  return events
end

-- targets: tracker targets; ls: lists; zone may be nil.
-- Returns decisions (id -> { action, cls, remainingMs }) and events.
function P.update(ps, now, targets, ls, zone)
  local cfg = ps.cfg
  local decisions, events = {}, {}

  for id, st in pairs(ps.per) do
    if st.lostAt and now - st.lostAt > cfg.visitGapMs then
      if st.kind ~= "other" and st.confirmed then events[#events + 1] = visitEnd(id, st) end
      ps.per[id] = nil
    elseif st.lostAt and not st.confirmed then
      ps.per[id] = nil -- a ghost: forget it at once
    end
  end

  local friends = {}
  local classes = {}
  for _, t in ipairs(targets) do
    local cls = tracker.classify(t, ls)
    classes[t.id] = cls
    if t.kind == "player" and (cls == "trusted" or cls == "visitor") then friends[#friends + 1] = t end
  end

  for _, t in ipairs(targets) do
    local cls = classes[t.id]
    local st = ps.per[t.id]
    if not st then
      st = { rings = {}, visitStart = now, enteredZone = false }
      ps.per[t.id] = st
    end
    local inside = Z.contains(zone, t.pos)
    local dist = zone and Z.distance(zone, t.pos) or nil
    st.lostAt = nil
    st.lastSeenAt = t.lastSeen or now -- the real last sighting, not the hold time of the tracker
    st.kind, st.cls = t.kind, cls
    st.name = t.name or st.name
    if dist and (not st.closest or dist < st.closest) then st.closest = dist end
    if inside then st.enteredZone = true end

    local escorted = false
    if t.kind == "ship" and cls == "unknown" then
      for _, f in ipairs(friends) do
        if V.dist3d(f.pos, t.pos) <= cfg.escortDist then escorted = true break end
      end
    end

    local function emit(type, extra)
      local ev = { type = type, target = snapshot(t, cls, zone, ls) }
      for k, v in pairs(extra or {}) do ev[k] = v end
      events[#events + 1] = ev
    end

    if cls ~= "other" and not st.confirmed then st.confirmed = confirmed(t, cls, cfg) end

    if cls == "other" then
      decisions[t.id] = { action = "ignore", cls = cls }
    elseif not st.confirmed then
      decisions[t.id] = { action = "pending", cls = cls }
    elseif cls == "trusted" or cls == "visitor" or escorted then
      if st.zoneSince then emit("zone_cleared") end
      st.zoneSince, st.engaged, st.hostileSeen = nil, false, false
      decisions[t.id] = { action = "friendly", cls = cls, escorted = escorted or nil }
    elseif cls == "hostile" then
      if not st.hostileSeen then
        emit("hostile")
        st.hostileSeen = true
      end
      decisions[t.id] = { action = "engage", cls = cls }
    else -- unknown
      st.hostileSeen = false
      if not st.detected then
        emit("detected")
        st.detected = true
      end
      if dist then
        -- rings are only announced outside the zone; inside, the zone alert says enough
        for _, r in ipairs(cfg.rings) do
          if dist <= r and not st.rings[r] then
            st.rings[r] = true
            if not inside then emit("approach", { ring = r }) end
          end
        end
      end
      if inside then
        if not st.zoneSince then
          st.zoneSince = now
          emit("zone_enter", { countdownMs = cfg.countdownMs })
        end
        local left = cfg.countdownMs - (now - st.zoneSince)
        if left <= 0 then
          if not st.engaged then
            st.engaged = true
            emit("engage")
          end
          decisions[t.id] = { action = "engage", cls = cls }
        else
          decisions[t.id] = { action = "warn", cls = cls, remainingMs = left }
        end
      else
        if st.zoneSince then emit("zone_leave") end
        st.zoneSince, st.engaged = nil, false
        decisions[t.id] = { action = "watch", cls = cls }
      end
    end
  end
  return decisions, events
end

return P
