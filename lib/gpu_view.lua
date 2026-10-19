-- Radar screen for a DirectGPU display: banner, map, target list, log, visit stats.
-- Touch: tap a target (map or list) for details and trust/visitor/hostile/forget.
--
-- Pure drawing logic: `gpu` is the DirectGPU peripheral (or any table with the same
-- methods), so it is tested with a mock. All sizes follow the display's pixel size.
-- Unverified in game (see "screen" commands): that drawText's y is the top of the
-- text, and that touch events carry pixel coordinates in .x/.y.
local Z = require("lib.zone")
local D = require("lib.duration")
local history = require("lib.history")
local lists = require("lib.lists")
local tracker = require("lib.tracker")

local V = {}

V.COLOR = {
  engage = { 235, 60, 60 }, warn = { 245, 150, 40 }, watch = { 235, 210, 70 },
  friendly = { 70, 205, 100 }, pending = { 160, 160, 170 }, ignore = { 95, 95, 105 },
}
V.LEVEL = { { 40, 150, 80 }, { 40, 150, 80 }, { 200, 170, 40 }, { 220, 120, 30 }, { 215, 40, 40 } }
local BG, PANEL, LINE = { 14, 16, 22 }, { 24, 28, 38 }, { 55, 62, 80 }
local WHITE, GRAY, DIM = { 235, 235, 240 }, { 150, 155, 170 }, { 100, 105, 120 }
local ORDER = { engage = 1, warn = 2, watch = 3, friendly = 4, pending = 5, ignore = 6 }

V.SELECT_TIMEOUT_MS = 25000

---------------------------------------------------------------- model
-- Snapshot of everything the screen shows. a = { now, cfg, tracker, decisions, lists,
-- history, level, log (array of strings) }
function V.model(a)
  local cfg = a.cfg
  local targets = {}
  for _, t in ipairs(tracker.all(a.tracker)) do
    local d = a.decisions[t.id] or { action = "ignore", cls = "?" }
    local label
    if t.kind == "player" then
      label = t.name or tracker.short(t.id)
    elseif t.kind == "ship" then
      local e = a.lists.ships[t.id]
      label = "ship " .. ((e and e.label) or tracker.short(t.id))
    else
      label = tostring(t.category or "?"):lower()
    end
    local extra
    if d.action == "warn" and d.remainingMs then
      extra = D.format(d.remainingMs)
    elseif d.cls == "visitor" then
      local e = t.kind == "player" and lists.player(a.lists, t.name, t.id) or a.lists.ships[t.id]
      if e and e.expires then extra = D.format(e.expires - a.now) end
    end
    targets[#targets + 1] = {
      id = t.id, kind = t.kind, name = t.name, label = label, cls = d.cls, action = d.action,
      pos = t.pos, dist = cfg.zone and t.pos and Z.distance(cfg.zone, t.pos) or 0,
      inZone = cfg.zone and Z.contains(cfg.zone, t.pos) or false, extra = extra,
    }
  end
  table.sort(targets, function(x, y)
    local ox, oy = ORDER[x.action] or 9, ORDER[y.action] or 9
    if ox ~= oy then return ox < oy end
    return x.dist < y.dist
  end)
  local hist = a.history
  return {
    now = a.now, baseName = cfg.baseName or "Void base", zone = cfg.zone, level = a.level,
    targets = targets, log = a.log or {},
    top = hist and history.top(hist, 5) or {},
    last24h = hist and history.recentCount(hist, a.now, 24 * 3600000) or 0,
    visitors = hist and (function() local n = 0 for _ in pairs(hist.players) do n = n + 1 end return n end)() or 0,
    history = hist, offset = cfg.timeOffsetHours,
  }
end

