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
  { title = "SCREEN (DirectGPU)", items = {
    { "screen", "State of the DirectGPU radar screen: display, pixel size, how long the last frame took." },
    { "screen test", "Draw a test pattern (coloured corners, diagonals, circle, text) for 10 s to check size, orientation and font." },
    { "screen events", "Log every touch event for 15 s, to see what the display sends." },
    { "screen reset", "Drop the display and create it again (after moving the monitor or the GPU block)." },
    { "screen font <name>", "Font for the screen (default SansSerif). Java names like SansSerif, Monospaced or Dialog always exist." },
    { "screen range <blocks>", "Fixed range of the radar scope: 64, 128, 256 (default), 512 or 1024 blocks. Same as the - and + buttons on the screen." },
    { "screen show <category|all> on|off", "Show or hide a radar category on the screen: player, ship, shot, contraption, monster, mob, animal, item, misc. Only the screen; alerts stay the same. Same as the chips on the TARGETS page." },
    { "screen filter", "Which categories the screen shows." },
  } },
  { title = "SHELL: void (outside the radar)", items = {
    { "void list", "Installed apps." },
    { "void update", "Update everything from GitHub (GitHub caches up to 5 minutes). Restart running apps afterwards." },
    { "void version", "Installed version." },
    { "void radar [tab]", "Start the radar. With tab it runs in its own tab (advanced computer) and the shell stays free." },
    { "void radar autostart on|off", "Start the radar when the computer boots (in a tab if possible)." },
    { "void music [tab]", "Music player on the same speakers. Q quits. The radar siren takes over the speakers and the music resumes afterwards." },
    { "void music autostart on|off", "Open the music player in a tab on boot (advanced computer)." },
    { "void discord-test", "Enter the Discord webhook URLs and send a test message." },
    { "void probe [seconds] [--discord]", "Measure what radars and the player detector return; with --discord the report goes to the log channel." },
  } },
  { title = "OTHER", items = {
    { "help [command]", "Short list, or the explanation of one command, e.g. help zone." },
    { "commands", "This full list. Keys: up/down or space to scroll, Q to close." },
    { "commands discord", "Post this list to the Discord log channel (also done once automatically when the list changes after an update)." },
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

-- Discord version: one { title, description } per group, ASCII only.
function R.embeds()
  local out = {}
  for _, g in ipairs(R.GROUPS) do
    local lines = {}
    for _, it in ipairs(g.items) do lines[#lines + 1] = "`" .. it[1] .. "`  " .. it[2] end
    out[#out + 1] = { title = "COMMANDS: " .. g.title, description = table.concat(lines, "\n") }
  end
  return out
end

-- Changes whenever a command or explanation changes (for the one-time Discord post).
function R.hash()
  local h = 0
  for _, e in ipairs(R.embeds()) do
    for i = 1, #e.description do h = (h * 31 + e.description:byte(i)) % 2147483647 end
  end
  return tostring(h)
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
