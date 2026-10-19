-- Full command reference for the radar: usage + explanation, grouped.
-- Shown by "commands" (full-screen pager) and "help <command>".
local R = {}

R.GROUPS = {
  { title = "WATCHING", items = {
    { "targets", "Everything the radar sees right now: list, distance to the zone centre, ZONE if inside the no-go zone. Short: t" },
    { "players", "All players on a list (trusted, hostile, visitor) with the visitor time left. Players on no list are unknown and not shown." },
    { "ships", "Ships seen now and listed ships. Old = the previous id of a reassembled ship, kept for a short time before it is dropped." },
    { "history [name]", "How often and when players visited. With a name: every single visit of that player." },
  } },
  { title = "FRIEND OR FOE: PLAYERS", items = {
    { "trust <name>", "Trusted: never warned, never engaged, no Discord alert." },
    { "hostile <name>", "Hostile: reported as HOSTILE as soon as seen, engaged in the zone without countdown." },
    { "visitor <name> [time]", "Allowed for a while, e.g. visitor Bob 45m (default 30m). After the time the player goes back to the previous list." },
    { "forget <name>", "Back to unknown (also unknown <name>). Unknown players get a warning countdown in the zone." },
  } },
  { title = "FRIEND OR FOE: SHIPS", items = {
    { "ship <id> trust|hostile", "Put a ship on a list. <id> = at least 3 characters of the id from 'ships'. After reassembly the list is taken over automatically." },
    { "ship <id> visitor [time]", "Ship allowed for a while, like visitor for players." },
    { "ship <id> forget", "Remove a ship from the lists." },
    { "label <id> <text>", "Give a listed ship a name (up to 24 characters), shown in lists and Discord." },
  } },
  { title = "NO-GO ZONE", items = {
    { "zone", "Show the zone: centre and size in chunks." },
    { "zone center <x> <z> [chunks]", "Set the zone centre and size (1-64 chunks, default 10)." },
    { "zone radars [chunks]", "Centre the zone on the average position of the plane radars." },
  } },
  { title = "ALARM", items = {
    { "alarm", "Show siren state: on or muted, volume, number of speakers." },
    { "alarm mute [time]", "Silence the siren (default 10m). Discord keeps reporting." },
    { "alarm on", "Turn the siren on again after mute." },
    { "alarm test", "Play the siren for 3 seconds. Music pauses meanwhile." },
    { "alarm volume <0-3>", "Siren volume." },
  } },
  { title = "SETTINGS", items = {
    { "detectrange <16-512>", "Range of the player detector in blocks (default 512)." },
    { "basename <text>", "Name of the base in Discord messages." },
    { "timezone <hours>", "Shown times use this offset from UTC, e.g. timezone 2. Discord times follow each reader's clock." },
  } },
  { title = "OTHER", items = {
    { "help [command]", "Short list, or the explanation of one command, e.g. help zone." },
    { "commands", "This full list. Keys: up/down or space to scroll, Q to close." },
    { "exit", "Stop the radar and go back to the shell. Also: quit." },
  } },
}

-- Wraps text to `width` columns. Returns a list of lines.
function R.wrap(text, width, indent)
  indent = indent or ""
  local out, line = {}, ""
  for word in text:gmatch("%S+") do
    if line == "" then
      line = word
    elseif #line + 1 + #word <= width - #indent then
      line = line .. " " .. word
    else
      out[#out + 1] = line
      line = word
    end
  end
  if line ~= "" then out[#out + 1] = line end
  for i, l in ipairs(out) do out[i] = indent .. l end
  return out
end

-- Whole reference as plain lines for a screen `width` columns wide.
-- Each line is { text, kind } with kind = "title" | "usage" | "text".
function R.render(width)
  local out = {}
  for gi, g in ipairs(R.GROUPS) do
    if gi > 1 then out[#out + 1] = { "", "text" } end
    out[#out + 1] = { g.title, "title" }
    for _, it in ipairs(g.items) do
      out[#out + 1] = { it[1], "usage" }
      for _, l in ipairs(R.wrap(it[2], width, "  ")) do out[#out + 1] = { l, "text" } end
    end
  end
  return out
end

-- Entries whose usage starts with the given command word(s), for "help <command>".
function R.find(word)
  word = (word or ""):lower()
  local hits = {}
  for _, g in ipairs(R.GROUPS) do
    for _, it in ipairs(g.items) do
      local first = it[1]:match("^(%S+)")
      if first:lower() == word then hits[#hits + 1] = it end
    end
  end
  return hits
end

return R
