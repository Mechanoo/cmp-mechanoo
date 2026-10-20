-- Target table: merges the tracks of several radars and the player detector.
--
-- * Players are identified by UUID (radar id == detector uuid, measured in game).
-- * Radars only report a target in some samples, so a target is kept for
--   holdMs after its last sighting.
-- * Velocities are in blocks per tick (that is what the radar reports).
-- * A ship gets a new id when it is disassembled and assembled again. A new ship
--   that appears close to where a listed ship vanished takes over its entry
--   ("takeover"); if the old ship shows up again the takeover is undone.
-- * Ragdolls (Sable Ragdolls mod): a player or mob knocked into a ragdoll becomes
--   one Sable sub-level per body part, so the radars see a burst of brand-new
--   SABLE tracks (six for a player) within a few blocks, for about 1.5 s. A
--   cluster of at least ragdollParts new, unlisted ships within ragdollDist of
--   each other is marked kind "ragdoll": no alerts, no visits, not in T.all.
local V = require("lib.vec")
local lists = require("lib.lists")

local T = {}

T.DEFAULTS = {
  holdMs = 10000,
  takeoverWindowMs = 60000,
  takeoverDist = 16,
  ragdollParts = 3,      -- new ships in one cluster that make it a ragdoll
  ragdollDist = 3,       -- blocks between neighbouring parts of one cluster
  ragdollWindowMs = 3000, -- a ship counts as new for this long after its first sighting
}

function T.new(cfg)
  local c = {}
  for k, v in pairs(T.DEFAULTS) do c[k] = v end
  for k, v in pairs(cfg or {}) do c[k] = v end
  return { cfg = c, targets = {}, names = {} }
end

function T.kindOf(category)
  if category == "PLAYER" then return "player" end
  if category == "SABLE" then return "ship" end
  return "other"
end

function T.short(id)
  return tostring(id):sub(1, 8)
end

