-- Speaker priority between the radar siren and the music player.
-- They run in separate tabs, so they share a small file: the radar renews
-- the claim every second while the siren sounds, the player waits while the
-- claim is valid. A claim expires by itself (radar crash, tab closed).
local store = require("lib.store")

local L = {}

L.FILE = "audio.lock"
L.TTL_MS = 3000

local function now() return os.epoch("utc") end

-- The siren is (still) sounding: valid for `ms` (default TTL_MS) from now.
function L.claim(ms)
  store.writeText(L.FILE, tostring(now() + (ms or L.TTL_MS)))
end

function L.release()
  local p = fs.combine(store.DIR, L.FILE)
  if fs.exists(p) then fs.delete(p) end
end

function L.held()
  local s = store.readText(L.FILE)
  local untilMs = s and tonumber(s)
  return untilMs ~= nil and now() < untilMs
end

return L
