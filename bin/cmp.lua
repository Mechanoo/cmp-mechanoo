-- cmp: launcher for the CMP programs.
--   cmp help | version | list | update | run <app> [args...] | <app> [args...]
package.path = "/cmp/?.lua;" .. package.path

local args = { ... }
local cmd = args[1]

local function apps()
  local out = {}
  if fs.exists("/cmp/apps") then
    for _, name in ipairs(fs.list("/cmp/apps")) do
      if fs.exists("/cmp/apps/" .. name .. "/main.lua") then out[#out + 1] = name end
    end
  end
  table.sort(out)
  return out
end

local function version()
  if not fs.exists("/cmp/version.json") then return nil end
  local h = fs.open("/cmp/version.json", "r")
  local v = textutils.unserialiseJSON(h.readAll())
  h.close()
  return v and v.version
end

local function runApp(name, rest)
  if not name:match("^[%w_%-]+$") then
    printError("Bad app name.")
    return
  end
  local path = "/cmp/apps/" .. name .. "/main.lua"
  if not fs.exists(path) then
    printError("Unknown app '" .. name .. "'. Try: cmp list")
    return
  end
  shell.run(path, table.unpack(rest))
end

if cmd == nil or cmd == "help" then
  print("cmp - Void tools")
  print("  cmp list           installed apps")
  print("  cmp <app> [args]   run an app")
  print("  cmp update         update everything")
  print("  cmp version        installed version")
elseif cmd == "version" then
  print(tostring(version() or "not installed"))
elseif cmd == "list" then
  for _, a in ipairs(apps()) do print(a) end
elseif cmd == "update" then
  local updater = require("lib.updater")
  local ok, msg = updater.run(nil, { force = args[2] == "force" })
  if not ok then printError("Update failed: " .. tostring(msg)) end
elseif cmd == "run" then
  runApp(args[2] or "", { table.unpack(args, 3) })
else
  runApp(cmd, { table.unpack(args, 2) })
end
