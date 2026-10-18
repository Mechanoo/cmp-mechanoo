print("CraftOS", os.version(), _HOST)
print("http:", http ~= nil, "monitor-api:", peripheral ~= nil)
local t = {3,1,2}; table.sort(t); print(textutils.serialize(t, {compact=true}))
