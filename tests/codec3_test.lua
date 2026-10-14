-- lib/codec3.lua against the engine's own codec, with real FireRed data:
-- party structs dumped from a FireRed cart over the link round-trip
-- through the engine's wire format byte for byte; mail and the trainer card
-- round-trip too.
--
--   POKEPORT_IDENTITY=<identity with a FireRed cache> luajit <mod>/tests/codec3_test.lua   (from the engine root)
package.path = "./?.lua;./?/init.lua;" .. package.path
local here = (arg[0] or ""):match("^(.*)/tests/[^/]+$") or "."

local Cache = require("tests.game3_cache")
if not Cache.mount("meta.json") then print("[skip] no FireRed cache: " .. tostring(Cache.reason)) os.exit(0) end
require("tests.fixture_data.game3_items").install()

local Codec3 = dofile(here .. "/lib/codec3.lua")
local Pk3 = dofile(here .. "/lib/pk3.lua")
local codec = Codec3.new("firered")

local pass, fail = 0, 0
local function check(ok, what)
  if ok then pass = pass + 1 else fail = fail + 1 end
  print(("  %s %s"):format(ok and "ok  " or "FAIL", what))
end
local function read(name)
  local f = assert(io.open(here .. "/tests/fixtures/" .. name, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end
local function firstDiff(a, b)
  for i = 1, math.max(#a, #b) do
    if a:byte(i) ~= b:byte(i) then return i - 1 end
  end
end

print("party structs -> wire -> structs")
for _, name in ipairs({ "cart_party_a.bin", "cart_party_b.bin", "recomp_party.bin" }) do
  local structs = read(name)
  local packed, records, refusal = codec:packParty(structs)
  check(refusal == nil, name .. ": the engine takes every mon" .. (refusal and (" (" .. refusal .. ")") or ""))
  local n = 0
  for i = 0, 5 do if Pk3.describe(structs:sub(i * 100 + 1, i * 100 + 100)) then n = n + 1 end end
  check(#packed == n, ("%s: %d mons packed"):format(name, #packed))
  local back, mail = codec:cartParty(packed, nil)
  check(#back == 600 and #mail == 220, name .. ": 600 B of structs, 220 B of mail")
  local d = firstDiff(back:sub(1, n * 100), structs:sub(1, n * 100))
  check(d == nil, name .. ": byte for byte" .. (d and (" (first difference at 0x%X, slot %d)"):format(d, math.floor(d / 100) + 1) or ""))
  check(back:sub(n * 100 + 1) == string.rep(Codec3.EMPTY_MON, 6 - n), name .. ": empty slots as the game leaves them")
  for i = 0, n - 1 do
    local a = Pk3.describe(back:sub(i * 100 + 1, i * 100 + 100))
    check(a and a.checksumOk, ("%s: slot %d %s checksum ok"):format(name, i + 1, a and a.nickname or "?"))
  end
end

print("mail")
local rec = { words = { 1, 2, 3, 4, 5, 6, 7, 8, 9 }, playerName = "RED", trainerId = 0x1234, trainerIdRaw = 0x56781234,
              species = 25, itemId = 122 }
local bytes = codec:mailBytes(rec)
check(#bytes == 36, "a MailStruct is 36 bytes")
local back = codec:mailRecord(bytes .. string.rep("\0", 220 - 36), 0)
check(back and back.itemId == 122 and back.species == 25 and back.trainerIdRaw == 0x56781234
      and back.words[9] == 9 and back.playerName == "RED", "mail round-trips")
check(codec:mailRecord(codec:mailBytes(nil) .. string.rep("\0", 184), 0) == nil, "an empty mail slot reads as none")

print("trainer card")
local card = codec:card({ name = "RECOMP", gender = 1, trainerId = 44444, stars = 2, money = 123456,
  playTimeHours = 12, playTimeMinutes = 34, caughtMonsCount = 151, pokemonTrades = 7,
  easyChatProfile = { 0x1001, 0x1002, 0x1003, 0x1004 } }, { { species = 25 }, { species = 6 } })
check(#card == 100, "a card is 100 bytes")
local c = codec:readCard(card)
check(c.name == "RECOMP" and c.gender == 1 and c.trainerId == 44444 and c.stars == 2 and c.money == 123456
      and c.playTimeHours == 12 and c.caughtMonsCount == 151 and c.pokemonTrades == 7
      and c.easyChatProfile[4] == 0x1004 and c.version == "firered", "card round-trips")
check(card:byte(0x55) == 25 and card:byte(0x57) == 6, "party icons on the card")

print(("%d/%d checks passed"):format(pass, pass + fail))
os.exit(fail == 0 and 0 or 1)
