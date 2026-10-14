-- A fake Celio room with a scripted FireRed behind it, for tests: the same
-- interface as lib/celio.lua (what lib/gbalink.lua and lib/visit3.lua
-- use), and on the far side a follower GBA (multiplayer id 1) that plays
-- pokefirered's Cable Club the way the real cart did over celio.gblink.io:
-- LinkPlayer swap, trainer card, room standby, sitting down, the five
-- party blocks, picks and confirms, 0xABCD, the save standbys after
-- 0xDCBA, the room re-link and walking out.
--
--   local celio, cart = FakeCart3.new({ party = <600 B>, script = {...}, now = fn })
--   script: list of rounds, each { give = <1-based slot> } or { cancel = true },
--           or { stay = true } (back in the room: wait there); after the
--           last round the cart walks out of the room (unless stayInRoom).
--   dropIn: a link type; the room drops when that link session opens.
--   cart.received[n]  the 100 B struct the cart got in trade n
--   cart.party        its party now (600 B)

local FakeCart3 = {}

local CMD = { LINK_TYPE = 0x2222, STANDBY = 0x2FFE, CLOSE = 0x5FFF, CONT = 0x8888, INIT = 0xBBBB,
              KEYS = 0xCAFE, REQ = 0xCCCC }
local MENU = { READY_TO_TRADE = 0xAABB, READY_FINISH_TRADE = 0xABCD, START_TRADE = 0xCCDD,
               CONFIRM_FINISH_TRADE = 0xDCBA, SET_MONS_TO_TRADE = 0xDDDD, PLAYER_CANCEL_TRADE = 0xDDEE,
               REQUEST_CANCEL = 0xEEAA, BOTH_CANCEL_TRADE = 0xEEBB, PARTNER_CANCEL_TRADE = 0xEECC,
               CONFIRM = 0xBBBB }
local STATUS = { AwaitModeEmulator = 0xFF01, HandshakeReceived = 0xFF03, LinkConnected = 0xFF05,
                 LinkReconnecting = 0xFF06, LinkClosed = 0xFF07 }
local COMMAND = { SetModeSlave = 0x11, StartHandshake = 0x12 }
local MAGIC = "GameFreak inc."

local function u16(v) return string.char(v % 256, math.floor(v / 256) % 256) end
local function u32(v) return u16(v % 65536) .. u16(math.floor(v / 65536) % 65536) end

local function linkPlayer(linkType, name)
  local magic = MAGIC .. "\0\0"
  local lp = u16(0x4004) .. u16(0x8000) .. u32(33333 + 1000 * 65536) .. name
    .. string.char(0, 0, 0, 0) .. u32(linkType) .. u16(1) .. u16(2)
  return magic .. lp .. magic
end

