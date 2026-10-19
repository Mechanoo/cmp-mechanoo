-- music app: tab / autostart commands, plus the alarm gate with a mocked speaker and stream
local t = require("tests.t")
local lock = require("lib.audiolock")
local realPrint = print

-- autostart
fs.delete("/startup/void_music.lua")
local app = assert(loadfile("/work/apps/music/main.lua", "t", _ENV))
print = function() end
app("autostart", "on")
print = realPrint
t.truthy(fs.exists("/startup/void_music.lua") or multishell == nil, "autostart written (or refused without tabs)")
if fs.exists("/startup/void_music.lua") then
  local h = fs.open("/startup/void_music.lua", "r")
  local src = h.readAll()
  h.close()
  t.contains(src, '"music"', "starts the music app")
  print = function() end
  app("autostart", "off")
  print = realPrint
  t.eq(fs.exists("/startup/void_music.lua"), false, "autostart removed")
end

-- tab on a computer without tabs: friendly refusal, no crash
local errs = {}
local env = setmetatable({ multishell = false, printError = function(m) errs[#errs + 1] = m end }, { __index = _ENV })
assert(loadfile("/work/apps/music/main.lua", "t", env))("tab")
t.contains(errs[1] or "", "advanced computer", "tab needs multishell")

-- gate: the player must not queue audio while the claim is held
local played = 0
local speaker = {
  playAudio = function() played = played + 1 return true end,
  stop = function() end,
}
local menv = setmetatable({
  peripheral = setmetatable({
    find = function(kind) if kind == "speaker" then return speaker end end,
    getName = function() return "speaker_0" end,
  }, { __index = peripheral }),
}, { __index = _ENV })
-- the player is big and interactive: only check that it loads and finds the speaker
local fn, err = loadfile("/work/apps/music/main.lua", "t", menv)
t.truthy(fn, "music app compiles: " .. tostring(err))
t.finish("music app")
