-- A virtual GBA's link layer (pokefirered src/link.c, cable mode) on a
-- Celio relay session, as the link LEADER (multiplayer id 0): what a real
-- GBA's link code and a Celio adapter between them do for one side.
--
-- One "link session" is one OpenLink()..CloseLink() of the game: the
-- status handshake with the server, then a 60 Hz command clock carrying
-- 8-word frames until both sides have sent READY_CLOSE_LINK (0x5FFF).
-- A FRLG trade is several of these in a row (0x1133, 0x1122, 0x1144,
-- 0x1111); lib/trade3.lua decides which, this file runs each one.
--
--   link:open(linkType, localPlayer)   status handshake, then 0x2222 + our
--                                     LinkPlayer block; the partner's comes
--                                     back as an event
--   link:sendBlock(bytes)             INIT_BLOCK + CONT_BLOCKs
--   link:command(w0, w1, ...)         one frame
--   link:requestBlock(t)              0xCCCC t (the partner sends its buffer;
--                                     we must send ours too)
--   link:standby()                    0x2FFE
--   link:close(t)                     0x5FFF t; the session ends once the
--                                     partner's 0x5FFF is in
--   link:update(dt)                   the clock; events come from takeEvents()
--
-- Events: { type = "connected" }, { type = "linkPlayer", block = bytes },
-- { type = "block", data = bytes }, { type = "standby" }, { type = "close" },
-- { type = "keys", key = k }, { type = "closed", exitRoom = bool },
-- { type = "error", message = ... }.
--
-- Frames go out at most one per 1/60 s and four to a Celio packet, the
-- cadence a real adapter has, because the partner GBA takes one frame per
-- video frame and faults when 50 are queued.

local bit = require("bit")

local Link = {}
Link.__index = Link

Link.CMD = {
  SEND_LINK_TYPE = 0x2222, READY_EXIT_STANDBY = 0x2FFE, READY_CLOSE_LINK = 0x5FFF,
  CONT_BLOCK = 0x8888, INIT_BLOCK = 0xBBBB, SEND_HELD_KEYS = 0xCAFE, SEND_BLOCK_REQ = 0xCCCC,
}
Link.BLOCK_REQ_SIZE = { [0] = 200, [1] = 200, [2] = 100, [3] = 220, [4] = 40 }
Link.LINKTYPE = { TRADE = 0x1111, TRADE_CONNECTING = 0x1122, TRADE_SETUP = 0x1133,
                  TRADE_DISCONNECTED = 0x1144 }
Link.KEY = { EMPTY = 0x11, DOWN = 0x12, UP = 0x13, LEFT = 0x14, RIGHT = 0x15, READY = 0x16,
             EXIT_ROOM = 0x17, START = 0x18, A = 0x19, IDLE = 0x1A, EXIT_SEAT = 0x1D }

local FRAME = 1 / 60
local CONNECT_DELAY = 0.5      -- the adapter's pause before reporting LinkConnected as leader
local MAGIC = "GameFreak inc."

local function noop() end

-- opts: celio (lib/celio.lua), Celio (module, for the enums), now, log
function Link.new(opts)
  local self = setmetatable({
    celio = opts.celio,
    S = opts.Celio.STATUS,
    C = opts.Celio.COMMAND,
    now = opts.now or os.clock,
    log = opts.log or noop,
    role = nil,              -- "leader" once the server said SetModeSlave
    state = "idle",          -- idle | mode | handshake | starting | connected | closing
    out = {},                -- frames waiting for the clock (outHead..outTail)
    outHead = 1,
    outTail = 0,
    batch = {},              -- frames of the packet being filled
    acc = 0,
    events = {},
    recv = nil,              -- partner block being received { size, data = {} }
    linkPlayerIn = false,    -- the partner's LinkPlayer block has arrived this session
    sentClose = false,
    gotClose = false,
    exitRoom = false,
    sessions = 0,
    debug = opts.debug,
  }, Link)
  return self
end

