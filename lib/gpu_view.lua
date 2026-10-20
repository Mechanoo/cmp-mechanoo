-- Radar screen for a DirectGPU display, with touch tabs:
--   RADAR     round scope with a FIXED range (zoom buttons) + contact list
--             (tap a blip or a row for details and buttons)
--   TARGETS   table of everything the radar sees
--   VISITORS  who was here, how often, how long (tap a name for the history and buttons)
--   EVENTS    the radar log, scrollable
--   CONTROL   siren, zone and sensor settings
-- A header with the base level stays visible on every tab.
--
-- Pure drawing logic: `gpu` is the DirectGPU peripheral (or any table with the same
-- methods), so it is tested with a mock. All sizes follow the display's pixel size,
-- and the layout never depends on the targets (nothing jumps when a target moves).
-- Unverified in game (see the "screen" commands): that drawText's y is the top of the
-- text, and that touch events carry pixel coordinates in .x/.y.
local Z = require("lib.zone")
local D = require("lib.duration")
local history = require("lib.history")
local lists = require("lib.lists")
local tracker = require("lib.tracker")

local V = {}

V.COLOR = {
  engage = { 240, 72, 72 }, warn = { 250, 160, 50 }, watch = { 238, 210, 90 },
  friendly = { 80, 210, 120 }, pending = { 160, 166, 184 }, ignore = { 96, 102, 120 },
}
V.LIST_COLOR = {
  trusted = { 80, 210, 120 }, visitor = { 95, 170, 245 }, hostile = { 240, 72, 72 }, unknown = { 160, 166, 184 },
}
V.LEVEL = { { 34, 140, 84 }, { 40, 120, 160 }, { 196, 160, 36 }, { 222, 118, 32 }, { 210, 44, 44 } }
V.TABS = {
  { id = "radar", label = "RADAR" }, { id = "targets", label = "TARGETS" }, { id = "visitors", label = "VISITORS" },
  { id = "events", label = "EVENTS" }, { id = "control", label = "CONTROL" },
}
-- zoom steps of the scope (blocks from the base centre to the rim)
V.RANGES = { 64, 128, 256, 512, 1024 }
V.DEFAULT_RANGE = 256

local BG, PANEL, PANEL2, LINE = { 10, 12, 18 }, { 19, 23, 33 }, { 28, 33, 47 }, { 40, 46, 64 }
local ZEBRA = { 14, 17, 25 }
local WHITE, GRAY, DIM = { 234, 237, 245 }, { 156, 163, 182 }, { 98, 105, 126 }
local ACCENT = { 72, 168, 230 }
local SCOPE, SCOPE_RING, SCOPE_AXIS, SCOPE_RIM = { 8, 22, 16 }, { 30, 92, 58 }, { 20, 56, 38 }, { 56, 160, 98 }
local ZONE_FILL, ZONE_LINE = { 46, 16, 20 }, { 196, 64, 64 }
local ORDER = { engage = 1, warn = 2, watch = 3, friendly = 4, pending = 5, ignore = 6 }
local STATUS_WORD = { engage = "ENGAGE", warn = "COUNTDOWN", watch = "SEEN", friendly = "OK", pending = "CHECKING", ignore = "-" }
local BTN = {
  trust = { 34, 120, 74 }, visitor = { 44, 98, 156 }, hostile = { 166, 46, 46 }, neutral = { 62, 68, 90 },
  warn = { 168, 98, 28 },
}

V.SELECT_TIMEOUT_MS = 30000

local atan2 = math.atan2 or math.atan

-- N, NE, E ... from the base centre (north = -z)
local function compass(dx, dz)
  local deg = math.deg(atan2(dx, -dz)) % 360
  local names = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
  return names[math.floor((deg + 22.5) / 45) % 8 + 1]
end

function V.validRange(r)
  r = tonumber(r)
  for _, x in ipairs(V.RANGES) do if x == r then return r end end
  return nil
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
      pos = t.pos, vel = t.vel, dist = cfg.zone and t.pos and Z.distance(cfg.zone, t.pos) or 0,
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
    clock = history.time(a.now, cfg.timeOffsetHours):sub(-5),
    alarm = { muted = muted, volume = cfg.alarmVolume or 3, mutedUntil = cfg.alarmMuteUntil },
    detectRange = cfg.detectRange or 512,
    range = V.validRange(cfg.screenRange) or V.DEFAULT_RANGE,
  }
end

