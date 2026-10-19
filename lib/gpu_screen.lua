-- Keeps the DirectGPU radar screen alive: finds the GPU block, creates the display,
-- polls touch events, redraws when something changed. Errors never reach the radar:
-- a failing GPU call drops the display and tries again after a pause.
--
-- deps = {
--   args = function() -> table for gpu_view.model (now, cfg, tracker, decisions, lists, history, level, log),
--   run  = function(cmd)   run a radar command line (touch buttons),
--   log  = function(text)  message for the radar log,
--   font = function() -> font name or nil,
-- }
local view = require("lib.gpu_view")

local S = {}

S.RETRY_MS = 15000
S.CLICK_TYPES = { mouse_click = true, touch = true, monitor_touch = true, click = true }

local function now() return os.epoch("utc") end

-- Calls go through peripheral.call, so the table works with real and mocked peripherals.
local function proxy(name, counter)
  return setmetatable({}, { __index = function(_, method)
    return function(...)
      counter.n = counter.n + 1
      return peripheral.call(name, method, ...)
    end
  end })
end

function S.new(deps)
  return { deps = deps, view = nil, nextTry = 0, sig = nil, lastErr = nil, eventsUntil = 0,
    counter = { n = 0 }, lastMs = 0, lastCalls = 0, frames = 0 }
end

local function findGpu()
  for _, name in ipairs(peripheral.getNames()) do
    local types = { peripheral.getType(name) }
    for _, ty in ipairs(types) do
      if ty == "directgpu" then return name end
    end
  end
end

local function fail(s, err)
  err = tostring(err)
  if err ~= s.lastErr then s.deps.log("screen: " .. err) end
  s.lastErr = err
  s.view, s.sig = nil, nil
  s.nextTry = now() + S.RETRY_MS
end

local function attach(s)
  local name = findGpu()
  if not name then
    s.nextTry = now() + S.RETRY_MS
    return
  end
  local ok, err = pcall(function()
    local gpu = proxy(name, s.counter)
    pcall(gpu.clearAllDisplays) -- no stale displays of an earlier run
    local d = gpu.autoDetectAndCreateDisplay()
    if type(d) ~= "number" then error("no monitor found next to the GPU block (autoDetect returned " .. tostring(d) .. ")", 0) end
    local info = gpu.getDisplayInfo(d)
    s.gpuName, s.display, s.info = name, d, info
    s.view = view.new(gpu, d, info, { font = s.deps.font and s.deps.font() })
    s.sig = nil
    s.deps.log(("screen: display %d on %s, %sx%s px"):format(d, name,
      tostring(info and info.pixelWidth), tostring(info and info.pixelHeight)))
    s.lastErr = nil
  end)
  if not ok then fail(s, err) end
end

local function draw(s)
  local v = s.view
  local m = view.model(s.deps.args())
  view.prepare(v, m)
  local sig = view.signature(m, v)
  if sig == s.sig then return end
  s.sig = sig
  local t0, c0 = os.clock(), s.counter.n
  view.draw(v, m)
  v.gpu.updateDisplay(v.d)
  s.lastMs = math.floor((os.clock() - t0) * 1000)
  s.lastCalls = s.counter.n - c0
  s.frames = s.frames + 1
end

function S.step(s)
  if not s.view then
    if now() >= s.nextTry then attach(s) end
    if not s.view then return end
  end
  local ok, err = pcall(function()
    local v = s.view
    local n = 0
    while n < 10 and v.gpu.hasEvents(v.d) do
      n = n + 1
      local ev = v.gpu.pollEvent(v.d)
      if now() < s.eventsUntil then s.deps.log("screen event: " .. textutils.serialise(ev, { compact = true })) end
      if type(ev) == "table" and S.CLICK_TYPES[ev.type] and tonumber(ev.x) and tonumber(ev.y) then
        local action, changed = view.click(v, ev.x, ev.y, now())
        if action and action.type == "cmd" then s.deps.run(action.cmd) end
        if changed then s.sig = nil end
      end
    end
    if now() >= (s.holdUntil or 0) then draw(s) end
  end)
  if not ok then fail(s, err) end
end

-- "screen events": log raw touch events for 15 s (to check the real event format)
function S.watchEvents(s) s.eventsUntil = now() + 15000 end

-- "screen reset": drop the display, recreate it on the next step
function S.reset(s)
  S.close(s)
  s.nextTry = 0
end

-- "screen test": fixed pattern with labelled corners, to check coordinates and fonts
function S.test(s)
  if not s.view then return false, "no screen attached" end
  local ok, err = pcall(function()
    local v = s.view
    local g = v.gpu
    g.clear(v.d, 10, 10, 30)
    g.fillRect(v.d, 0, 0, 40, 20, 255, 0, 0)
    g.fillRect(v.d, v.W - 40, 0, 40, 20, 0, 255, 0)
    g.fillRect(v.d, 0, v.H - 20, 40, 20, 0, 0, 255)
    g.fillRect(v.d, v.W - 40, v.H - 20, 40, 20, 255, 255, 0)
    g.drawLine(v.d, 0, 0, v.W - 1, v.H - 1, 255, 255, 255)
    g.drawLine(v.d, v.W - 1, 0, 0, v.H - 1, 255, 255, 255)
    g.drawCircle(v.d, math.floor(v.W / 2), math.floor(v.H / 2), math.floor(v.H / 4), 0, 255, 255, false)
    g.drawText(v.d, ("TEST %dx%d  font %s"):format(v.W, v.H, v.font), 50, 30, 255, 255, 255, v.font, v.u, "plain")
    g.updateDisplay(v.d)
    s.holdUntil = now() + 10000 -- show the pattern 10 s, then the radar again
    s.sig = nil
  end)
  if not ok then fail(s, err) return false, err end
  return true
end

function S.status(s)
  if not s.view then
    local name = findGpu()
    if not name then return { "screen: no DirectGPU block found (peripheral type 'directgpu')" } end
    return { "screen: GPU '" .. name .. "' found, not attached" .. (s.lastErr and (": " .. s.lastErr) or "") }
  end
  local v = s.view
  return {
    ("screen: display %d on %s, %dx%d px, font %s"):format(s.display, s.gpuName, v.W, v.H, v.font),
    ("last frame: %d GPU calls, %d ms, %d frame(s) drawn"):format(s.lastCalls, s.lastMs, s.frames),
  }
end

function S.close(s)
  if s.view then
    pcall(function() s.view.gpu.removeDisplay(s.view.d) end)
  end
  s.view, s.sig = nil, nil
end

return S
