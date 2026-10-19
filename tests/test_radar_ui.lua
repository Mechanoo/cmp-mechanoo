-- Interactive mode: the prompt runs next to the service; typed commands change the lists.
local t = require("tests.t")
fs.delete("/void-data")
local function writeAll(path, s) local h = fs.open(path, "w"); h.write(s); h.close() end
writeAll("/void-data/radar.json", textutils.serialiseJSON({ intervalS = 0.05 }))
writeAll("/void-data/lists.json", textutils.serialiseJSON({ players = { me = { name = "Me", list = "trusted" } }, ships = {} }))

local gpuCalls, gpuUpdates, gpuRemoved = {}, 0, 0
peripheral = {
  getNames = function() return { "r0", "directgpu_0" } end,
  getType = function(n) return n == "directgpu_0" and "directgpu" or "create_radar:plane_radar" end,
  getMethods = function(n)
    if n == "directgpu_0" then return { "drawText", "fillRect", "updateDisplay" } end
    return { "getTracks", "getPosition", "getRange" }
  end,
  call = function(n, m, ...)
    if n == "directgpu_0" then
      gpuCalls[m] = (gpuCalls[m] or 0) + 1
      if m == "autoDetectAndCreateDisplay" then return 3 end
      if m == "getDisplayInfo" then return { pixelWidth = 512, pixelHeight = 320 } end
      if m == "updateDisplay" then gpuUpdates = gpuUpdates + 1 end
      if m == "removeDisplay" then gpuRemoved = gpuRemoved + 1 end
      if m == "hasEvents" then return false end
      return nil
    end
    if m == "getPosition" then return { x = 0, y = 64, z = 0 } end
    if m == "getTracks" then return { { id = "abc12345", category = "SABLE", position = { x = 5, y = 70, z = 5 }, velocity = { x = 0, y = 0, z = 0 } } } end
  end,
}
local script = { "help", "hostile Steve", "visitor Ann 2h", "ship abc trust", "label abc Flagship", "targets", "zone", "commands", "zone", "screen", "screen test", "exit" }
local i = 0
read = function()
  sleep(0.1) -- let the service run a cycle between commands
  i = i + 1
  if script[i] == "commands" then
    -- the full-screen list waits for keys: scroll down, up, then close with Q
    os.queueEvent("key", keys.space)
    os.queueEvent("key", keys.up)
    os.queueEvent("key", keys.q)
  end
  if script[i] then return script[i] end
  error("end of script", 0)
end

local fn = assert(loadfile("/work/apps/radar/main.lua", "t", _ENV))
local ok, err = pcall(fn)
term.redirect(term.native())
t.truthy(ok, "exit stops the radar cleanly (also after the full-screen command list): " .. tostring(err))
local h = fs.open("/void-data/lists.json", "r")
local saved = textutils.unserialiseJSON(h.readAll())
h.close()
t.eq(saved.players.steve and saved.players.steve.list, "hostile", "typed hostile saved")
t.eq(saved.players.ann and saved.players.ann.list, "visitor", "typed visitor saved")
t.eq(saved.ships.abc12345 and saved.ships.abc12345.list, "trusted", "ship trusted by prefix")
t.eq(saved.ships.abc12345 and saved.ships.abc12345.label, "Flagship", "ship label saved")
t.truthy((gpuCalls.autoDetectAndCreateDisplay or 0) >= 1, "radar attaches a DirectGPU display")
t.truthy(gpuUpdates >= 1, "radar draws frames on the DirectGPU display")
t.truthy((gpuCalls.drawText or 0) > 10, "frames contain text")
t.eq(gpuRemoved, 1, "display removed when the radar stops")
fs.delete("/void-data")
t.finish("radar ui")
