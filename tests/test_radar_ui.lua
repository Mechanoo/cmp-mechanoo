-- Interactive mode: the prompt runs next to the service; typed commands change the lists.
local t = require("tests.t")
fs.delete("/void-data")
local function writeAll(path, s) local h = fs.open(path, "w"); h.write(s); h.close() end
writeAll("/void-data/radar.json", textutils.serialiseJSON({ intervalS = 0.05 }))
writeAll("/void-data/lists.json", textutils.serialiseJSON({ players = { me = { name = "Me", list = "trusted" } }, ships = {} }))

peripheral = {
  getNames = function() return { "r0" } end,
  getType = function() return "create_radar:plane_radar" end,
  getMethods = function() return { "getTracks", "getPosition", "getRange" } end,
  call = function(n, m)
    if m == "getPosition" then return { x = 0, y = 64, z = 0 } end
    if m == "getTracks" then return { { id = "abc12345", category = "SABLE", position = { x = 5, y = 70, z = 5 }, velocity = { x = 0, y = 0, z = 0 } } } end
  end,
}
local script = { "help", "hostile Steve", "visitor Ann 2h", "ship abc trust", "label abc Flagship", "targets", "zone" }
local i = 0
read = function()
  sleep(0.1) -- let the service run a cycle between commands
  i = i + 1
  if script[i] then return script[i] end
  error("end of script", 0)
end

local fn = assert(loadfile("/work/apps/radar/main.lua", "t", _ENV))
local ok, err = pcall(fn)
term.redirect(term.native())
t.eq(err, "end of script", "ran until the script ended: " .. tostring(err))
local h = fs.open("/void-data/lists.json", "r")
local saved = textutils.unserialiseJSON(h.readAll())
h.close()
t.eq(saved.players.steve and saved.players.steve.list, "hostile", "typed hostile saved")
t.eq(saved.players.ann and saved.players.ann.list, "visitor", "typed visitor saved")
t.eq(saved.ships.abc12345 and saved.ships.abc12345.list, "trusted", "ship trusted by prefix")
t.eq(saved.ships.abc12345 and saved.ships.abc12345.label, "Flagship", "ship label saved")
fs.delete("/void-data")
t.finish("radar ui")
