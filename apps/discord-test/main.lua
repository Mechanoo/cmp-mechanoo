-- discord-test: stores your Discord webhook URLs locally and sends a test message.
--   void discord-test          send a test (asks for URLs on first run)
--   void discord-test set      enter the URLs again
package.path = "/void/?.lua;" .. package.path
local discord = require("lib.discord")

local args = { ... }
local cfg = discord.config()

local function ask(label, key)
  while true do
    write(label .. " webhook URL (empty = skip): ")
    local v = read()
    if v == "" then return end
    if discord.validUrl(v) then
      cfg[key] = v
      return
    end
    print("That does not look like a Discord webhook URL.")
  end
end

if args[1] == "set" or not (cfg.alerts or cfg.log) then
  print("The URLs are stored only on this computer in /void-data/discord.json.")
  ask("Alerts", "alerts")
  ask("Log", "log")
  discord.saveConfig(cfg)
end

local label = os.getComputerLabel() or ("computer " .. os.getComputerID())
for _, channel in ipairs({ "alerts", "log" }) do
  if cfg[channel] then
    write("Sending test to " .. channel .. " (" .. discord.mask(cfg[channel]) .. ") ... ")
    local ok, err = discord.send(channel, "Test from " .. label .. " in game. http.post works.")
    print(ok and "OK" or ("FAILED: " .. tostring(err)))
  end
end
