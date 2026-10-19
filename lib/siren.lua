-- Siren sounds for the CC:Tweaked speaker (speaker.playAudio).
-- Audio is 8-bit PCM at 48 kHz: a list of whole numbers from -128 to 127.
--
--   wail: slow up-and-down sweep, 1 cycle per second   (countdown running)
--   yelp: fast sweep, 4 cycles per second              (engage / hostile)
--
-- Every buffer is 1 second long, so the player queues one per second.
local S = {}

S.RATE = 48000

S.MODES = {
  wail = { low = 550, high = 1100, cycle = 1.0 },
  yelp = { low = 700, high = 1500, cycle = 0.25 },
}

-- Frequency sweeps low -> high -> low once per `cycle` seconds, for `seconds`.
function S.sweep(low, high, cycle, seconds, amp)
  amp = amp or 100
  local n = math.floor(S.RATE * seconds)
  local per = S.RATE * cycle
  local out, phase = {}, 0
  local twoPi = 2 * math.pi
  for i = 1, n do
    local x = ((i - 1) % per) / per          -- 0 .. 1 inside one cycle
    local tri = x < 0.5 and x * 2 or (1 - x) * 2
    phase = phase + twoPi * (low + (high - low) * tri) / S.RATE
    if phase > twoPi then phase = phase - twoPi end
    local v = math.sin(phase) * 1.4           -- a little clipping: harsher, louder
    if v > 1 then v = 1 elseif v < -1 then v = -1 end
    out[i] = math.floor(v * amp + 0.5)
  end
  return out
end

function S.build(mode)
  local m = S.MODES[mode]
  if not m then return nil end
  return S.sweep(m.low, m.high, m.cycle, 1.0)
end

-- Which siren the current decisions call for: "yelp", "wail" or nil.
function S.modeFor(decisions)
  local mode
  for _, d in pairs(decisions or {}) do
    if d.action == "engage" then return "yelp" end
    if d.action == "warn" then mode = "wail" end
  end
  return mode
end

return S
