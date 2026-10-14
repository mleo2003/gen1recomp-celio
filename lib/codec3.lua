-- The cart's trade data <-> the engine's: 100-byte party structs (and the
-- mail block that rides with them), the 100-byte trainer card, Gen 3 text.
-- All the hard parts are the engine's own save codec
-- (src/save_convert/Gen3Save.lua) and wire format (src/link/Protocol.lua);
-- this file only puts them together the way a cable trade needs.
--
--   codec:packParty(structs)        cart party (600 B) -> wire mons, as the
--                                   engine's game3_trade_party carries them
--   codec:cartParty(packed, s)      engine party (wire mons + the session,
--                                   for mail) -> 600 B structs + 220 B mail
--   codec:mailRecord(block, i)      one 36-byte MailStruct -> engine record
--   codec:card(c) / readCard(b)     trainer card both ways
--   codec:encodeName / decodeName   Gen 3 text

local Codec3 = {}
Codec3.__index = Codec3

local PARTY_SIZE = 6
local MON_SIZE = 100
local MAIL_SIZE = 36
local MAIL_BLOCK = 220           -- mail[0..5] + 4 bytes of mail[6] (pokefirered trade.c)
local MAIL_NONE = 0xFF
local EC_WORD_UNDEFINED = 0xFFFF

local function u16(s, o) return s:byte(o + 1) + s:byte(o + 2) * 256 end
local function u32(s, o) return u16(s, o) + u16(s, o + 2) * 65536 end
local function w16(v) v = math.floor(tonumber(v) or 0) % 65536; return string.char(v % 256, math.floor(v / 256)) end
local function w32(v) v = math.floor(tonumber(v) or 0) % 4294967296; return w16(v % 65536) .. w16(math.floor(v / 65536)) end

-- an empty party slot as the game leaves it: zeros, mail byte 0xFF
Codec3.EMPTY_MON = string.rep("\0", 0x55) .. "\255" .. string.rep("\0", MON_SIZE - 0x56)

-- deps (engine modules, all optional): Gen3Save, SaveMon, Protocol, Mail
function Codec3.new(version, deps)
  deps = deps or {}
  local self = setmetatable({
    version = version or "firered",
    Gen3Save = deps.Gen3Save or require("src.save_convert.Gen3Save"),
    SaveMon = deps.SaveMon or require("src.core.game3.save_mon"),
    Protocol = deps.Protocol or require("src.link.Protocol"),
    Mail = deps.Mail or require("src.core.game3.mail"),
  }, Codec3)
  self.G3 = self.Gen3Save.forVersion(self.version)
  return self
end

-- ------------------------------------------------------------------
-- text
-- ------------------------------------------------------------------

