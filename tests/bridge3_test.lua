-- The engine's own Cable Club (src/core/game3/link, headless) trading with
-- a scripted FireRed (tests/fake_cart3.lua) through the mod's whole stack:
-- lib/visit3.lua, lib/bridge3.lua, lib/trade3.lua, lib/gbalink.lua and
-- lib/codec3.lua.  Only the Celio room is a test double.
--
--   POKEPORT_IDENTITY=<identity with a FireRed cache> luajit <mod>/tests/bridge3_test.lua [scenario]
--   (from the engine root; scenarios: all (default), trade, engine_leaves, drop_mid_trade)
package.path = "./?.lua;./?/init.lua;" .. package.path
local here = (arg[0] or ""):match("^(.*)/tests/[^/]+$") or "."
local only = arg[1] or "all"

local Cache = require("tests.game3_cache")
if not Cache.mount("meta.json") then print("[skip] no FireRed cache: " .. tostring(Cache.reason)) os.exit(0) end
require("tests.fixture_data.game3_items").install()
package.loaded["src.core.game3.rom_text"] = {
  plain = function(key) return key end, box = function(key) return key end,
  ascii = function(key) return key end, has = function() return true end,
  key = function(n, i, j) return j and (n .. "[" .. i .. "][" .. j .. "]") or (n .. "[" .. i .. "]") end,
  at = function(n, i, j) return j and (n .. "[" .. i .. "][" .. j .. "]") or (n .. "[" .. i .. "]") end,
  count = function() return 0 end, list = function() return {} end,
  lazy = function(map) return setmetatable({}, { __index = function(_, k) return map[k] end }) end,
}

local function lib(n) return dofile(here .. "/lib/" .. n .. ".lua") end
local GbaLink, Trade3, Pk3 = lib("gbalink"), lib("trade3"), lib("pk3")
local Codec3, Bridge3, Visit3, Door3 = lib("codec3"), lib("bridge3"), lib("visit3"), lib("door3")
local FakeCart3 = dofile(here .. "/tests/fake_cart3.lua")
local Celio = { STATUS = { AwaitModeEmulator = 0xFF01, AwaitMode = 0xFF02, HandshakeReceived = 0xFF03,
                           HandshakeFinished = 0xFF04, LinkConnected = 0xFF05, LinkReconnecting = 0xFF06,
                           LinkClosed = 0xFF07 },
                COMMAND = { SetMode = 0x00, SetModeMaster = 0x10, SetModeSlave = 0x11, StartHandshake = 0x12,
                            ConnectLink = 0x13 } }

