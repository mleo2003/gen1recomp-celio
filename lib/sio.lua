-- A Socket.IO client (protocol 5, over Engine.IO 4, WebSocket transport
-- only), enough for the Celio relay: one namespace ("/"), JSON events,
-- acknowledgements both ways, and the server's ping.
--
--   local io = Sio.new("wss://celio-server.up.railway.app", { Ws = Ws, json = json,
--                       socket = socket, tls = tls, now = now, clientId = "..." })
--   io:on("partnerJoined", function(payload, ack) ack(true) end)
--   io:emit("sessionJoin", { "0421" }, { ack = function(result) ... end, retries = 5 })
--   io:update()   -- every frame
--
-- Engine.IO packets are WebSocket text frames: "0{open}", "2" ping (the
-- server's; we answer "3"), "4..." message.  Socket.IO packets ride in
-- the message: "40{auth}" connect, "41" disconnect, "42[N][event,...]"
-- event (N = ack id), "43N[...]" ack, "44{...}" connect error.
--
-- An emit with an ack is retried (same payload, new ack id) when no ack
-- comes within `timeout` seconds -- the Celio client and server both do
-- this, and dedup by uuid or sequence on the far end.  A dropped socket is
-- reopened with the same clientId within the server's 5 s grace, and every
-- emit still waiting for its ack is sent again.

local Sio = {}
Sio.__index = Sio

local function noop() end

function Sio.new(base, opts)
  local self = setmetatable({
    base = tostring(base):gsub("/+$", ""),
    Ws = opts.Ws,
    json = opts.json,
    socket = opts.socket,
    tls = opts.tls,
    now = opts.now or os.clock,
    random = opts.random or math.random,
    log = opts.log or noop,
    clientId = opts.clientId,
    path = opts.path or "/socket.io/",
    reconnectFor = opts.reconnectFor or 4.5,   -- the server keeps a dropped client 5 s
    handlers = {},
    nextAck = 0,
    pending = {},       -- ack id -> { event, args, cb, at, tries, timeout, retries }
    order = {},         -- pending ack ids in emit order (for resends after a reconnect)
    state = "connecting",
    error = nil,
    lastPing = nil,
  }, Sio)
  self:openSocket()
  return self
end

function Sio:url()
  local scheme, rest = self.base:match("^(wss?)://(.+)$")
  if not scheme then
    scheme, rest = "wss", self.base:gsub("^https?://", "")
    if self.base:match("^http://") then scheme = "ws" end
  end
  return ("%s://%s%s?EIO=4&transport=websocket"):format(scheme, rest, self.path)
end

function Sio:openSocket()
  self.ws = self.Ws.new(self:url(), { socket = self.socket, tls = self.tls, now = self.now,
                                      random = self.random, userAgent = "gen1recomp-celio" })
  self.connected = false
  self.openedAt = self.now()
end

function Sio:on(event, fn) self.handlers[event] = fn end

function Sio:fail(why)
  if self.state == "closed" then return end
  self.state = "closed"
  self.error = self.error or why
  self.log("socket.io: %s", tostring(why))
  if self.handlers["#closed"] then self.handlers["#closed"](why) end
end

-- ------------------------------------------------------------------
-- sending
-- ------------------------------------------------------------------

function Sio:raw(text)
  if self.ws and not self.ws.closed then self.ws:sendText(text) end
end

local function packetArgs(json, event, args)
  local list = { event }
  for i = 1, (args.n or #args) do
    local v = args[i]
    if v == nil then v = json.null end
    list[#list + 1] = v
  end
  return list
end

-- args: a list of arguments after the event name (use json.null for null)
-- opts: { ack = function(...) end, timeout = 1, retries = 5 }
function Sio:emit(event, args, opts)
  opts = opts or {}
  args = args or {}
  if not opts.ack then
    if self.connected then
      self:raw("42" .. self.json.encode(packetArgs(self.json, event, args)))
    end
    return
  end
  local p = { event = event, args = args, cb = opts.ack, tries = 0,
              timeout = opts.timeout or 1, retries = opts.retries or 5 }
  self:sendPending(p)
end

function Sio:sendPending(p)
  local id = self.nextAck
  self.nextAck = self.nextAck + 1
  p.id = id
  p.at = self.now()
  p.tries = p.tries + 1
  self.pending[id] = p
  self.order[#self.order + 1] = id
  if self.connected then
    self:raw("42" .. id .. self.json.encode(packetArgs(self.json, p.event, p.args)))
  end
end

-- ------------------------------------------------------------------
-- receiving
-- ------------------------------------------------------------------

function Sio:handlePacket(text)
  local eio = text:sub(1, 1)
  if eio == "0" then
    local open = self.json.decode(text:sub(2)) or {}
    self.pingInterval = (open.pingInterval or 25000) / 1000
    self.pingTimeout = (open.pingTimeout or 20000) / 1000
    self.lastPing = self.now()
    self:raw("40" .. self.json.encode({ clientId = self.clientId }))
  elseif eio == "2" then
    self.lastPing = self.now()
    self:raw("3")
  elseif eio == "1" then
    self.ws:close(1000)
  elseif eio == "4" then
    local sio = text:sub(2, 2)
    local rest = text:sub(3)
    if sio == "0" then
      self.connected = true
      self.state = "open"
      self.reconnecting = nil
      -- emits waiting for their ack go out again on the new socket
      local waiting = self.order
      self.order = {}
      for _, id in ipairs(waiting) do
        local p = self.pending[id]
        if p then
          self.pending[id] = nil
          p.tries = p.tries - 1
          self:sendPending(p)
        end
      end
      if self.handlers["#connect"] then self.handlers["#connect"]() end
    elseif sio == "1" then
      self:fail("the server closed the connection")
    elseif sio == "4" then
      self:fail("the server refused the connection")
    elseif sio == "2" or sio == "3" then
      local digits, body = rest:match("^(%d*)(.*)$")
      local id = tonumber(digits)
      local list = self.json.decode(body)
      if type(list) ~= "table" then return end
      if sio == "3" then
        local p = id and self.pending[id]
        if p then
          self.pending[id] = nil
          p.cb(unpack(list, 1, #list))
        end
      else
        local event = list[1]
        local fn = self.handlers[event]
        local acked = false
        local function ack(...)
          if acked or id == nil then return end
          acked = true
          local out = { ... }
          if #out == 0 then out = { true } end
          self:raw("43" .. id .. self.json.encode(out))
        end
        if fn then
          fn(list[2], ack, list)
        end
        -- every server emit wants an ack, or the session is evicted
        ack(true)
      end
    end
  end
end

-- ------------------------------------------------------------------
-- pump
-- ------------------------------------------------------------------

function Sio:update()
  if self.state == "closed" then return end
  local ws = self.ws
  ws:update()
  for _, m in ipairs(ws:poll()) do
    if m.text then self:handlePacket(m.text) end
  end
  local t = self.now()
  -- a server that stops pinging is gone
  if self.connected and self.lastPing and self.pingInterval
     and t - self.lastPing > self.pingInterval + self.pingTimeout + 0.5 then
    ws:close(1000)
  end
  if ws.closed then
    if not self.reconnecting then
      self.reconnecting = t
      self.log("socket.io: connection lost (%s); reconnecting", tostring(ws.error or "closed"))
    end
    self.connected = false
    if t - self.reconnecting > self.reconnectFor then
      return self:fail(ws.error or "the connection to the server was lost")
    end
    if not self.nextTry or t >= self.nextTry then
      self.nextTry = t + 0.5
      self:openSocket()
    end
    return
  end
  if not self.connected and t - self.openedAt > 10 then
    return self:fail(ws.error or "the server did not answer")
  end
  -- retry emits whose ack is late
  for _, id in ipairs(self.order) do
    local p = self.pending[id]
    if p and self.connected and t - p.at > p.timeout then
      self.pending[id] = nil
      if p.tries > p.retries then
        self:fail(("the server did not answer %s"):format(p.event))
        return
      end
      self:sendPending(p)
    end
  end
  -- forget ids that have been answered
  local keep = {}
  for _, id in ipairs(self.order) do
    if self.pending[id] then keep[#keep + 1] = id end
  end
  self.order = keep
end

function Sio:close()
  if self.state == "closed" then return end
  if self.connected then self:raw("41") end
  self.state = "closed"
  self.ws:close(1000)
end

return Sio
