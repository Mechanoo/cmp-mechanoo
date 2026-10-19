-- Installer/updater. Downloads manifest.json and every file listed in it into /void.
-- All files are downloaded and size-checked BEFORE anything on disk is touched.
local M = {}

M.BASE = "https://raw.githubusercontent.com/Mechanoo/cmp-mechanoo/main/"
M.ROOT = "/void"
M.STARTUP = "/startup/void.lua"
M.DATA = "/void-data"

-- First versions installed to /cmp with the "cmp" command and kept data in /cmp-data.
M.LEGACY = { root = "/cmp", data = "/cmp-data", startup = "/startup/cmp.lua" }

local STARTUP_CODE = [[
-- installed by void: adds the "void" command to the shell path
if not string.find(shell.path(), "/void/bin", 1, true) then
  shell.setPath(shell.path() .. ":/void/bin")
end
]]

function M.fetch(url)
  if not http then return nil, "the http API is disabled" end
  local h, err = http.get(url, nil, true)
  if not h then return nil, err or "request failed" end
  local code = h.getResponseCode and h.getResponseCode() or 200
  local body = h.readAll()
  h.close()
  if code ~= 200 then return nil, "http " .. tostring(code) end
  return body
end

function M.safePath(p)
  return type(p) == "string" and p ~= ""
      and not p:find("..", 1, true)
      and p:sub(1, 1) ~= "/"
      and p:match("^[%w_%-%./]+$") ~= nil
end

local function writeFile(path, data)
  fs.makeDir(fs.getDir(path))
  local h, err = fs.open(path, "wb")
  if not h then return false, err end
  h.write(data)
  h.close()
  return true
end

local function readJson(path)
  if not fs.exists(path) then return nil end
  local h = fs.open(path, "r")
  local s = h.readAll()
  h.close()
  return textutils.unserialiseJSON(s)
end

-- Moves data of the old /cmp install to the new place and removes the old install.
-- Only touches /cmp if it holds our version.json, and the old startup file only if we wrote it.
-- Returns a list of what was done.
function M.migrateLegacy(legacy, dataDir)
  legacy = legacy or M.LEGACY
  dataDir = dataDir or M.DATA
  local done = {}
  if fs.exists(legacy.data) and fs.isDir(legacy.data) then
    if not fs.exists(dataDir) then
      fs.move(legacy.data, dataDir)
      done[#done + 1] = "moved " .. legacy.data .. " to " .. dataDir
    else
      for _, name in ipairs(fs.list(legacy.data)) do
        local src, dst = fs.combine(legacy.data, name), fs.combine(dataDir, name)
        if not fs.exists(dst) then
          fs.move(src, dst)
          done[#done + 1] = "moved " .. src .. " to " .. dst
        end
      end
      if #fs.list(legacy.data) == 0 then fs.delete(legacy.data) end
    end
  end
  if fs.exists(fs.combine(legacy.root, "version.json")) then
    fs.delete(legacy.root)
    done[#done + 1] = "removed old install " .. legacy.root
  end
  if fs.exists(legacy.startup) then
    local h = fs.open(legacy.startup, "r")
    local text = h.readAll()
    h.close()
    if text:find("installed by cmp", 1, true) then
      fs.delete(legacy.startup)
      done[#done + 1] = "removed " .. legacy.startup
    end
  end
  return done
end

-- opts: root, startup (false = do not write), force, print
-- Returns true, "updated"|"current"  or  false, errorMessage
function M.run(base, opts)
  base = base or M.BASE
  opts = opts or {}
  local root = opts.root or M.ROOT
  local say = opts.print or print
  local cb = "?cb=" .. os.epoch("utc") -- try to dodge CDN caches

  local body, err = M.fetch(base .. "manifest.json" .. cb)
  if not body then return false, "manifest: " .. tostring(err) end
  local mf = textutils.unserialiseJSON(body)
  if type(mf) ~= "table" or type(mf.files) ~= "table" or not mf.version then
    return false, "manifest is invalid"
  end

  local old = readJson(fs.combine(root, "version.json"))
  if old and old.version == mf.version and not opts.force then
    say("Already up to date (" .. tostring(mf.version) .. ")")
    return true, "current"
  end

  local blobs = {}
  for i, f in ipairs(mf.files) do
    if not M.safePath(f.path) then return false, "unsafe path in manifest: " .. tostring(f.path) end
    local data, e = M.fetch(base .. f.path .. cb)
    if not data then return false, f.path .. ": " .. tostring(e) end
    if f.size and #data ~= f.size then
      return false, f.path .. ": size mismatch (got " .. #data .. ", expected " .. f.size .. ")"
    end
    blobs[i] = data
    say(("[%d/%d] %s"):format(i, #mf.files, f.path))
  end

  local paths, keep = {}, {}
  for i, f in ipairs(mf.files) do
    local ok, e = writeFile(fs.combine(root, f.path), blobs[i])
    if not ok then return false, f.path .. ": " .. tostring(e) end
    paths[#paths + 1] = f.path
    keep[f.path] = true
  end

  if old and type(old.files) == "table" then
    for _, p in ipairs(old.files) do
      if not keep[p] and M.safePath(p) then fs.delete(fs.combine(root, p)) end
    end
  end

  local vh = fs.open(fs.combine(root, "version.json"), "w")
  vh.write(textutils.serialiseJSON({ version = mf.version, files = paths }))
  vh.close()

  local startup = opts.startup
  if startup == nil then startup = M.STARTUP end
  if startup then
    local cur
    if fs.exists(startup) then
      local h = fs.open(startup, "r")
      cur = h.readAll()
      h.close()
    end
    if cur ~= STARTUP_CODE then writeFile(startup, STARTUP_CODE) end
  end
  if shell and not opts.noShell and not string.find(shell.path(), "/void/bin", 1, true) then
    shell.setPath(shell.path() .. ":/void/bin")
  end

  if not opts.root then
    for _, line in ipairs(M.migrateLegacy()) do say(line) end
  end

  say("Installed version " .. tostring(mf.version) .. " (" .. #paths .. " files)")
  return true, "updated"
end

return M
