-- autostart file: runs the radar in a tab when multishell exists, directly otherwise
local t = require("tests.t")

fs.delete("/startup/void_radar.lua")
local app = assert(loadfile("/work/apps/radar/main.lua", "t", _ENV))
local realPrint = print
print = function() end
app("autostart", "on")
print = realPrint
t.truthy(fs.exists("/startup/void_radar.lua"), "autostart file written")
local code = fs.open("/startup/void_radar.lua", "r")
local src = code.readAll()
code.close()

-- with multishell: one tab, titled radar
local opened, titled, ran = {}, {}, {}
local env = setmetatable({
  multishell = { setTitle = function(id, s) titled[id] = s end },
  shell = {
    openTab = function(...) opened[#opened + 1] = table.concat({ ... }, " ") return 2 end,
    run = function(...) ran[#ran + 1] = table.concat({ ... }, " ") end,
  },
}, { __index = _G })
assert(load(src, "=autostart", "t", env))()
t.eq(opened[1], "/void/bin/void.lua radar", "opened in a tab")
t.eq(titled[2], "radar", "tab title")
t.eq(#ran, 0, "not run in the foreground")

-- without multishell: run directly
opened, ran = {}, {}
local env2 = setmetatable({
  multishell = false,
  shell = { run = function(...) ran[#ran + 1] = table.concat({ ... }, " ") end },
}, { __index = _G })
assert(load(src, "=autostart", "t", env2))()
t.eq(ran[1], "/void/bin/void.lua radar", "run directly on a normal computer")

print = function() end
app("autostart", "off")
print = realPrint
t.eq(fs.exists("/startup/void_radar.lua"), false, "autostart removed")
t.finish("autostart")
