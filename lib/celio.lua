-- One Celio relay session: a room of two "devices" keyed by a 4-digit
-- code, as the Celio server (celio.gblink.io) runs it.  This side plays
-- the device -- what a Celio USB adapter or the mGBA script is to the
-- web page -- so it reports link statuses, receives the commands the
-- server derives from both sides' statuses, and exchanges data packets of
-- four 8-word GBA link-command frames.
--
--   create(cb) / join(code, cb)      cb(ok, codeOrError)
--   status(LinkStatus value)         deviceStatus {uuid, linkStatus}
--   takeCommand()                    the next deviceCommand (deduplicated)
--   sendFrames(f1..f4)               one deviceData packet, next sequence
--   takeFrame()                      the partner's next frame, in order
--
-- Every server emit is acknowledged (sio.lua does that); deviceCommand
-- and the session events are deduplicated by uuid, data by sequence, and
-- data is delivered strictly in sequence order (the server may reorder
-- its retries).  Our own data goes out one packet per emit, at most 64
-- unacknowledged, with the same sequence number on every retry.

local Celio = {}
Celio.__index = Celio

Celio.STATUS = {
  AwaitModeEmulator = 0xFF01, AwaitMode = 0xFF02, HandshakeReceived = 0xFF03,
  HandshakeFinished = 0xFF04, LinkConnected = 0xFF05, LinkReconnecting = 0xFF06,
  LinkClosed = 0xFF07,
}
Celio.COMMAND = { SetMode = 0x00, SetModeMaster = 0x10, SetModeSlave = 0x11,
                  StartHandshake = 0x12, ConnectLink = 0x13 }

local MAX_UNACKED = 64

local function noop() end

