-- One visit to the Cable Club over Celio: the relay room, the virtual GBA
-- (lib/gbalink.lua + lib/trade3.lua) and, once the other GBA has linked,
-- the bridge (lib/bridge3.lua) the engine's own link runs on.
--
--   local visit = Visit3.new(opts)
--   visit:create()  or  visit:join("1234")
--   visit:update(dt)              every frame, for the whole visit
--   visit.state                   connecting | joining | room | linking |
--                                 linked | open | ending | ended | failed
--   visit.code, visit.error, visit.partnerName
--   visit:attach(Link, game)      linked -> open: Link.open on the bridge
--   visit:cancel()                leave (before or after linking)
--
-- The visit outlives the engine's link: when the engine's player walks out
-- the cart still has to hear it (key 0x17, then 0x5FFF), and the room is
-- left a few seconds later so its device can play our last frames out.

local Visit3 = {}
Visit3.__index = Visit3

local function noop() end

-- opts: celio (a lib/celio.lua session, or a test double), Celio, GbaLink,
--   Trade3, Bridge3 (modules), codec (lib/codec3.lua), identity, card,
--   LT, Wire, Protocol (engine modules), session (fn), now, log, debug
function Visit3.new(opts)
  local self = setmetatable({
    o = opts,
    celio = opts.celio,
    now = opts.now or os.clock,
    log = opts.log or noop,
    state = "connecting",
  }, Visit3)
  self.link = opts.GbaLink.new({ celio = self.celio, Celio = opts.Celio, now = self.now, log = self.log,
                                 debug = opts.debug })
  self.trade = opts.Trade3.new({ link = self.link, Link = opts.GbaLink, now = self.now, log = self.log,
                                 identity = opts.identity, card = opts.card, partyPerMenu = true })
  return self
end

function Visit3:create() self.want = { create = true } end
function Visit3:join(code) self.want = { code = code } end

function Visit3:fail(why)
  if self.state == "failed" or self.state == "ended" then return end
  self.log("visit: %s", tostring(why))
  self.error = self.error or why
  self.state = "failed"
  if self.bridge then
    self.bridge.error = self.bridge.error or why
    self.bridge.closed = true
  end
  self.celio:closeSoon(0)
end

-- leave: before linking at once, after it as politely as the cart allows
function Visit3:cancel()
  if self.state == "ended" or self.state == "failed" then return end
  if self.bridge then
    self.bridge.closed = true
  end
  self.state = "ending"
  self.celio:closeSoon(0)
end

function Visit3:attach(Link, game)
  if self.state ~= "linked" then return nil, "not linked" end
  local o = self.o
  self.bridge = o.Bridge3.new({
    trade = self.trade, Trade3 = o.Trade3, codec = o.codec, LT = o.LT, Wire = o.Wire, Protocol = o.Protocol,
    session = o.session, partner = self.partner, partnerCard = self.partnerCard, log = self.log,
  })
  self.state = "open"
  return Link.open({ transport = self.bridge, seat = 0, seats = 2, linkType = 0x1133, game = game })
end

function Visit3:onTradeEvent(ev)
  local k = ev.type
  if k == "linked" then
    self.partner = ev.partner
    self.partnerCard = ev.card
    self.partnerName = self.o.codec:decodeName(ev.partner.name)
    if self.state == "linking" then self.state = "linked" end
  elseif k == "error" then
    self:fail(ev.message)
    return
  end
  if self.bridge then self.bridge:onEvent(ev) end
  if k == "ended" and self.state ~= "failed" then
    self.state = "ending"
    self.celio:closeSoon()
  end
end

function Visit3:update(dt)
  local c = self.celio
  c:update()
  if self.state == "ended" or self.state == "failed" then return end
  if self.state == "connecting" and c:connected() and self.want then
    local want = self.want
    self.want = nil
    self.state = "joining"
    local function done(ok, v)
      if not ok then return self:fail(v) end
      self.code = v
      if self.state == "joining" then self.state = "room" end
    end
    if want.create then c:create(done) else c:join(want.code, done) end
  end
  for _, e in ipairs(c:takeEvents()) do
    if e == "partnerJoined" and self.state == "room" then
      self.state = "linking"
      self.link:start()
      self.trade:start()
    elseif e == "partnerLeft" and self.state ~= "ending" then
      self:fail("partner_left")
    end
  end
  if c.closed then
    if self.state == "ending" then
      self.state = "ended"
    else
      self:fail(c.error or "closed")
    end
    if self.bridge then self.bridge.closed = true end
    return
  end
  self.trade:update(dt)
  for _, ev in ipairs(self.trade:takeEvents()) do self:onTradeEvent(ev) end
  local b = self.bridge
  if b and self.state == "open" and (b.abandoned or b.error) then
    self:fail(b.error or "the game closed the link")
  end
end

return Visit3