-- Changes whenever something visible changes (to skip needless redraws).
function V.signature(model, view)
  local parts = { model.level and model.level.n or 0, #model.log, model.last24h, model.visitors,
    view and view.selected or "-", view and view.page or "" }
  for _, t in ipairs(model.targets) do
    parts[#parts + 1] = table.concat({ t.id, t.action, t.cls, t.label, math.floor(t.dist / 8),
      t.inZone and 1 or 0, t.extra or "" }, ":")
  end
  for _, p in ipairs(model.top) do parts[#parts + 1] = p.name .. p.visits .. math.floor(p.totalMs / 60000) end
  if model.level and model.level.n >= 5 then parts[#parts + 1] = math.floor(model.now / 1000) % 2 end
  return table.concat(parts, "|")
end

---------------------------------------------------------------- view
function V.new(gpu, display, info, opts)
  opts = opts or {}
  local W = tonumber(info and (info.pixelWidth or info.width)) or 512
  local H = tonumber(info and (info.pixelHeight or info.height)) or 256
  local u = math.max(8, math.floor(H / 30))
  return { gpu = gpu, d = display, W = W, H = H, u = u, font = opts.font or "SansSerif", hits = {},
    selected = nil, selectedAt = 0, calls = 0 }
end

function V.layout(view)
  local W, H = view.W, view.H
  local bh = math.floor(H * 0.12)
  local mw, mh = math.floor(W * 0.56), math.floor(H * 0.58)
  local lw = math.floor(W * 0.5)
  return {
    banner = { 0, 0, W, bh },
    map = { 0, bh, mw, mh },
    list = { mw, bh, W - mw, mh },
    log = { 0, bh + mh, lw, H - bh - mh },
    stats = { lw, bh + mh, W - lw, H - bh - mh },
  }
end

local function rect(view, r, col)
  view.gpu.fillRect(view.d, r[1], r[2], r[3], r[4], col[1], col[2], col[3])
end

local function text(view, str, x, y, col, size, style)
  view.gpu.drawText(view.d, str, math.floor(x), math.floor(y), col[1], col[2], col[3], view.font,
    math.floor(size or view.u), style or "plain")
end

-- characters that fit into `px` pixels at the given size (rough: 0.6 x size per char)
local function fit(str, px, size)
  local n = math.max(1, math.floor(px / (size * 0.6)))
  if #str <= n then return str end
  return str:sub(1, math.max(1, n - 1)) .. "~"
end

local function addHit(view, x, y, w, h, hit)
  hit.x, hit.y, hit.w, hit.h = x, y, w, h
  view.hits[#view.hits + 1] = hit
end

local function button(view, label, x, y, w, h, col, hit)
  rect(view, { x, y, w, h }, col)
  local size = view.u
  text(view, fit(label, w - 6, size), x + 6, y + math.floor((h - size) / 2), WHITE, size, "bold")
  addHit(view, x, y, w, h, hit)
end

local function age(ms, now)
  return D.format(math.max(0, now - ms))
end

---------------------------------------------------------------- panels
local function drawBanner(view, m, r)
  local lv = m.level
  local n = lv and lv.n or 1
  local col = V.LEVEL[n] or V.LEVEL[1]
  if n >= 5 and math.floor(m.now / 1000) % 2 == 0 then col = { 120, 20, 20 } end
  rect(view, r, col)
  local big = math.floor(view.u * 1.6)
  local label = lv and (("LEVEL %d  %s"):format(lv.n, lv.label)) or "NO DATA"
  text(view, label, r[1] + view.u, r[2] + math.floor((r[4] - big) / 2), WHITE, big, "bold")
  local seen, engaged, warned = #m.targets, 0, 0
  for _, t in ipairs(m.targets) do
    if t.action == "engage" then engaged = engaged + 1 elseif t.action == "warn" then warned = warned + 1 end
  end
  local right = ("%s   %d target%s%s%s"):format(m.baseName, seen, seen == 1 and "" or "s",
    warned > 0 and ("  " .. warned .. " warned") or "", engaged > 0 and ("  " .. engaged .. " ENGAGED") or "")
  local w = math.floor(#right * view.u * 0.6)
  text(view, right, r[3] - w - view.u, r[2] + math.floor((r[4] - view.u) / 2), WHITE, view.u, "plain")
end

local function project(view, m, r)
  -- square map area inside the rectangle, north (-z) up
  local pad = view.u
  local s = math.min(r[3], r[4]) - 2 * pad
  local cx, cy = r[1] + math.floor(r[3] / 2), r[2] + math.floor(r[4] / 2)
  local c = m.zone and Z.center(m.zone) or { x = 0, z = 0 }
  local half = m.zone and ((m.zone.x2 - m.zone.x1) / 2) or 160
  local R = half * 1.6
  for _, t in ipairs(m.targets) do
    if t.dist * 1.08 > R and t.dist < 2000 then R = t.dist * 1.08 end
  end
  local k = (s / 2) / R
  return {
    cx = cx, cy = cy, R = R, k = k, half = s / 2,
    to = function(p)
      local px, py = cx + (p.x - c.x) * k, cy + (p.z - c.z) * k
      local dx, dy = px - cx, py - cy
      local len = math.sqrt(dx * dx + dy * dy)
      local edge = s / 2 - 2
      if len > edge then px, py = cx + dx / len * edge, cy + dy / len * edge end -- clamp to the border
      return math.floor(px + 0.5), math.floor(py + 0.5), len > edge
    end,
  }
end

local function drawMap(view, m, r)
  rect(view, r, PANEL)
  local g, d = view.gpu, view.d
  local pr = project(view, m, r)
  -- range rings
  for _, ring in ipairs({ 128, 256, 512, 1024 }) do
    if ring < pr.R then
      g.drawCircle(d, pr.cx, pr.cy, math.floor(ring * pr.k), LINE[1], LINE[2], LINE[3], false)
      text(view, tostring(ring), pr.cx + 3, pr.cy - math.floor(ring * pr.k) - view.u, DIM, math.floor(view.u * 0.8))
    end
  end
  -- north marker
  text(view, "N", pr.cx - 3, r[2] + 2, GRAY, view.u, "bold")
  -- no-go zone square
  if m.zone then
    local c = Z.center(m.zone)
    local x1, y1 = pr.cx + (m.zone.x1 - c.x) * pr.k, pr.cy + (m.zone.z1 - c.z) * pr.k
    local x2, y2 = pr.cx + (m.zone.x2 - c.x) * pr.k, pr.cy + (m.zone.z2 - c.z) * pr.k
    local col = { 200, 70, 70 }
    g.drawLine(d, math.floor(x1), math.floor(y1), math.floor(x2), math.floor(y1), col[1], col[2], col[3])
    g.drawLine(d, math.floor(x2), math.floor(y1), math.floor(x2), math.floor(y2), col[1], col[2], col[3])
    g.drawLine(d, math.floor(x2), math.floor(y2), math.floor(x1), math.floor(y2), col[1], col[2], col[3])
    g.drawLine(d, math.floor(x1), math.floor(y2), math.floor(x1), math.floor(y1), col[1], col[2], col[3])
  end
  -- base
  local b = math.max(3, math.floor(view.u / 2))
  g.drawLine(d, pr.cx - b, pr.cy, pr.cx + b, pr.cy, WHITE[1], WHITE[2], WHITE[3])
  g.drawLine(d, pr.cx, pr.cy - b, pr.cx, pr.cy + b, WHITE[1], WHITE[2], WHITE[3])
  -- targets (worst last, so they are drawn on top)
  for i = #m.targets, 1, -1 do
    local t = m.targets[i]
    if t.pos then
      local px, py, clamped = pr.to(t.pos)
      local col = V.COLOR[t.action] or V.COLOR.ignore
      local rad = math.max(3, math.floor(view.u * 0.45))
      if t.id == view.selected then
        g.drawCircle(d, px, py, rad + 4, WHITE[1], WHITE[2], WHITE[3], false)
      end
      g.drawCircle(d, px, py, rad, col[1], col[2], col[3], not clamped)
      if t.action ~= "ignore" then
        text(view, fit(t.label, 14 * view.u * 0.6, view.u * 0.85), px + rad + 3, py - math.floor(view.u / 2), col, math.floor(view.u * 0.85))
      end
      addHit(view, px - rad - 4, py - rad - 4, 2 * rad + 8, 2 * rad + 8, { kind = "target", id = t.id })
    end
  end
end

local function drawList(view, m, r)
  rect(view, r, BG)
  local u = view.u
  text(view, "TARGETS", r[1] + u, r[2] + 3, GRAY, u, "bold")
  local rowH = math.floor(u * 1.9)
  local y = r[2] + math.floor(u * 1.8)
  local rows = math.floor((r[2] + r[4] - y) / rowH)
  if #m.targets == 0 then
    text(view, "nothing in range", r[1] + u, y, DIM, u)
    return
  end
  local shown = #m.targets > rows and rows - 1 or rows
  for i = 1, math.min(shown, #m.targets) do
    local t = m.targets[i]
    local col = V.COLOR[t.action] or V.COLOR.ignore
    if t.id == view.selected then rect(view, { r[1], y - 2, r[3], rowH }, PANEL) end
    view.gpu.drawCircle(view.d, r[1] + u, y + math.floor(u / 2), math.floor(u * 0.4), col[1], col[2], col[3], true)
    local right = ("%d%s%s"):format(math.floor(t.dist + 0.5), t.inZone and " Z" or "", t.extra and (" " .. t.extra) or "")
    local rw = math.floor(#right * u * 0.6)
    text(view, fit(t.label, r[3] - rw - 3 * u, u), r[1] + 2 * u, y, col, u, t.action == "engage" and "bold" or "plain")
    text(view, right, r[1] + r[3] - rw - u, y, WHITE, u)
    addHit(view, r[1], y - 2, r[3], rowH, { kind = "target", id = t.id })
    y = y + rowH
  end
  if #m.targets > shown then
    text(view, ("+%d more"):format(#m.targets - shown), r[1] + u, y, DIM, u)
  end
end

local function findTarget(m, id)
  for _, t in ipairs(m.targets) do if t.id == id then return t end end
end

local function drawDetail(view, m, r, t)
  rect(view, r, BG)
  local u = view.u
  local x, y = r[1] + u, r[2] + 3
  text(view, fit(t.label, r[3] - 2 * u, math.floor(u * 1.3)), x, y, V.COLOR[t.action] or WHITE, math.floor(u * 1.3), "bold")
  y = y + math.floor(u * 1.9)
  local function line(s, col)
    text(view, fit(s, r[3] - 2 * u, u), x, y, col or WHITE, u)
    y = y + math.floor(u * 1.3)
  end
  line(("%s / %s"):format(t.cls or "?", t.action or "?"), GRAY)
  line(("%d blocks from base%s"):format(math.floor(t.dist + 0.5), t.inZone and ", IN ZONE" or ""))
  if t.pos then
    line(("x %d  y %d  z %d"):format(math.floor(t.pos.x), math.floor(t.pos.y), math.floor(t.pos.z)), GRAY)
  end
  if t.extra then line((t.action == "warn" and "engaging in " or "time left ") .. t.extra, V.COLOR.warn) end
  if t.kind == "player" and t.name and m.history then
    local p = history.get(m.history, t.name)
    if p then
      line(("%d visit%s, %s total"):format(p.visits, p.visits == 1 and "" or "s", D.format(history.totalMs(p))), GRAY)
      line("last here " .. age(p.last, m.now) .. " ago", GRAY)
    else
      line("first visit", GRAY)
    end
  end
  -- buttons (a ship is told apart by its id prefix, a player by name)
  local who
  if t.kind == "player" and t.name and t.name:match("^[%w_]+$") then who = { prefix = "", name = t.name }
  elseif t.kind == "ship" then who = { prefix = "ship ", name = tracker.short(t.id), ship = true } end
  local bw, bh = math.floor((r[3] - 3 * u) / 2), math.floor(u * 2)
  local by = r[2] + r[4] - 3 * (bh + 4) - 2
  if who then
    local function cmd(action)
      if who.ship then return "ship " .. who.name .. " " .. action end
      return action .. " " .. who.name
    end
    button(view, "TRUST", x, by, bw, bh, { 40, 120, 70 }, { kind = "cmd", cmd = cmd("trust") })
    button(view, "VISITOR 30m", x + bw + u, by, bw, bh, { 50, 100, 150 }, { kind = "cmd", cmd = cmd("visitor 30m") })
    button(view, "HOSTILE", x, by + bh + 4, bw, bh, { 160, 50, 50 }, { kind = "cmd", cmd = cmd("hostile") })
    button(view, "FORGET", x + bw + u, by + bh + 4, bw, bh, { 90, 90, 100 }, { kind = "cmd", cmd = cmd("forget") })
  end
  button(view, "BACK", x, by + 2 * (bh + 4), r[3] - 2 * u, bh, { 60, 65, 85 }, { kind = "back" })
end

local function drawLog(view, m, r)
  rect(view, r, BG)
  local u = view.u
  text(view, "EVENTS", r[1] + u, r[2] + 3, GRAY, u, "bold")
  local small = math.floor(u * 0.9)
  local rowH = math.floor(u * 1.2)
  local y = r[2] + math.floor(u * 1.8)
  local rows = math.max(1, math.floor((r[2] + r[4] - y) / rowH))
  local first = math.max(1, #m.log - rows + 1)
  for i = first, #m.log do
    local line = m.log[i]
    local bang = line:find("!", 1, true)
    local col = (bang and bang <= 9) and V.COLOR.warn or GRAY
    text(view, fit(line, r[3] - 2 * u, small), r[1] + u, y, col, small)
    y = y + rowH
  end
end

local function drawStats(view, m, r)
  rect(view, r, PANEL)
  local u = view.u
  text(view, "VISITORS", r[1] + u, r[2] + 3, GRAY, u, "bold")
  local small = math.floor(u * 0.9)
  local rowH = math.floor(u * 1.2)
  local y = r[2] + math.floor(u * 1.8)
  text(view, ("%d known, %d visit%s in 24 h"):format(m.visitors, m.last24h, m.last24h == 1 and "" or "s"), r[1] + u, y, WHITE, small)
  y = y + rowH
  if #m.top == 0 then
    text(view, "no visits recorded yet", r[1] + u, y, DIM, small)
    return
  end
  for _, p in ipairs(m.top) do
    if y + rowH > r[2] + r[4] then break end
    local right = ("%dx %s"):format(p.visits, D.format(p.totalMs))
    local rw = math.floor(#right * small * 0.6)
    text(view, fit(p.name, r[3] - rw - 3 * u, small), r[1] + u, y, WHITE, small)
    text(view, right, r[1] + r[3] - rw - u, y, GRAY, small)
    y = y + rowH
  end
end

-- Draws one frame. Returns nothing; the caller calls gpu.updateDisplay.
function V.draw(view, m)
  view.hits = {}
  local L = V.layout(view)
  if view.selected and m.now - view.selectedAt > V.SELECT_TIMEOUT_MS then view.selected = nil end
  local sel = view.selected and findTarget(m, view.selected)
  if view.selected and not sel then view.selected = nil end -- target left the radar
  view.gpu.clear(view.d, BG[1], BG[2], BG[3])
  drawBanner(view, m, L.banner)
  drawMap(view, m, L.map)
  if sel then drawDetail(view, m, L.list, sel) else drawList(view, m, L.list) end
  drawLog(view, m, L.log)
  drawStats(view, m, L.stats)
end

---------------------------------------------------------------- touch
function V.hit(view, x, y)
  for i = #view.hits, 1, -1 do
    local h = view.hits[i]
    if x >= h.x and x < h.x + h.w and y >= h.y and y < h.y + h.h then return h end
  end
end

-- Handles a tap. Returns an action for the caller:
--   { type = "cmd", cmd = "trust Bob" }  or  nil (selection changed / nothing hit)
function V.click(view, x, y, now)
  local h = V.hit(view, x, y)
  if not h then
    return nil, false
  end
  if h.kind == "target" then
    view.selected, view.selectedAt = h.id, now
    return nil, true
  elseif h.kind == "back" then
    view.selected = nil
    return nil, true
  elseif h.kind == "cmd" then
    view.selected = nil
    return { type = "cmd", cmd = h.cmd }, true
  end
  return nil, false
end

return V