-- opts: sio (lib/sio.lua), json, log, now, random
function Celio.new(opts)
  local self = setmetatable({
    sio = opts.sio,
    json = opts.json,
    log = opts.log or noop,
    now = opts.now or os.clock,
    random = opts.random or math.random,
    code = nil,
    inRoom = false,
    full = false,
    closed = false,
    error = nil,
    seen = {},           -- uuids of commands/events already handled
    commands = {},
    sequence = 0,        -- our next data sequence
    inflight = 0,
    outbox = {},         -- packets waiting for a free slot
    expected = 0,        -- partner's next data sequence
    buffered = {},       -- seq -> packet data (32 words)
    frames = {},         -- partner frames in order, each { w0..w7 }
    frameHead = 1,
    frameTail = 0,
    events = {},
  }, Celio)
  local io = self.sio
  io:on("partnerJoined", function(p)
    if self:dup(p) then return end
    self.full = true
    self:emitEvent("partnerJoined")
  end)
  io:on("partnerLeft", function(p)
    if self:dup(p) then return end
    self.full = false
    self:emitEvent("partnerLeft")
  end)
  io:on("sessionClose", function(p)
    if self:dup(p) then return end
    self.closed = true
    self.inRoom = false
    self:emitEvent("sessionClose")
  end)
  io:on("deviceCommand", function(p)
    if self:dup(p) then return end
    local c = type(p) == "table" and tonumber(p.command)
    if c then self.commands[#self.commands + 1] = c end
  end)
  io:on("deviceData", function(list)
    if type(list) ~= "table" then return end
    for _, packet in ipairs(list) do self:receive(packet) end
  end)
  io:on("#closed", function(why)
    self.error = self.error or why
    self.closed = true
  end)
  return self
end

function Celio:dup(p)
  local id = type(p) == "table" and p.uuid
  if not id then return false end
  if self.seen[id] then return true end
  self.seen[id] = true
  return false
end

function Celio:emitEvent(kind)
  self.events[#self.events + 1] = kind
  self.log("celio: %s", kind)
end

function Celio:takeEvents()
  local out = self.events
  self.events = {}
  return out
end

function Celio:uuid()
  local r = self.random
  return ("%08x-%04x-4%03x-%04x-%06x%06x"):format(r(0, 0x7fffffff), r(0, 0xffff), r(0, 0xfff),
                                                   0x8000 + r(0, 0x3fff), r(0, 0xffffff), r(0, 0xffffff))
end

-- ------------------------------------------------------------------
-- the room
-- ------------------------------------------------------------------

local function result(r)
  if type(r) ~= "table" then return false, "no answer" end
  if r.variant == "Ok" then return true, r.value end
  return false, r.error or "refused"
end

function Celio:create(cb)
  self.sio:emit("sessionCreate", { self.json.null }, { ack = function(r)
    local ok, v = result(r)
    if ok and type(v) == "table" and v.id then
      self.code, self.inRoom, self.full = v.id, true, v.full == true
      cb(true, v.id)
    else
      cb(false, ok and "bad answer" or v)
    end
  end })
end

function Celio:join(code, cb)
  self.sio:emit("sessionJoin", { code }, { ack = function(r)
    local ok, v = result(r)
    if ok and type(v) == "table" then
      self.code, self.inRoom, self.full = v.id or code, true, v.full == true
      if self.full then self:emitEvent("partnerJoined") end
      cb(true, self.code)
    else
      cb(false, ok and "bad answer" or v)
    end
  end })
end

-- the relay is reachable (Socket.IO handshake done)
function Celio:connected()
  return self.sio.connected == true
end

function Celio:leave()
  if self.inRoom then self.sio:emit("sessionLeft", {}) end
  self.inRoom = false
end

-- ------------------------------------------------------------------
-- device statuses and commands
-- ------------------------------------------------------------------

function Celio:status(value)
  self.log("celio: status %04X", value)
  self.sio:emit("deviceStatus", { { uuid = self:uuid(), linkStatus = value } },
                { ack = noop, retries = 5 })
end

function Celio:takeCommand()
  return table.remove(self.commands, 1)
end

-- ------------------------------------------------------------------
-- data
-- ------------------------------------------------------------------

-- words: 32 numbers (four 8-word frames)
function Celio:sendPacket(words)
  local packet = { sequence = self.sequence, data = self.json.array(words) }
  self.sequence = self.sequence + 1
  self.outbox[#self.outbox + 1] = packet
  self:pumpOut()
end

function Celio:pumpOut()
  while self.inflight < MAX_UNACKED and #self.outbox > 0 do
    local packet = table.remove(self.outbox, 1)
    self.inflight = self.inflight + 1
    self.sio:emit("deviceData", { self.json.array({ packet }) }, { ack = function()
      self.inflight = self.inflight - 1
      self:pumpOut()
    end, retries = 5 })
  end
end

function Celio:receive(packet)
  if type(packet) ~= "table" then return end
  local seq, data = tonumber(packet.sequence), packet.data
  if not seq or type(data) ~= "table" or #data ~= 32 then return end
  if seq < self.expected or self.buffered[seq] then return end
  self.buffered[seq] = data
  while self.buffered[self.expected] do
    local d = self.buffered[self.expected]
    self.buffered[self.expected] = nil
    self.expected = self.expected + 1
    for f = 0, 3 do
      local frame = {}
      for w = 1, 8 do frame[w] = (tonumber(d[f * 8 + w]) or 0) % 65536 end
      self.frameTail = self.frameTail + 1
      self.frames[self.frameTail] = frame
    end
  end
end

-- the partner's next frame (8 words), or nil
function Celio:takeFrame()
  local f = self.frames[self.frameHead]
  if not f then return nil end
  self.frames[self.frameHead] = nil
  self.frameHead = self.frameHead + 1
  return f
end

function Celio:pendingFrames()
  return self.frameTail - self.frameHead + 1
end

-- drop everything still queued from the partner (a new link session)
function Celio:flushFrames()
  self.frames = {}
  self.frameHead, self.frameTail = 1, 0
end

function Celio:update()
  if self.closeAt and (self.closed or self.now() >= self.closeAt) then
    self.closeAt = nil
    self:close()
  end
  self.sio:update()
  if self.sio.state == "closed" and not self.closed then
    self.closed = true
    self.error = self.error or self.sio.error
  end
end

function Celio:close()
  self:leave()
  self.sio:close()
end

-- Leave a little later.  The partner's device feeds our frames to its GBA
-- one per video frame, and leaving the room resets it: leave at once after
-- the last 0x5FFF and the GBA may never see it ("Communication error").
-- The server closes the session itself once both devices report
-- LinkClosed; whichever comes first.
Celio.LINGER = 5

function Celio:closeSoon(seconds)
  if not self.closeAt then self.closeAt = self.now() + (seconds or Celio.LINGER) end
end

return Celio
