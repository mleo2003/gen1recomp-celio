-- A FireRed/LeafGreen Cable Club trade, played by a virtual GBA that leads
-- the link (multiplayer id 0), over lib/gbalink.lua.  The game's own flow
-- (pokefirered src/cable_club.c, src/trade.c, src/trade_scene.c) is a
-- chain of link sessions; this file runs the chain and leaves every choice
-- to its owner (the engine bridge, or a test's script):
--
--   setup 0x1133   LinkPlayer swap, version gate, trainer cards (0xCCCC 2),
--                  the Trade Center: standby, then held keys until both
--                  players are seated (key 0x16), then 0x5FFF
--   menu  0x1122   LinkPlayer swap, then five block requests: party 0-1,
--                  2-3, 4-5 (200 B each), mail (220), gift ribbons (40);
--                  then the trade-menu messages (20-byte blocks)
--   anim  0x1144   LinkPlayer swap, the partner's READY_FINISH_TRADE
--                  (0xABCD), ours, then CONFIRM_FINISH_TRADE (0xDCBA);
--                  standbys around its save; then menu again
--   room  0x1111   after both cancelled: LinkPlayer swap, held keys: sit
--                  again (menu) or leave (key 0x17, then the link ends)
--
-- Events (takeEvents): linked {partner}, room, partnerSeated, menu {party,
-- mail, ribbons}, partnerSelect {slot|nil}, partnerConfirm {ok},
-- finished (the partner's 0xABCD is in; the trade is final on both GBAs
-- once we send 0xDCBA), animDone, leftRoom, ended, error {message}.
--
-- The owner calls: seat() in the room, leave() to walk out, and in the
-- menu sendMenu(code, arg) with the leader's decisions (SET_MONS_TO_TRADE,
-- START_TRADE, ...), and setParty(...) before each menu session opens.

local Trade3 = {}
Trade3.__index = Trade3

Trade3.MENU = {
  READY_TO_TRADE = 0xAABB, READY_FINISH_TRADE = 0xABCD, READY_CANCEL_TRADE = 0xBBCC,
  START_TRADE = 0xCCDD, CONFIRM_FINISH_TRADE = 0xDCBA, SET_MONS_TO_TRADE = 0xDDDD,
  PLAYER_CANCEL_TRADE = 0xDDEE, REQUEST_CANCEL = 0xEEAA, BOTH_CANCEL_TRADE = 0xEEBB,
  PARTNER_CANCEL_TRADE = 0xEECC, CONFIRM = 0xBBBB,
}

local STAGE_GAP = 1.0      -- after each block pair: the follower refills its buffer 11 frames later
local CARD_DELAY = 0.75    -- after the LinkPlayer swap at the desk
local CLOSE_DELAY = 16 / 60

local function noop() end

-- opts: link (lib/gbalink.lua), Link (module), now, log,
--   identity { version, trainerId, name (Gen 3 bytes), progressFlags, gender, language },
--   card (100 bytes),
--   partyPerMenu: forget the party when a menu session ends, so every
--   menu waits for a fresh setParty (the engine re-sends its party each time)
function Trade3.new(opts)
  local self = setmetatable({
    partyPerMenu = opts.partyPerMenu,
    link = opts.link,
    Link = opts.Link,
    now = opts.now or os.clock,
    log = opts.log or noop,
    identity = opts.identity,
    card = opts.card,
    phase = "idle",
    events = {},
    timers = {},
    party = nil,       -- { structs = 600 bytes, mail = 220 bytes, ribbons = 40 bytes }
    partner = nil,     -- the partner's LinkPlayer (parsed)
    seated = false,
    partnerSeated = false,
  }, Trade3)
  return self
end