-- Changes whenever something visible changes (to skip needless redraws).
function V.signature(model, view)
  local parts = { model.level and model.level.n or 0, #model.log, model.log[#model.log] or "", model.last24h,
    model.visitorCount, view and view.selected or "-", view and view.selectedPlayer or "-", view and view.page or "",
    view and view.logScroll or 0, model.alarm.muted and 1 or 0, model.alarm.volume, model.range, model.clock }
  local cell = math.max(2, model.range / 48) -- about one blip size on the scope
  for _, t in ipairs(model.targets) do
    local px, pz = 0, 0
    if t.pos then px, pz = math.floor(t.pos.x / cell), math.floor(t.pos.z / cell) end
    parts[#parts + 1] = table.concat({ t.id, t.action, t.cls, t.label, math.floor(t.dist / 8), px, pz,
      t.inZone and 1 or 0, t.extra or "" }, ":")
  end
  for _, p in ipairs(model.visitors) do
    parts[#parts + 1] = p.name .. p.visits .. math.floor(p.totalMs / 60000) .. p.cls .. (p.here and "h" or "")
  end
  if model.level and model.level.n >= 5 then parts[#parts + 1] = math.floor(model.now / 1000) % 2 end
  return table.concat(parts, "|")
end

---------------------------------------------------------------- view state
-- opts.rounded: the GPU has drawRoundedRect (checked by gpu_screen when it attaches)
function V.new(gpu, display, info, opts)
  opts = opts or {}
  local W = tonumber(info and (info.pixelWidth or info.width)) or 512
  local H = tonumber(info and (info.pixelHeight or info.height)) or 256
  local u = math.max(8, math.floor(math.min(H / 26, W / 44)))
  return { gpu = gpu, d = display, W = W, H = H, u = u, font = opts.font or "SansSerif", hits = {},
    rounded = opts.rounded or false,
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
  local sh = math.max(view.u * 2, math.floor(H * 0.1))
  local th = math.max(math.floor(view.u * 1.8), math.floor(H * 0.075))
  local y0 = sh + th
  return {
    status = { 0, 0, W, sh }, tabs = { 0, sh, W, th },
    content = { 0, y0, W, H - y0 },
  }
end

---------------------------------------------------------------- drawing helpers
local function rect(view, r, col)
  view.gpu.fillRect(view.d, math.floor(r[1]), math.floor(r[2]), math.floor(r[3]), math.floor(r[4]), col[1], col[2], col[3])
end

-- filled box, rounded when the GPU can do it
local function box(view, x, y, w, h, col, radius)
  x, y, w, h = math.floor(x), math.floor(y), math.floor(w), math.floor(h)
  if view.rounded then
    view.gpu.drawRoundedRect(view.d, x, y, w, h, radius or math.max(3, math.floor(view.u * 0.35)), col[1], col[2], col[3], true)
  else
    view.gpu.fillRect(view.d, x, y, w, h, col[1], col[2], col[3])
  end
end

local function line(view, x1, y1, x2, y2, col)
  view.gpu.drawLine(view.d, math.floor(x1), math.floor(y1), math.floor(x2), math.floor(y2), col[1], col[2], col[3])
end

local function circle(view, x, y, r, col, filled)
  view.gpu.drawCircle(view.d, math.floor(x), math.floor(y), math.max(1, math.floor(r)), col[1], col[2], col[3], filled)
end

local function text(view, str, x, y, col, size, style)
  view.gpu.drawText(view.d, str, math.floor(x), math.floor(y), col[1], col[2], col[3], view.font,
    math.floor(size or view.u), style or "plain")
end

-- rough text width (no measureText call per string: every GPU call costs time)
local function textWidth(str, size, bold)
  return math.floor(#tostring(str) * size * (bold and 0.62 or 0.56))
end

local function fit(str, px, size, bold)
  str = tostring(str)
  local n = math.max(1, math.floor(px / (size * (bold and 0.62 or 0.56))))
  if #str <= n then return str end
  return str:sub(1, math.max(1, n - 1)) .. "~"
end

local function addHit(view, x, y, w, h, hit)
  hit.x, hit.y, hit.w, hit.h = math.floor(x), math.floor(y), math.floor(w), math.floor(h)
  view.hits[#view.hits + 1] = hit
end

local function button(view, label, x, y, w, h, col, hit, size)
  box(view, x, y, w, h, col)
  size = size or view.u
  local label2 = fit(label, w - 8, size, true)
  text(view, label2, x + (w - textWidth(label2, size, true)) / 2, y + (h - size) / 2, WHITE, size, "bold")
  addHit(view, x, y, w, h, hit)
end

-- small coloured tag, right-aligned at xRight; returns its left edge
local function chip(view, str, xRight, y, h, col)
  local size = math.floor(view.u * 0.8)
  local w = textWidth(str, size, true) + math.floor(view.u * 0.9)
  local x = xRight - w
  box(view, x, y, w, h, { math.floor(col[1] * 0.28), math.floor(col[2] * 0.28), math.floor(col[3] * 0.28) },
    math.floor(h / 2))
  text(view, str, x + (w - textWidth(str, size, true)) / 2, y + (h - size) / 2, col, size, "bold")
  return x
end

local function age(ms, now) return D.format(math.max(0, now - ms)) end

local function heading(view, str, x, y)
  text(view, str, x, y, DIM, math.floor(view.u * 0.78), "bold")
end

---------------------------------------------------------------- header + tab bar
local function drawStatus(view, m, r)
  local u = view.u
  local lv = m.level
  local n = lv and lv.n or 1
  local col = V.LEVEL[n] or V.LEVEL[1]
  local blink = n >= 5 and math.floor(m.now / 1000) % 2 == 0
  rect(view, r, PANEL)
  rect(view, { 0, r[4] - 2, r[3], 2 }, blink and V.COLOR.engage or col)
  -- level block: small "LEVEL n" above the big label
  local pad = math.floor(u * 0.4)
  local big = math.floor(u * 1.25)
  local small = math.floor(u * 0.7)
  local label = lv and lv.label or "NO DATA"
  local chipW = math.max(math.floor(view.W * 0.2), textWidth(label, big, true) + 2 * u)
  local blockH = r[4] - 2 * pad - 2
  box(view, pad, pad, chipW, blockH, blink and { 120, 20, 20 } or col)
  local ty = pad + (blockH - big - small - 2) / 2
  text(view, lv and ("LEVEL " .. lv.n) or "LEVEL -", pad + u * 0.6, ty, WHITE, small, "bold")
  text(view, fit(label, chipW - u, big, true), pad + u * 0.6, ty + small + 2, WHITE, big, "bold")
  -- base name
  local x = pad + chipW + u
  local name = fit(m.baseName, view.W * 0.3, big, true)
  text(view, name, x, (r[4] - big) / 2 - 1, WHITE, big, "bold")
  local nameEnd = x + textWidth(name, big, true) + u
  -- right side: clock, then chips, then the contact count
  local right = view.W - u
  local clockSize = math.floor(u * 1.1)
  text(view, m.clock, right - textWidth(m.clock, clockSize), (r[4] - clockSize) / 2 - 1, GRAY, clockSize)
  right = right - textWidth(m.clock, clockSize) - u
  local engaged, warned = 0, 0
  for _, t in ipairs(m.targets) do
    if t.action == "engage" then engaged = engaged + 1 elseif t.action == "warn" then warned = warned + 1 end
  end
  local ch = math.floor(u * 1.35)
  local cy = (r[4] - ch) / 2 - 1
  if m.alarm.muted then right = chip(view, "SIREN MUTED", right, cy, ch, V.COLOR.warn) - pad end
  if engaged > 0 then right = chip(view, engaged .. " ENGAGED", right, cy, ch, V.COLOR.engage) - pad end
  if warned > 0 then right = chip(view, warned .. " COUNTDOWN", right, cy, ch, V.COLOR.warn) - pad end
  local cnt = ("%d contact%s"):format(#m.targets, #m.targets == 1 and "" or "s")
  if right - textWidth(cnt, u) > nameEnd then
    text(view, cnt, right - textWidth(cnt, u), (r[4] - u) / 2 - 1, GRAY, u)
  end
end

local function drawTabs(view, m, r)
  rect(view, r, BG)
  local n = #V.TABS
  local w = math.floor(r[3] / n)
  local size = math.floor(view.u * 0.95)
  for i, tab in ipairs(V.TABS) do
    local x = (i - 1) * w
    local on = view.page == tab.id
    if on then
      rect(view, { x, r[2], w, r[4] }, PANEL2)
      rect(view, { x, r[2] + r[4] - 3, w, 3 }, ACCENT)
    end
    local label = tab.label
    if tab.id == "targets" and #m.targets > 0 then label = label .. " " .. #m.targets end
    label = fit(label, w - 6, size, true)
    text(view, label, x + (w - textWidth(label, size, true)) / 2, r[2] + (r[4] - size) / 2 - 1,
      on and WHITE or GRAY, size, "bold")
    addHit(view, x, r[2], w, r[4], { kind = "tab", page = tab.id })
  end
  rect(view, { 0, r[2] + r[4] - 1, r[3], 1 }, LINE)
end

---------------------------------------------------------------- detail cards
local function targetCard(m, t)
  local lines = {}
  lines[#lines + 1] = { (t.cls or "?") .. "  /  " .. (STATUS_WORD[t.action] or t.action or "?"), V.LIST_COLOR[t.cls] or GRAY }
  lines[#lines + 1] = { ("%d blocks %s%s"):format(math.floor(t.dist + 0.5), t.dir, t.inZone and "  IN ZONE" or ""),
    t.inZone and V.COLOR.warn or WHITE }
  if t.pos then
    lines[#lines + 1] = { ("x %d   y %d   z %d"):format(math.floor(t.pos.x), math.floor(t.pos.y), math.floor(t.pos.z)), GRAY }
  end
  if t.vel then
    local sp = math.sqrt(t.vel.x * t.vel.x + t.vel.z * t.vel.z) * 20
    if sp >= 1 then lines[#lines + 1] = { ("moving %d blocks/s"):format(math.floor(sp + 0.5)), GRAY } end
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
  lines[#lines + 1] = { ("%s%s"):format(p.cls, p.here and "  - HERE NOW" or ""), p.here and V.COLOR.warn or (V.LIST_COLOR[p.cls] or GRAY) }
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
  local u = view.u
  rect(view, r, PANEL)
  rect(view, { r[1], r[2], 4, r[4] }, card.color)
  local x, y = r[1] + u + 4, r[2] + math.floor(u * 0.7)
  local big = math.floor(u * 1.4)
  text(view, fit(card.title, r[3] - 2 * u - 4, big, true), x, y, card.color, big, "bold")
  y = y + math.floor(u * 2.1)
  local bh = math.floor(u * 2.2)
  local gap = math.floor(u * 0.4)
  local rows = card.who and 3 or 1
  local top = r[2] + r[4] - rows * (bh + gap) - math.floor(u * 0.4)
  for _, l in ipairs(card.lines) do
    if y + u > top - gap then break end
    text(view, fit(l[1], r[3] - 2 * u - 4, u), x, y, l[2], u)
    y = y + math.floor(u * 1.4)
  end
  local inner = r[3] - 2 * u - 4
  local bw = math.floor((inner - gap) / 2)
  if card.who then
    local function cmd(action)
      if card.who.ship then return "ship " .. card.who.name .. " " .. action end
      return action .. " " .. card.who.name
    end
    button(view, "TRUST", x, top, bw, bh, BTN.trust, { kind = "cmd", cmd = cmd("trust") })
    button(view, "VISITOR 30m", x + bw + gap, top, bw, bh, BTN.visitor, { kind = "cmd", cmd = cmd("visitor 30m") })
    button(view, "HOSTILE", x, top + bh + gap, bw, bh, BTN.hostile, { kind = "cmd", cmd = cmd("hostile") })
    button(view, "FORGET", x + bw + gap, top + bh + gap, bw, bh, BTN.neutral, { kind = "cmd", cmd = cmd("forget") })
  end
  button(view, "BACK", x, top + (rows - 1) * (bh + gap), inner, bh, PANEL2, { kind = "back" })
end

---------------------------------------------------------------- table
-- cols: { {label, w (fraction), align "l"|"r"}, ... }
-- rows: { {cells = { {text, color, style}, ... }, dot = color|nil, hit = {...}, selected = bool}, ... }
local function drawTable(view, r, cols, rows, emptyText, footer)
  rect(view, r, BG)
  local u = view.u
  local rowH = math.floor(u * 2)
  local size = u
  local hs = math.floor(u * 0.78)
  local x0 = r[1] + u
  local inner = r[3] - 2 * u
  local xs = {}
  local acc = 0
  for i, c in ipairs(cols) do xs[i] = x0 + math.floor(acc * inner) acc = acc + c[2] end
  local headH = math.floor(u * 1.7)
  for i, c in ipairs(cols) do
    local w = math.floor(c[2] * inner)
    local lbl = fit(c[1], w, hs, true)
    local tx = c[3] == "r" and (xs[i] + w - textWidth(lbl, hs, true) - 4) or (xs[i] + (i == 1 and 2 * u or 0))
    text(view, lbl, tx, r[2] + (headH - hs) / 2, DIM, hs, "bold")
  end
  rect(view, { r[1] + u, r[2] + headH - 1, r[3] - 2 * u, 1 }, LINE)
  local y = r[2] + headH + 2
  local bottom = r[2] + r[4] - (footer and math.floor(u * 1.6) or 0)
  local maxRows = math.max(1, math.floor((bottom - y) / rowH))
  if #rows == 0 then
    text(view, emptyText or "nothing here", x0, y + u * 0.5, DIM, u)
  end
  local shown = #rows > maxRows and maxRows - 1 or maxRows
  for i = 1, math.min(shown, #rows) do
    local row = rows[i]
    if row.selected then rect(view, { r[1], y, r[3], rowH - 1 }, PANEL2)
    elseif i % 2 == 0 then rect(view, { r[1], y, r[3], rowH - 1 }, ZEBRA) end
    if row.dot then circle(view, x0 + u * 0.6, y + rowH / 2 - 1, u * 0.36, row.dot, true) end
    for ci, c in ipairs(cols) do
      local cell = row.cells[ci]
      if cell then
        local w = math.floor(c[2] * inner)
        local bold = cell[3] == "bold"
        local txt = fit(cell[1], w - (ci == 1 and 2 * u or 6), size, bold)
        local tx = c[3] == "r" and (xs[ci] + w - textWidth(txt, size, bold) - 4) or (xs[ci] + (ci == 1 and 2 * u or 0))
        text(view, txt, tx, y + (rowH - size) / 2 - 1, cell[2] or WHITE, size, cell[3])
      end
    end
    addHit(view, r[1], y, r[3], rowH, row.hit)
    y = y + rowH
  end
  if #rows > shown then text(view, ("+%d more"):format(#rows - shown), x0, y + 2, DIM, math.floor(u * 0.85)) end
  if footer then text(view, footer, x0, r[2] + r[4] - math.floor(u * 1.35), DIM, math.floor(u * 0.85)) end
end

local function findTarget(m, id)
  for _, t in ipairs(m.targets) do if t.id == id then return t end end
end

local function findPlayer(m, name)
  for _, p in ipairs(m.visitors) do if p.name == name then return p end end
end

---------------------------------------------------------------- page: radar
local function overlaps(boxes, b)
  for _, o in ipairs(boxes) do
    if b[1] < o[1] + o[3] and o[1] < b[1] + b[3] and b[2] < o[2] + o[4] and o[2] < b[2] + b[4] then return true end
  end
  return false
end

local function rangeIndex(range)
  for i, x in ipairs(V.RANGES) do if x == range then return i end end
  return 3
end

local function drawScope(view, m, r)
  rect(view, r, BG)
  local u = view.u
  local cx, cy = r[1] + math.floor(r[3] / 2), r[2] + math.floor(r[4] / 2)
  local rad = math.floor(math.min(r[3], r[4]) / 2 - u * 1.3)
  local c = m.zone and Z.center(m.zone) or { x = 0, z = 0 }
  local R = m.range
  local k = rad / R
  -- scope face
  circle(view, cx, cy, rad, SCOPE, true)
  -- no-go zone (only when it fits inside the scope)
  if m.zone then
    local x1, y1 = cx + (m.zone.x1 - c.x) * k, cy + (m.zone.z1 - c.z) * k
    local x2, y2 = cx + (m.zone.x2 + 1 - c.x) * k, cy + (m.zone.z2 + 1 - c.z) * k
    if x2 - x1 >= 2 and x2 - x1 <= rad * 1.4 then
      rect(view, { x1, y1, x2 - x1, y2 - y1 }, ZONE_FILL)
      line(view, x1, y1, x2, y1, ZONE_LINE)
      line(view, x2, y1, x2, y2, ZONE_LINE)
      line(view, x2, y2, x1, y2, ZONE_LINE)
      line(view, x1, y2, x1, y1, ZONE_LINE)
    end
  end
  -- axes and rings at a quarter of the range each
  line(view, cx - rad, cy, cx + rad, cy, SCOPE_AXIS)
  line(view, cx, cy - rad, cx, cy + rad, SCOPE_AXIS)
  local rs = math.floor(u * 0.7)
  for q = 1, 3 do
    local rr = math.floor(rad * q / 4)
    circle(view, cx, cy, rr, SCOPE_RING, false)
    local lbl = tostring(math.floor(R * q / 4))
    local off = math.floor(rr * 0.7071)
    text(view, lbl, cx + off + 2, cy - off - rs - 1, SCOPE_RING, rs)
  end
  circle(view, cx, cy, rad, SCOPE_RIM, false)
  -- ticks every 30 degrees on the rim
  for a = 0, 330, 30 do
    local s, co = math.sin(math.rad(a)), -math.cos(math.rad(a))
    local inner = a % 90 == 0 and rad - u * 0.7 or rad - u * 0.4
    line(view, cx + s * inner, cy + co * inner, cx + s * rad, cy + co * rad, SCOPE_RIM)
  end
  -- compass letters just outside the rim
  local cs = math.floor(u * 0.9)
  text(view, "N", cx - cs * 0.3, cy - rad - cs - 1, WHITE, cs, "bold")
  text(view, "S", cx - cs * 0.3, cy + rad + 2, GRAY, cs)
  text(view, "W", cx - rad - cs - 1, cy - cs / 2, GRAY, cs)
  text(view, "E", cx + rad + 3, cy - cs / 2, GRAY, cs)
  -- base
  local b = math.max(3, math.floor(u / 2))
  line(view, cx - b, cy, cx + b, cy, WHITE)
  line(view, cx, cy - b, cx, cy + b, WHITE)
  -- blips (worst last, so they are on top); targets beyond the range sit hollow on the rim
  local placed, blips = {}, {}
  for i = #m.targets, 1, -1 do
    local t = m.targets[i]
    if t.pos then
      local px, py = cx + (t.pos.x - c.x) * k, cy + (t.pos.z - c.z) * k
      local dx, dy = px - cx, py - cy
      local len = math.sqrt(dx * dx + dy * dy)
      local outside = len > rad - 4
      if outside then px, py = cx + dx / len * (rad - 4), cy + dy / len * (rad - 4) end
      px, py = math.floor(px + 0.5), math.floor(py + 0.5)
      local col = V.COLOR[t.action] or V.COLOR.ignore
      local br = math.max(3, math.floor(u * 0.42))
      -- heading: where it will be in 5 s (velocity is blocks per tick)
      if t.vel and not outside then
        local vx, vz = t.vel.x * 100 * k, t.vel.z * 100 * k
        local vl = math.sqrt(vx * vx + vz * vz)
        if vl >= br + 2 then
          if vl > rad / 2 then vx, vz = vx / vl * rad / 2, vz / vl * rad / 2 end
          line(view, px, py, px + vx, py + vz, col)
        end
      end
      if t.action == "engage" or t.action == "warn" then circle(view, px, py, br + 4, col, false) end
      if t.id == view.selected then circle(view, px, py, br + 7, WHITE, false) end
      if t.kind == "ship" then -- ships are squares, players dots
        if outside then
          line(view, px - br, py - br, px + br, py - br, col)
          line(view, px + br, py - br, px + br, py + br, col)
          line(view, px + br, py + br, px - br, py + br, col)
          line(view, px - br, py + br, px - br, py - br, col)
        else
          rect(view, { px - br, py - br, 2 * br + 1, 2 * br + 1 }, col)
        end
      else
        circle(view, px, py, br, col, not outside)
      end
      placed[#placed + 1] = { px - br - 2, py - br - 2, 2 * br + 4, 2 * br + 4 }
      blips[#blips + 1] = { t = t, px = px, py = py, br = br, col = col, outside = outside }
      addHit(view, px - br - 6, py - br - 6, 2 * br + 12, 2 * br + 12, { kind = "target", id = t.id })
    end
  end
  -- labels, most important first; a label that fits nowhere is left out (the blip stays)
  local sz = math.floor(u * 0.8)
  for i = #blips, 1, -1 do
    local bl = blips[i]
    if bl.t.action ~= "ignore" then
      local label = fit(bl.t.label, 11 * sz * 0.56, sz)
      if bl.outside then label = label .. " " .. math.floor(bl.t.dist + 0.5) end
      local w, h = textWidth(label, sz), sz + 2
      local g = bl.br + 3
      local spots = {
        { bl.px + g, bl.py - h / 2 }, { bl.px - g - w, bl.py - h / 2 },
        { bl.px - w / 2, bl.py - g - h }, { bl.px - w / 2, bl.py + g },
      }
      for _, s in ipairs(spots) do
        local bx = { s[1], s[2], w, h }
        if s[1] >= r[1] and s[1] + w <= r[1] + r[3] and s[2] >= r[2] and s[2] + h <= r[2] + r[4]
            and not overlaps(placed, bx) then
          placed[#placed + 1] = bx
          text(view, label, s[1], s[2] + 1, bl.col, sz)
          break
        end
      end
    end
  end
  -- zoom: [-] range [+] in the lower left corner
  local zs = math.floor(u * 1.9)
  local zy = r[2] + r[4] - zs - math.floor(u * 0.3)
  local zx = r[1] + math.floor(u * 0.3)
  local ri = rangeIndex(R)
  local function zoomBtn(lbl, x, idx)
    local to = V.RANGES[idx]
    button(view, lbl, x, zy, zs, zs, to and PANEL2 or PANEL,
      to and { kind = "cmd", cmd = "screen range " .. to, stay = true } or { kind = "none" }, math.floor(u * 1.2))
  end
  zoomBtn("-", zx, ri + 1) -- "-" shows more area
  local rl = R .. " m"
  local rlw = textWidth("1024 m", u) + u
  text(view, rl, zx + zs + (rlw - textWidth(rl, u)) / 2, zy + (zs - u) / 2, GRAY, u)
  zoomBtn("+", zx + zs + rlw, ri - 1)
end

local function contactRow(view, t, x, y, w, h)
  local u = view.u
  local col = V.COLOR[t.action] or V.COLOR.ignore
  rect(view, { x, y + 2, 3, h - 4 }, col)
  local sub = math.floor(u * 0.85)
  local word = STATUS_WORD[t.action] or "?"
  if t.action == "warn" and t.extra then word = t.extra end
  local ch = math.floor(u * 1.3)
  local cl = chip(view, word, x + w - math.floor(u * 0.4), y + (h - ch) / 2, ch, col)
  local tx = x + u * 0.7
  text(view, fit(t.label, cl - tx - u * 0.5, u, true), tx, y + h / 2 - u - 1, WHITE, u, "bold")
  local info = ("%d m %s"):format(math.floor(t.dist + 0.5), t.dir)
  if t.inZone then info = info .. "  IN ZONE" end
  if t.cls and t.cls ~= "?" then info = info .. "  " .. t.cls end
  text(view, fit(info, cl - tx - u * 0.5, sub), tx, y + h / 2 + 1, t.inZone and V.COLOR.warn or GRAY, sub)
end

local function drawRadarPage(view, m, r)
  local u = view.u
  local scopeW = math.max(math.floor(r[3] * 0.5), math.min(r[3] - math.floor(view.W * 0.34), r[4]))
  drawScope(view, m, { r[1], r[2], scopeW, r[4] })
  local side = { r[1] + scopeW, r[2], r[3] - scopeW, r[4] }
  local sel = view.selected and findTarget(m, view.selected)
  if view.selected and not sel then view.selected = nil end
  if sel then
    drawCard(view, side, targetCard(m, sel))
    return
  end
  rect(view, side, PANEL)
  heading(view, "CONTACTS", side[1] + u, side[2] + math.floor(u * 0.6))
  local rowH = math.floor(u * 2.5)
  local y = side[2] + math.floor(u * 1.9)
  local rows = math.max(1, math.floor((side[2] + side[4] - y) / rowH))
  if #m.targets == 0 then
    text(view, "nothing in range", side[1] + u, y + u * 0.3, DIM, u)
  end
  local shown = #m.targets > rows and rows - 1 or rows
  for i = 1, math.min(shown, #m.targets) do
    local t = m.targets[i]
    contactRow(view, t, side[1] + math.floor(u * 0.5), y, side[3] - u, rowH - 2)
    addHit(view, side[1], y, side[3], rowH, { kind = "target", id = t.id })
    y = y + rowH
  end
  if #m.targets > shown then text(view, ("+%d more"):format(#m.targets - shown), side[1] + u, y + 2, DIM, math.floor(u * 0.85)) end
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
    cols = { { "NAME", 0.27 }, { "LIST", 0.13 }, { "STATUS", 0.16 }, { "DIST", 0.11, "r" }, { "DIR", 0.08, "r" },
      { "Y", 0.1, "r" }, { "TIME", 0.15, "r" } }
  end
  local rows = {}
  for _, t in ipairs(m.targets) do
    local col = V.COLOR[t.action] or V.COLOR.ignore
    local lc = V.LIST_COLOR[t.cls] or GRAY
    local dist = tostring(math.floor(t.dist + 0.5))
    local cells
    if sel then
      cells = { { t.label, WHITE, "bold" }, { STATUS_WORD[t.action] or "?", col }, { dist, WHITE } }
    else
      cells = { { t.label, WHITE, "bold" }, { t.cls or "?", lc }, { STATUS_WORD[t.action] or "?", col },
        { dist, t.inZone and V.COLOR.warn or WHITE }, { t.dir, GRAY }, { t.pos and tostring(math.floor(t.pos.y)) or "", GRAY },
        { t.extra or "", V.COLOR.warn } }
    end
    rows[#rows + 1] = { cells = cells, dot = col, hit = { kind = "target", id = t.id }, selected = t.id == view.selected }
  end
  drawTable(view, tableR, cols, rows, "nothing in range", not sel and "orange distance = inside the no-go zone" or nil)
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
      cells = { { p.name, WHITE, "bold" }, { tostring(p.visits), WHITE }, { D.format(p.totalMs), GRAY } }
    else
      cells = { { p.name, WHITE, "bold" }, { p.cls, lc }, { tostring(p.visits), WHITE }, { D.format(p.totalMs), WHITE },
        { p.here and "here now" or (age(p.last, m.now) .. " ago"), p.here and V.COLOR.warn or GRAY } }
    end
    rows[#rows + 1] = { cells = cells, dot = lc, hit = { kind = "player", name = p.name },
      selected = p.name == view.selectedPlayer }
  end
  local footer = not sel and ("%d known, %d visit%s in the last 24 h"):format(m.visitorCount, m.last24h,
    m.last24h == 1 and "" or "s") or nil
  drawTable(view, tableR, cols, rows, "no visits recorded yet", footer)
end

---------------------------------------------------------------- page: events
local function drawEventsPage(view, m, r)
  rect(view, r, BG)
  local u = view.u
  local rowH = math.floor(u * 1.55)
  local btnW = math.floor(u * 4.2)
  local top = r[2] + math.floor(u * 0.4)
  local rows = math.max(1, math.floor((r[4] - u * 0.8) / rowH))
  local maxScroll = math.max(0, #m.log - rows)
  if view.logScroll > maxScroll then view.logScroll = maxScroll end
  local last = #m.log - view.logScroll
  local first = math.max(1, last - rows + 1)
  local y = top
  if #m.log == 0 then text(view, "no events yet", r[1] + u, y + u * 0.3, DIM, u) end
  local textW = r[3] - btnW - 3 * u
  for i = first, last do
    local ln = m.log[i]
    local stamp, rest = ln:match("^(%[[^%]]+%])%s?(.*)$")
    if not stamp then stamp, rest = "", ln end
    local alert = rest:sub(1, 1) == "!"
    if alert then rest = rest:sub(2) end
    rest = rest:gsub("^%s+", "")
    if (i - first) % 2 == 1 then rect(view, { r[1], y, r[3] - btnW - 2 * u, rowH }, ZEBRA) end
    local x = r[1] + u
    if alert then rect(view, { r[1] + 2, y + 2, 3, rowH - 4 }, V.COLOR.warn) end
    if stamp ~= "" then
      text(view, stamp, x, y + (rowH - u) / 2, DIM, u)
      x = x + textWidth(stamp, u) + u * 0.5
    end
    text(view, fit(rest, textW - (x - r[1] - u), u), x, y + (rowH - u) / 2, alert and V.COLOR.warn or GRAY, u)
    y = y + rowH
  end
  local bx = r[1] + r[3] - btnW - u
  local bh = math.floor(u * 2.6)
  button(view, "UP", bx, r[2] + u, btnW, bh, PANEL2, { kind = "scroll", delta = 5 })
  button(view, "DOWN", bx, r[2] + u + bh + math.floor(u * 0.5), btnW, bh, PANEL2, { kind = "scroll", delta = -5 })
  if view.logScroll > 0 then
    text(view, ("%d newer"):format(view.logScroll), bx, r[2] + u + 2 * bh + u, DIM, math.floor(u * 0.8))
  end
end

---------------------------------------------------------------- page: control
local function drawControlPage(view, m, r)
  rect(view, r, BG)
  local u = view.u
  local gap = math.floor(u * 0.6)
  local colW = math.floor((r[3] - 3 * u) / 2)
  local bh = math.floor(u * 2.4)
  local vol = tonumber(m.alarm.volume) or 3

  -- left: siren
  local x, y = r[1] + u, r[2] + u
  box(view, x, y, colW, r[4] - 2 * u, PANEL)
  local px = x + u
  heading(view, "SIREN", px, y + gap)
  local yy = y + gap + u * 1.4
  local big = math.floor(u * 1.4)
  text(view, m.alarm.muted and "MUTED" or "ON", px, yy, m.alarm.muted and V.COLOR.warn or V.COLOR.friendly, big, "bold")
  local note = "Siren: on, sounds during countdowns"
  if m.alarm.muted and m.alarm.mutedUntil then
    note = "Siren: muted until " .. history.time(m.alarm.mutedUntil, m.offset):sub(-5)
  end
  text(view, fit(note, colW - 3 * u - textWidth("MUTED", big, true), u), px + textWidth("MUTED", big, true) + u,
    yy + (big - u) / 2, GRAY, u)
  yy = yy + u * 2.2
  text(view, "volume", px, yy, GRAY, u)
  local segW = math.floor(u * 1.6)
  for i = 1, 3 do
    box(view, px + textWidth("volume", u) + u + (i - 1) * (segW + 3), yy, segW, u, i <= vol and ACCENT or PANEL2, 2)
  end
  yy = yy + u * 1.8
  local bw = math.floor((colW - 2 * u - gap) / 2)
  button(view, m.alarm.muted and "SIREN ON" or "MUTE SIREN 10m", px, yy, bw, bh, m.alarm.muted and BTN.trust or BTN.warn,
    { kind = "cmd", cmd = m.alarm.muted and "alarm on" or "alarm mute 10m", stay = true })
  button(view, "TEST", px + bw + gap, yy, bw, bh, BTN.visitor, { kind = "cmd", cmd = "alarm test", stay = true })
  yy = yy + bh + gap
  button(view, "VOLUME -", px, yy, bw, bh, BTN.neutral, { kind = "cmd", cmd = "alarm volume " .. math.max(0, vol - 1), stay = true })
  button(view, "VOLUME +", px + bw + gap, yy, bw, bh, BTN.neutral, { kind = "cmd", cmd = "alarm volume " .. math.min(3, vol + 1), stay = true })
  yy = yy + bh + gap
  if m.alarm.muted then
    button(view, "MUTE SIREN 10m", px, yy, colW - 2 * u, bh, BTN.warn, { kind = "cmd", cmd = "alarm mute 10m", stay = true })
  end

  -- right: base and sensors
  x = r[1] + 2 * u + colW
  box(view, x, y, colW, r[4] - 2 * u, PANEL)
  px = x + u
  heading(view, "BASE", px, y + gap)
  yy = y + gap + u * 1.4
  local function info(k, v)
    text(view, k, px, yy, DIM, u)
    text(view, fit(v, colW - 2 * u - u * 6, u), px + u * 6, yy, WHITE, u)
    yy = yy + u * 1.5
  end
  info("zone", Z.describe(m.zone))
  info("detector", m.detectRange .. " blocks")
  info("scope", m.range .. " m")
  yy = yy + gap
  button(view, "COMMANDS TO DISCORD", px, yy, colW - 2 * u, bh, BTN.neutral, { kind = "cmd", cmd = "commands discord", stay = true })
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
