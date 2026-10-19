local t = require("tests.t")
local lists = require("lib.lists")
local D = require("lib.duration")

-- durations
t.eq(D.parse("45m"), 45 * 60000, "45m")
t.eq(D.parse("2h"), 2 * 3600000, "2h")
t.eq(D.parse("1h30m"), 90 * 60000, "1h30m")
t.eq(D.parse("90s"), 90000, "90s")
t.eq(D.parse("30"), 30 * 60000, "bare number = minutes")
t.eq(D.parse("0m"), nil, "zero rejected")
t.eq(D.parse("abc"), nil, "text rejected")
t.eq(D.parse("10x"), nil, "bad unit rejected")
t.eq(D.parse("5m junk"), nil, "trailing junk rejected")
t.eq(D.format(45 * 60000), "45m00s", "format minutes")
t.eq(D.format(3 * 3600000 + 5 * 60000), "3h05m", "format hours")
t.eq(D.format(9000), "9s", "format seconds")

local ls = lists.new()
local now = 1000000

t.eq(lists.effective(lists.player(ls, "Bob")), "unknown", "nobody listed -> unknown")

lists.setPlayer(ls, "Bob", "hostile", now)
t.eq(lists.effective(lists.player(ls, "bob")), "hostile", "names are case-insensitive")
t.truthy(ls.dirty, "dirty after change")

-- visitor goes back to the previous list
lists.setPlayer(ls, "Bob", "visitor", now, 60000)
t.eq(lists.player(ls, "Bob").list, "visitor", "visitor now")
t.eq(lists.player(ls, "Bob").prev, "hostile", "remembers hostile")
t.eq(#lists.expire(ls, now + 59999), 0, "not expired yet")
local ev = lists.expire(ls, now + 60000)
t.eq(#ev, 1, "expired")
t.eq(ev[1].to, "hostile", "back to hostile")
t.eq(lists.player(ls, "Bob").list, "hostile", "list restored")
t.eq(lists.player(ls, "Bob").expires, nil, "no expiry left")

-- visitor twice keeps the original previous list and extends the time
lists.setPlayer(ls, "Bob", "visitor", now, 60000)
lists.setPlayer(ls, "Bob", "visitor", now + 30000, 60000)
t.eq(lists.player(ls, "Bob").prev, "hostile", "prev kept on extension")
t.eq(lists.player(ls, "Bob").expires, now + 90000, "time extended")

-- an unknown visitor disappears after the time
lists.setPlayer(ls, "Eve", "visitor", now, 1000)
ev = lists.expire(ls, now + 1000)
t.eq(ev[1].to, "unknown", "unknown visitor -> unknown")
t.eq(lists.player(ls, "Eve"), nil, "entry removed")

-- uuid lookup
lists.setPlayer(ls, "Ann", "trusted", now)
lists.notePlayer(ls, "Ann", "uuid-ann")
t.eq(lists.effective(lists.player(ls, nil, "uuid-ann")), "trusted", "found by uuid")
t.eq(lists.player(ls, nil, "uuid-other"), nil, "other uuid not found")

-- forget
t.eq(lists.setPlayer(ls, "Ann", nil, now), true, "forget returns true")
t.eq(lists.setPlayer(ls, "Ann", nil, now), false, "second forget returns false")

-- ships
lists.setShip(ls, "s1", "trusted", now, nil, { label = "Home", pos = { x = 1, y = 2, z = 3 }, seen = now })
t.eq(lists.effective(lists.ship(ls, "s1")), "trusted", "ship trusted")
t.eq(lists.ship(ls, "s1").label, "Home", "label kept")
lists.setShip(ls, "s2", "visitor", now, 5000)
ev = lists.expire(ls, now + 5000)
t.eq(#ev, 1, "ship visitor expired")
t.eq(ev[1].target, "ship", "event says ship")
t.eq(lists.ship(ls, "s2"), nil, "ship entry removed")

-- round trip through JSON
local copy = lists.new(textutils.unserialiseJSON(textutils.serialiseJSON(lists.data(ls))))
t.eq(lists.effective(lists.player(copy, "Bob")), "visitor", "players survive JSON")
t.eq(lists.ship(copy, "s1").label, "Home", "ships survive JSON")

t.finish("lists")