function Trade3:emit(ev)
  self.events[#self.events + 1] = ev
  self.log("trade3: %s", ev.type)
end

function Trade3:takeEvents()
  local out = self.events
  self.events = {}
  return out
end

function Trade3:fail(why)
  if self.phase == "error" then return end
  self.phase = "error"
  self:emit({ type = "error", message = why })
end

function Trade3:after(seconds, fn)
  self.timers[#self.timers + 1] = { at = self.now() + seconds, fn = fn }
end

function Trade3:localBlock(linkType)
  local id = self.identity
  return self.Link.linkPlayerBlock({
    version = id.version, trainerId = id.trainerId, name = id.name,
    progressFlags = id.progressFlags, gender = id.gender, linkType = linkType,
    id = 0, language = id.language or 2,
  })
end

function Trade3:open(phase, linkType)
  self.phase = phase
  self.linkType = linkType
  self.stage = nil
  self.log("trade3: open %s (%04X)", phase, linkType)
  self.link:open(linkType, self:localBlock(linkType))
end

-- ------------------------------------------------------------------
-- the owner's side
-- ------------------------------------------------------------------

function Trade3:start() self:open("setup", self.Link.LINKTYPE.TRADE_SETUP) end

function Trade3:setParty(party) self.party = party end

-- our player sat down in the Trade Center (kept until the room is open,
-- when it comes early: after a both-cancel the room re-links first)
function Trade3:seat()
  self.wantSeat = true
  if self.seated then return end
  if self.phase == "room" or self.phase == "setupRoom" then
    self.seated = true
    self.link:keys(self.Link.KEY.READY)
    self:maybeStartTrade()
  end
end

-- our player walks out
function Trade3:leave()
  if self.phase == "room" or self.phase == "setupRoom" then
    self.leaving = true
    self.link:keys(self.Link.KEY.EXIT_ROOM)
  end
end

-- a trade-menu message, as a 20-byte block
function Trade3:sendMenu(code, arg)
  local s = string.char(code % 256, math.floor(code / 256), (arg or 0) % 256, math.floor((arg or 0) / 256))
  self.link:sendBlock(s .. string.rep("\0", 16))
  local M = Trade3.MENU
  if code == M.START_TRADE then
    self:after(CLOSE_DELAY, function() self.link:close(32) end)
    self.next = "anim"
  elseif code == M.BOTH_CANCEL_TRADE then
    self:after(CLOSE_DELAY, function() self.link:close(12) end)
    self.next = "room"
  end
end

-- ------------------------------------------------------------------
-- the flow
-- ------------------------------------------------------------------

function Trade3:maybeStartTrade()
  if self.seated and self.partnerSeated and not self.closing then
    self.closing = true
    self.wantSeat = false
    self.next = "menu"
    self.link:close(0)
  end
end

function Trade3:onLinkPlayer(block)
  local p = self.Link.parseLinkPlayer(block)
  self.partner = p
  if p.linkType ~= self.linkType then
    return self:fail(("the other game chose something else (link type %04X)"):format(p.linkType))
  end
  local phase = self.phase
  if phase == "setup" then
    local v = p.version % 256
    if v ~= 4 and v ~= 5 then
      -- Ruby/Sapphire/Emerald partners need progress checks this side
      -- does not make; FireRed/LeafGreen trade freely
      self.log("trade3: partner version %04X is not FireRed/LeafGreen", p.version)
    end
    self:after(CARD_DELAY, function()
      self.link:requestBlock(2)
      self.link:sendBlock(self.card)
      self.stage = "card"
    end)
  elseif phase == "menu" then
    self.stage = 0
    self.blocksIn = {}
    self:after(STAGE_GAP, function() self:requestStage() end)
  elseif phase == "anim" then
    self.stage = "waitFinish"
  elseif phase == "room" then
    self.seated, self.partnerSeated, self.closing = false, false, false
    self:emit({ type = "room" })
    if self.wantSeat then self:seat() end
  end
end

local STAGES = {
  { req = 1, from = 0, size = 200 }, { req = 1, from = 200, size = 200 }, { req = 1, from = 400, size = 200 },
  { req = 3, mail = true, size = 220 }, { req = 4, ribbons = true, size = 40 },
}

function Trade3:requestStage()
  local party = self.party
  if not party then
    -- the owner's party is not in yet (after a trade the engine saves
    -- first): the other GBA just waits on "Communication standby"
    return self:after(0.1, function() self:requestStage() end)
  end
  self.stage = (self.stage or 0) + 1
  local st = STAGES[self.stage]
  local bytes
  if st.mail then
    bytes = (party.mail or "") .. string.rep("\0", 220)
  elseif st.ribbons then
    bytes = (party.ribbons or "") .. string.rep("\0", 40)
  else
    bytes = party.structs:sub(st.from + 1, st.from + st.size)
  end
  bytes = bytes:sub(1, st.size)
  self.link:requestBlock(st.req)
  self.link:sendBlock(bytes)
end

function Trade3:onBlock(data)
  local phase = self.phase
  if phase == "setup" and self.stage == "card" then
    self.partnerCard = data
    self.stage = "warp"
    self:emit({ type = "linked", partner = self.partner, card = data })
    return
  end
  if phase == "menu" and type(self.stage) == "number" and self.stage <= #STAGES and not self.menuOpen then
    self.blocksIn[self.stage] = data
    if self.stage < #STAGES then
      self:after(STAGE_GAP, function() self:requestStage() end)
    else
      self.menuOpen = true
      local b = self.blocksIn
      self:emit({ type = "menu", party = b[1] .. b[2] .. b[3], mail = b[4], ribbons = b[5] })
    end
    return
  end
  -- 20-byte trade messages
  local code = data:byte(1) + data:byte(2) * 256
  local arg = data:byte(3) + data:byte(4) * 256
  local M = Trade3.MENU
  if phase == "menu" and self.menuOpen then
    if code == M.READY_TO_TRADE then
      self:emit({ type = "partnerSelect", slot = arg })
    elseif code == M.REQUEST_CANCEL then
      self:emit({ type = "partnerSelect", slot = nil })
    elseif code == M.CONFIRM then
      self:emit({ type = "partnerConfirm", ok = true })
    elseif code == M.READY_CANCEL_TRADE then
      self:emit({ type = "partnerConfirm", ok = false })
    end
  elseif phase == "anim" and code == M.READY_FINISH_TRADE and self.stage == "waitFinish" then
    -- the partner's animation is over and it has swapped; ours, then the
    -- leader's confirmation, which makes the partner save
    self.stage = "saving"
    self:sendMenu(M.READY_FINISH_TRADE, 0)
    self:sendMenu(M.CONFIRM_FINISH_TRADE, 0)
    self:emit({ type = "finished" })
  end
end

function Trade3:onClosed(ev)
  self.closing = false
  if ev.exitRoom then
    self.phase = "done"
    self:emit({ type = "leftRoom" })
    self:emit({ type = "ended" })
    return
  end
  local nextPhase = self.next
  self.next = nil
  self.menuOpen = false
  if self.phase == "menu" and self.partyPerMenu then self.party = nil end
  if self.phase == "anim" then
    self:emit({ type = "animDone" })
    nextPhase = "menu"
  end
  if nextPhase == "menu" then
    self:open("menu", self.Link.LINKTYPE.TRADE_CONNECTING)
  elseif nextPhase == "anim" then
    self:open("anim", self.Link.LINKTYPE.TRADE_DISCONNECTED)
  elseif nextPhase == "room" then
    self:open("room", self.Link.LINKTYPE.TRADE)
  else
    self:fail("the link closed unexpectedly")
  end
end

function Trade3:update(dt)
  local link = self.link
  link:update(dt)
  local t = self.now()
  local due = {}
  for i = #self.timers, 1, -1 do
    if self.timers[i].at <= t then
      due[#due + 1] = self.timers[i].fn
      table.remove(self.timers, i)
    end
  end
  for i = #due, 1, -1 do due[i]() end
  for _, ev in ipairs(link:takeEvents()) do
    local kind = ev.type
    if kind == "linkPlayer" then
      self:onLinkPlayer(ev.block)
    elseif kind == "block" then
      self:onBlock(ev.data)
    elseif kind == "standby" then
      -- one for one; in the Trade Center the first one starts the room
      link:standby()
      if self.phase == "setup" and self.stage == "warp" then
        self.phase = "setupRoom"
        self.seated, self.partnerSeated = false, false
        self:emit({ type = "room" })
        if self.wantSeat then self:seat() end
      end
    elseif kind == "keys" then
      local K = self.Link.KEY
      if ev.key == K.READY then
        if not self.partnerSeated then
          self.partnerSeated = true
          self:emit({ type = "partnerSeated" })
          self:maybeStartTrade()
        end
      elseif ev.key == K.EXIT_SEAT then
        self.partnerSeated = false
      elseif ev.key == K.EXIT_ROOM then
        if not self.leaving then
          self.leaving = true
          link:keys(K.EXIT_ROOM)
        end
      end
    elseif kind == "close" then
      -- the partner closes after START_TRADE / BOTH_CANCEL (it may beat our
      -- own 16-frame delay), after its save, and on the way out of the room
      if self.phase == "anim" or self.leaving or self.next then
        link:close(ev.kind)
      elseif self.phase == "setupRoom" or self.phase == "room" then
        link:close(ev.kind)
        self.next = "menu"
      else
        link:close(ev.kind)
      end
    elseif kind == "closed" then
      self:onClosed(ev)
    elseif kind == "error" then
      self:fail(ev.message)
    end
  end
end

return Trade3
