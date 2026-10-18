-- Pure logic of the probe program: collects radar tracks and player positions
-- over time and answers: are track ids stable, and does a radar track match a
-- player from the player detector?
local core = {}

core.MATCH_DIST = 5 -- blocks (horizontal) to count a radar track as "this player"

local function dist2d(a, b)
  local dx, dz = a.x - b.x, a.z - b.z
  return math.sqrt(dx * dx + dz * dz)
end

function core.new()
  return {
    samples = 0,
    tracks = {}, -- id -> record
    order = {},
    radars = {}, -- radar name -> counters
    players = {}, -- player name -> number of samples seen
    pairs = {}, -- player name -> matching info
    rawTrack = nil,
    rawPlayer = nil,
    cur = nil,
  }
end

function core.beginSample(s, t)
  s.samples = s.samples + 1
  s.cur = { t = t, tracks = {}, players = {} }
end

function core.addTracks(s, radarName, tracks)
  local r = s.radars[radarName]
  if not r then
    r = { name = radarName, samples = 0, total = 0, max = 0 }
    s.radars[radarName] = r
  end
  r.samples = r.samples + 1
  r.total = r.total + #tracks
  if #tracks > r.max then r.max = #tracks end

  for _, tr in ipairs(tracks) do
    local id = tostring(tr.id)
    if not s.rawTrack then s.rawTrack = tr end
    local rec = s.tracks[id]
    if not rec then
      rec = { id = id, n = 0, reappear = 0, radars = {}, firstIdx = s.samples, first = s.cur.t }
      s.tracks[id] = rec
      s.order[#s.order + 1] = id
    end
    if rec.lastIdx ~= s.samples then -- count once per sample, even if two radars see it
      if rec.lastIdx and s.samples - rec.lastIdx > 1 then rec.reappear = rec.reappear + 1 end
      rec.n = rec.n + 1
      rec.lastIdx = s.samples
    end
    rec.last = s.cur.t
    rec.radars[radarName] = true
    rec.pos = tr.position
    rec.vel = tr.velocity
    rec.category = tr.category or rec.category
    rec.entityType = tr.entityType or rec.entityType
    s.cur.tracks[#s.cur.tracks + 1] = tr
  end
end

-- players: list of { name, x, y, z }
function core.addPlayers(s, players)
  for _, p in ipairs(players) do
    s.players[p.name] = (s.players[p.name] or 0) + 1
    s.cur.players[#s.cur.players + 1] = p
    if not s.rawPlayer then s.rawPlayer = p end
  end
end

function core.endSample(s)
  for _, p in ipairs(s.cur.players) do
    local best, bd
    for _, tr in ipairs(s.cur.tracks) do
      if tr.position then
        local d = dist2d(p, tr.position)
        if not bd or d < bd then best, bd = tr, d end
      end
    end
    local pr = s.pairs[p.name]
    if not pr then
      pr = { name = p.name, samples = 0, matched = 0, ids = {} }
      s.pairs[p.name] = pr
    end
    pr.samples = pr.samples + 1
    if best then
      if not pr.minDist or bd < pr.minDist then pr.minDist = bd end
      if bd <= core.MATCH_DIST then
        pr.matched = pr.matched + 1
        local id = tostring(best.id)
        pr.ids[id] = (pr.ids[id] or 0) + 1
      end
    end
  end
  s.cur = nil
end

local function sortedKeys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

local function count(map, key)
  key = tostring(key or "?")
  map[key] = (map[key] or 0) + 1
end

-- Returns a list of text lines.
function core.summarize(s)
  local L = {}
  L[#L + 1] = "samples: " .. s.samples

  for _, name in ipairs(sortedKeys(s.radars)) do
    local r = s.radars[name]
    L[#L + 1] = ("radar %s: avg %.1f tracks, max %d"):format(name, r.total / math.max(r.samples, 1), r.max)
  end

  local once, again, cats, types = 0, 0, {}, {}
  for _, id in ipairs(s.order) do
    local rec = s.tracks[id]
    if rec.n == 1 then once = once + 1 end
    if rec.reappear > 0 then again = again + 1 end
    count(cats, rec.category)
    count(types, rec.entityType)
  end
  L[#L + 1] = ("track ids: %d unique, %d seen only once, %d came back after a gap"):format(#s.order, once, again)

  local parts = {}
  for _, k in ipairs(sortedKeys(cats)) do parts[#parts + 1] = k .. "=" .. cats[k] end
  L[#L + 1] = "categories: " .. (#parts > 0 and table.concat(parts, ", ") or "-")
  parts = {}
  for _, k in ipairs(sortedKeys(types)) do parts[#parts + 1] = k .. "=" .. types[k] end
  L[#L + 1] = "entityTypes: " .. (#parts > 0 and table.concat(parts, ", ") or "-")

  for _, name in ipairs(sortedKeys(s.players)) do
    local pr = s.pairs[name]
    local line = ("player %s: seen %d samples"):format(name, s.players[name])
    if pr then
      line = line .. (", radar match %d/%d"):format(pr.matched, pr.samples)
      if pr.minDist then line = line .. (", closest track %.1f blocks"):format(pr.minDist) end
      local ids = {}
      for _, id in ipairs(sortedKeys(pr.ids)) do ids[#ids + 1] = id .. " x" .. pr.ids[id] end
      if #ids > 0 then line = line .. ", ids: " .. table.concat(ids, " ") end
    end
    L[#L + 1] = line
    if pr and pr.matched >= 3 then
      local n = 0
      for _ in pairs(pr.ids) do n = n + 1 end
      L[#L + 1] = "  -> " .. (n == 1 and "id looks STABLE for this player" or "id CHANGED while matched (" .. n .. " different ids)")
    end
  end

  if s.rawTrack then L[#L + 1] = "raw track: " .. textutils.serialise(s.rawTrack, { compact = true }) end
  if s.rawPlayer then L[#L + 1] = "raw player: " .. textutils.serialise(s.rawPlayer, { compact = true }) end
  return L
end

return core
