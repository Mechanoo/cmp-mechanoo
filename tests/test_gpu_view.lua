-- DirectGPU screen: model, drawing (mock GPU), touch, buttons, error handling
local t = require("tests.t")
local V = require("lib.gpu_view")
local S = require("lib.gpu_screen")
local lists = require("lib.lists")
local tracker = require("lib.tracker")
local policy = require("lib.policy")
local history = require("lib.history")
local Z = require("lib.zone")
local commands = require("lib.commands")

local NOW = 2000000
local ls = lists.new()
lists.setPlayer(ls, "Mechanoo", "trusted", NOW)
local tr = tracker.new()
local cfg = { zone = Z.fromCenter(0, 0, 10), baseName = "Void test" }
tracker.update(tr, NOW, {
  { id = "8c98841d-1a03", category = "SABLE", position = { x = 20, y = 70, z = 0 }, velocity = { x = 0, y = 0, z = 0 } },
  { id = "far00000-0000", category = "SABLE", position = { x = 900, y = 70, z = -300 }, velocity = { x = 0, y = 0, z = 0 } },
}, {
  { name = "Steve", uuid = "u-steve", x = 30, y = 64, z = 10 },
  { name = "Mechanoo", uuid = "u-me", x = 5, y = 64, z = 5 },
}, ls)
local ps = policy.new()
local decisions = policy.update(ps, NOW, tracker.all(tr), ls, cfg.zone)
local level = policy.level(ps, decisions, tracker.all(tr), cfg.zone)

local hist = history.new()
history.record(hist, { target = { kind = "player", name = "Steve", cls = "unknown" }, start = NOW - 3600000, stop = NOW - 3000000, closest = 40 })
history.record(hist, { target = { kind = "player", name = "Steve", cls = "unknown" }, start = NOW - 900000, stop = NOW - 300000 })
history.record(hist, { target = { kind = "player", name = "Bob", cls = "visitor" }, start = NOW - 200000, stop = NOW - 100000 })

local args = { now = NOW, cfg = cfg, tracker = tr, decisions = decisions, lists = ls, history = hist, level = level,
  log = { "[12:00] ! CONTACT Steve (unknown player)", "[12:01]   Radar online" } }

-- history totals
t.eq(history.get(hist, "Steve").totalMs, 600000 + 600000, "total time adds up")
local top = history.top(hist, 5)
t.eq(top[1].name, "Steve", "longest visitor first")
t.eq(history.recentCount(hist, NOW, 24 * 3600000), 3, "visits in 24 h")

