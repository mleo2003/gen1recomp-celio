-- luajit tests/e2e/describe_party.lua <party.bin (6 x 100-byte structs)>
package.path = "./?.lua;" .. package.path
local Pk3 = dofile("lib/pk3.lua")
local f = assert(io.open(arg[1], "rb")); local p = f:read("*a"); f:close()
for i = 0, 5 do
  local d = Pk3.describe(p:sub(i * 100 + 1, i * 100 + 100))
  if d then
    print(("%d. species %d %s OT %s L%d item %d mail %d %s"):format(i + 1, d.species, d.nickname, d.otName,
      d.level, d.heldItem, d.mail, d.checksumOk and "checksum ok" or "BAD CHECKSUM"))
  end
end
