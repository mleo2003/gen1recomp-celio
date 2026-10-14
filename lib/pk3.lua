-- Gen 3 party Pokémon (pokefirered include/pokemon.h, struct Pokemon):
-- 100 bytes = 32-byte header, 48 bytes of four encrypted 12-byte
-- substructures, 20 bytes of party stats.  The substructures are XORed
-- with personality ^ otId (u32 words) and ordered by personality % 24;
-- their u16 sum is the checksum at 0x1C.  Enough of it to read what is
-- offered and to check a struct is intact.  Text uses the international
-- Gen 3 charset.

local bit = require("bit")

local Pk3 = {}

local function u16(s, o) return s:byte(o + 1) + s:byte(o + 2) * 256 end
local function u32(s, o) return u16(s, o) + u16(s, o + 2) * 65536 end
Pk3.u16, Pk3.u32 = u16, u32

-- substructure order: G(rowth) A(ttacks) E(Vs) M(isc) positions per personality % 24
local ORDER = {
  "GAEM", "GAME", "GEAM", "GEMA", "GMAE", "GMEA", "AGEM", "AGME", "AEGM", "AEMG", "AMGE", "AMEG",
  "EGAM", "EGMA", "EAGM", "EAMG", "EMGA", "EMAG", "MGAE", "MGEA", "MAGE", "MAEG", "MEGA", "MEAG",
}

local function words(s, o, n)
  local out = {}
  for i = 0, n - 1 do out[i + 1] = u32(s, o + i * 4) end
  return out
end

-- decrypt the 48 secure bytes; returns { G = 12 bytes, A = ..., E = ..., M = ... }, checksumOk
function Pk3.substructs(s)
  local pid, otId = u32(s, 0), u32(s, 4)
  local key = bit.bxor(pid, otId)
  local w = words(s, 32, 12)
  local plain = {}
  for i = 1, 12 do
    local v = bit.bxor(w[i], key)
    if v < 0 then v = v + 4294967296 end
    plain[i] = string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
  end
  local bytes = table.concat(plain)
  local sum = 0
  for i = 0, 46, 2 do sum = (sum + u16(bytes, i)) % 65536 end
  local order = ORDER[(pid % 24) + 1]
  local subs = {}
  for i = 1, 4 do
    subs[order:sub(i, i)] = bytes:sub((i - 1) * 12 + 1, i * 12)
  end
  return subs, sum == u16(s, 0x1C)
end

-- the international charset, enough for names
local CHARS = {}
do
  for i = 0, 25 do
    CHARS[0xBB + i] = string.char(65 + i)
    CHARS[0xD5 + i] = string.char(97 + i)
  end
  for i = 0, 9 do CHARS[0xA1 + i] = string.char(48 + i) end
  CHARS[0x00] = " "
  CHARS[0xAB] = "!"; CHARS[0xAC] = "?"; CHARS[0xAD] = "."; CHARS[0xAE] = "-"
  CHARS[0xB4] = "'"; CHARS[0xB8] = ","; CHARS[0xBA] = "/"
end
local REVERSE = {}
for code, ch in pairs(CHARS) do REVERSE[ch] = code end
REVERSE[" "] = 0x00

function Pk3.decodeText(s)
  local out = {}
  for i = 1, #s do
    local c = s:byte(i)
    if c == 0xFF then break end
    out[#out + 1] = CHARS[c] or "?"
  end
  return table.concat(out)
end

-- text -> n bytes, 0xFF terminated and padded
function Pk3.encodeText(str, n)
  local out = {}
  for i = 1, math.min(#str, n) do out[#out + 1] = string.char(REVERSE[str:sub(i, i)] or 0xAC) end
  while #out < n do out[#out + 1] = "\255" end
  return table.concat(out)
end

-- a summary of one 100-byte struct (nil for an empty slot: the game zeroes
-- those but leaves the mail byte at 0xFF)
function Pk3.describe(s)
  if #s < 100 or s:sub(1, 100) == string.rep("\0", 100) then return nil end
  local subs, ok = Pk3.substructs(s)
  local G = subs.G
  if u16(G, 0) == 0 then return nil end
  return {
    personality = u32(s, 0), otId = u32(s, 4),
    nickname = Pk3.decodeText(s:sub(9, 18)), otName = Pk3.decodeText(s:sub(21, 27)),
    species = u16(G, 0), heldItem = u16(G, 2), experience = u32(G, 4),
    level = s:byte(0x55), mail = s:byte(0x56), checksumOk = ok,
    isEgg = bit.band(s:byte(0x14), 4) ~= 0,
  }
end

return Pk3
