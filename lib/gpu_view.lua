-- Radar screen for a DirectGPU display, with touch tabs:
--   RADAR     round scope + nearest targets (tap a blip or a row for details and buttons)
--   TARGETS   table of everything the radar sees
--   VISITORS  who was here, how often, how long (tap a name for the history and buttons)
--   EVENTS    the radar log, scrollable
--   CONTROL   siren and zone buttons
-- A status bar with the base level stays visible on every tab.
--
-- Pure drawing logic: `gpu` is the DirectGPU peripheral (or any table with the same
-- methods), so it is tested with a mock. All sizes follow the display's pixel size.
-- Unverified in game (see the "screen" commands): that drawText's y is the top of the
-- text, and that touch events carry pixel coordinates in .x/.y.
local Z = require("lib.zone")
local D = require("lib.duration")
local history = require("lib.history")
local lists = require("lib.lists")
local tracker = require("lib.tracker")

local V = {}

V.COLOR = {
  engage = { 240, 70, 70 }, warn = { 250, 160, 50 }, watch = { 240, 215, 80 },
  friendly = { 80, 210, 110 }, pending = { 165, 170, 185 }, ignore = { 100, 105, 120 },
}
V.LIST_COLOR = {
  trusted = { 80, 210, 110 }, visitor = { 90, 170, 240 }, hostile = { 240, 70, 70 }, unknown = { 165, 170, 185 },
}
V.LEVEL = { { 40, 150, 80 }, { 40, 150, 80 }, { 200, 165, 35 }, { 225, 120, 30 }, { 215, 40, 40 } }
V.TABS = {
  { id = "radar", label = "RADAR" }, { id = "targets", label = "TARGETS" }, { id = "visitors", label = "VISITORS" },
  { id = "events", label = "EVENTS" }, { id = "control", label = "CONTROL" },
}

local BG, PANEL, PANEL2 = { 11, 13, 19 }, { 22, 26, 37 }, { 31, 36, 50 }
local WHITE, GRAY, DIM = { 236, 238, 244 }, { 160, 166, 184 }, { 105, 111, 130 }
local ACCENT = { 70, 170, 225 }
local SCOPE, SCOPE_RING, SCOPE_AXIS = { 7, 26, 17 }, { 28, 105, 60 }, { 22, 72, 44 }
local ORDER = { engage = 1, warn = 2, watch = 3, friendly = 4, pending = 5, ignore = 6 }
local STATUS_WORD = { engage = "ENGAGE", warn = "WARN", watch = "seen", friendly = "ok", pending = "?", ignore = "-" }

V.SELECT_TIMEOUT_MS = 30000

local atan2 = math.atan2 or math.atan

-- N, NE, E ... from the base centre (north = -z)
local function compass(dx, dz)
  local deg = math.deg(atan2(dx, -dz)) % 360
  local names = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
  return names[math.floor((deg + 22.5) / 45) % 8 + 1]
end

