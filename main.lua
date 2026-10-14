-- GB-Link Celio trades: FireRed and LeafGreen's Cable Club, online with a
-- real GBA (a Celio adapter) or mGBA through celio.gblink.io.
--
-- The Pokémon Center 2F attendant's TRADE CENTER gains a door: make a
-- room (its four-digit number is what the friend types at celio.gblink.io)
-- or join theirs.  The friend's GBA links as it would to a cable; from the
-- seat on, the trade runs on the engine's own Trade Center, animation,
-- trade evolution and save included.
--
--   lib/ws.lua, lib/json.lua, lib/sio.lua   WebSocket, JSON, Socket.IO v5
--   lib/celio.lua     one Celio room: device statuses, commands, data
--   lib/gbalink.lua   a GBA's link layer, as the link leader
--   lib/trade3.lua    pokefirered's Cable Club chain over it
--   lib/codec3.lua    party structs, mail and trainer cards <-> the engine
--   lib/bridge3.lua   the engine link's transport: the engine's messages
--                     <-> the cart's
--   lib/visit3.lua    one visit: room, link, chain, bridge
--   lib/door3.lua     the door screen inside the attendant's linkup

return function(mod)
  local GameVersion = require("src.core.GameVersion")
  if (GameVersion.generation() or 1) ~= 3 then
    mod.exports.version = mod.version
    return
  end

  local function lib(name)
    local source = assert(mod:read("lib/" .. name .. ".lua"))
    return assert(load(source, "@gblink_celio/lib/" .. name .. ".lua"))()
  end
  local Json, Ws, Sio, Celio = lib("json"), lib("ws"), lib("sio"), lib("celio")
  local GbaLink, Trade3, Codec3 = lib("gbalink"), lib("trade3"), lib("codec3")
  local Bridge3, Visit3, Door3 = lib("bridge3"), lib("visit3"), lib("door3")

  local DEFAULT_SERVER = "wss://celio-server.up.railway.app"
  mod.options:define({
    { key = "server", label = "SERVER", type = "text", default = DEFAULT_SERVER, maxLen = 96 },
  })
  local function serverUrl()
    return (tostring(mod.options:get("server") or DEFAULT_SERVER):gsub("/+$", ""))
  end

  local Link = require("src.core.game3.link")
  local LT = require("src.core.game3.link.trade")
  local Family = require("src.core.game3.link.family")
  local Natives = require("src.core.game3.scripting.natives")
  local Stack = require("src.ui.game3.stack")
  local Window = require("src.ui.game3.window")
  local Font = require("src.ui.game3.frlg_font")
  local Strings = require("src.core.Strings")
  local Wire = require("src.link.Wire")
  local Protocol = require("src.link.Protocol")

  local function now()
    return (love and love.timer and love.timer.getTime()) or os.clock()
  end
  local function log(fmt, ...)
    local ok, line = pcall(string.format, fmt, ...)
    print("[gblink_celio] " .. (ok and line or tostring(fmt)))
  end
  local function random(a, b)
    if love and love.math then return love.math.random(a, b) end
    return math.random(a, b)
  end

  -- visits being pumped, and the engine setting each one borrows
  local live = {}
  local savedLoopback

  local function newVisit()
    -- luasocket is required here, not at load: a host without it (the
    -- headless validator, a console port) still loads the mod and says why
    local okSocket, socket = pcall(require, "socket")
    if not okSocket or type(socket) ~= "table" then return nil, "no_socket" end
    local server = serverUrl()
    -- wss:// needs the engine's TLS dialer (official Windows builds, Android)
    local tls = Ws.tlsFrom(love and love.system)
    if server:match("^wss://") and not tls then return nil, "no_tls" end
    local s = Link.session() or {}
    local io = Sio.new(server, { Ws = Ws, json = Json, socket = socket, tls = tls, now = now, random = random,
                                 clientId = ("gen1recomp-%d-%d"):format(random(1, 1e9), random(1, 1e9)), log = log })
    local celio = Celio.new({ sio = io, json = Json, now = now, log = log, random = random })
    local codec = Codec3.new(Family.activeVersion())
    local lp = Family.localLinkPlayer(s)
    local identity = {
      version = lp.version, trainerId = Family.trainerId(s),
      name = codec:encodeName(s.name or "PLAYER", 7) .. "\255", progressFlags = lp.progressFlags,
      gender = (s.gender == 1 or s.gender == "female") and 1 or 0, language = 2,
    }
    local visit = Visit3.new({
      celio = celio, Celio = Celio, GbaLink = GbaLink, Trade3 = Trade3, Bridge3 = Bridge3, codec = codec,
      identity = identity, card = codec:card(Link.localTrainerCard(), s.party),
      LT = LT, Wire = Wire, Protocol = Protocol, session = function() return Link.session() end,
      now = now, log = log,
    })
    if savedLoopback == nil then savedLoopback = LT.loopbackCommit or false end
    live[#live + 1] = visit
    return visit
  end

  local function lastCode()
    local ok, saved = pcall(mod.storage.read, mod.storage, mod.game, "room")
    return ok and type(saved) == "table" and type(saved.code) == "string" and saved.code or "0000"
  end
  local function saveCode(code)
    pcall(mod.storage.write, mod.storage, mod.game, "room", { code = code })
  end

  local env = {
    Link = Link, LT = LT, Natives = Natives, Stack = Stack, Window = Window, Font = Font, Strings = Strings,
    newVisit = newVisit, lastCode = lastCode, saveCode = saveCode, log = log,
    game = function() return mod.game end,
  }

  -- the attendant's linkup: with no link open, our door first
  LT._celioTryTradeLinkup = LT._celioTryTradeLinkup or LT.tryTradeLinkup
  env.original = LT._celioTryTradeLinkup
  LT.tryTradeLinkup = function(ctx, adapters)
    local open = Link.link
    if open and open.isOpen and open:isOpen() then return env.original(ctx, adapters) end
    return Door3.run(ctx, adapters, env)
  end

  -- The engine's own Wireless Club is off while a mod like this one is on;
  -- skip its "can't go online" notice so the attendant goes straight to
  -- the cable services.
  Link._celioIsWirelessAdapterConnected = Link._celioIsWirelessAdapterConnected or Link.isWirelessAdapterConnected
  local adapterCheck = Link._celioIsWirelessAdapterConnected
  Link.isWirelessAdapterConnected = function(ctx, adapters)
    local profile, why = Link.liveProfile()
    if not profile and why == "mods" then
      Link.setResult(ctx, 0)
      return false, 0
    end
    return adapterCheck(ctx, adapters)
  end

  mod.hooks:wrap("input.step", function(nextStep, game, dt)
    for i = #live, 1, -1 do
      local v = live[i]
      local ok, err = pcall(v.update, v, tonumber(dt) or (1 / 60))
      if not ok then v:fail(tostring(err)) end
      if v.state == "ended" or (v.state == "failed" and v.celio.closed) then
        table.remove(live, i)
        if #live == 0 and savedLoopback ~= nil then
          LT.loopbackCommit = savedLoopback
          savedLoopback = nil
        end
      end
    end
    return nextStep(game, dt)
  end)

  mod.exports.version = mod.version
end
