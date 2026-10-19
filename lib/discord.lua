-- Discord webhook sender.
-- Webhook URLs are secrets. They live in /void-data/discord.json on the computer
-- ({ alerts = "<url>", log = "<url>" }) and are never part of this repository.
local store = require("lib.store")

local M = {}

M.FILE = "discord.json"
M.MAX_CHUNK = 1800 -- Discord allows 2000 characters per message
M.delay = 1        -- seconds between chunks (rate limit)

function M.config()
  return store.readJson(M.FILE, {})
end

function M.saveConfig(cfg)
  return store.writeJson(M.FILE, cfg)
end

function M.validUrl(url)
  if type(url) ~= "string" then return false end
  return url:match("^https://discord%.com/api/webhooks/%d+/[%w_%-]+$") ~= nil
      or url:match("^https://discordapp%.com/api/webhooks/%d+/[%w_%-]+$") ~= nil
end

-- Hide the token part of a webhook URL for display.
function M.mask(url)
  if type(url) ~= "string" then return "-" end
  return (url:gsub("(/webhooks/%d+/).+", "%1***"))
end

-- Send a message. payload: string or table (content, username, embeds ...).
-- Returns true, httpCode  or  false, errorMessage, httpCode
function M.send(channel, payload)
  local url = M.config()[channel]
  if not url then return false, "no webhook configured for '" .. channel .. "'" end
  if not M.validUrl(url) then return false, "invalid webhook url for '" .. channel .. "'" end
  if not http then return false, "the http API is disabled" end

  if type(payload) == "string" then payload = { content = payload } end
  if payload.content and #payload.content > 2000 then
    payload.content = payload.content:sub(1, 1997) .. "..."
  end

  local body = textutils.serialiseJSON(payload)
  local res, err, fail = http.post(url, body, { ["Content-Type"] = "application/json" })
  local h = res or fail
  local code
  if h then
    if h.getResponseCode then code = h.getResponseCode() end
    h.close()
  end
  if res and code and code >= 200 and code < 300 then return true, code end
  if code == 429 then return false, "rate limited by Discord", code end
  return false, err or ("http " .. tostring(code)), code
end

-- Send a long text as several code blocks.
function M.sendChunks(channel, title, text)
  local chunks, cur = {}, ""
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if #line > M.MAX_CHUNK then line = line:sub(1, M.MAX_CHUNK - 3) .. "..." end
    if #cur + #line + 1 > M.MAX_CHUNK then
      chunks[#chunks + 1] = cur
      cur = ""
    end
    cur = cur .. line .. "\n"
  end
  if cur ~= "" then chunks[#chunks + 1] = cur end

  for i, c in ipairs(chunks) do
    local msg = "**" .. title .. "** (" .. i .. "/" .. #chunks .. ")\n```\n" .. c .. "```"
    local ok, err = M.send(channel, msg)
    if not ok then return false, err end
    if i < #chunks then sleep(M.delay) end
  end
  return true, #chunks
end

return M