---------------------------------------------------------------- model
-- Snapshot of everything the screen shows. a = { now, cfg, tracker, decisions, lists,
-- history, level, log (array of strings) }
function V.model(a)
  local cfg = a.cfg
  local targets = {}
  local here = {}
  local c = cfg.zone and Z.center(cfg.zone) or nil
  for _, t in ipairs(tracker.all(a.tracker)) do
    local d = a.decisions[t.id] or { action = "ignore", cls = "?" }
    local label
    if t.kind == "player" then
      label = t.name or tracker.short(t.id)
      if t.name then here[t.name:lower()] = true end
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
      dir = (c and t.pos) and compass(t.pos.x - c.x, t.pos.z - c.z) or "",
      inZone = cfg.zone and Z.contains(cfg.zone, t.pos) or false, extra = extra,
    }
  end
  table.sort(targets, function(x, y)
    local ox, oy = ORDER[x.action] or 9, ORDER[y.action] or 9
    if ox ~= oy then return ox < oy end
    return x.dist < y.dist
  end)
  local hist = a.history
  local visitors = {}
  if hist then
    for _, p in ipairs(history.top(hist, 40)) do
      local e = lists.player(a.lists, p.name)
      p.cls = e and e.list or "unknown"
      p.here = here[p.name:lower()] or false
      visitors[#visitors + 1] = p
    end
  end
  local muted = cfg.alarmMuteUntil ~= nil and a.now < cfg.alarmMuteUntil
  return {
    now = a.now, baseName = cfg.baseName or "Void base", zone = cfg.zone, level = a.level,
    targets = targets, log = a.log or {}, visitors = visitors,
    visitorCount = hist and (function() local n = 0 for _ in pairs(hist.players) do n = n + 1 end return n end)() or 0,
    last24h = hist and history.recentCount(hist, a.now, 24 * 3600000) or 0,
    history = hist, offset = cfg.timeOffsetHours,
    alarm = { muted = muted, volume = cfg.alarmVolume or 3, mutedUntil = cfg.alarmMuteUntil },
    detectRange = cfg.detectRange or 512,
  }
end

-- Changes whenever something visible changes (to skip needless redraws).
function V.signature(model, view)
  local parts = { model.level and model.level.n or 0, #model.log, model.last24h, model.visitorCount,
    view and view.selected or "-", view and view.selectedPlayer or "-", view and view.page or "",
    view and view.logScroll or 0, model.alarm.muted and 1 or 0, model.alarm.volume }
  for _, t in ipairs(model.targets) do
    parts[#parts + 1] = table.concat({ t.id, t.action, t.cls, t.label, math.floor(t.dist / 8),
      t.inZone and 1 or 0, t.extra or "" }, ":")
  end
  for _, p in ipairs(model.visitors) do
    parts[#parts + 1] = p.name .. p.visits .. math.floor(p.totalMs / 60000) .. p.cls .. (p.here and "h" or "")
  end
  if model.level and model.level.n >= 5 then parts[#parts + 1] = math.floor(model.now / 1000) % 2 end
  return table.concat(parts, "|")
end

---------------------------------------------------------------- view state
function V.new(gpu, display, info, opts)
  opts = opts or {}
  local W = tonumber(info and (info.pixelWidth or info.width)) or 512
  local H = tonumber(info and (info.pixelHeight or info.height)) or 256
  local u = math.max(8, math.floor(H / 28))
  return { gpu = gpu, d = display, W = W, H = H, u = u, font = opts.font or "SansSerif", hits = {},
    page = "radar", selected = nil, selectedAt = 0, selectedPlayer = nil, logScroll = 0, lastLevel = 0 }
end

-- Level 4+ (countdown running or engaged): jump to the radar page, drop old selections.
function V.prepare(view, m)
  local n = m.level and m.level.n or 0
  if n >= 4 and view.lastLevel < 4 and view.page ~= "radar" then
    view.page, view.selected, view.selectedPlayer = "radar", nil, nil
  end
  view.lastLevel = n
  if view.selected and m.now - view.selectedAt > V.SELECT_TIMEOUT_MS then view.selected = nil end
  if view.selectedPlayer and m.now - view.selectedAt > V.SELECT_TIMEOUT_MS then view.selectedPlayer = nil end
end

function V.layout(view)
  local W, H = view.W, view.H
  local sh = math.floor(H * 0.085)
  local th = math.floor(H * 0.075)
  local y0 = sh + th
  return {
    status = { 0, 0, W, sh }, tabs = { 0, sh, W, th },
    content = { 0, y0, W, H - y0 },
  }
end

---------------------------------------------------------------- drawing helpers
local function rect(view, r, col)
  view.gpu.fillRect(view.d, r[1], r[2], r[3], r[4], col[1], col[2], col[3])
end

local function text(view, str, x, y, col, size, style)
  view.gpu.drawText(view.d, str, math.floor(x), math.floor(y), col[1], col[2], col[3], view.font,
    math.floor(size or view.u), style or "plain")
end

-- characters that fit into `px` pixels at the given size (rough: 0.6 x size per char)
local function fit(str, px, size)
  str = tostring(str)
  local n = math.max(1, math.floor(px / (size * 0.6)))
  if #str <= n then return str end
  return str:sub(1, math.max(1, n - 1)) .. "~"
end

local function textWidth(str, size) return math.floor(#str * size * 0.6) end

local function addHit(view, x, y, w, h, hit)
  hit.x, hit.y, hit.w, hit.h = x, y, w, h
  view.hits[#view.hits + 1] = hit
end

local function button(view, label, x, y, w, h, col, hit)
  rect(view, { x, y, w, h }, col)
  local size = view.u
  local label2 = fit(label, w - 8, size)
  text(view, label2, x + math.floor((w - textWidth(label2, size)) / 2), y + math.floor((h - size) / 2), WHITE, size, "bold")
  addHit(view, x, y, w, h, hit)
end

local function age(ms, now) return D.format(math.max(0, now - ms)) end

---------------------------------------------------------------- status + tab bar
local function drawStatus(view, m, r)
  local lv = m.level
  local n = lv and lv.n or 1
  local col = V.LEVEL[n] or V.LEVEL[1]
  local blink = n >= 5 and math.floor(m.now / 1000) % 2 == 0
  rect(view, r, PANEL)
  local chipW = math.floor(view.W * 0.34)
  rect(view, { 0, 0, chipW, r[4] }, blink and { 110, 18, 18 } or col)
  local label = lv and (("LEVEL %d  %s"):format(lv.n, lv.label)) or "NO DATA"
  local size = math.floor(view.u * 1.2)
  text(view, fit(label, chipW - view.u, size), view.u, math.floor((r[4] - size) / 2), WHITE, size, "bold")
  text(view, fit(m.baseName, view.W * 0.3, view.u), chipW + view.u, math.floor((r[4] - view.u) / 2), WHITE, view.u, "bold")
  local engaged, warned = 0, 0
  for _, t in ipairs(m.targets) do
    if t.action == "engage" then engaged = engaged + 1 elseif t.action == "warn" then warned = warned + 1 end
  end
  local right = ("%d target%s"):format(#m.targets, #m.targets == 1 and "" or "s")
  local rcol = GRAY
  if warned > 0 then right = right .. ("  %d warned"):format(warned) rcol = V.COLOR.warn end
  if engaged > 0 then right = right .. ("  %d ENGAGED"):format(engaged) rcol = V.COLOR.engage end
  if m.alarm.muted then right = "SIREN MUTED  " .. right end
  text(view, right, view.W - textWidth(right, view.u) - view.u, math.floor((r[4] - view.u) / 2), rcol, view.u, "plain")
end

local function drawTabs(view, m, r)
  rect(view, r, BG)
  local n = #V.TABS
  local gap = 3
  local w = math.floor((r[3] - gap * (n + 1)) / n)
  for i, tab in ipairs(V.TABS) do
    local x = gap + (i - 1) * (w + gap)
    local on = view.page == tab.id
    rect(view, { x, r[2] + 2, w, r[4] - 4 }, on and ACCENT or PANEL2)
    local label = tab.label
    if tab.id == "targets" and #m.targets > 0 then label = label .. " " .. #m.targets end
    label = fit(label, w - 6, view.u)
    text(view, label, x + math.floor((w - textWidth(label, view.u)) / 2), r[2] + math.floor((r[4] - view.u) / 2),
      on and BG or GRAY, view.u, "bold")
    addHit(view, x, r[2], w, r[4], { kind = "tab", page = tab.id })
  end
end

---------------------------------------------------------------- detail cards
local function targetCard(m, t)
  local lines = {}
  lines[#lines + 1] = { ("%s  /  %s"):format(t.cls or "?", STATUS_WORD[t.action] or t.action or "?"), GRAY }
  lines[#lines + 1] = { ("%d blocks %s%s"):format(math.floor(t.dist + 0.5), t.dir, t.inZone and "  IN ZONE" or ""),
    t.inZone and V.COLOR.warn or WHITE }
  if t.pos then
    lines[#lines + 1] = { ("x %d   y %d   z %d"):format(math.floor(t.pos.x), math.floor(t.pos.y), math.floor(t.pos.z)), GRAY }
  end
  if t.extra then
    lines[#lines + 1] = { (t.action == "warn" and "engaging in " or "time left ") .. t.extra, V.COLOR.warn }
  end
  if t.kind == "player" and t.name and m.history then
    local p = history.get(m.history, t.name)
    if p then
      lines[#lines + 1] = { ("%d visit%s, %s total"):format(p.visits, p.visits == 1 and "" or "s", D.format(history.totalMs(p))), GRAY }
      lines[#lines + 1] = { "last here " .. age(p.last, m.now) .. " ago", GRAY }
    else
      lines[#lines + 1] = { "first visit", GRAY }
    end
  end
  local who
  if t.kind == "player" and t.name and t.name:match("^[%w_]+$") then who = { name = t.name }
  elseif t.kind == "ship" then who = { name = tracker.short(t.id), ship = true } end
  return { title = t.label, color = V.COLOR[t.action] or WHITE, lines = lines, who = who }
end

local function playerCard(m, p)
  local lines = {}
  lines[#lines + 1] = { ("%s%s"):format(p.cls, p.here and "  - HERE NOW" or ""), p.here and V.COLOR.warn or GRAY }
  lines[#lines + 1] = { ("%d visit%s, %s total"):format(p.visits, p.visits == 1 and "" or "s", D.format(p.totalMs)), WHITE }
  lines[#lines + 1] = { "last here " .. age(p.last, m.now) .. " ago", GRAY }
  local h = m.history and history.get(m.history, p.name)
  if h then
    for i, v in ipairs(h.recent) do
      if i > 5 then break end
      lines[#lines + 1] = { ("%s  %s%s"):format(history.time(v.start, m.offset):sub(6), D.format(v.stop - v.start),
        v.zone and "  zone" or ""), DIM }
    end
  end
  return { title = p.name, color = V.LIST_COLOR[p.cls] or WHITE, lines = lines, who = { name = p.name } }
end

-- Card with text lines and the trust/visitor/hostile/forget buttons plus BACK.
local function drawCard(view, r, card)
  rect(view, r, PANEL)
  local u = view.u
  local x, y = r[1] + u, r[2] + math.floor(u * 0.6)
  local big = math.floor(u * 1.3)
  text(view, fit(card.title, r[3] - 2 * u, big), x, y, card.color, big, "bold")
  y = y + math.floor(u * 1.9)
  local bh = math.floor(u * 2)
  local rows = card.who and 3 or 1
  local top = r[2] + r[4] - rows * (bh + 4) - 2
  for _, l in ipairs(card.lines) do
    if y + u > top then break end
    text(view, fit(l[1], r[3] - 2 * u, u), x, y, l[2], u)
    y = y + math.floor(u * 1.35)
  end
  local bw = math.floor((r[3] - 3 * u) / 2)
  if card.who then
    local function cmd(action)
      if card.who.ship then return "ship " .. card.who.name .. " " .. action end
      return action .. " " .. card.who.name
    end
    button(view, "TRUST", x, top, bw, bh, { 38, 120, 72 }, { kind = "cmd", cmd = cmd("trust") })
    button(view, "VISITOR 30m", x + bw + u, top, bw, bh, { 48, 100, 155 }, { kind = "cmd", cmd = cmd("visitor 30m") })
    button(view, "HOSTILE", x, top + bh + 4, bw, bh, { 165, 48, 48 }, { kind = "cmd", cmd = cmd("hostile") })
    button(view, "FORGET", x + bw + u, top + bh + 4, bw, bh, { 85, 90, 105 }, { kind = "cmd", cmd = cmd("forget") })
  end
  button(view, "BACK", x, top + (rows - 1) * (bh + 4), r[3] - 2 * u, bh, { 58, 64, 86 }, { kind = "back" })
end

---------------------------------------------------------------- table
-- cols: { {label, w (fraction), align "l"|"r"}, ... }
-- rows: { {cells = { {text, color}, ... }, dot = color|nil, hit = {...}, selected = bool}, ... }
local function drawTable(view, r, cols, rows, emptyText)
  rect(view, r, BG)
  local u = view.u
  local rowH = math.floor(u * 1.9)
  local size = u
  local x0 = r[1] + u
  local inner = r[3] - 2 * u
  local xs = {}
  local acc = 0
  for i, c in ipairs(cols) do xs[i] = x0 + math.floor(acc * inner) acc = acc + c[2] end
  rect(view, { r[1], r[2], r[3], rowH }, PANEL2)
  for i, c in ipairs(cols) do
    local w = math.floor(c[2] * inner)
    local lbl = fit(c[1], w, size * 0.9)
    local tx = c[3] == "r" and (xs[i] + w - textWidth(lbl, size * 0.9) - 4) or (xs[i] + (i == 1 and 2 * u or 0))
    text(view, lbl, tx, r[2] + math.floor((rowH - size) / 2), GRAY, size * 0.9, "bold")
  end
  local y = r[2] + rowH + 2
  local maxRows = math.floor((r[2] + r[4] - y) / rowH)
  if #rows == 0 then
    text(view, emptyText or "nothing here", x0, y + 4, DIM, u)
    return
  end
  local shown = #rows > maxRows and maxRows - 1 or maxRows
  for i = 1, math.min(shown, #rows) do
    local row = rows[i]
    if row.selected then rect(view, { r[1], y, r[3], rowH - 2 }, PANEL2) end
    if row.dot then
      view.gpu.drawCircle(view.d, x0 + math.floor(u * 0.6), y + math.floor(rowH / 2) - 1, math.floor(u * 0.38),
        row.dot[1], row.dot[2], row.dot[3], true)
    end
    for ci, c in ipairs(cols) do
      local cell = row.cells[ci]
      if cell then
        local w = math.floor(c[2] * inner)
        local txt = fit(cell[1], w - (ci == 1 and 2 * u or 6), size)
        local tx = c[3] == "r" and (xs[ci] + w - textWidth(txt, size) - 4) or (xs[ci] + (ci == 1 and 2 * u or 0))
        text(view, txt, tx, y + math.floor((rowH - size) / 2) - 1, cell[2] or WHITE, size)
      end
    end
    addHit(view, r[1], y, r[3], rowH, row.hit)
    y = y + rowH
  end
  if #rows > shown then text(view, ("+%d more"):format(#rows - shown), x0, y + 2, DIM, u) end
end

local function findTarget(m, id)
  for _, t in ipairs(m.targets) do if t.id == id then return t end end
end

local function findPlayer(m, name)
  for _, p in ipairs(m.visitors) do if p.name == name then return p end end
end

---------------------------------------------------------------- page: radar
local function ringSteps(R)
  local out = {}
  for _, ring in ipairs({ 64, 128, 256, 512, 1024, 2048 }) do
    if ring < R * 0.96 then out[#out + 1] = ring end
  end
  return out
end

local function drawScope(view, m, r)
  rect(view, r, BG)
  local g, d = view.gpu, view.d
  local u = view.u
  local s = math.min(r[3], r[4]) - 3 * u
  local cx, cy = r[1] + math.floor(r[3] / 2), r[2] + math.floor(r[4] / 2)
  local rad = math.floor(s / 2)
  local c = m.zone and Z.center(m.zone) or { x = 0, z = 0 }
  local half = m.zone and ((m.zone.x2 - m.zone.x1) / 2) or 160
  local R = half * 1.6
  for _, t in ipairs(m.targets) do
    if t.dist * 1.08 > R and t.dist < 2000 then R = t.dist * 1.08 end
  end
  local k = rad / R
  -- scope face
  g.drawCircle(d, cx, cy, rad, SCOPE[1], SCOPE[2], SCOPE[3], true)
  g.drawLine(d, cx - rad, cy, cx + rad, cy, SCOPE_AXIS[1], SCOPE_AXIS[2], SCOPE_AXIS[3])
  g.drawLine(d, cx, cy - rad, cx, cy + rad, SCOPE_AXIS[1], SCOPE_AXIS[2], SCOPE_AXIS[3])
  for _, ring in ipairs(ringSteps(R)) do
    g.drawCircle(d, cx, cy, math.floor(ring * k), SCOPE_RING[1], SCOPE_RING[2], SCOPE_RING[3], false)
    text(view, tostring(ring), cx + 4, cy - math.floor(ring * k) + 2, SCOPE_RING, math.floor(u * 0.75))
  end
  g.drawCircle(d, cx, cy, rad, 50, 160, 95, false)
  -- compass letters outside the scope
  text(view, "N", cx - 4, cy - rad - u - 1, WHITE, u, "bold")
  text(view, "S", cx - 4, cy + rad + 2, GRAY, u)
  text(view, "W", cx - rad - u, cy - math.floor(u / 2), GRAY, u)
  text(view, "E", cx + rad + 4, cy - math.floor(u / 2), GRAY, u)
  -- no-go zone
  if m.zone then
    local zc = { 200, 70, 70 }
    local x1, y1 = math.floor(cx + (m.zone.x1 - c.x) * k), math.floor(cy + (m.zone.z1 - c.z) * k)
    local x2, y2 = math.floor(cx + (m.zone.x2 - c.x) * k), math.floor(cy + (m.zone.z2 - c.z) * k)
    g.drawLine(d, x1, y1, x2, y1, zc[1], zc[2], zc[3])
    g.drawLine(d, x2, y1, x2, y2, zc[1], zc[2], zc[3])
    g.drawLine(d, x2, y2, x1, y2, zc[1], zc[2], zc[3])
    g.drawLine(d, x1, y2, x1, y1, zc[1], zc[2], zc[3])
  end
  -- base
  local b = math.max(3, math.floor(u / 2))
  g.drawLine(d, cx - b, cy, cx + b, cy, WHITE[1], WHITE[2], WHITE[3])
  g.drawLine(d, cx, cy - b, cx, cy + b, WHITE[1], WHITE[2], WHITE[3])
  -- blips (worst last, so they are on top)
  for i = #m.targets, 1, -1 do
    local t = m.targets[i]
    if t.pos then
      local px, py = cx + (t.pos.x - c.x) * k, cy + (t.pos.z - c.z) * k
      local dx, dy = px - cx, py - cy
      local len = math.sqrt(dx * dx + dy * dy)
      local clamped = len > rad - 4
      if clamped then px, py = cx + dx / len * (rad - 4), cy + dy / len * (rad - 4) end
      px, py = math.floor(px + 0.5), math.floor(py + 0.5)
      local col = V.COLOR[t.action] or V.COLOR.ignore
      local br = math.max(3, math.floor(u * 0.45))
      if t.action == "engage" or t.action == "warn" then
        g.drawCircle(d, px, py, br + 4, col[1], col[2], col[3], false)
      end
      if t.id == view.selected then g.drawCircle(d, px, py, br + 7, WHITE[1], WHITE[2], WHITE[3], false) end
      g.drawCircle(d, px, py, br, col[1], col[2], col[3], not clamped)
      if t.action ~= "ignore" then
        local sz = math.floor(u * 0.85)
        local label = fit(t.label, 12 * sz * 0.6, sz)
        local lx = px + br + 4
        if lx + textWidth(label, sz) > r[1] + r[3] then lx = px - br - 4 - textWidth(label, sz) end
        text(view, label, lx, py - math.floor(sz / 2), col, sz)
      end
      addHit(view, px - br - 6, py - br - 6, 2 * br + 12, 2 * br + 12, { kind = "target", id = t.id })
    end
  end
end

local function drawRadarPage(view, m, r)
  local u = view.u
  local scopeW = math.min(r[3] - math.floor(view.W * 0.3), r[4] + 2 * u)
  scopeW = math.max(scopeW, math.floor(r[3] * 0.5))
  drawScope(view, m, { r[1], r[2], scopeW, r[4] })
  local side = { r[1] + scopeW, r[2], r[3] - scopeW, r[4] }
  local sel = view.selected and findTarget(m, view.selected)
  if view.selected and not sel then view.selected = nil end
  if sel then
    drawCard(view, side, targetCard(m, sel))
    return
  end
  rect(view, side, PANEL)
  text(view, "NEAREST", side[1] + u, side[2] + math.floor(u * 0.6), GRAY, u, "bold")
  local rowH = math.floor(u * 1.9)
  local y = side[2] + math.floor(u * 2)
  local rows = math.floor((side[2] + side[4] - y) / rowH)
  if #m.targets == 0 then
    text(view, "nothing in range", side[1] + u, y, DIM, u)
  end
  local shown = #m.targets > rows and rows - 1 or rows
  for i = 1, math.min(shown, #m.targets) do
    local t = m.targets[i]
    local col = V.COLOR[t.action] or V.COLOR.ignore
    view.gpu.drawCircle(view.d, side[1] + u, y + math.floor(rowH / 2) - 1, math.floor(u * 0.38), col[1], col[2], col[3], true)
    local right = ("%d%s"):format(math.floor(t.dist + 0.5), t.extra and (" " .. t.extra) or (t.inZone and " Z" or ""))
    local rw = textWidth(right, u)
    text(view, fit(t.label, side[3] - rw - 3 * u, u), side[1] + 2 * u, y + math.floor((rowH - u) / 2) - 1, col, u,
      t.action == "engage" and "bold" or "plain")
    text(view, right, side[1] + side[3] - rw - u, y + math.floor((rowH - u) / 2) - 1, WHITE, u)
    addHit(view, side[1], y, side[3], rowH, { kind = "target", id = t.id })
    y = y + rowH
  end
  if #m.targets > shown then text(view, ("+%d more"):format(#m.targets - shown), side[1] + u, y, DIM, u) end
end

---------------------------------------------------------------- page: targets
local function drawTargetsPage(view, m, r)
  local sel = view.selected and findTarget(m, view.selected)
  if view.selected and not sel then view.selected = nil end
  local tableR = r
  if sel then
    local cw = math.floor(r[3] * 0.42)
    tableR = { r[1], r[2], r[3] - cw, r[4] }
    drawCard(view, { r[1] + r[3] - cw, r[2], cw, r[4] }, targetCard(m, sel))
  end
  local cols
  if sel then
    cols = { { "NAME", 0.5 }, { "STATUS", 0.28 }, { "DIST", 0.22, "r" } }
  else
    cols = { { "NAME", 0.28 }, { "LIST", 0.14 }, { "STATUS", 0.14 }, { "DIST", 0.12, "r" }, { "DIR", 0.1, "r" },
      { "Y", 0.08, "r" }, { "TIME", 0.14, "r" } }
  end
  local rows = {}
  for _, t in ipairs(m.targets) do
    local col = V.COLOR[t.action] or V.COLOR.ignore
    local lc = V.LIST_COLOR[t.cls] or GRAY
    local dist = ("%d%s"):format(math.floor(t.dist + 0.5), t.inZone and " Z" or "")
    local cells
    if sel then
      cells = { { t.label, col }, { STATUS_WORD[t.action] or "?", col }, { dist, WHITE } }
    else
      cells = { { t.label, col }, { t.cls or "?", lc }, { STATUS_WORD[t.action] or "?", col }, { dist, WHITE },
        { t.dir, GRAY }, { t.pos and tostring(math.floor(t.pos.y)) or "", GRAY }, { t.extra or "", V.COLOR.warn } }
    end
    rows[#rows + 1] = { cells = cells, dot = col, hit = { kind = "target", id = t.id }, selected = t.id == view.selected }
  end
  drawTable(view, tableR, cols, rows, "nothing in range")
end

---------------------------------------------------------------- page: visitors
local function drawVisitorsPage(view, m, r)
  local sel = view.selectedPlayer and findPlayer(m, view.selectedPlayer)
  if view.selectedPlayer and not sel then view.selectedPlayer = nil end
  local tableR = r
  if sel then
    local cw = math.floor(r[3] * 0.42)
    tableR = { r[1], r[2], r[3] - cw, r[4] }
    drawCard(view, { r[1] + r[3] - cw, r[2], cw, r[4] }, playerCard(m, sel))
  end
  local cols
  if sel then
    cols = { { "NAME", 0.5 }, { "VISITS", 0.2, "r" }, { "TIME", 0.3, "r" } }
  else
    cols = { { "NAME", 0.3 }, { "LIST", 0.14 }, { "VISITS", 0.12, "r" }, { "TOTAL TIME", 0.22, "r" }, { "LAST HERE", 0.22, "r" } }
  end
  local rows = {}
  for _, p in ipairs(m.visitors) do
    local lc = V.LIST_COLOR[p.cls] or GRAY
    local cells
    if sel then
      cells = { { p.name, lc }, { tostring(p.visits), WHITE }, { D.format(p.totalMs), GRAY } }
    else
      cells = { { p.name, lc }, { p.cls, lc }, { tostring(p.visits), WHITE }, { D.format(p.totalMs), WHITE },
        { p.here and "now" or (age(p.last, m.now) .. " ago"), p.here and V.COLOR.warn or GRAY } }
    end
    rows[#rows + 1] = { cells = cells, dot = p.here and V.COLOR.warn or nil, hit = { kind = "player", name = p.name },
      selected = p.name == view.selectedPlayer }
  end
  drawTable(view, tableR, cols, rows, "no visits recorded yet")
  if not sel then
    text(view, ("%d known, %d visit%s in the last 24 h"):format(m.visitorCount, m.last24h, m.last24h == 1 and "" or "s"),
      r[1] + view.u, r[2] + r[4] - math.floor(view.u * 1.4), DIM, math.floor(view.u * 0.9))
  end
end

---------------------------------------------------------------- page: events
local function drawEventsPage(view, m, r)
  rect(view, r, BG)
  local u = view.u
  local rowH = math.floor(u * 1.45)
  local btnW = math.floor(u * 4)
  local rows = math.max(1, math.floor((r[4] - u) / rowH))
  local maxScroll = math.max(0, #m.log - rows)
  if view.logScroll > maxScroll then view.logScroll = maxScroll end
  local last = #m.log - view.logScroll
  local first = math.max(1, last - rows + 1)
  local y = r[2] + math.floor(u * 0.5)
  if #m.log == 0 then text(view, "no events yet", r[1] + u, y, DIM, u) end
  for i = first, last do
    local line = m.log[i]
    local bang = line:find("!", 1, true)
    local col = (bang and bang <= 9) and V.COLOR.warn or GRAY
    text(view, fit(line, r[3] - btnW - 3 * u, u), r[1] + u, y, col, u)
    y = y + rowH
  end
  local bx = r[1] + r[3] - btnW - u
  button(view, "UP", bx, r[2] + u, btnW, math.floor(u * 2.2), PANEL2, { kind = "scroll", delta = 5 })
  button(view, "DOWN", bx, r[2] + u + math.floor(u * 2.6), btnW, math.floor(u * 2.2), PANEL2, { kind = "scroll", delta = -5 })
  if view.logScroll > 0 then
    text(view, ("%d newer"):format(view.logScroll), bx - 2, r[2] + u + math.floor(u * 5.4), DIM, math.floor(u * 0.85))
  end
end

---------------------------------------------------------------- page: control
local function drawControlPage(view, m, r)
  rect(view, r, BG)
  local u = view.u
  local x, y = r[1] + u, r[2] + u
  local function line(s, col)
    text(view, fit(s, r[3] - 2 * u, u), x, y, col or WHITE, u)
    y = y + math.floor(u * 1.4)
  end
  line(m.alarm.muted and "Siren: MUTED" or "Siren: on", m.alarm.muted and V.COLOR.warn or V.COLOR.friendly)
  line(("Siren volume: %s of 3"):format(tostring(m.alarm.volume)), GRAY)
  line("Zone: " .. Z.describe(m.zone), GRAY)
  line(("Player detector range: %d blocks"):format(m.detectRange), GRAY)
  y = y + math.floor(u * 0.5)
  local bw = math.floor((r[3] - 3 * u) / 2)
  local bh = math.floor(u * 2.4)
  local vol = tonumber(m.alarm.volume) or 3
  local items = {
    { "MUTE SIREN 10m", "alarm mute 10m", { 160, 95, 30 } },
    { "SIREN ON", "alarm on", { 38, 120, 72 } },
    { "TEST SIREN", "alarm test", { 48, 100, 155 } },
    { "COMMANDS TO DISCORD", "commands discord", { 85, 90, 105 } },
    { "VOLUME -", "alarm volume " .. math.max(0, vol - 1), { 58, 64, 86 } },
    { "VOLUME +", "alarm volume " .. math.min(3, vol + 1), { 58, 64, 86 } },
  }
  for i, it in ipairs(items) do
    local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
    local bx, by = x + col * (bw + u), y + row * (bh + math.floor(u * 0.6))
    if by + bh <= r[2] + r[4] then
      button(view, it[1], bx, by, bw, bh, it[3], { kind = "cmd", cmd = it[2], stay = true })
    end
  end
end

---------------------------------------------------------------- frame
-- Draws one frame. The caller calls gpu.updateDisplay afterwards.
function V.draw(view, m)
  view.hits = {}
  V.prepare(view, m)
  local L = V.layout(view)
  view.gpu.clear(view.d, BG[1], BG[2], BG[3])
  drawStatus(view, m, L.status)
  drawTabs(view, m, L.tabs)
  local page = view.page
  if page == "targets" then drawTargetsPage(view, m, L.content)
  elseif page == "visitors" then drawVisitorsPage(view, m, L.content)
  elseif page == "events" then drawEventsPage(view, m, L.content)
  elseif page == "control" then drawControlPage(view, m, L.content)
  else drawRadarPage(view, m, L.content) end
end

---------------------------------------------------------------- touch
function V.hit(view, x, y)
  for i = #view.hits, 1, -1 do
    local h = view.hits[i]
    if x >= h.x and x < h.x + h.w and y >= h.y and y < h.y + h.h then return h end
  end
end

-- Handles a tap. Returns action, changed:
--   action = { type = "cmd", cmd = "trust Bob" } or nil
--   changed = true when the screen state changed (selection, tab, scroll)
function V.click(view, x, y, now)
  local h = V.hit(view, x, y)
  if not h then return nil, false end
  if h.kind == "tab" then
    view.page, view.selected, view.selectedPlayer, view.logScroll = h.page, nil, nil, 0
    return nil, true
  elseif h.kind == "target" then
    view.selected, view.selectedAt = h.id, now
    return nil, true
  elseif h.kind == "player" then
    view.selectedPlayer, view.selectedAt = h.name, now
    return nil, true
  elseif h.kind == "back" then
    view.selected, view.selectedPlayer = nil, nil
    return nil, true
  elseif h.kind == "scroll" then
    view.logScroll = math.max(0, view.logScroll + h.delta)
    return nil, true
  elseif h.kind == "cmd" then
    if not h.stay then view.selected, view.selectedPlayer = nil, nil end
    return { type = "cmd", cmd = h.cmd }, true
  end
  return nil, false
end

return V
