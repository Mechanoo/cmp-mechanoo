-- Small JSON/text storage under /void-data.
-- /void-data is separate from /void, so updates never overwrite user data or secrets.
local store = {}

store.DIR = "/void-data"

local function path(name)
  return fs.combine(store.DIR, name)
end

function store.readText(name, default)
  local p = path(name)
  if not fs.exists(p) or fs.isDir(p) then return default end
  local h = fs.open(p, "r")
  if not h then return default end
  local s = h.readAll()
  h.close()
  return s
end

function store.writeText(name, text)
  local p = path(name)
  fs.makeDir(fs.getDir(p))
  local tmp = p .. ".tmp"
  local h, err = fs.open(tmp, "w")
  if not h then return false, err end
  h.write(text)
  h.close()
  if fs.exists(p) then fs.delete(p) end
  fs.move(tmp, p)
  return true
end

function store.readJson(name, default)
  local s = store.readText(name)
  if not s then return default end
  local v = textutils.unserialiseJSON(s)
  if v == nil then return default end
  return v
end

function store.writeJson(name, value)
  return store.writeText(name, textutils.serialiseJSON(value))
end

return store
