-- lib/sio.lua + lib/celio.lua against a real Celio server (the open-source
-- Celio-Server run locally, or the public one): two clients make a room,
-- trade statuses for the commands the server derives from them, and send
-- each other data packets that must arrive complete and in order.
--
--   CELIO_URL=ws://127.0.0.1:34443 luajit tests/celio_test.lua      (from the mod root)
package.path = "./?.lua;./?/init.lua;" .. package.path
local socket = require("socket")
local url = os.getenv("CELIO_URL") or "ws://127.0.0.1:34443"

local function lib(n) return dofile("lib/" .. n .. ".lua") end
local json, Ws, Sio, Celio = lib("json"), lib("ws"), lib("sio"), lib("celio")

local failures, checks = 0, 0
local function check(ok, what)
  checks = checks + 1
  if ok then print("  ok   " .. what) else failures = failures + 1; print("  FAIL " .. what) end
end

-- json round trips
do
  local s = json.encode({ "sessionCreate", json.null })
  check(s == '["sessionCreate",null]', "json: a null placeholder argument (" .. s .. ")")
  local v = json.decode('{"variant":"Ok","value":{"id":"0421","full":false},"n":[1,2,3]}')
  check(v and v.value.id == "0421" and v.value.full == false and #v.n == 3, "json: decodes the server's ack")
  check(json.encode(json.decode('"a\\u00e9\\n"')) == '"a\195\169\\n"', "json: string escapes")
end

math.randomseed(os.time())
local function client(name)
  local io = Sio.new(url, { Ws = Ws, json = json, socket = socket, now = socket.gettime,
                            clientId = name .. "-" .. math.random(1, 1e9),
                            log = function(f, ...) print(("[%s] " .. f):format(name, ...)) end })
  local c = Celio.new({ sio = io, json = json, now = socket.gettime,
                        log = function(f, ...) print(("[%s] " .. f):format(name, ...)) end })
  return c
end

local A, B = client("A"), client("B")
local function pump(seconds, cond)
  local deadline = socket.gettime() + seconds
  while socket.gettime() < deadline do
    A:update(); B:update()
    if cond and cond() then return true end
    socket.sleep(0.005)
  end
  return cond == nil
end

check(pump(5, function() return A.sio.connected and B.sio.connected end), "both clients connect (Socket.IO handshake)")
local code
A:create(function(ok, v) code = ok and v or false end)
check(pump(5, function() return code ~= nil end) and code, "A creates a room: " .. tostring(code))
local joined
B:join(code, function(ok, v) joined = ok end)
check(pump(5, function() return joined ~= nil end) and joined, "B joins it")
check(pump(5, function() return A.full and B.full end), "both see the room full")

-- statuses -> commands
A:status(Celio.STATUS.AwaitModeEmulator)
B:status(Celio.STATUS.AwaitMode)
local ca, cb
check(pump(5, function() ca = ca or A:takeCommand(); cb = cb or B:takeCommand(); return ca and cb end),
      "both get a mode command")
check(ca == Celio.COMMAND.SetModeSlave, "AwaitModeEmulator -> SetModeSlave (we lead the link)")
check(cb == Celio.COMMAND.SetModeMaster, "AwaitMode -> SetModeMaster (the partner follows)")
A:status(Celio.STATUS.HandshakeReceived)
B:status(Celio.STATUS.HandshakeReceived)
ca, cb = nil, nil
check(pump(5, function() ca = ca or A:takeCommand(); cb = cb or B:takeCommand(); return ca and cb end)
      and ca == Celio.COMMAND.StartHandshake and cb == Celio.COMMAND.StartHandshake,
      "both HandshakeReceived -> StartHandshake to both")
A:status(Celio.STATUS.LinkConnected)
cb = nil
check(pump(5, function() cb = cb or B:takeCommand(); return cb end) and cb == Celio.COMMAND.ConnectLink,
      "A LinkConnected -> ConnectLink to B")

-- data, both ways, in order
local N = 40
for i = 1, N do
  local words = {}
  for w = 1, 32 do words[w] = (i * 100 + w) % 65536 end
  A:sendPacket(words)
end
for i = 1, 5 do
  local words = {}
  for w = 1, 32 do words[w] = 0xFF00 + i end
  B:sendPacket(words)
end
check(pump(10, function() return B:pendingFrames() >= N * 4 and A:pendingFrames() >= 20 end),
      ("B got %d frames from A, A got %d from B"):format(B:pendingFrames(), A:pendingFrames()))
local inOrder = true
for i = 1, N do
  for f = 0, 3 do
    local frame = B:takeFrame()
    for w = 1, 8 do
      if not frame or frame[w] ~= (i * 100 + f * 8 + w) % 65536 then inOrder = false end
    end
  end
end
check(inOrder, "A's 40 packets arrive complete and in order")
local fromB = A:takeFrame()
check(fromB and fromB[1] == 0xFF01, "B's first frame arrives at A")

-- the end
A:status(Celio.STATUS.LinkClosed)
B:status(Celio.STATUS.LinkClosed)
check(pump(6, function() return A.closed and B.closed end), "both LinkClosed -> the server closes the session")
A:close(); B:close()
print(("%d/%d checks passed%s"):format(checks - failures, checks, failures > 0 and (", " .. failures .. " FAILURES") or ""))
os.exit(failures == 0 and 0 or 1)