local function read(name)
  local f = assert(io.open(here .. "/tests/fixtures/" .. name, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

local pass, fail = 0, 0
local function check(ok, what)
  if ok then pass = pass + 1 else fail = fail + 1 end
  print(("  %s %s"):format(ok and "ok  " or "FAIL", what))
end

local verbose = os.getenv("BRIDGE3_VERBOSE") ~= nil

-- one engine + one fake cart; returns the pieces and a stepper
local function world(script, opts)
  opts = opts or {}
  for name in pairs(package.loaded) do
    if name:match("^src%.core%.game3%.link") or name == "src.core.game3.trade_scene" then package.loaded[name] = nil end
  end
  local codec = Codec3.new("firered")
  local TRADE_CENTER = "FR_TRADE_CENTER"
  local MAPS = {
    FR_VIRIDIAN_CITY_POKEMON_CENTER_2F = { warps = { { x = 9, y = 1, destMap = TRADE_CENTER, destWarp = 1 } } },
    [TRADE_CENTER] = { warps = { { x = 5, y = 8, mapGroup = 0x7F, mapNum = 0x7F, destWarp = 128 } } },
  }
  -- the engine's player: RECOMP's party from a real save
  local _, records = codec:packParty(read("recomp_party.bin"))
  local party = {}
  for i, c in ipairs(records) do
    party[i] = codec.G3.toPortMon(c, true)
    codec.SaveMon.normalize(party[i])
  end
  local store = { flags = {}, vars = {} }
  local session = { store = store, map = TRADE_CENTER, x = 5, y = 8, name = "RECOMP", gender = 0,
                    trainerId = 44444, secretId = 1000, party = party, bag = { pockets = { items = {} } },
                    version = "firered" }
  local saves = 0
  local game = { data = { maps = MAPS }, session = session, saveGame = function() saves = saves + 1 return true end }
  package.loaded["src.core.game3.runtime"] = { getSession = function() return session end,
    isActive = function() return true end, _game = game, _mod = nil }
  package.loaded["src.core.game3.player"] = { cellX = 4, cellY = 5, facing = "up" }
  package.loaded["src.core.game3.quest_log_recorder"] = { event = function() end }
  package.loaded["src.core.game3.map"] = { load = function() end, current = TRADE_CENTER }
  package.loaded["src.core.game3.objects"] = { addObject = function() return true end,
    removeObject = function() return true end, refreshGraphics = function() return 0 end }
  local ctx = { specialVars = {}, stringVars = {} }
  local adapters = { log = function() end, playSe = function() end }
  package.loaded["src.core.game3.scripting.space"] = { store = store, mapId = TRADE_CENTER,
    vm = { ctx = ctx, adapters = adapters } }

  local W = { session = session, game = game, ctx = ctx, adapters = adapters, store = store, codec = codec,
              saves = function() return saves end }
  W.Link = require("src.core.game3.link")
  W.LT = require("src.core.game3.link.trade")
  W.Natives = require("src.core.game3.scripting.natives")
  W.NativesLink = require("src.core.game3.scripting.natives_link")
  W.Flags = require("src.core.game3.scripting.flags")
  local Family = require("src.core.game3.link.family")

  local t = 0
  local now = function() return t end
  local log = verbose and function(fmt, ...) print(("[%7.2f] " .. fmt):format(t, ...)) end or function() end
  local celio, cart = FakeCart3.new({ party = read(opts.cartParty or "cart_party_a.bin"), script = script, now = now,
                                      log = log, stayInRoom = opts.stayInRoom, dropIn = opts.dropIn })
  W.cart = cart
  local lp = Family.localLinkPlayer(session)
  local identity = { version = lp.version, trainerId = Family.trainerId(session),
                     name = codec:encodeName(session.name, 7) .. "\255", progressFlags = lp.progressFlags,
                     gender = 0, language = 2 }
  W.visit = Visit3.new({
    celio = celio, Celio = Celio, GbaLink = GbaLink, Trade3 = Trade3, Bridge3 = Bridge3, codec = codec,
    identity = identity, card = codec:card(W.Link.localTrainerCard(), session.party),
    LT = W.LT, Wire = require("src.link.Wire"), Protocol = require("src.link.Protocol"),
    session = function() return session end, now = now, log = log, debug = verbose,
  })
  function W.step(n)
    for _ = 1, n or 1 do
      t = t + 1 / 60
      W.visit:update(1 / 60)
      local ok, err = pcall(W.Link.update, 0)
      if not ok then print("[Link.update] " .. tostring(err)) end
      W.LT.update(0)
      if W.onStep then W.onStep() end
    end
  end
  function W.until_(cond, limit)
    for _ = 1, limit or 6000 do
      if cond() then return true end
      W.step(1)
    end
    return cond()
  end
  function W.special(name)
    local ctx = W.ctx
    ctx.nativePoll = nil
    local y = W.Natives.special(ctx, W.NativesLink.SPECIAL[name], W.adapters)
    if y then
      W.until_(function() return ctx.nativePoll == nil or ctx.nativePoll() end, 6000)
      ctx.nativePoll = nil
    end
    return W.Flags.getVar(W.store, ctx, W.Link.VAR_RESULT)
  end
  function W.now() return t end
  return W
end

-- the engine player at the desk: the mod's door has linked the cart, so
-- open the engine's link on the bridge and run the attendant's special
local function linkUp(W)
  W.visit:create()
  check(W.until_(function() return W.visit.state == "linked" end, 3000), "the cart links (LinkPlayer and trainer cards)")
  check(W.visit.partnerName == "CART", "the other player is CART")
  W.LT.loopbackCommit = true
  check(W.visit:attach(W.Link, W.game) ~= nil, "the engine's link opens on the bridge")
  local res = W.special("TryTradeLinkup")
  check(res == W.Link.LINKUP.SUCCESS, "TryTradeLinkup: SUCCESS (" .. tostring(res) .. ")")
  check(W.Link.peerCard and W.Link.peerCard.name == "CART", "the engine has the cart's trainer card")
  W.Flags.setVar(W.store, W.ctx, W.Link.VAR_CABLE_CLUB_STATE, W.Link.USING.TRADE_CENTER)
end

-- the same through the door screen, as a player at the desk would do it
local function linkUpThroughDoor(W)
  local Stack = require("src.ui.game3.stack")
  local LT = W.LT
  local env = {
    Link = W.Link, LT = LT, Natives = W.Natives, Stack = Stack, Strings = function(f, ...) return f:format(...) end,
    original = LT.tryTradeLinkup, newVisit = function() return W.visit end, game = function() return W.game end,
    lastCode = function() return "0421" end,
  }
  local ctx = W.ctx
  ctx.nativePoll = nil
  local y = Door3.run(ctx, W.adapters, env)
  check(y == true and Stack.top() and Stack.top().id == Door3.ID, "the door holds the attendant's script and shows")
  local function press(key)
    Stack.top().mod.handleInput({ wasPressed = function(_, k) return k == key end })
  end
  press("a")   -- MAKE A ROOM
  local finished = W.until_(function() return ctx.nativePoll == nil or ctx.nativePoll() end, 4000)
  check(finished, "the linkup finishes")
  check(not Stack.has(Door3.ID), "the door screen is gone")
  check(W.Flags.getVar(W.store, ctx, W.Link.VAR_RESULT) == W.Link.LINKUP.SUCCESS, "TryTradeLinkup: SUCCESS")
  check(W.visit.code == "4321" and W.visit.state == "open", "room 4321, the visit is open")
  ctx.nativePoll = nil
  W.Flags.setVar(W.store, ctx, W.Link.VAR_CABLE_CLUB_STATE, W.Link.USING.TRADE_CENTER)
end

local function sit(W, chair)
  W.Flags.setVar(W.store, W.ctx, 0x8005, chair or 0)
  W.special("EnterTradeSeat")
  return W.until_(function() return W.LT.state == "menu" and W.LT.peer ~= nil and #W.LT.peerParty > 0 end, 3000)
end

local scenarios = {}

function scenarios.trade()
  print("trade: the engine's KADABRA for the cart's HAUNTER, then both cancel and the cart walks out")
  local W = world({ { give = 1 }, { cancel = true } })
  linkUp(W)
  check(sit(W, 0), "both sit down: the trade menu opens with the cart's party")
  local names = {}
  for i, m in ipairs(W.LT.peerParty) do names[i] = tostring(m.species) end
  check(table.concat(names, ",") == "93,75,16", "the cart's party is HAUNTER, GRAVELER, PIDGEY (" .. table.concat(names, ",") .. ")")
  local sent = W.session.party[1]
  W.LT.offer(1)
  check(W.until_(function() return W.LT.state == "confirm" end, 600), "both picked: the engine asks to confirm")
  W.LT.confirm(true)
  -- the engine must not commit before the cart has saved
  local committedEarly
  W.onStep = function()
    if W.LT.state == "committed" or W.LT._committed then
      if committedEarly == nil then committedEarly = not (W.cart.received[1] and W.cart.standbys == nil) end
    end
  end
  check(W.until_(function() return W.LT.completed == 1 and W.LT.state == "menu" and W.LT.peer ~= nil
                                   and W.visit.trade.menuOpen end, 6000),
        "the trade completes and the menu reopens on both sides")
  W.onStep = nil
  check(committedEarly == false, "the engine committed only after the cart's save")
  check(W.saves() == 1, "the engine saved once")
  local got = W.session.party[1]
  check(got and (got.species == 93 or got.species == 94), "the engine's slot 1 is the cart's HAUNTER (or GENGAR): " .. tostring(got and got.species))
  local d = Pk3.describe(W.cart.received[1] or "")
  check(d and d.species == sent.species and d.checksumOk and d.otId % 65536 == 44444,
        "the cart got the engine's KADABRA, intact, OT 44444")
  check(W.cart.party:sub(1, 100) == W.cart.received[1], "the cart filed it in the slot it gave")
  -- round 2: the cart cancels (its script); so does the engine
  W.LT.cancelSelect()
  check(W.until_(function() return W.LT.state == "exit" end, 600), "both cancel: the engine's menu closes")
  check(W.until_(function() return W.visit.trade.phase == "room" end, 1200), "the cart is back in the Trade Center (0x1111)")
  -- the cart has no more rounds: it walks out, and the engine follows
  check(W.until_(function() return W.Link.link == nil end, 1200), "the cart walked out: the engine's link closes")
  check(W.Link.lastCloseReason == "peer_left", "  as peer_left (" .. tostring(W.Link.lastCloseReason) .. ")")
  check(W.until_(function() return W.visit.state == "ended" end, 1200), "the visit ends and leaves the room")
end

function scenarios.engine_leaves()
  print("engine_leaves: both cancel at once, the engine's player walks out")
  local W = world({ { cancel = true } }, { stayInRoom = true })
  W.cart.script = { { cancel = true }, { stay = true } }
  linkUp(W)
  check(sit(W, 1), "both sit down")
  W.LT.cancelSelect()
  check(W.until_(function() return W.LT.state == "exit" end, 600), "both cancel")
  check(W.until_(function() return W.visit.trade.phase == "room" end, 1200), "the cart is back in the room")
  W.special("ExitLinkRoom")
  W.step(2)
  check(W.Link.link == nil, "the engine left")
  check(W.until_(function() return W.cart.leaving and W.cart.sentClose end, 600), "the cart heard 0x17 and closed")
  check(W.until_(function() return W.visit.state == "ended" end, 1200), "the visit ends")
  check(W.cart.linkClosed, "the cart's device reported LinkClosed")
end

function scenarios.drop_mid_trade()
  print("drop_mid_trade: the room drops while the cart animates; nobody trades")
  local W = world({ { give = 1 } }, { dropIn = 0x1144 })
  linkUp(W)
  check(sit(W, 0), "both sit down")
  local before = W.session.party[1]
  W.LT.offer(1)
  W.until_(function() return W.LT.state == "confirm" end, 600)
  W.LT.confirm(true)
  check(W.until_(function() return W.visit.state == "failed" end, 3000), "the visit fails when the room drops")
  W.step(30)
  check(W.session.party[1] == before, "the engine kept its KADABRA")
  check(W.cart.received[1] == nil, "the cart never committed")
  check(W.saves() == 0, "the engine did not save a trade")
  check(W.Link.link == nil and not W.LT._committed, "the engine's link closed without a commit")
end

function scenarios.door()
  print("door: MAKE A ROOM at the desk, the cart joins, one trade")
  local W = world({ { give = 2 }, { cancel = true } })
  linkUpThroughDoor(W)
  check(sit(W, 0), "both sit down")
  W.LT.offer(2)
  check(W.until_(function() return W.LT.state == "confirm" end, 600), "both picked")
  W.LT.confirm(true)
  check(W.until_(function() return W.LT.completed == 1 and W.LT.state == "menu" and W.visit.trade.menuOpen end, 6000),
        "the trade completes")
  check(W.session.party[2] and W.session.party[2].species == 76,
        "the engine got the cart's GRAVELER, and it evolved: GOLEM (" .. tostring(W.session.party[2] and W.session.party[2].species) .. ")")
  local d = Pk3.describe(W.cart.received[1] or "")
  check(d and d.species == 67, "the cart got the engine's MACHOKE")
end

local order = { "trade", "engine_leaves", "drop_mid_trade", "door" }
if only == "all" then
  -- one process per scenario: the engine's modules keep state between visits
  local failed = 0
  for _, name in ipairs(order) do
    local p = assert(io.popen(("luajit %q %s 2>&1"):format(arg[0], name)))
    local out = p:read("*a")
    p:close()
    io.write((out:gsub("[^\n]*pack ready[^\n]*\n", "")))
    local ok, total = out:match("(%d+)/(%d+) checks passed")
    pass, fail = pass + tonumber(ok or 0), fail + (tonumber(total or 1) - tonumber(ok or 0))
  end
  print(("all scenarios: %d/%d checks passed"):format(pass, pass + fail))
  os.exit(fail == 0 and 0 or 1)
end
assert(scenarios[only], "no scenario " .. only)
scenarios[only]()
print(("%d/%d checks passed"):format(pass, pass + fail))
os.exit(fail == 0 and 0 or 1)
