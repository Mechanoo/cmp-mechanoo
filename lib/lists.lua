-- Friend/foe lists for players and ships.
--
-- Players are keyed by lower-case name (that is what you type); the UUID is
-- remembered once the player detector has seen them, so a radar-only sighting
-- can still be matched. Ships are keyed by their radar id.
--
-- Lists: "trusted", "hostile", "visitor". No entry = "unknown".
-- A visitor entry remembers the list it came from (prev) and goes back to it
-- when it expires.
local lists = {}

lists.NAMES = { trusted = true, hostile = true, visitor = true }

function lists.new(data)
  data = data or {}
  return { players = data.players or {}, ships = data.ships or {}, dirty = false, touched = false }
end

function lists.data(ls)
  return { players = ls.players, ships = ls.ships }
end

local function key(name)
  return string.lower(name)
end

local function apply(e, list, now, durationMs)
  if list == "visitor" then
    if e.list ~= "visitor" then e.prev = e.list end -- nil when the player was unknown
    e.list = "visitor"
    e.expires = now + durationMs
  else
    e.list = list
    e.prev = nil
    e.expires = nil
  end
end

function lists.effective(e)
  return (e and e.list) or "unknown"
end

-- list = nil removes the entry. Returns true if something changed.
function lists.setPlayer(ls, name, list, now, durationMs)
  local k = key(name)
  if list == nil then
    local had = ls.players[k] ~= nil
    ls.players[k] = nil
    if had then ls.dirty = true end
    return had
  end
  local e = ls.players[k] or {}
  e.name = name
  apply(e, list, now, durationMs)
  ls.players[k] = e
  ls.dirty = true
  return true
end

function lists.player(ls, name, uuid)
  if name then
    local e = ls.players[key(name)]
    if e then return e end
  end
  if uuid then
    for _, e in pairs(ls.players) do
      if e.uuid == uuid then return e end
    end
  end
  return nil
end

-- Remember the UUID of a listed player.
function lists.notePlayer(ls, name, uuid)
  local e = ls.players[key(name)]
  if e and uuid and e.uuid ~= uuid then
    e.uuid = uuid
    ls.dirty = true
  end
end

-- info: { label, pos, seen }
function lists.setShip(ls, id, list, now, durationMs, info)
  if list == nil then
    local had = ls.ships[id] ~= nil
    ls.ships[id] = nil
    if had then ls.dirty = true end
    return had
  end
  local e = ls.ships[id] or { id = id }
  apply(e, list, now, durationMs)
  if info then
    if info.label then e.label = info.label end
    if info.pos then e.lastPos = info.pos end
    if info.seen then e.lastSeen = info.seen end
  end
  ls.ships[id] = e
  ls.dirty = true
  return true
end

function lists.ship(ls, id)
  return ls.ships[id]
end

-- Ends visitor time. Returns events.
function lists.expire(ls, now)
  local events = {}
  local function check(map, target)
    for k, e in pairs(map) do
      if e.list == "visitor" and e.expires and now >= e.expires then
        local to = e.prev
        if to then
          e.list, e.prev, e.expires = to, nil, nil
        else
          map[k] = nil
        end
        ls.dirty = true
        events[#events + 1] = {
          type = "visitor_expired", target = target,
          name = e.name, id = e.id, label = e.label, to = to or "unknown",
        }
      end
    end
  end
  check(ls.players, "player")
  check(ls.ships, "ship")
  return events
end

return lists