function Link:emit(ev) self.events[#self.events + 1] = ev end

function Link:takeEvents()
  local out = self.events
  self.events = {}
  return out
end

function Link:fail(why)
  self.state = "error"
  self.error = why
  self.log("link: %s", tostring(why))
  self:emit({ type = "error", message = why })
end

-- ------------------------------------------------------------------
-- the Celio side: mode once, then a status handshake per link session
-- ------------------------------------------------------------------

-- once the room is full: ask to lead (AwaitModeEmulator -> SetModeSlave)
function Link:start()
  self.state = "mode"
  self.celio:status(self.S.AwaitModeEmulator)
end

-- open a link session of this type; `player` = { block = 60 bytes } (our LinkPlayerBlock)
function Link:open(linkType, localBlock)
  self.linkType = linkType
  self.localBlock = localBlock
  self.linkPlayerIn = false
  self.sentClose, self.gotClose = false, false
  self.recv = nil
  self.out, self.outHead, self.outTail, self.batch = {}, 1, 0, {}
  if self.state == "mode" then
    self.pendingOpen = true          -- after the mode arrives
    return
  end
  self.state = "handshake"
  self.celio:status(self.S.HandshakeReceived)
end

function Link:handleCommand(c)
  local C = self.C
  if c == C.SetModeSlave or c == C.SetModeMaster then
    self.role = c == C.SetModeSlave and "leader" or "follower"
    self.log("link: role %s", self.role)
    if self.role ~= "leader" then
      return self:fail("the other device also asked to lead the link")
    end
    if self.state == "mode" then
      self.state = "idle"
      if self.pendingOpen then
        self.pendingOpen = nil
        self.state = "handshake"
        self.celio:status(self.S.HandshakeReceived)
      end
    end
  elseif c == C.StartHandshake then
    if self.state == "handshake" then
      self.state = "starting"
      self.startAt = self.now() + CONNECT_DELAY
    end
  elseif c == C.ConnectLink then
    -- the leader's own LinkConnected comes back to it as the partner's
    -- ConnectLink: nothing to do
  end
end

function Link:connected()
  self.state = "connected"
  self.sessions = self.sessions + 1
  self.celio:status(self.S.LinkConnected)
  self.acc = 0
  self:emit({ type = "connected", linkType = self.linkType })
  -- the leader's first frame: the link type; every GBA (the leader too,
  -- through its own echo) then sends its LinkPlayer block
  self:command(Link.CMD.SEND_LINK_TYPE, self.linkType)
  self:sendBlock(self.localBlock)
end

-- ------------------------------------------------------------------
-- sending
-- ------------------------------------------------------------------

function Link:push(f)
  self.outTail = self.outTail + 1
  self.out[self.outTail] = f
end

function Link:command(...)
  local f = { ... }
  for w = 1, 8 do f[w] = (f[w] or 0) % 65536 end
  self:push(f)
end

function Link:sendBlock(bytes)
  local size = #bytes
  self:command(Link.CMD.INIT_BLOCK, size, 0x80)
  for pos = 0, size - 1, 14 do
    local f = { Link.CMD.CONT_BLOCK }
    for k = 0, 6 do
      local lo = bytes:byte(pos + 2 * k + 1) or 0
      local hi = bytes:byte(pos + 2 * k + 2) or 0
      f[k + 2] = lo + hi * 256
    end
    self:push(f)
  end
end

function Link:requestBlock(t) self:command(Link.CMD.SEND_BLOCK_REQ, t) end
function Link:standby() self:command(Link.CMD.READY_EXIT_STANDBY) end
function Link:keys(k) self:command(Link.CMD.SEND_HELD_KEYS, k) end

function Link:close(t)
  if self.sentClose then return end
  self.sentClose = true
  self:command(Link.CMD.READY_CLOSE_LINK, t or 0)
end

function Link:idle()
  return self.outHead > self.outTail
end

function Link:queued()
  return self.outTail - self.outHead + 1
end

-- ------------------------------------------------------------------
-- receiving
-- ------------------------------------------------------------------

local function hex(f)
  local t = {}
  for i = 1, 8 do t[i] = ("%04X"):format(f[i] or 0) end
  return table.concat(t, " ")
end
Link.hex = hex

