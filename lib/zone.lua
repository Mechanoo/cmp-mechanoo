-- The no-go zone: a square of whole chunks around the base, all heights.
local Z = {}

-- Builds a zone of `chunks` x `chunks` chunks around block x/z.
-- Even sizes are centred on the nearest chunk border, odd sizes on the chunk x/z is in.
function Z.fromCenter(x, z, chunks)
  chunks = chunks or 10
  local function axis(v)
    local first
    if chunks % 2 == 0 then
      first = math.floor(v / 16 + 0.5) - chunks / 2
    else
      first = math.floor(v / 16) - (chunks - 1) / 2
    end
    return first * 16, (first + chunks) * 16
  end
  local x1, x2 = axis(x)
  local z1, z2 = axis(z)
  return { x1 = x1, z1 = z1, x2 = x2, z2 = z2, chunks = chunks }
end

-- Inside means x1 <= x < x2 and z1 <= z < z2 (block coordinates of whole chunks).
function Z.contains(zone, p)
  if not zone or not p then return false end
  return p.x >= zone.x1 and p.x < zone.x2 and p.z >= zone.z1 and p.z < zone.z2
end

function Z.center(zone)
  return { x = (zone.x1 + zone.x2) / 2, y = 0, z = (zone.z1 + zone.z2) / 2 }
end

-- Horizontal distance from the zone centre.
function Z.distance(zone, p)
  local c = Z.center(zone)
  local dx, dz = p.x - c.x, p.z - c.z
  return math.sqrt(dx * dx + dz * dz)
end

function Z.describe(zone)
  if not zone then return "not set" end
  return ("%dx%d chunks, x %d..%d, z %d..%d"):format(zone.chunks or 0, zone.chunks or 0,
    zone.x1, zone.x2 - 1, zone.z1, zone.z2 - 1)
end

return Z
