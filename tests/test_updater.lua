local t = require("tests.t")
local updater = require("lib.updater")

local BASE = "https://raw.githubusercontent.com/Mechanoo/cmp-mechanoo/main/"
local ROOT = "/cmp-test"
fs.delete(ROOT)

-- Mock http.get: serves files from the project folder (/work); `served` overrides.
local served = {}
local failing = {}
http = {
  get = function(url)
    local rel = url:sub(#BASE + 1):gsub("%?.*$", "")
    if failing[rel] then return nil, "boom" end
    local data = served[rel]
    if not data then
      local p = "/work/" .. rel
      if not fs.exists(p) then return nil, "Not Found" end
      local h = fs.open(p, "rb")
      data = h.readAll()
      h.close()
    end
    return { readAll = function() return data end, close = function() end, getResponseCode = function() return 200 end }
  end,
}

local opts = { root = ROOT, startup = false, noShell = true, print = function() end }

local ok, res = updater.run(BASE, opts)
t.eq(ok, true, "first install ok: " .. tostring(res))
t.eq(res, "updated", "first install updates")
t.truthy(fs.exists(ROOT .. "/lib/updater.lua"), "updater installed")
t.truthy(fs.exists(ROOT .. "/bin/cmp.lua"), "launcher installed")
t.truthy(fs.exists(ROOT .. "/apps/probe/main.lua"), "probe installed")
t.truthy(fs.exists(ROOT .. "/version.json"), "version written")

ok, res = updater.run(BASE, opts)
t.eq(res, "current", "second run: nothing to do")

-- a new manifest without probe: stale file is removed
local mf = textutils.unserialiseJSON(served["manifest.json"] or (function()
  local h = fs.open("/work/manifest.json", "r"); local s = h.readAll(); h.close(); return s
end)())
local files = {}
for _, f in ipairs(mf.files) do
  if f.path ~= "apps/probe/main.lua" then files[#files + 1] = f end
end
served["manifest.json"] = textutils.serialiseJSON({ version = "next", files = files })
ok, res = updater.run(BASE, opts)
t.eq(res, "updated", "new version installs")
t.eq(fs.exists(ROOT .. "/apps/probe/main.lua"), false, "stale file removed")
t.truthy(fs.exists(ROOT .. "/lib/store.lua"), "kept files stay")

-- size mismatch aborts BEFORE touching the disk
served["lib/store.lua"] = "-- tampered"
served["manifest.json"] = textutils.serialiseJSON({ version = "broken", files = files })
ok, res = updater.run(BASE, opts)
t.eq(ok, false, "size mismatch fails")
t.contains(res, "size mismatch", "message mentions size")
local h = fs.open(ROOT .. "/version.json", "r"); local v = textutils.unserialiseJSON(h.readAll()); h.close()
t.eq(v.version, "next", "version file unchanged after failed update")

-- network failure
served["lib/store.lua"] = nil
failing["lib/discord.lua"] = true
served["manifest.json"] = textutils.serialiseJSON({ version = "net", files = files })
ok, res = updater.run(BASE, opts)
t.eq(ok, false, "download failure fails")
failing["lib/discord.lua"] = nil

-- hostile manifest paths are rejected
for _, bad in ipairs({ "../evil.lua", "/startup.lua", "a/../../b.lua", "x y.lua" }) do
  served["manifest.json"] = textutils.serialiseJSON({ version = "evil", files = { { path = bad, size = 1 } } })
  ok, res = updater.run(BASE, opts)
  t.eq(ok, false, "unsafe path rejected: " .. bad)
end

fs.delete(ROOT)
t.finish("updater")
