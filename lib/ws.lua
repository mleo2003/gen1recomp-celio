-- A small non-blocking WebSocket client (RFC 6455).
--
-- Only what the trade server needs: client frames masked, server frames
-- unmasked, fragmented messages reassembled, pings answered.  Never blocks:
-- update() is called once per frame and moves whatever the connection will
-- take or give right now.
--
-- ws:// rides luasocket.  wss:// needs TLS, which LÖVE's luasocket lacks; it
-- rides the engine's TLS dialer instead when the game has one (love.system's
-- tlsOpen/tlsStatus/tlsSend/tlsReceive/tlsError/tlsClose: official Windows
-- builds via gen1tls, and Android), passed in as opts.tls.
--
--   local ws = Ws.new("ws://host/link1/12345", { socket = require("socket") })
--   ws:update()            -- every frame
--   ws:send(bytes)         -- binary message (queued until the upgrade is done)
--   ws:sendText(text)
--   for _, m in ipairs(ws:poll()) do ... m.text / m.binary ... end
--   ws.open / ws.closed / ws.error

local bit = require("bit")

local Ws = {}
Ws.__index = Ws

local CONNECT_TIMEOUT = 10
local HANDSHAKE_TIMEOUT = 10
local MAX_FRAME = 1024 * 1024
local RX_BUDGET = 256 * 1024

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64(s)
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local q = {
      bit.band(bit.rshift(n, 18), 63), bit.band(bit.rshift(n, 12), 63),
      bit.band(bit.rshift(n, 6), 63), bit.band(n, 63),
    }
    out[#out + 1] = B64:sub(q[1] + 1, q[1] + 1) .. B64:sub(q[2] + 1, q[2] + 1)
      .. (b and B64:sub(q[3] + 1, q[3] + 1) or "=")
      .. (c and B64:sub(q[4] + 1, q[4] + 1) or "=")
  end
  return table.concat(out)
end

Ws.base64 = base64

function Ws.parseUrl(url)
  local scheme, rest = tostring(url):match("^(wss?)://(.+)$")
  if not scheme then return nil, "not a ws:// address" end
  local hostport, path = rest:match("^([^/]+)(/.*)$")
  hostport = hostport or rest
  path = path or "/"
  local host, port = hostport:match("^(.-):(%d+)$")
  host = host or hostport
  port = tonumber(port) or (scheme == "wss" and 443 or 80)
  return { scheme = scheme, host = host, port = port, path = path }
end

-- the engine's TLS dialer (src/net/Gen1Tls.lua, native/tls_dial), or nil
function Ws.tlsFrom(system)
  if type(system) ~= "table" then return nil end
  local t = {
    open = system.tlsOpen, status = system.tlsStatus, send = system.tlsSend,
    receive = system.tlsReceive, error = system.tlsError, close = system.tlsClose,
  }
  for _, k in ipairs({ "open", "status", "send", "receive", "close" }) do
    if type(t[k]) ~= "function" then return nil end
  end
  return t
end

-- TLS status codes (native/tls_dial/TlsDialer.cs)
local TLS_CONNECTING, TLS_OPEN = 0, 1
local TLS_CONNECT_TIMEOUT = 20

-- opts.socket: luasocket; opts.tls: Ws.tlsFrom(love.system) for wss://;
-- opts.now: clock; opts.random(lo, hi)
function Ws.new(url, opts)
  opts = opts or {}
  local self = setmetatable({
    url = url,
    socket = opts.socket,
    now = opts.now or os.clock,
    random = opts.random or math.random,
    userAgent = opts.userAgent or "gen1recomp-gblink",
    open = false,
    closed = false,
    error = nil,
    tx = "",           -- bytes waiting for the socket
    pending = {},      -- frames queued before the upgrade finished
    rx = "",
    inbox = {},
    fragments = nil,
    fragmentOpcode = nil,
  }, Ws)
  local u, why = Ws.parseUrl(url)
  if not u then return self:fail(why) end
  self.target = u
  if u.scheme == "wss" then
    self.tls = opts.tls
    if not self.tls then
      return self:fail("wss:// needs TLS, which this build of the game doesn't have; use ws://")
    end
    local ok, handle = pcall(self.tls.open, u.host, u.port)
    if not ok or type(handle) ~= "number" or handle < 0 then
      return self:fail(("can't reach %s:%d over TLS"):format(u.host, u.port))
    end
    self.tlsHandle = handle
    self.connecting = true
    self.deadline = self.now() + TLS_CONNECT_TIMEOUT
    return self
  end
  if not self.socket then return self:fail("no luasocket (needs the network permission)") end
  local tcp = self.socket.tcp()
  tcp:settimeout(0)
  local ok, err = tcp:connect(u.host, u.port)
  self.tcp = tcp
  self.deadline = self.now() + CONNECT_TIMEOUT
  if ok then
    self:startHandshake()
  elseif err == "timeout" or tostring(err):find("progress", 1, true) then
    self.connecting = true
  else
    return self:fail(("can't reach %s:%d (%s)"):format(u.host, u.port, tostring(err)))
  end
  return self
end

function Ws:fail(why)
  self.error = self.error or why
  self.closed = true
  self.open = false
  if self.tcp then pcall(self.tcp.close, self.tcp) end
  if self.tlsHandle then
    pcall(self.tls.close, self.tlsHandle)
    self.tlsHandle = nil
  end
  return self
end

function Ws:tlsError()
  local ok, err = pcall(self.tls.error or function() end, self.tlsHandle)
  return ok and err or nil
end

function Ws:startHandshake()
  self.connecting = false
  if self.tcp then pcall(self.tcp.setoption, self.tcp, "tcp-nodelay", true) end
  local key = {}
  for i = 1, 16 do key[i] = string.char(self.random(0, 255)) end
  local u = self.target
  local defaultPort = u.scheme == "wss" and 443 or 80
  local hostHeader = u.port == defaultPort and u.host or (u.host .. ":" .. u.port)
  self.tx = self.tx .. table.concat({
    "GET " .. u.path .. " HTTP/1.1",
    "Host: " .. hostHeader,
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Key: " .. base64(table.concat(key)),
    "Sec-WebSocket-Version: 13",
    "User-Agent: " .. self.userAgent,
    "", "",
  }, "\r\n")
  self.handshaking = true
  self.deadline = self.now() + HANDSHAKE_TIMEOUT
end

-- ------------------------------------------------------------------
-- frames
-- ------------------------------------------------------------------

local function u16(n) return string.char(bit.rshift(n, 8), bit.band(n, 0xFF)) end

function Ws:frame(opcode, payload)
  payload = payload or ""
  local n = #payload
  local head = string.char(0x80 + opcode)
  if n < 126 then
    head = head .. string.char(0x80 + n)
  elseif n < 65536 then
    head = head .. string.char(0x80 + 126) .. u16(n)
  else
    head = head .. string.char(0x80 + 127) .. "\0\0\0\0"
      .. string.char(bit.band(bit.rshift(n, 24), 0xFF), bit.band(bit.rshift(n, 16), 0xFF))
      .. u16(bit.band(n, 0xFFFF))
  end
  local mask = { self.random(0, 255), self.random(0, 255), self.random(0, 255), self.random(0, 255) }
  local out = {}
  for i = 1, n do
    out[i] = string.char(bit.bxor(payload:byte(i), mask[(i - 1) % 4 + 1]))
  end
  return head .. string.char(mask[1], mask[2], mask[3], mask[4]) .. table.concat(out)
end

function Ws:queue(opcode, payload)
  if self.closed then return false end
  local f = self:frame(opcode, payload)
  if self.open then self.tx = self.tx .. f else self.pending[#self.pending + 1] = f end
  return true
end

function Ws:send(bytes) return self:queue(0x2, bytes) end
function Ws:sendText(text) return self:queue(0x1, text) end

function Ws:close(code)
  if self.closed then return end
  if self.open then
    local payload = code and u16(code) or ""
    self.tx = self.tx .. self:frame(0x8, payload)
    self:flush()
  end
  self.closing = true
  self:fail(nil)
end

function Ws:deliver(opcode, payload)
  if opcode == 0x1 then
    self.inbox[#self.inbox + 1] = { text = payload }
  elseif opcode == 0x2 then
    self.inbox[#self.inbox + 1] = { binary = payload }
  end
end

-- parse as many complete frames as rx holds
function Ws:parseFrames()
  while true do
    local rx = self.rx
    if #rx < 2 then return end
    local b0, b1 = rx:byte(1, 2)
    local fin = bit.band(b0, 0x80) ~= 0
    local opcode = bit.band(b0, 0x0F)
    local masked = bit.band(b1, 0x80) ~= 0
    local n = bit.band(b1, 0x7F)
    local pos = 3
    if n == 126 then
      if #rx < 4 then return end
      n = rx:byte(3) * 256 + rx:byte(4)
      pos = 5
    elseif n == 127 then
      if #rx < 10 then return end
      n = 0
      for i = 3, 10 do n = n * 256 + rx:byte(i) end
      pos = 11
    end
    if n > MAX_FRAME then self:fail("frame too large") return end
    local mask
    if masked then
      if #rx < pos + 3 then return end
      mask = { rx:byte(pos, pos + 3) }
      pos = pos + 4
    end
    if #rx < pos + n - 1 then return end
    local payload = rx:sub(pos, pos + n - 1)
    self.rx = rx:sub(pos + n)
    if mask then
      local out = {}
      for i = 1, n do out[i] = string.char(bit.bxor(payload:byte(i), mask[(i - 1) % 4 + 1])) end
      payload = table.concat(out)
    end
    if opcode == 0x8 then
      -- echo the close and stop
      if not self.closing then
        self.tx = self.tx .. self:frame(0x8, payload:sub(1, 2))
        self:flush()
      end
      local code = #payload >= 2 and (payload:byte(1) * 256 + payload:byte(2)) or nil
      self.closeCode = code
      self:fail(nil)
      return
    elseif opcode == 0x9 then
      self.tx = self.tx .. self:frame(0xA, payload)
    elseif opcode == 0xA then
      -- pong: nothing to do
    elseif opcode == 0x0 then
      if self.fragments then
        self.fragments[#self.fragments + 1] = payload
        if fin then
          self:deliver(self.fragmentOpcode, table.concat(self.fragments))
          self.fragments, self.fragmentOpcode = nil, nil
        end
      end
    elseif fin then
      self:deliver(opcode, payload)
    else
      self.fragments, self.fragmentOpcode = { payload }, opcode
    end
  end
end

-- ------------------------------------------------------------------
-- socket pump
-- ------------------------------------------------------------------

function Ws:flush()
  if #self.tx == 0 then return end
  if self.tlsHandle then
    -- the dialer queues whatever it is given until its stream is ready
    local ok, n = pcall(self.tls.send, self.tlsHandle, self.tx)
    if ok and type(n) == "number" and n >= 0 then
      self.tx = self.tx:sub(n + 1)
    else
      self:fail("send failed: " .. tostring(self:tlsError() or n))
    end
    return
  end
  if not self.tcp then return end
  local sent, err, last = self.tcp:send(self.tx)
  if sent then
    self.tx = ""
  elseif err == "timeout" then
    self.tx = self.tx:sub((last or 0) + 1)
  else
    self:fail("send failed: " .. tostring(err))
  end
end

function Ws:pollConnect()
  if self.tlsHandle then
    local ok, status = pcall(self.tls.status, self.tlsHandle)
    if ok and status == TLS_OPEN then
      self:startHandshake()
      return true
    elseif not ok or status ~= TLS_CONNECTING then
      self:fail(("can't reach %s over TLS (%s)"):format(self.target.host,
        tostring(self:tlsError() or "closed")))
      return false
    end
    if self.now() > self.deadline then
      self:fail(("can't reach %s over TLS (timed out)"):format(self.target.host))
    end
    return false
  end
  local ok, _, writable = pcall(self.socket.select, nil, { self.tcp }, 0)
  if ok and writable and #writable > 0 then
    local cok, err = self.tcp:connect(self.target.host, self.target.port)
    err = tostring(err or "")
    if cok or err:find("already connected", 1, true) then
      self:startHandshake()
      return true
    end
    if err ~= "timeout" and not err:find("progress", 1, true) then
      self:fail(("can't reach %s (%s)"):format(self.target.host, err))
      return false
    end
  end
  if self.now() > self.deadline then
    self:fail(("can't reach %s (timed out)"):format(self.target.host))
  end
  return false
end

function Ws:update()
  if self.closed then return end
  if self.connecting and not self:pollConnect() then return end
  self:flush()
  if self.closed then return end
  if self.tlsHandle then
    self:receiveTls()
    if self.closed then return end
    self:parseIncoming()
    if self.handshaking and self.now() > self.deadline then
      self:fail("the server did not answer the WebSocket upgrade")
    end
    self:flush()
    return
  end
  local budget = RX_BUDGET
  while budget > 0 do
    local data, err, partial = self.tcp:receive(8192)
    local chunk = data or partial or ""
    if #chunk > 0 then
      self.rx = self.rx .. chunk
      budget = budget - #chunk
    end
    if err == "closed" then
      self:parseIncoming()
      -- a hang-up after the upgrade is a close, not a failure
      local why
      if not self.open then why = "the server closed the connection" end
      self:fail(why)
      return
    elseif err and err ~= "timeout" then
      self:fail(tostring(err))
      return
    end
    if not data then break end
  end
  self:parseIncoming()
  if self.handshaking and self.now() > self.deadline then
    self:fail("the server did not answer the WebSocket upgrade")
  end
  self:flush()
end

function Ws:receiveTls()
  local budget = RX_BUDGET
  while budget > 0 do
    local ok, chunk = pcall(self.tls.receive, self.tlsHandle, 65536)
    if not ok or type(chunk) ~= "string" or #chunk == 0 then break end
    self.rx = self.rx .. chunk
    budget = budget - #chunk
  end
  local ok, status = pcall(self.tls.status, self.tlsHandle)
  if not ok or status ~= TLS_OPEN then
    -- whatever arrived before the hang-up still counts
    self:parseIncoming()
    local why
    if not self.open then
      why = "the server closed the connection"
      local err = self:tlsError()
      if err then why = why .. " (" .. tostring(err) .. ")" end
    end
    self:fail(why)
  end
end

function Ws:parseIncoming()
  if self.handshaking then
    local headEnd = self.rx:find("\r\n\r\n", 1, true)
    if not headEnd then return end
    local head = self.rx:sub(1, headEnd - 1)
    self.rx = self.rx:sub(headEnd + 4)
    self.handshaking = false
    local status = tonumber(head:match("^HTTP/%d%.%d (%d+)"))
    if status ~= 101 then
      self:fail(("the server refused the upgrade (%s)"):format(head:match("^[^\r\n]*") or "?"))
      return
    end
    self.open = true
    for _, f in ipairs(self.pending) do self.tx = self.tx .. f end
    self.pending = {}
  end
  if self.open then self:parseFrames() end
end

function Ws:poll()
  local out = self.inbox
  self.inbox = {}
  return out
end

return Ws
