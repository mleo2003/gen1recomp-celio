-- The engine's Cable Club, played against a real FireRed/LeafGreen.
--
-- The engine (src/core/game3/link) runs the Trade Center as link seat 0,
-- the leader, and wants a far machine that speaks its game3_* messages.
-- lib/trade3.lua runs the cable side as GBA link player 0, also the leader.
-- This file sits between them: to the engine it is the transport
-- (update/poll/send/close) and plays seat 1, the far machine; to trade3 it
-- is the owner that makes the leader's choices, which are the engine's.
--
--   engine                         bridge                  trade3 / the cart
--   game3_hello            ->  mirror it as the cart
--   game3_battle_linkup    ->  answer from the cart's LinkPlayer
--   game3_battle_seat      ->  seat()                    -> key 0x16
--                          <-  game3_battle_seat         <- the cart sat down
--   game3_trade_party      ->  structs + mail            -> setParty
--                          <-  game3_trade_party         <- menu (the cart's party)
--                          <-  READY_TO_TRADE / ...      <- partnerSelect
--   SET_MONS_TO_TRADE ...  ->                            -> sendMenu
--   START_TRADE            ->                            -> sendMenu (the cart animates,
--                                                           commits on 0xDCBA, saves)
--                          <-  game3_trade_mon + confirm <- animDone: the cart has saved
--   CONFIRM_FINISH_TRADE   <-> answered at once
--
-- The engine commits its side only after the cart has saved its own, so a
-- link that drops in the middle leaves both games as they were.

local Bridge3 = {}
Bridge3.__index = Bridge3

local function noop() end

local function copy(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = copy(v) end
  return out
end

-- opts: trade, Trade3 (lib/trade3.lua instance and module), codec (lib/codec3.lua),
--   LT (src.core.game3.link.trade), Wire, Protocol (src.link.*),
--   session (function -> the engine's session), partner (trade3's LinkPlayer),
--   partnerCard (the cart's 100-byte card or nil), log
function Bridge3.new(opts)
  local self = setmetatable({
    trade = opts.trade,
    Trade3 = opts.Trade3,
    codec = opts.codec,
    LT = opts.LT,
    Wire = opts.Wire,
    Protocol = opts.Protocol,
    session = opts.session or noop,
    partner = opts.partner,
    partnerCard = opts.partnerCard,
    log = opts.log or noop,
    -- transport fields the engine reads
    paired = true,
    closed = false,
    error = nil,
    inbox = {},
    engineSeated = false,
    cartSeated = false,
    engineClosed = false,
  }, Bridge3)
  local p = self.partner
  self.cartName = self.codec:decodeName(p.name)
  return self
end

function Bridge3:toEngine(m)
  m.seat = m.seat or 1
  self.inbox[#self.inbox + 1] = m
end

-- ------------------------------------------------------------------
-- the transport (src/link/Session.lua)
-- ------------------------------------------------------------------

function Bridge3:seat() return 0 end
function Bridge3:seats() return 2 end
function Bridge3:leave() end

function Bridge3:poll()
  local out = self.inbox
  self.inbox = {}
  return out
end

-- called many times a frame: only hands over a held pick
function Bridge3:update()
  local held = self.heldSelect
  if held and self:engineTakesPicks() then
    self.heldSelect = nil
    self:forwardSelect(held.slot)
  end
end

function Bridge3:close()
  if self.engineClosed then return end
  self.engineClosed = true
  self.log("bridge: the engine closed the link")
  -- the engine walked out: trade3 already sent the cart our 0x17; anything
  -- else (an error, a refused hello) ends the visit for the cart too
  if not self.engineLeaving and not self.done then self.abandoned = true end
end

function Bridge3:send(raw)
  local ok, m = pcall(self.Wire.sanitize, raw)
  if not ok or type(m) ~= "table" then return true end
  local fn = self["on_" .. tostring(m.type)]
  if fn then
    local okH, err = pcall(fn, self, m)
    if not okH then self:fail("bridge: " .. tostring(err)) end
  end
  return true
end

function Bridge3:fail(why)
  self.log("bridge: %s", tostring(why))
  self.error = self.error or why
end

-- ------------------------------------------------------------------
-- engine -> cart
-- ------------------------------------------------------------------

function Bridge3:on_game3_hello(m)
  -- mirror the engine's own hello as the cart (Handshake: same engine,
  -- fingerprint, ruleset and caches make it a "full" peer)
  local p = self.partner
  local h = copy(m)
  h.type, h.name, h.seat, h.relay = "game3_hello", self.cartName, 1, nil
  h.game3 = type(h.game3) == "table" and h.game3 or {}
  h.game3.seat = 1
  h.game3.trainerId = p.trainerId
  h.game3.gender = p.gender == 1 and 1 or 0
  h.game3.gameVersion = p.version
  h.game3.progressFlags = p.progressFlags
  self:toEngine(h)
  local card = self.partnerCard and self.codec:readCard(self.partnerCard)
  if card then self:toEngine({ type = "game3_link_card", card = card }) end
end

function Bridge3:on_game3_battle_linkup(m)
  local p = self.partner
  self:toEngine({ type = "game3_battle_linkup", linkType = tonumber(m.linkType) or 0x1133, players = 2,
                  version = p.version, progressFlags = p.progressFlags })
end

function Bridge3:on_game3_battle_seat()
  self.engineSeated = true
  self.trade:seat()
  self:maybeSeat()
end

-- one seat message per menu: when both players are in their chairs (a seat
-- sent early would stay in the engine's inbox and seat it next time)
function Bridge3:maybeSeat()
  if self.engineSeated and self.cartSeated then
    self.engineSeated, self.cartSeated = false, false
    self:toEngine({ type = "game3_battle_seat" })
  end
end

local function ribbonBlock(list)
  local out = {}
  for i = 1, 11 do out[i] = string.char((tonumber(type(list) == "table" and list[i]) or 0) % 256) end
  return table.concat(out) .. string.rep("\0", 40 - 11)
end

function Bridge3:on_game3_trade_party(m)
  local structs, mail = self.codec:cartParty(m.party or {}, self.session())
  self.enginePacked = m.party
  self.trade:setParty({ structs = structs, mail = mail, ribbons = ribbonBlock(m.giftRibbons) })
end

function Bridge3:on_game3_trade_cmd(m)
  local C = self.LT.LINKCMD
  local M = self.Trade3.MENU
  local cmd = tonumber(m.cmd)
  if cmd == C.SET_MONS_TO_TRADE then
    self.engineCursor = tonumber(m.cursor) or 0
    self.trade:sendMenu(M.SET_MONS_TO_TRADE, self.engineCursor)
  elseif cmd == C.START_TRADE then
    self.trading = { engineCursor = self.engineCursor, cartCursor = self.cartCursor }
    self.trade:sendMenu(M.START_TRADE, 0)
  elseif cmd == C.PLAYER_CANCEL_TRADE or cmd == C.PARTNER_CANCEL_TRADE or cmd == C.BOTH_CANCEL_TRADE then
    self.cartCursor = nil
    self.trade:sendMenu(cmd, 0)
  elseif cmd == C.CONFIRM_FINISH_TRADE then
    -- the engine's swap is done; the cart's was done (and saved) before
    -- the engine was allowed to commit
    self:toEngine({ type = "game3_trade_cmd", cmd = C.CONFIRM_FINISH_TRADE, cursor = 0 })
  end
end

function Bridge3:on_game3_trade_mon(m)
  self.engineBlock = m
  self:maybeCommit()
end

function Bridge3:on_game3_trade_confirm(m)
  if self.digest and m.digest ~= self.digest then
    self.log("bridge: the engine's digest %s is not ours %s", tostring(m.digest), tostring(self.digest))
  end
end

function Bridge3:on_game3_exit_link_room()
  self.engineLeaving = true
  self.trade:leave()
end

-- ------------------------------------------------------------------
-- cart -> engine (trade3's events)
-- ------------------------------------------------------------------

function Bridge3:engineTakesPicks()
  local s = self.LT.state
  return s == "menu" or s == "ready_wait"
end

function Bridge3:forwardSelect(slot)
  local C = self.LT.LINKCMD
  if slot then
    self.cartCursor = slot
    self:toEngine({ type = "game3_trade_cmd", cmd = C.READY_TO_TRADE, cursor = slot })
  else
    self.cartCursor = nil
    self:toEngine({ type = "game3_trade_cmd", cmd = C.REQUEST_CANCEL, cursor = 0 })
  end
end

local function ribbonList(bytes)
  local out = {}
  for i = 1, 11 do out[i] = type(bytes) == "string" and bytes:byte(i) or 0 end
  return out
end

function Bridge3:onEvent(ev)
  local k = ev.type
  local C = self.LT.LINKCMD
  if k == "partnerSeated" then
    self.cartSeated = true
    self:maybeSeat()
  elseif k == "menu" then
    local packed, records, refusal = self.codec:packParty(ev.party)
    if refusal then self.log("bridge: the engine will refuse the other party (%s)", refusal) end
    self.cartPacked, self.cartRecords, self.cartMail = packed, records, ev.mail
    self.cartCursor, self.heldSelect, self.trading, self.engineBlock = nil, nil, nil, nil
    self.cartSaved, self.digest, self.committed = false, nil, false
    local p = self.partner
    self:toEngine({ type = "game3_trade_party", party = packed, name = self.cartName,
                    trainerId = p.trainerId, gender = p.gender == 1 and 1 or 0,
                    version = p.version % 256, progressFlags = p.progressFlags,
                    giftRibbons = ribbonList(ev.ribbons) })
  elseif k == "partnerSelect" then
    -- a pick that lands while the engine shows "trade canceled" would be
    -- wiped when its player presses A: hold it until the menu is back
    if self:engineTakesPicks() then
      self:forwardSelect(ev.slot)
    else
      self.heldSelect = { slot = ev.slot }
    end
  elseif k == "partnerConfirm" then
    self:toEngine({ type = "game3_trade_cmd", cmd = ev.ok and C.INIT_BLOCK or C.READY_CANCEL_TRADE, cursor = 0 })
  elseif k == "finished" then
    self.log("bridge: the other game has the trade; it saves next")
  elseif k == "animDone" then
    -- the cart closed the trade session after its save standbys
    self.cartSaved = true
    self:maybeCommit()
  elseif k == "leftRoom" or k == "ended" then
    self.done = true
    if not self.engineLeaving and not self.engineClosed and not self.byeSent then
      self.byeSent = true
      self:toEngine({ type = "game3_bye", reason = "partner_left" })
    end
  elseif k == "error" then
    self:fail(ev.message)
  end
end

-- the cart has saved and the engine's block is in: let the engine commit
function Bridge3:maybeCommit()
  if not (self.cartSaved and self.engineBlock and self.trading) or self.committed then return end
  local i = self.trading.cartCursor or self.cartCursor or 0
  local packed = self.cartPacked and self.cartPacked[i + 1]
  if not packed then return self:fail("no POKéMON in the other player's slot " .. (i + 1)) end
  local record = self.cartRecords[i + 1]
  local mailIndex = record and tonumber(record.mail)
  local mail = mailIndex and mailIndex < 6 and self.codec:mailRecord(self.cartMail, mailIndex) or nil
  local p = self.partner
  local mine = { type = "game3_trade_mon", mon = packed, mail = mail, name = self.cartName, trainerId = p.trainerId }
  local theirs = self.Wire.sanitize(copy(mine)).mon
  self.digest = self.Protocol.tradeDigest(self.engineBlock.mon, theirs)
  self.committed = true
  self:toEngine(mine)
  self:toEngine({ type = "game3_trade_confirm", digest = self.digest })
  self.log("bridge: the other game saved; the engine commits (%s)", self.digest)
end

return Bridge3