-- UTF-8 -> n bytes of Gen 3 text, 0xFF terminated and padded
function Codec3:encodeName(str, n)
  local bytes = self.G3.encodeString(tostring(str or ""), n, 0xFF)
  bytes = bytes:sub(1, n)
  return bytes .. string.rep("\255", n - #bytes)
end

function Codec3:decodeName(bytes)
  return (self.G3.decodeString(bytes, 0, #bytes):gsub(" +$", ""))
end

-- ------------------------------------------------------------------
-- the party
-- ------------------------------------------------------------------

-- the boxed part of an empty slot is all zero
local ZERO_BOX = string.rep("\0", 0x50)
local function isEmpty(raw)
  return #raw < MON_SIZE or raw:sub(1, 0x50) == ZERO_BOX
end

-- cart party (6 x 100 B) -> { packed wire mons }, { decoded cart records },
-- and the first refusal (the engine's strict unpack) if any
function Codec3:packParty(structs)
  local P = self.Protocol
  local packed, records, refusal = {}, {}, nil
  for i = 0, PARTY_SIZE - 1 do
    local raw = structs:sub(i * MON_SIZE + 1, i * MON_SIZE + MON_SIZE)
    if isEmpty(raw) then break end
    local c = self.G3.decodePartyMon(raw)
    if not c or (c.species or 0) == 0 then break end
    local mon = self.G3.toPortMon(c, true)
    self.SaveMon.normalize(mon)
    local p = P.packMon3(mon)
    local ok, why = P.unpackMon3(nil, p, { strict = true })
    if not ok and not refusal then refusal = ("slot %d: %s"):format(i + 1, tostring(why)) end
    packed[#packed + 1] = p
    records[#records + 1] = c
  end
  return packed, records, refusal
end

-- the engine's mail for a party mon (src/core/game3/link/trade.lua mailRecordFor)
function Codec3:mailFor(session, mon)
  local Mail = self.Mail
  local id = tonumber(mon and mon.mail)
  if not id or id == Mail.MAIL_NONE then return nil end
  local record = Mail.slot(session, id)
  if not record or Mail.isEmpty(record) then return nil end
  return Mail.copy(record)
end

-- one MailStruct (pokefirered include/global.h struct Mail, FRLG layout)
function Codec3:mailBytes(record)
  if not record or (tonumber(record.itemId) or 0) == 0 then
    -- ClearMailStruct: words undefined, name 0xFF, id 0, species 1, item 0
    return string.rep(w16(EC_WORD_UNDEFINED), 9) .. string.rep("\255", 8) .. w32(0) .. w16(1) .. w16(0) .. "\0\0"
  end
  local words = {}
  for i = 1, 9 do words[i] = w16(tonumber(record.words and record.words[i]) or EC_WORD_UNDEFINED) end
  local name = tostring(record.playerName or "")
  local chars = 0
  for _ in name:gmatch("[^\128-\191]") do chars = chars + 1 end
  if chars < 6 then name = name .. string.rep(" ", 6 - chars) end   -- mail_data.c: pads to 6
  return table.concat(words) .. self:encodeName(name, 7) .. "\255"
    .. w32(tonumber(record.trainerIdRaw) or tonumber(record.trainerId) or 0)
    .. w16(tonumber(record.species) or 1) .. w16(tonumber(record.itemId) or 0) .. "\0\0"
end

function Codec3:mailRecord(block, index)
  if type(block) ~= "string" or not index or index >= PARTY_SIZE then return nil end
  local off = index * MAIL_SIZE
  if #block < off + 0x22 then return nil end
  local item = u16(block, off + 0x20)
  if item == 0 then return nil end
  local words = {}
  for i = 1, 9 do words[i] = u16(block, off + (i - 1) * 2) end
  local raw = u32(block, off + 0x1A)
  return {
    words = words,
    playerName = self:decodeName(block:sub(off + 0x13, off + 0x1A)),
    trainerId = raw % 65536, trainerIdRaw = raw,
    species = u16(block, off + 0x1E),
    itemId = item,
  }
end

-- The game names a mon from its species-name table, whose entries are zero
-- after the terminator; the engine's encoder pads with 0xFF.  Either reads
-- the same, but keep the cart's bytes.
function Codec3.zeroNicknameTail(raw)
  local name = raw:sub(9, 18)
  local eos = name:find("\255", 1, true)
  if not eos or eos == #name then return raw end
  return raw:sub(1, 8) .. name:sub(1, eos) .. string.rep("\0", #name - eos) .. raw:sub(19)
end

-- engine party (wire mons, in party order) -> 600 B of structs and the
-- 220 B mail block; `session` (optional) supplies each mon's mail
function Codec3:cartParty(packed, session)
  local P = self.Protocol
  local live = type(session) == "table" and type(session.party) == "table" and session.party or {}
  local structs, mails = {}, {}
  for i = 1, math.min(#packed, PARTY_SIZE) do
    local mon = assert(P.unpackMon3(nil, packed[i], { strict = true }))
    local record = self:mailFor(session, live[i])
    mails[i] = record
    local c = self.G3.fromPortMon(mon, {
      mailIndex = function() return record and (i - 1) or MAIL_NONE end,
    }, true)
    structs[i] = Codec3.zeroNicknameTail(self.G3.encodePartyMon(c))
  end
  for i = #structs + 1, PARTY_SIZE do structs[i] = Codec3.EMPTY_MON end
  local block = {}
  for i = 1, PARTY_SIZE do block[i] = self:mailBytes(mails[i]) end
  local mail = (table.concat(block) .. self:mailBytes(nil)):sub(1, MAIL_BLOCK)
  return table.concat(structs), mail
end

-- ------------------------------------------------------------------
-- the trainer card (pokefirered include/trainer_card.h struct TrainerCard)
-- ------------------------------------------------------------------

local VERSION_CODE = { firered = 4, leafgreen = 5 }

-- c: the engine's Link.localTrainerCard() table; party: session party (icons)
function Codec3:card(c, party)
  c = c or {}
  local tid = math.floor(tonumber(c.trainerId) or 0) % 65536
  local gender = (c.gender == 1 or c.gender == "female") and 1 or 0
  local profile = {}
  for i = 1, 4 do
    profile[i] = w16(tonumber(type(c.easyChatProfile) == "table" and c.easyChatProfile[i]) or EC_WORD_UNDEFINED)
  end
  local species = {}
  for i = 1, PARTY_SIZE do
    local m = type(party) == "table" and party[i]
    species[i] = w16(m and not m.isEgg and tonumber(m.species or m.speciesId) or 0)
  end
  local function clampHour(v) return math.min(999, math.floor(tonumber(v) or 0)) end
  local b = table.concat({
    string.char(gender, math.min(4, tonumber(c.stars) or 0), 1, 0, c.hasAllPaintings and 1 or 0, 0),
    w16(c.hofDebutHours), w16(c.hofDebutMinutes), w16(c.hofDebutSeconds),
    w16(c.caughtMonsCount), w16(tid), w16(clampHour(c.playTimeHours)), w16(c.playTimeMinutes),
    w16(c.linkBattleWins), w16(c.linkBattleLosses), w16(0), w16(0), w16(0), w16(0),
    w16(c.pokemonTrades), "\0\0", w32(math.min(999999, tonumber(c.money) or 0)),
    table.concat(profile),
    self:encodeName(c.name or "", 7), "\255",
    string.char(VERSION_CODE[self.version] or 4, 0), w16(0),
    w32(c.berryCrushPoints), w32(c.unionRoomNum), w32(0), w32(0),
    string.char(0, 0, 0, 0), string.rep("\0", 4),
    table.concat(species), string.rep("\0", 100 - 0x60),
  })
  assert(#b == 100, #b)
  return b
end

-- the cart's card -> a table shaped like the engine's localTrainerCard()
function Codec3:readCard(b)
  if type(b) ~= "string" or #b < 0x60 then return nil end
  local profile = {}
  for i = 1, 4 do profile[i] = u16(b, 0x28 + (i - 1) * 2) end
  return {
    gender = b:byte(1), stars = b:byte(2),
    hofDebutHours = u16(b, 0x06), hofDebutMinutes = u16(b, 0x08), hofDebutSeconds = u16(b, 0x0A),
    caughtMonsCount = u16(b, 0x0C), trainerId = u16(b, 0x0E),
    playTimeHours = u16(b, 0x10), playTimeMinutes = u16(b, 0x12),
    linkBattleWins = u16(b, 0x14), linkBattleLosses = u16(b, 0x16),
    pokemonTrades = u16(b, 0x20), money = u32(b, 0x24),
    easyChatProfile = profile,
    name = self:decodeName(b:sub(0x31, 0x38)),
    version = b:byte(0x39) == 5 and "leafgreen" or "firered",
    berryCrushPoints = u32(b, 0x3C), unionRoomNum = u32(b, 0x40),
  }
end

return Codec3