function FakeCart3.new(opts)
  local now = opts.now or os.clock
  local cart = {
    party = opts.party, script = opts.script or {}, round = 0, received = {}, events = {},
    name = "\189\187\204\206\255\255\255\255", log = opts.log or function() end,
    out = {}, outHead = 1, outTail = 0, timers = {}, closes = 0,
  }
  local celio = {
    code = nil, inRoom = false, closed = false, error = nil,
    commands = {}, events = {}, statuses = {},
  }

  -- ---------------------------------------------------------------- cart side
  local function frame(...)
    local f = { ... }
    for w = 1, 8 do f[w] = (f[w] or 0) % 65536 end
    cart.outTail = cart.outTail + 1
    cart.out[cart.outTail] = f
  end
  local function block(bytes)
    frame(CMD.INIT, #bytes, 0x81)
    for pos = 0, #bytes - 1, 14 do
      local f = { CMD.CONT }
      for k = 0, 6 do f[k + 2] = (bytes:byte(pos + 2 * k + 1) or 0) + (bytes:byte(pos + 2 * k + 2) or 0) * 256 end
      cart.outTail = cart.outTail + 1
      cart.out[cart.outTail] = f
    end
  end
  local function menu(code, arg)
    block(u16(code) .. u16(arg or 0) .. string.rep("\0", 16))
  end
  local function after(seconds, fn) cart.timers[#cart.timers + 1] = { at = now() + seconds, fn = fn } end
  local function closeLink(t)
    if cart.sentClose then return end
    cart.sentClose = true
    frame(CMD.CLOSE, t or 0)
  end
  cart.menu = menu

  local function newSession(linkType)
    if opts.dropIn == linkType then
      -- the room drops (a browser closed, a network gone)
      celio.closed, celio.error = true, "dropped"
      return
    end
    cart.session = { type = linkType, blocks = 0, stage = 0 }
    cart.sentClose, cart.gotClose = false, false
    cart.recv = nil
    block(linkPlayer(linkType, cart.name))
  end

  local function card()
    local c = string.rep("\0", 100)
    return c:sub(1, 0x30) .. cart.name .. string.char(4) .. c:sub(0x3A)
  end

  -- what the cart does with a whole block from the leader
  local function onBlock(bytes)
    local s = cart.session
    s.blocks = s.blocks + 1
    if s.blocks == 1 then
      cart.leaderPlayer = bytes
      if s.type == 0x1144 then
        -- the trade animation, then READY_FINISH_TRADE
        after(1.0, function() menu(MENU.READY_FINISH_TRADE, 0) end)
      elseif s.type == 0x1111 then
        local nextRound = cart.script[cart.round + 1]
        if nextRound and nextRound.stay then
          cart.round = cart.round + 1     -- waits in the room
        elseif nextRound then
          after(0.5, function() frame(CMD.KEYS, 0x16) end)
        elseif not opts.stayInRoom then
          after(0.5, function() cart.leaving = true; frame(CMD.KEYS, 0x17) end)
        end
      end
      return
    end
    if s.type == 0x1133 then
      -- the leader's trainer card: into the Trade Center, room standby
      cart.leaderCard = bytes
      after(0.5, function() frame(CMD.STANDBY) end)
    elseif s.type == 0x1122 and s.stage <= 5 and not s.menuOpen then
      local parts = cart.leaderParts or {}
      cart.leaderParts = parts
      parts[s.stage] = bytes
      if s.stage == 5 then
        s.menuOpen = true
        cart.leaderParty = parts[1] .. parts[2] .. parts[3]
        cart.leaderMail = parts[4]
        cart.leaderParts = nil
        cart.round = cart.round + 1
        local r = cart.script[cart.round]
        cart.log("cart: menu %d", cart.round)
        after(0.5, function()
          if r and r.give then
            cart.pick = r.give - 1
            menu(MENU.READY_TO_TRADE, cart.pick)
          else
            menu(MENU.REQUEST_CANCEL, 0)
          end
        end)
      end
    elseif #bytes == 20 then
      local code = bytes:byte(1) + bytes:byte(2) * 256
      local arg = bytes:byte(3) + bytes:byte(4) * 256
      cart.log("cart: < %04X %d", code, arg)
      if code == MENU.SET_MONS_TO_TRADE then
        cart.leaderPick = arg
        after(0.3, function() menu(MENU.CONFIRM, 0) end)
      elseif code == MENU.START_TRADE then
        after(16 / 60, function() closeLink(32) end)
      elseif code == MENU.BOTH_CANCEL_TRADE then
        after(16 / 60, function() closeLink(12) end)
      elseif code == MENU.CONFIRM_FINISH_TRADE then
        -- TradeMons: the leader's mon into our offered slot; then evolution
        -- and the save, with its standbys
        local got = cart.leaderParty:sub(cart.leaderPick * 100 + 1, cart.leaderPick * 100 + 100)
        cart.received[#cart.received + 1] = got
        local at = cart.pick * 100
        cart.party = cart.party:sub(1, at) .. got .. cart.party:sub(at + 101)
        cart.standbys = 0
        after(0.5, function() frame(CMD.STANDBY) end)
      end
    end
  end

  local function onFrame(f)
    local w0 = f[1]
    if w0 == 0 then return end
    if w0 == CMD.LINK_TYPE then
      newSession(f[2])
    elseif w0 == CMD.INIT then
      cart.recv = { size = f[2], data = {} }
    elseif w0 == CMD.CONT then
      local r = cart.recv
      if not r then return end
      for k = 2, 8 do r.data[#r.data + 1] = u16(f[k]) end
      if #r.data * 2 >= r.size then
        cart.recv = nil
        onBlock(table.concat(r.data):sub(1, r.size))
      end
    elseif w0 == CMD.REQ then
      local s = cart.session
      if f[2] == 2 then
        block(card())
      elseif s.type == 0x1122 then
        s.stage = s.stage + 1
        if s.stage <= 3 then
          block(cart.party:sub((s.stage - 1) * 200 + 1, s.stage * 200))
        elseif s.stage == 4 then
          block(string.rep("\0", 220))
        else
          block(string.rep("\0", 40))
        end
      end
    elseif w0 == CMD.STANDBY then
      -- the leader's echo; after a trade, three of them around the save
      local s = cart.session
      if s and s.type == 0x1144 and cart.standbys then
        cart.standbys = cart.standbys + 1
        if cart.standbys < 3 then
          after(0.3, function() frame(CMD.STANDBY) end)
        else
          cart.standbys = nil
          after(0.5, function() closeLink(0) end)
        end
      end
    elseif w0 == CMD.KEYS then
      if f[2] == 0x16 then
        cart.leaderSeated = true
      elseif f[2] == 0x17 then
        -- the other player is leaving too (or first): then ReturnFromLinkRoom
        if not cart.leaving then
          cart.leaving = true
          frame(CMD.KEYS, 0x17)
        end
        after(0.5, function() closeLink(0) end)
      end
    elseif w0 == CMD.CLOSE then
      cart.gotClose = true
      closeLink(f[2])
    end
  end

  -- the cart sits down once in the Trade Center (after the room standby)
  local function sitWhenInRoom()
    local s = cart.session
    if s and s.type == 0x1133 and cart.leaderCard and not cart.sat then
      cart.sat = true
      after(1.0, function() frame(CMD.KEYS, 0x16) end)
    end
  end

  -- ---------------------------------------------------------------- the room
  function celio:connected() return true end
  function celio:create(cb) self.code, self.inRoom = "4321", true; cb(true, "4321"); self:join_() end
  function celio:join(code, cb) self.code, self.inRoom = code, true; cb(true, code); self:join_() end
  function celio:join_() self.events[#self.events + 1] = "partnerJoined" end
  function celio:takeEvents() local e = self.events; self.events = {}; return e end
  function celio:status(v)
    self.statuses[#self.statuses + 1] = v
    if v == STATUS.AwaitModeEmulator then
      self.commands[#self.commands + 1] = COMMAND.SetModeSlave
    elseif v == STATUS.HandshakeReceived then
      self.commands[#self.commands + 1] = COMMAND.StartHandshake
    elseif v == STATUS.LinkClosed then
      cart.linkClosed = true
      -- the server closes the room once both devices said LinkClosed
      self.closeAt = now() + 1
    end
  end
  function celio:takeCommand() return table.remove(self.commands, 1) end
  function celio:sendPacket(words)
    for f = 0, 3 do
      local fr = {}
      for w = 1, 8 do fr[w] = words[f * 8 + w] end
      onFrame(fr)
    end
  end
  function celio:takeFrame()
    local f = cart.out[cart.outHead]
    if not f then return nil end
    cart.out[cart.outHead] = nil
    cart.outHead = cart.outHead + 1
    return f
  end
  function celio:pendingFrames() return cart.outTail - cart.outHead + 1 end
  function celio:closeSoon(seconds) self.leaveAt = self.leaveAt or (now() + (seconds or 5)) end
  function celio:close() self.closed = true; self.inRoom = false end
  function celio:update()
    sitWhenInRoom()
    local t = now()
    local due = {}
    for i = #cart.timers, 1, -1 do
      if cart.timers[i].at <= t then
        due[#due + 1] = cart.timers[i].fn
        table.remove(cart.timers, i)
      end
    end
    for i = #due, 1, -1 do due[i]() end
    if (self.closeAt and t >= self.closeAt) or (self.leaveAt and t >= self.leaveAt) then self:close() end
  end

  return celio, cart
end

return FakeCart3