local function touch(tr, id, now, events, kind)
  local t = tr.targets[id]
  if not t then
    t = { id = id, kind = kind, firstSeen = now }
    tr.targets[id] = t
    events[#events + 1] = { type = "new", id = id, kind = kind }
  end
  return t
end

local function takeover(tr, ls, now, newShips, seen, events)
  local cfg = tr.cfg
  for _, n in ipairs(newShips) do
    if not ls.ships[n.id] then
      local cands = {}
      for id, e in pairs(ls.ships) do
        if id ~= n.id and not seen[id] and not e.replacedBy and e.lastPos and e.lastSeen
            and now - e.lastSeen <= cfg.takeoverWindowMs
            and V.dist3d(e.lastPos, n.pos) <= cfg.takeoverDist then
          cands[#cands + 1] = e
        end
      end
      if #cands >= 1 then
        local others = 0
        for _, m in ipairs(newShips) do
          if m.id ~= n.id and not ls.ships[m.id] and V.dist3d(cands[1].lastPos, m.pos) <= cfg.takeoverDist then
            others = others + 1
          end
        end
        if #cands == 1 and others == 0 then
          local old = cands[1]
          ls.ships[n.id] = {
            id = n.id, list = old.list, prev = old.prev, expires = old.expires, label = old.label,
            takenFrom = old.id, lastPos = V.copy(n.pos), lastSeen = now,
          }
          old.replacedBy = n.id
          old.replacedAt = now
          ls.dirty = true
          events[#events + 1] = { type = "takeover", from = old.id, to = n.id, list = old.list, label = old.label }
        else
          events[#events + 1] = { type = "takeover_ambiguous", id = n.id, near = cands[1].id, label = cands[1].label }
        end
      end
    end
  end
end

-- Marks ragdoll clusters among the ships seen in this update. Candidates are young
-- unlisted ships and parts already known as ragdoll (a part a radar missed in the
-- first sample joins its cluster later). Returns the ids of the newly marked parts.
local function findRagdolls(tr, ls, now, seenIds, events)
  local cfg = tr.cfg
  local cand = {}
  for _, id in ipairs(seenIds) do
    local t = tr.targets[id]
    if t.kind == "ragdoll" or (t.kind == "ship" and not ls.ships[id] and now - t.firstSeen <= cfg.ragdollWindowMs) then
      cand[#cand + 1] = t
    end
  end
  local done, marked = {}, {}
  for i = 1, #cand do
    if not done[i] then
      local cluster, queue = {}, { i }
      done[i] = true
      while #queue > 0 do
        local j = table.remove(queue)
        cluster[#cluster + 1] = cand[j]
        for k = 1, #cand do
          if not done[k] and V.dist3d(cand[j].pos, cand[k].pos) <= cfg.ragdollDist then
            done[k] = true
            queue[#queue + 1] = k
          end
        end
      end
      local known = false
      for _, t in ipairs(cluster) do if t.kind == "ragdoll" then known = true end end
      if known or #cluster >= cfg.ragdollParts then
        local fresh = {}
        for _, t in ipairs(cluster) do
          if t.kind ~= "ragdoll" then
            t.kind = "ragdoll"
            fresh[#fresh + 1] = t.id
            marked[t.id] = true
          end
        end
        if #fresh > 0 and not known then
          events[#events + 1] = { type = "ragdoll", ids = fresh, parts = #cluster, pos = V.copy(cluster[1].pos) }
        end
      end
    end
  end
  return marked
end

local function settleTakeovers(tr, ls, now, seen, events)
  for id, e in pairs(ls.ships) do
    if e.replacedBy then
      if seen[id] and now - e.replacedAt <= tr.cfg.takeoverWindowMs then
        local n = ls.ships[e.replacedBy]
        if n and n.takenFrom == id then ls.ships[e.replacedBy] = nil end
        events[#events + 1] = { type = "takeover_revoked", from = id, to = e.replacedBy, label = e.label }
        e.replacedBy, e.replacedAt = nil, nil
        ls.dirty = true
      elseif now - e.replacedAt > tr.cfg.takeoverWindowMs then
        local n = ls.ships[e.replacedBy]
        if n then n.takenFrom = nil end
        ls.ships[id] = nil
        ls.dirty = true
      end
    end
  end
end

-- tracks: radar tracks (all radars together, duplicates allowed)
-- players: { name, uuid, x, y, z } from the player detector
-- Returns a list of events.
function T.update(tr, now, tracks, players, ls)
  local events, seen, newShips = {}, {}, {}

  for _, tk in ipairs(tracks or {}) do
    local id = tostring(tk.id)
    if not seen[id] and type(tk.position) == "table" then
      local kind = T.kindOf(tk.category)
      local isNew = tr.targets[id] == nil
      local t = touch(tr, id, now, events, kind)
      if t.kind == "ragdoll" then kind = "ragdoll" end -- stays a ragdoll part until it is gone
      t.kind, t.category, t.entityType = kind, tk.category, tk.entityType
      t.pos = V.copy(tk.position)
      t.vel = V.copy(tk.velocity) or { x = 0, y = 0, z = 0 }
      t.posT, t.lastSeen, t.velFromRadar = now, now, true
      if kind == "player" and tr.names[id] then t.name = tr.names[id] end
      if isNew and kind == "ship" then newShips[#newShips + 1] = t end
      seen[id] = true
    end
  end

  for _, p in ipairs(players or {}) do
    local id = p.uuid and tostring(p.uuid) or ("name:" .. string.lower(p.name))
    local t = touch(tr, id, now, events, "player")
    local pos = { x = p.x, y = p.y, z = p.z }
    if not seen[id] then
      if t.pos and t.posT and now > t.posT then
        local ticks = (now - t.posT) / 50
        t.vel = { x = (pos.x - t.pos.x) / ticks, y = (pos.y - t.pos.y) / ticks, z = (pos.z - t.pos.z) / ticks }
      else
        t.vel = t.vel or { x = 0, y = 0, z = 0 }
      end
      t.velFromRadar = false
    end
    t.kind, t.category = "player", "PLAYER"
    t.pos, t.posT, t.lastSeen = pos, now, now
    t.name = p.name
    if p.uuid then
      tr.names[id] = p.name
      lists.notePlayer(ls, p.name, id)
    end
    seen[id] = true
  end

  for id in pairs(seen) do
    local t = tr.targets[id]
    t.sightings = (t.sightings or 0) + 1 -- updates in which the target was really seen
  end

  local seenIds = {}
  for id in pairs(seen) do seenIds[#seenIds + 1] = id end
  table.sort(seenIds) -- stable cluster order
  local ragdolls = findRagdolls(tr, ls, now, seenIds, events)
  if next(ragdolls) then
    local keep = {}
    for _, n in ipairs(newShips) do if not ragdolls[n.id] then keep[#keep + 1] = n end end
    newShips = keep
  end

  for id in pairs(seen) do
    local e = ls.ships[id]
    local t = tr.targets[id]
    if e and t.kind == "ship" then
      e.lastPos, e.lastSeen = V.copy(t.pos), now
      ls.touched = true
    end
  end

  settleTakeovers(tr, ls, now, seen, events)
  takeover(tr, ls, now, newShips, seen, events)

  for id, t in pairs(tr.targets) do
    if now - t.lastSeen > tr.cfg.holdMs then
      tr.targets[id] = nil
      events[#events + 1] = { type = "lost", id = id, kind = t.kind, name = t.name }
    end
  end
  return events
end

-- Which list a target is on: trusted / visitor / hostile / unknown, or "other"
-- for things that are neither players nor ships (shells, ...).
function T.classify(t, ls)
  if t.kind == "player" then
    return lists.effective(lists.player(ls, t.name, t.id))
  elseif t.kind == "ship" then
    return lists.effective(ls.ships[t.id])
  end
  return "other"
end

-- All targets as an array, sorted by id (stable output). Ragdoll parts are left out.
function T.all(tr)
  local out = {}
  for _, t in pairs(tr.targets) do
    if t.kind ~= "ragdoll" then out[#out + 1] = t end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

return T
