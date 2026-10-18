local t = require("tests.t")
local store = require("lib.store")
local discord = require("lib.discord")

local GOOD = "https://discord.com/api/webhooks/123456789/AbC_def-123"
t.truthy(discord.validUrl(GOOD), "valid url")
t.eq(discord.validUrl("https://evil.example/api/webhooks/1/x"), false, "foreign host rejected")
t.eq(discord.validUrl("https://discord.com/api/webhooks/1/x y"), false, "space rejected")
t.eq(discord.validUrl(nil), false, "nil rejected")
t.eq(discord.mask(GOOD), "https://discord.com/api/webhooks/123456789/***", "token masked")

-- mock http
local calls = {}
local nextCode = 204
http = {
  post = function(url, body, headers)
    calls[#calls + 1] = { url = url, body = body, headers = headers }
    local code = nextCode
    local handle = { getResponseCode = function() return code end, close = function() end }
    if code >= 200 and code < 300 then return handle end
    return nil, "http " .. code, handle
  end,
}
discord.delay = 0

fs.delete("/cmp-data")

local ok, err = discord.send("alerts", "hi")
t.eq(ok, false, "no config -> fails")
t.contains(err, "no webhook", "error mentions missing webhook")
t.eq(#calls, 0, "nothing sent without config")

discord.saveConfig({ alerts = GOOD, log = GOOD })
ok = discord.send("alerts", "he said \"hi\"")
t.eq(ok, true, "send ok")
t.eq(#calls, 1, "one http call")
t.eq(calls[1].url, GOOD, "posted to the configured url")
t.eq(calls[1].headers["Content-Type"], "application/json", "json header")
t.eq(textutils.unserialiseJSON(calls[1].body).content, "he said \"hi\"", "body round-trips")

nextCode = 429
ok, err = discord.send("alerts", "again")
t.eq(ok, false, "429 is a failure")
t.contains(err, "rate limited", "429 message")

nextCode = 204
local long = string.rep("x", 2500)
discord.send("alerts", long)
t.eq(#textutils.unserialiseJSON(calls[#calls].body).content, 2000, "long content truncated to 2000")

-- chunking
calls = {}
local lines = {}
for i = 1, 200 do lines[i] = "line " .. i .. " " .. string.rep("y", 40) end
ok, err = discord.sendChunks("log", "report", table.concat(lines, "\n"))
t.eq(ok, true, "chunks sent")
t.truthy(#calls >= 4, "split into several messages")
for _, c in ipairs(calls) do
  t.truthy(#textutils.unserialiseJSON(c.body).content <= 2000, "each chunk under 2000")
end

-- invalid stored url is refused without any http call
discord.saveConfig({ alerts = "not-a-url" })
calls = {}
ok = discord.send("alerts", "x")
t.eq(ok, false, "invalid url refused")
t.eq(#calls, 0, "no request for an invalid url")

fs.delete("/cmp-data")
t.finish("discord")
