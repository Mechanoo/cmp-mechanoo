-- Small vector helpers for {x, y, z} tables.
local V = {}

function V.copy(p)
  if type(p) ~= "table" then return nil end
  return { x = p.x or 0, y = p.y or 0, z = p.z or 0 }
end

function V.dist2d(a, b)
  local dx, dz = a.x - b.x, a.z - b.z
  return math.sqrt(dx * dx + dz * dz)
end

function V.dist3d(a, b)
  local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function V.round(p)
  return ("%d, %d, %d"):format(math.floor(p.x + 0.5), math.floor(p.y + 0.5), math.floor(p.z + 0.5))
end

return V