-- model
local m = V.model(args)
t.eq(#m.targets, 4, "all targets in the model")
t.eq(m.targets[1].label ~= nil, true, "labels")
local steve
for _, x in ipairs(m.targets) do if x.name == "Steve" then steve = x end end
t.truthy(steve and steve.inZone, "Steve is in the zone")
t.eq(m.targets[#m.targets].dist > 800, true, "sorted: far target last")
local sig1 = V.signature(m)
t.eq(sig1, V.signature(V.model(args)), "signature is stable")
args.log[#args.log + 1] = "[12:02] ! new"
t.truthy(sig1 ~= V.signature(V.model(args)), "signature changes with the log")
args.log[#args.log] = nil

-- mock GPU
local function mockGpu()
  local g = { calls = {}, texts = {}, events = {}, displays = 0, removed = {} }
  local function rec(name) return function(...) g.calls[#g.calls + 1] = { name, ... } end end
  for _, n in ipairs({ "clear", "fillRect", "drawCircle", "drawLine", "updateDisplay", "clearAllDisplays" }) do g[n] = rec(n) end
  g.drawText = function(d, str, x, y, r, gg, b, font, size, style)
    g.texts[#g.texts + 1] = { str = str, x = x, y = y, size = size, font = font }
    g.calls[#g.calls + 1] = { "drawText", str }
  end
  g.autoDetectAndCreateDisplay = function() g.displays = g.displays + 1 return 7 end
  g.getDisplayInfo = function() return { pixelWidth = 640, pixelHeight = 384 } end
  g.hasEvents = function() return #g.events > 0 end
  g.pollEvent = function() return table.remove(g.events, 1) end
  g.removeDisplay = function(d) g.removed[#g.removed + 1] = d end
  return g
end

local g = mockGpu()
local view = V.new(g, 7, { pixelWidth = 640, pixelHeight = 384 }, {})
local function frame(mm)
  g.texts = {}
  V.draw(view, mm or V.model(args))
  local all = {}
  for _, x in ipairs(g.texts) do all[#all + 1] = x.str end
  return table.concat(all, "\n")
end
local function tap(h) return V.click(view, h.x + 2, h.y + 2, NOW) end
local function findHit(pred)
  for _, h in ipairs(view.hits) do if pred(h) then return h end end
end

-- radar page (default)
local joined = frame()
t.eq(view.page, "radar", "starts on the radar page")
t.contains(joined, "LEVEL", "status bar shows the level")
t.contains(joined, "Void test", "status bar shows the base name")
t.contains(joined, "RADAR", "tab bar")
t.contains(joined, "TARGETS", "tab bar: targets")
t.contains(joined, "CONTACTS", "radar page: contact list")
t.contains(joined, "Steve", "radar page: player")
t.contains(joined, "N", "compass")
local inside = true
for _, x in ipairs(g.texts) do
  if x.x < -1 or x.y < -1 or x.x > 640 or x.y > 384 then inside = false end
end
t.truthy(inside, "all text starts inside the display")
t.truthy(#view.hits >= 9, "tabs and targets are touchable")
-- the level 4+ jump is not triggered by a calm radar
t.eq(view.lastLevel, level and level.n or 0, "level remembered")

-- the scope has a fixed range: a far target does not change its scale
local function scopeCalls(mm)
  g.calls = {}
  frame(mm)
  local out = {}
  for _, c in ipairs(g.calls) do
    if c[1] == "drawCircle" and c[9] == false then out[#out + 1] = table.concat({ c[3], c[4], c[5] }, ",") end
  end
  return table.concat(out, ";")
end
local near = V.model(args)
local onlyNear = {}
for _, x in ipairs(near.targets) do if x.dist < 200 then onlyNear[#onlyNear + 1] = x end end
local farModel = V.model(args)
local nearModel = V.model(args)
nearModel.targets = onlyNear
t.eq(scopeCalls(farModel):match("^[^;]+;[^;]+;[^;]+;[^;]+"), scopeCalls(nearModel):match("^[^;]+;[^;]+;[^;]+;[^;]+"),
  "rings and rim stay the same with and without a far target")
t.eq(m.range, 256, "default scope range")
local zoomOut = findHit(function(h) return h.kind == "cmd" and h.cmd == "screen range 512" end)
local zoomIn = findHit(function(h) return h.kind == "cmd" and h.cmd == "screen range 128" end)
t.truthy(zoomOut and zoomIn, "zoom buttons ask for the next range steps")
local zr = tap(zoomOut)
t.eq(zr and zr.cmd, "screen range 512", "zoom button returns its command")
local cfgZ = { zone = cfg.zone }
local rz = commands.run({ lists = ls, tracker = tr, config = cfgZ, now = NOW }, "screen range 512")
t.eq(cfgZ.screenRange, 512, "screen range stored")
t.truthy(rz.configChanged, "screen range saves the config")
commands.run({ lists = ls, tracker = tr, config = cfgZ, now = NOW }, "screen range 300")
t.eq(cfgZ.screenRange, 512, "only the listed steps are accepted")
local m512 = V.model({ now = NOW, cfg = { zone = cfg.zone, screenRange = 512 }, tracker = tr, decisions = decisions, lists = ls,
  history = hist, level = level, log = {} })
t.eq(m512.range, 512, "model uses the stored range")
frame(m512)
t.eq(findHit(function(h) return h.kind == "cmd" and h.cmd == "screen range 1024" end) ~= nil, true, "at 512 '-' goes to 1024")
local m1024 = V.model({ now = NOW, cfg = { zone = cfg.zone, screenRange = 1024 }, tracker = tr, decisions = decisions, lists = ls,
  history = hist, level = level, log = {} })
frame(m1024)
t.eq(findHit(function(h) return h.kind == "cmd" and h.cmd:find("^screen range 2") end), nil, "no step beyond 1024")
-- rounded boxes only when asked for
local gr = mockGpu()
local rr = 0
gr.drawRoundedRect = function() rr = rr + 1 end
local vr = V.new(gr, 7, { pixelWidth = 640, pixelHeight = 384 }, { rounded = true })
V.draw(vr, V.model(args))
t.truthy(rr > 0, "rounded boxes drawn with drawRoundedRect")
frame()

-- tabs
local function gotoTab(id)
  local h = findHit(function(x) return x.kind == "tab" and x.page == id end)
  t.truthy(h, "tab " .. id .. " is a hit area")
  tap(h)
  t.eq(view.page, id, "tab " .. id .. " active")
  return frame()
end
joined = gotoTab("targets")
t.contains(joined, "NAME", "targets table header")
t.contains(joined, "Steve", "targets table row")
t.contains(joined, "unknown", "targets table: list column")
joined = gotoTab("visitors")
t.contains(joined, "TOTAL TIME", "visitors table header")
t.contains(joined, "Steve", "visitors: Steve")
t.contains(joined, "20m00s", "visitors: Steve total time")
t.contains(joined, "Bob", "visitors: Bob")
joined = gotoTab("log")
t.contains(joined, "CONTACT Steve", "log page: log line")
joined = gotoTab("stats")
t.contains(joined, "LAST 14 DAYS", "stats page")
t.contains(joined, "TOP VISITORS", "stats: top visitors")
t.contains(joined, "Steve", "stats: Steve listed")
local topHit = findHit(function(h) return h.kind == "player" and h.name == "Steve" end)
tap(topHit)
t.eq(view.page, "visitors", "tap on a top visitor opens the visitors page")
t.eq(view.selectedPlayer, "Steve", "with Steve selected")
view.selectedPlayer = nil
joined = gotoTab("control")
t.contains(joined, "MUTE SIREN 10m", "control: mute button")
t.contains(joined, "Siren: on", "control: siren state")

-- control buttons run commands and keep the page
local mute = findHit(function(h) return h.kind == "cmd" and h.cmd == "alarm mute 10m" end)
local action = tap(mute)
t.eq(action and action.cmd, "alarm mute 10m", "mute button returns its command")
t.eq(view.page, "control", "stays on the control page")
local volDown = findHit(function(h) return h.kind == "cmd" and h.cmd == "alarm volume 2" end)
t.truthy(volDown, "volume - from 3 asks for 2")
t.eq(findHit(function(h) return h.cmd == "zone radars" end), nil, "no zone button without a radar position")
t.contains(joined, "position unknown", "control: radar position unknown")
-- moved radars: position, warning and the ZONE TO RADARS button
args.radarCenter = { x = 2000, y = 0, z = 2000 }
local mm = V.model(args)
t.truthy(mm.radarsOutside, "radars outside the zone are flagged")
t.truthy(V.signature(mm) ~= V.signature(V.model((function() local a = {} for k, v in pairs(args) do a[k] = v end a.radarCenter = nil return a end)())),
  "signature changes with the radar position")
joined = frame(mm)
t.contains(joined, "x 2000 z 2000", "control: radar position")
t.contains(joined, "OUTSIDE ZONE", "control: outside warning")
local zb = findHit(function(h) return h.kind == "cmd" and h.cmd == "zone radars" end)
t.truthy(zb, "ZONE TO RADARS button")
t.eq(tap(zb).cmd, "zone radars", "button runs zone radars")
t.eq(view.page, "control", "stays on the control page after moving the zone")
args.radarCenter = nil

-- events scrolling
for i = 1, 40 do args.log[#args.log + 1] = "[12:" .. i .. "]   filler " .. i end
gotoTab("log")
local up = findHit(function(h) return h.kind == "scroll" and h.delta > 0 end)
tap(up)
t.eq(view.logScroll, 5, "UP scrolls back in the log")
joined = frame()
t.contains(joined, "newer", "scroll position shown")
local down = findHit(function(h) return h.kind == "scroll" and h.delta < 0 end)
tap(down)
tap(down)
t.eq(view.logScroll, 0, "DOWN stops at the newest line")
for i = 1, 40 do args.log[#args.log] = nil end

-- targets: tap a row -> card with buttons
gotoTab("targets")
local row = findHit(function(h) return h.kind == "target" and h.id == steve.id end)
t.truthy(row, "row of Steve is a hit area")
tap(row)
t.eq(view.selected, steve.id, "Steve selected")
joined = frame()
t.contains(joined, "TRUST", "card: trust button")
t.contains(joined, "HOSTILE", "card: hostile button")
t.contains(joined, "2 visits, 20m00s total", "card: visit stats")
t.contains(joined, "IN ZONE", "card: zone flag")
local trust = findHit(function(h) return h.kind == "cmd" and h.cmd == "trust Steve" end)
t.truthy(trust, "trust button maps to 'trust Steve'")
local act2 = tap(trust)
t.eq(act2 and act2.cmd, "trust Steve", "tap on TRUST returns the command")
t.eq(view.selected, nil, "selection cleared after a command")
commands.run({ lists = ls, tracker = tr, config = cfg, now = NOW }, act2.cmd)
t.eq(lists.player(ls, "Steve").list, "trusted", "command from the screen trusts Steve")

-- radar page: tap on a blip selects, BACK clears
gotoTab("radar")
local blip = findHit(function(h) return h.kind == "target" and h.id == steve.id and h.x < 640 * 0.6 end)
t.truthy(blip, "Steve's blip on the scope is touchable")
tap(blip)
t.eq(view.selected, steve.id, "blip selects")
frame()
local back = findHit(function(h) return h.kind == "back" end)
tap(back)
t.eq(view.selected, nil, "BACK clears the selection")

-- a ship gets ship commands
local shipT
for _, x in ipairs(m.targets) do if x.id == "8c98841d-1a03" then shipT = x end end
view.selected, view.selectedAt = shipT.id, NOW
frame()
t.truthy(findHit(function(h) return h.kind == "cmd" and h.cmd == "ship 8c98841d hostile" end), "ship buttons use 'ship <id> ...'")
-- selection times out
view.selected, view.selectedAt = shipT.id, NOW - V.SELECT_TIMEOUT_MS - 1
frame()
t.eq(view.selected, nil, "selection times out")

-- visitors: tap a name -> history card
gotoTab("visitors")
local bobHit = findHit(function(h) return h.kind == "player" and h.name == "Bob" end)
tap(bobHit)
joined = frame()
t.contains(joined, "1 visit, 1m40s total", "player card: totals")
t.truthy(findHit(function(h) return h.kind == "cmd" and h.cmd == "hostile Bob" end), "player card: hostile Bob")

-- level 4+ jumps back to the radar page
gotoTab("log")
local hot = V.model(args)
hot.level = { n = 4, label = "WARNING" }
view.lastLevel = 1
frame(hot)
t.eq(view.page, "radar", "a rising alarm level switches to the radar page")

-- empty radar and no zone must not crash
local empty = V.model({ now = NOW, cfg = {}, tracker = tracker.new(), decisions = {}, lists = lists.new(), history = nil, level = nil, log = {} })
for _, p in ipairs(V.TABS) do
  view.page = p.id
  frame(empty)
end
t.truthy(true, "empty model draws on every page")
view.page = "radar"

-- radar categories: hidden by default, chips toggle them, mob details
t.eq(V.typeName("entity.minecraft.zombie_villager"), "zombie villager", "type name from the entity type")
t.eq(V.typeName("entity.alexsmobs.crow"), "crow", "modded type name")
t.eq(V.catId("ship"), "SABLE", "category by screen label")
t.eq(V.catId("animal"), "ANIMAL", "category by id")
local trC = tracker.new()
tracker.update(trC, NOW, {
  { id = "cow1", category = "ANIMAL", entityType = "entity.minecraft.cow", position = { x = 10, y = 64, z = 10 }, velocity = { x = 0, y = 0, z = 0 } },
  { id = "zom1", category = "HOSTILE", entityType = "entity.minecraft.zombie", position = { x = -20, y = 64, z = 5 }, velocity = { x = 0, y = 0, z = 0 } },
  { id = "arrow", category = "PROJECTILE", entityType = "entity.minecraft.arrow", position = { x = 0, y = 70, z = 0 }, velocity = { x = 1, y = 0, z = 0 } },
}, {}, ls)
local cfgC = { zone = cfg.zone }
local function modelC() return V.model({ now = NOW, cfg = cfgC, tracker = trC, decisions = {}, lists = ls, history = hist, level = level, log = {} }) end
local mc = modelC()
t.eq(#mc.targets, 1, "only the projectile is shown by default")
t.eq(mc.hidden, 2, "cow and zombie hidden")
t.eq(mc.targets[1].label, "arrow", "label from the entity type")
view.lastLevel = 5 -- no jump to the radar page in this part
gotoTab("targets")
joined = frame(mc)
t.contains(joined, "ANIMAL 1", "filter chip with count")
t.contains(joined, "+2 hidden", "header counts hidden targets")
local chip = findHit(function(h) return h.kind == "cmd" and h.cmd == "screen show animal on" end)
t.truthy(chip, "animal chip turns animals on")
local ca = tap(chip)
t.eq(view.page, "targets", "chip keeps the page")
commands.run({ lists = ls, tracker = trC, config = cfgC, now = NOW }, ca.cmd)
t.eq(cfgC.screenShow.ANIMAL, true, "animals shown after the tap")
mc = modelC()
t.eq(#mc.targets, 2, "cow now listed")
local cow
for _, x in ipairs(mc.targets) do if x.id == "cow1" then cow = x end end
t.eq(cow and cow.label, "cow", "cow label")
view.selected, view.selectedAt = "cow1", NOW
joined = frame(mc)
t.contains(joined, "entity.minecraft.cow", "card shows the full entity type")
t.contains(joined, "ANIMAL", "card shows the category")
t.eq(findHit(function(h) return h.kind == "cmd" and h.cmd:find("trust") end), nil, "no trust buttons for a cow")
view.selected = nil
local rr2 = commands.run({ lists = ls, tracker = trC, config = cfgC, now = NOW }, "screen show all off")
t.eq(#modelC().targets, 0, "all off hides everything")
t.contains(table.concat(rr2.lines, " "), "player off", "screen show reports the state")
commands.run({ lists = ls, tracker = trC, config = cfgC, now = NOW }, "screen show unicorn on")
t.eq(cfgC.screenShow.UNICORN, nil, "unknown category rejected")
gotoTab("radar")

-- controller: attach, draw, touch, errors
local real = peripheral
local gpu2 = mockGpu()
peripheral = {
  getNames = function() return { "directgpu_0" } end,
  getType = function() return "directgpu" end,
  call = function(name, method, ...)
    local fn = gpu2[method]
    if not fn then error("no method " .. method, 0) end
    return fn(...)
  end,
}
local ran, logs = {}, {}
local ctrl = S.new({
  args = function() return args end,
  run = function(c) ran[#ran + 1] = c end,
  log = function(x) logs[#logs + 1] = x end,
})
S.step(ctrl)
t.truthy(ctrl.view, "controller attached")
t.eq(gpu2.displays, 1, "one display created")
t.contains(logs[1] or "", "display 7", "attach is logged")
local framesBefore = ctrl.frames
S.step(ctrl)
t.eq(ctrl.frames, framesBefore, "no redraw when nothing changed")
t.truthy(ctrl.frames >= 1, "first frame drawn")
local ups = 0
for _, c in ipairs(gpu2.calls) do if c[1] == "updateDisplay" then ups = ups + 1 end end
t.eq(ups, 1, "one updateDisplay per frame")
-- touch event on a list row selects, second on TRUST runs the command
local rowHit
for _, h in ipairs(ctrl.view.hits) do if h.kind == "target" then rowHit = h break end end
gpu2.events[1] = { type = "mouse_click", x = rowHit.x + 2, y = rowHit.y + 2 }
S.step(ctrl)
t.truthy(ctrl.view.selected, "touch selects a target")
local btn
for _, h in ipairs(ctrl.view.hits) do if h.kind == "cmd" and h.cmd:find("^trust ") then btn = h end end
if btn then
  gpu2.events[1] = { type = "mouse_click", x = btn.x + 1, y = btn.y + 1 }
  S.step(ctrl)
  t.contains(ran[1] or "", "trust ", "button press runs the command")
end
-- status and test
t.contains(S.status(ctrl)[1], "display 7", "status")
t.contains(S.status(ctrl)[2], "GPU calls", "status shows frame cost")
local okT = S.test(ctrl)
t.truthy(okT, "test pattern drawn")
-- raw event logging
S.watchEvents(ctrl)
gpu2.events[1] = { type = "mouse_click", x = 1, y = 1 }
S.step(ctrl)
local sawRaw = false
for _, l in ipairs(logs) do if l:find("screen event", 1, true) then sawRaw = true end end
t.truthy(sawRaw, "screen events logs raw events")
-- a failing GPU call drops the display and does not throw
gpu2.updateDisplay = function() error("boom", 0) end
ctrl.sig, ctrl.holdUntil = nil, 0
local okStep = pcall(S.step, ctrl)
t.truthy(okStep, "GPU errors never reach the radar")
t.eq(ctrl.view, nil, "display dropped after an error")
local sawErr = false
for _, l in ipairs(logs) do if l:find("boom", 1, true) then sawErr = true end end
t.truthy(sawErr, "error is logged")
-- no GPU at all: quiet
peripheral = { getNames = function() return {} end, getType = function() end, call = function() end }
local quiet = S.new({ args = function() return args end, run = function() end, log = function(x) logs[#logs + 1] = x end })
S.step(quiet)
t.eq(quiet.view, nil, "no GPU: no display")
t.contains(S.status(quiet)[1], "no DirectGPU block", "status without GPU")
peripheral = real

-- screen command
local c2 = { lists = ls, tracker = tr, config = cfg, now = NOW }
t.eq(commands.run(c2, "screen").screen, "status", "screen")
t.eq(commands.run(c2, "screen test").screen, "test", "screen test")
local r = commands.run(c2, "screen font Monospaced")
t.eq(cfg.gpuFont, "Monospaced", "font stored")
t.eq(r.screen, "reset", "font change resets the display")
t.finish("gpu view")
