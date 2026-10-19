-- speaker priority file shared by the radar siren and the music player
local t = require("tests.t")
local lock = require("lib.audiolock")

lock.release()
t.eq(lock.held(), false, "free at the start")
lock.claim()
t.eq(lock.held(), true, "held after claim")
lock.release()
t.eq(lock.held(), false, "free after release")
lock.release() -- releasing twice is fine

-- a claim expires by itself (crashed radar)
lock.claim(-1)
t.eq(lock.held(), false, "expired claim is not held")
lock.claim(200)
t.eq(lock.held(), true, "short claim held")
sleep(0.3)
t.eq(lock.held(), false, "short claim expired")

-- garbage in the file does not block the music
local store = require("lib.store")
store.writeText(lock.FILE, "garbage")
t.eq(lock.held(), false, "garbage is ignored")
lock.release()
t.finish("audiolock")
