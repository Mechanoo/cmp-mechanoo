-- Installer for the CMP programs by Mechanoo.
-- In game, on a computer with HTTP enabled:
--   wget run https://raw.githubusercontent.com/Mechanoo/cmp-mechanoo/main/install.lua
local BASE = "https://raw.githubusercontent.com/Mechanoo/cmp-mechanoo/main/"

if not http then
  printError("The http API is disabled on this computer.")
  return
end

local h, err = http.get(BASE .. "lib/updater.lua?cb=" .. os.epoch("utc"), nil, true)
if not h then
  printError("Could not download the updater: " .. tostring(err))
  return
end
local src = h.readAll()
h.close()

local fn, lerr = load(src, "=updater", "t", _ENV)
if not fn then
  printError("Updater is broken: " .. tostring(lerr))
  return
end

local ok, msg = fn().run(BASE, { force = true })
if not ok then
  printError("Install failed: " .. tostring(msg))
  return
end
print("Done. Type 'cmp help' (or reboot once if the command is not found).")
