-- A virtual FireRed that leads a Cable Club trade over the Celio relay,
-- without the game: lib/sio.lua + lib/celio.lua + lib/gbalink.lua +
-- lib/trade3.lua, a fixed party (6 x 100-byte structs, e.g. dumped by
-- PKHeX from a save) and scripted choices.  The other side is a real
-- FireRed: mGBA (Celio edition + its script) behind celio.gblink.io, or a
-- GBA on a Celio adapter.
--
--   luajit <mod>/tests/e2e/virtual_cart.lua <party.bin> <code|create> <out dir> [give slots] [server]
--
-- Run it from the engine root when the server is wss:// (it borrows the
-- engine's TLS dialer: GEN1TLS_DIR = the folder with gen1tls.{dylib,dll,so}).
-- <give slots>: comma separated, 1-based, one per trade (default "1");
-- after the last one it cancels, and leaves when the other player does.
-- Every party the other side sends is written to <out>/partner_party_<n>.bin
-- and every mon received to <out>/received_<n>.bin.
package.path = "./?.lua;./?/init.lua;" .. package.path
local here = (arg[0] or ""):match("^(.*)/tests/e2e/[^/]+$") or "."
local partyPath, codeArg, out = arg[1], arg[2], arg[3]
local gives = {}
for g in (arg[4] or "1"):gmatch("%d+") do gives[#gives + 1] = tonumber(g) end
local server = arg[5] or "wss://celio-server.up.railway.app"
assert(partyPath and codeArg and out, "usage: virtual_cart.lua <party.bin> <code|create> <out dir> [give slots] [server]")

local socket = require("socket")
local now = socket.gettime
local t0 = now()
local function log(fmt, ...)
  io.write(("[%6.1f] " .. fmt .. "\n"):format(now() - t0, ...))
  io.flush()
end

local function lib(n) return dofile(here .. "/lib/" .. n .. ".lua") end
local json, Ws, Sio, Celio = lib("json"), lib("ws"), lib("sio"), lib("celio")
local Link, Trade3, Pk3 = lib("gbalink"), lib("trade3"), lib("pk3")

local tls
if server:match("^wss://") then
  love = love or require("tests.love_stub")
  love.system = love.system or {}
  love.system.getOS = function() return os.getenv("GEN1TLS_OS") or "OS X" end
  love.filesystem.getSourceBaseDirectory = function() return assert(os.getenv("GEN1TLS_DIR"), "set GEN1TLS_DIR") end
  assert(require("src.net.Gen1Tls").install(), "gen1tls did not load")
  tls = Ws.tlsFrom(love.system)
  assert(tls, "no TLS")
end

local f = assert(io.open(partyPath, "rb"))
local structs = f:read("*a")
f:close()
assert(#structs == 600, "party.bin must be 600 bytes")
local function save(name, bytes)
  local fh = assert(io.open(out .. "/" .. name, "wb"))
  fh:write(bytes)
  fh:close()
end
local function partyLine(bytes)
  local names = {}
  for i = 0, 5 do
    local d = Pk3.describe(bytes:sub(i * 100 + 1, i * 100 + 100))
    if d then names[#names + 1] = ("%s(#%d L%d%s)"):format(d.nickname, d.species, d.level, d.checksumOk and "" or " BAD") end
  end
  return table.concat(names, ", ")
end

math.randomseed(os.time())
local io_ = Sio.new(server, { Ws = Ws, json = json, socket = socket, tls = tls, now = now,
                              clientId = "gen1recomp-test-" .. math.random(1, 1e9), log = log })
local celio = Celio.new({ sio = io_, json = json, now = now, log = log })
local link = Link.new({ celio = celio, Celio = Celio, now = now, log = log, debug = os.getenv("CELIO_DEBUG") ~= nil })

-- RECOMP, 44444, a FireRed with the National Dex (so anything can come our way)
local first = Pk3.describe(structs:sub(1, 100))
local trainerId = first and first.otId or 44444
local name = Pk3.encodeText(first and first.otName or "RECOMP", 7) .. "\255"
local card = string.rep("\0", 100)
do
  local function put(s, at, bytes) return s:sub(1, at) .. bytes .. s:sub(at + #bytes + 1) end
  card = put(card, 0x00, "\0\0\1")                                  -- gender, stars, hasPokedex
  card = put(card, 0x0E, string.char(trainerId % 256, math.floor(trainerId / 256) % 256))
  card = put(card, 0x30, name)
  card = put(card, 0x38, "\4")                                        -- FireRed card layout
end
local trade = Trade3.new({ link = link, Link = Link, now = now, log = log, card = card, identity = {
  version = 0x4004, trainerId = trainerId, name = name, progressFlags = 0x01, gender = 0, language = 2,
} })
trade:setParty({ structs = structs, mail = string.rep("\0", 220), ribbons = string.rep("\0", 40) })

local started, round, done, failed = false, 0, false, nil
local partnerParty, mySelect, partnerSelect, partnerConfirm
local M = Trade3.MENU

local function decide()
  -- the leader's arbitration (pokefirered src/trade.c Leader_HandleCommunication)
  if mySelect ~= nil and partnerSelect ~= nil then
    if mySelect ~= "cancel" and partnerSelect ~= "cancel" then
      log("both picked: our slot %d for their slot %d", mySelect + 1, partnerSelect + 1)
      trade:sendMenu(M.SET_MONS_TO_TRADE, mySelect)
    elseif mySelect ~= "cancel" then
      trade:sendMenu(M.PARTNER_CANCEL_TRADE, 0)
    elseif partnerSelect ~= "cancel" then
      trade:sendMenu(M.PLAYER_CANCEL_TRADE, 0)
    else
      log("both cancel: back to the room")
      trade:sendMenu(M.BOTH_CANCEL_TRADE, 0)
    end
    if not (mySelect ~= "cancel" and partnerSelect ~= "cancel") then mySelect, partnerSelect = nil, nil end
  end
end

local function handle(ev)
  local k = ev.type
  if k == "linked" then
    local p = ev.partner
    log("linked with %s (version %04X, trainer %d)", Pk3.decodeText(p.name), p.version, p.trainerId % 65536)
  elseif k == "room" then
    log("in the Trade Center; sitting down in a moment")
    trade.timers[#trade.timers + 1] = { at = now() + 1.5, fn = function()
      if round >= #gives and round > 0 then
        log("no more trades: waiting for the other player to leave")
      else
        trade:seat()
      end
    end }
  elseif k == "partnerSeated" then
    log("the other player sat down")
  elseif k == "menu" then
    round = round + 1
    partnerParty = ev.party
    save(("partner_party_%d.bin"):format(round), ev.party)
    log("trade menu %d; their party: %s", round, partyLine(ev.party))
    mySelect, partnerSelect, partnerConfirm = nil, nil, nil
    local give = gives[round]
    mySelect = give and (give - 1) or "cancel"
    log("we choose %s", give and ("slot " .. give) or "CANCEL")
    decide()
  elseif k == "partnerSelect" then
    partnerSelect = ev.slot or "cancel"
    log("they choose %s", ev.slot and ("slot " .. (ev.slot + 1)) or "CANCEL")
    decide()
  elseif k == "partnerConfirm" then
    log("they %s", ev.ok and "confirm" or "decline")
    if ev.ok then
      trade:sendMenu(M.START_TRADE, 0)
    else
      trade:sendMenu(M.PLAYER_CANCEL_TRADE, 0)
      mySelect, partnerSelect = nil, nil
    end
  elseif k == "finished" then
    local j = partnerSelect
    local got = partnerParty:sub(j * 100 + 1, j * 100 + 100)
    save(("received_%d.bin"):format(round), got)
    local d = Pk3.describe(got)
    log("TRADED: gave our slot %d, got %s (#%d L%d) from their slot %d", mySelect + 1, d.nickname, d.species, d.level, j + 1)
    -- the cart puts the received mon in the given mon's slot
    local s = mySelect * 100
    structs = structs:sub(1, s) .. got .. structs:sub(s + 101)
    trade:setParty({ structs = structs, mail = string.rep("\0", 220), ribbons = string.rep("\0", 40) })
  elseif k == "animDone" then
    log("animation session over; party now %s", partyLine(structs))
  elseif k == "leftRoom" or k == "ended" then
    done = true
  elseif k == "error" then
    failed = ev.message
  end
end

local function joinOrCreate()
  if codeArg == "create" then
    celio:create(function(ok, v) if ok then log("ROOM CODE %s", v) else failed = "create: " .. tostring(v) end end)
  else
    celio:join(codeArg, function(ok, v) if ok then log("joined %s", v) else failed = "join: " .. tostring(v) end end)
  end
end

local asked = false
local lastStat
local last = now()
local deadline = now() + tonumber(os.getenv("E2E_TIMEOUT") or "1800")
while not done and not failed and now() < deadline do
  local t = now()
  local dt = t - last
  last = t
  celio:update()
  if io_.connected and not asked then asked = true; joinOrCreate() end
  for _, e in ipairs(celio:takeEvents()) do
    if e == "partnerJoined" and not started then
      started = true
      log("room full: asking to lead the link")
      link:start()
      trade:start()
    elseif e == "sessionClose" then
      if not done then failed = "the session closed" end
    end
  end
  if celio.closed and not done then failed = failed or celio.error or "closed" end
  trade:update(dt)
  for _, ev in ipairs(trade:takeEvents()) do handle(ev) end
  if os.getenv("CELIO_DEBUG") and t - (lastStat or 0) > 5 then
    lastStat = t
    log("stats: link %s, sent packets %d (in flight %d), received packets %d, queued frames %d, sent frames %d, waiting %d",
        tostring(link.state), celio.sequence, celio.inflight, celio.expected, celio:pendingFrames(),
        link.outHead - 1, link:queued())
  end
  socket.sleep(0.004)
end
if failed then log("FAILED: %s", failed) end
if not done and not failed then log("timed out") end
-- let the other device play out our last frames before leaving the room
celio:closeSoon()
while io_.state ~= "closed" do
  celio:update()
  trade:update(0.004)
  socket.sleep(0.004)
end
log("left the room")
os.exit(done and 0 or 1)