function Link:handleFrame(f)
  local w0 = f[1]
  local CMD = Link.CMD
  if w0 == 0 then return end
  if self.debug then self.log("link < %s", hex(f)) end
  if w0 == CMD.INIT_BLOCK then
    local size = f[2]
    if size < 1 or size > 0x100 then return self:fail(("bad block size %d"):format(size)) end
    self.recv = { size = size, data = {} }
  elseif w0 == CMD.CONT_BLOCK then
    local r = self.recv
    if not r then return end
    for k = 2, 8 do
      local w = f[k]
      r.data[#r.data + 1] = string.char(w % 256, math.floor(w / 256))
    end
    if #r.data * 2 >= r.size then
      local bytes = table.concat(r.data):sub(1, r.size)
      self.recv = nil
      if not self.linkPlayerIn then
        self.linkPlayerIn = true
        if bytes:sub(1, #MAGIC) ~= MAGIC or bytes:sub(45, 44 + #MAGIC) ~= MAGIC then
          return self:fail("the other game's player data is damaged")
        end
        self:emit({ type = "linkPlayer", block = bytes })
      else
        self:emit({ type = "block", data = bytes })
      end
    end
  elseif w0 == CMD.READY_EXIT_STANDBY then
    self:emit({ type = "standby" })
  elseif w0 == CMD.READY_CLOSE_LINK then
    self.gotClose = true
    self:emit({ type = "close", kind = f[2] })
  elseif w0 == CMD.SEND_HELD_KEYS then
    if f[2] == Link.KEY.EXIT_ROOM then self.exitRoom = true end
    self:emit({ type = "keys", key = f[2] })
  elseif w0 == CMD.SEND_BLOCK_REQ then
    self:emit({ type = "blockRequest", req = f[2] })
  elseif w0 == CMD.SEND_LINK_TYPE then
    -- only a leader sends it; two leaders is a misconfigured room
    self:emit({ type = "linkType", value = f[2] })
  end
end

-- ------------------------------------------------------------------
-- the clock
-- ------------------------------------------------------------------

function Link:flushBatch(force)
  local b = self.batch
  if #b == 0 then return end
  if #b < 4 and not force then return end
  local words, any = {}, false
  for i = 1, 4 do
    local f = b[i] or { 0, 0, 0, 0, 0, 0, 0, 0 }
    for w = 1, 8 do
      words[#words + 1] = f[w]
      if f[w] ~= 0 then any = true end
    end
  end
  self.batch = {}
  if any then self.celio:sendPacket(words) end
end

function Link:update(dt)
  for _ = 1, 64 do
    local c = self.celio:takeCommand()
    if not c then break end
    self:handleCommand(c)
  end
  if self.state == "starting" and self.now() >= self.startAt then
    self:connected()
  end
  if self.state ~= "connected" then return end
  -- the partner's frames: we have no 50-frame queue of our own to protect
  for _ = 1, 256 do
    local f = self.celio:takeFrame()
    if not f then break end
    self:handleFrame(f)
    if self.state ~= "connected" then return end
  end
  -- our frames, one per 1/60 s
  self.acc = self.acc + (dt or FRAME)
  local ticks = 0
  while self.acc >= FRAME and ticks < 4 do
    self.acc = self.acc - FRAME
    ticks = ticks + 1
    local f = self.out[self.outHead]
    if f then
      self.out[self.outHead] = nil
      self.outHead = self.outHead + 1
      if self.debug then self.log("link > %s", hex(f)) end
    else
      f = { 0, 0, 0, 0, 0, 0, 0, 0 }
    end
    self.batch[#self.batch + 1] = f
    self:flushBatch(false)
  end
  if self.acc > 4 * FRAME then self.acc = 0 end
  -- both 0x5FFFs are through: the session is over
  if self.sentClose and self.gotClose and self:idle() then
    self:flushBatch(true)
    self.state = "idle"
    self.out, self.outHead, self.outTail = {}, 1, 0
    if self.exitRoom then
      self.celio:status(self.S.LinkClosed)
    else
      self.celio:status(self.S.LinkReconnecting)
    end
    self:emit({ type = "closed", exitRoom = self.exitRoom })
  end
end

-- ------------------------------------------------------------------
-- the LinkPlayerBlock (include/link.h): 60 bytes
-- ------------------------------------------------------------------

local function u16(v) return string.char(v % 256, math.floor(v / 256) % 256) end
local function u32(v) return u16(v % 65536) .. u16(math.floor(v / 65536) % 65536) end

-- p: { version (0x4004 FR / 0x4005 LG), trainerId (u32: TID | SID<<16),
--      name (8 bytes, Gen 3 charset, 0xFF terminated), progressFlags,
--      gender, linkType, id, language }
function Link.linkPlayerBlock(p)
  local magic = MAGIC .. "\0\0"
  local name = (p.name or ""):sub(1, 8)
  name = name .. string.rep("\255", 8 - #name)
  local lp = u16(p.version or 0x4004) .. u16(0x8000) .. u32(p.trainerId or 0) .. name
    .. string.char(p.progressFlags or 0x01, 0, 0, p.gender or 0)
    .. u32(p.linkType or 0) .. u16(p.id or 0) .. u16(p.language or 2)
  assert(#lp == 28)
  return magic .. lp .. magic
end

function Link.parseLinkPlayer(block)
  local b = function(i) return block:byte(i) or 0 end
  local function r16(o) return b(o + 1) + b(o + 2) * 256 end
  local function r32(o) return r16(o) + r16(o + 2) * 65536 end
  local o = 16
  return {
    version = r16(o), lpField2 = r16(o + 2), trainerId = r32(o + 4),
    name = block:sub(o + 9, o + 16), progressFlags = b(o + 17), gender = b(o + 20),
    linkType = r32(o + 20), id = r16(o + 24), language = r16(o + 26),
  }
end

return Link
