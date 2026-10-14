-- A small JSON codec for the Socket.IO messages Celio uses: objects,
-- arrays, strings, numbers, true/false/null.  null decodes to json.null
-- (so arrays keep their length) and json.null encodes to null.
--
--   json.encode({ "sessionCreate", json.null }) --> ["sessionCreate",null]
--   json.decode('{"variant":"Ok","value":{"id":"0421"}}')
--
-- A Lua table encodes as an array when its keys are exactly 1..n (or it is
-- json.array(...)), otherwise as an object.

local json = {}

json.null = setmetatable({}, { __tostring = function() return "null" end })
local ARRAY = {}

-- force a table to encode as an array (an empty table is an object otherwise)
function json.array(t)
  return setmetatable(t or {}, { __index = ARRAY, [ARRAY] = true })
end

local function isArray(t)
  local mt = getmetatable(t)
  if mt and mt[ARRAY] then return true end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return false end
    n = n + 1
  end
  for i = 1, n do
    if t[i] == nil then return false end
  end
  return n > 0
end

local ESC = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
              ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }

local function encodeString(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    return ESC[c] or ("\\u%04x"):format(c:byte())
  end) .. '"'
end

local function encode(v, out)
  local t = type(v)
  if v == json.null or v == nil then
    out[#out + 1] = "null"
  elseif t == "boolean" then
    out[#out + 1] = v and "true" or "false"
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then error("json: can't encode " .. tostring(v)) end
    if v % 1 == 0 and math.abs(v) < 2^53 then
      out[#out + 1] = ("%d"):format(v)
    else
      out[#out + 1] = ("%.17g"):format(v)
    end
  elseif t == "string" then
    out[#out + 1] = encodeString(v)
  elseif t == "table" then
    if isArray(v) then
      out[#out + 1] = "["
      for i = 1, #v do
        if i > 1 then out[#out + 1] = "," end
        encode(v[i], out)
      end
      out[#out + 1] = "]"
    else
      out[#out + 1] = "{"
      local keys = {}
      for k in pairs(v) do
        if type(k) ~= "string" then error("json: object keys must be strings") end
        keys[#keys + 1] = k
      end
      table.sort(keys)
      for i, k in ipairs(keys) do
        if i > 1 then out[#out + 1] = "," end
        out[#out + 1] = encodeString(k)
        out[#out + 1] = ":"
        encode(v[k], out)
      end
      out[#out + 1] = "}"
    end
  else
    error("json: can't encode a " .. t)
  end
end

function json.encode(v)
  local out = {}
  encode(v, out)
  return table.concat(out)
end

-- ------------------------------------------------------------------
-- decoding
-- ------------------------------------------------------------------

local function skip(s, i)
  return s:find("[^ \t\r\n]", i) or (#s + 1)
end

local function utf8(cp)
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64) end
  if cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
  end
  return string.char(0xF0 + math.floor(cp / 262144), 0x80 + math.floor(cp / 4096) % 64,
                     0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

local UNESC = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }

local decodeValue

local function decodeString(s, i)
  local out, j = {}, i + 1
  while true do
    local c = s:sub(j, j)
    if c == "" then error("json: unterminated string") end
    if c == '"' then return table.concat(out), j + 1 end
    if c == "\\" then
      local e = s:sub(j + 1, j + 1)
      if e == "u" then
        local cp = tonumber(s:sub(j + 2, j + 5), 16)
        if not cp then error("json: bad \\u escape") end
        j = j + 6
        if cp >= 0xD800 and cp <= 0xDBFF and s:sub(j, j + 1) == "\\u" then
          local lo = tonumber(s:sub(j + 2, j + 5), 16)
          if lo and lo >= 0xDC00 and lo <= 0xDFFF then
            cp = 0x10000 + (cp - 0xD800) * 1024 + (lo - 0xDC00)
            j = j + 6
          end
        end
        out[#out + 1] = utf8(cp)
      else
        out[#out + 1] = UNESC[e] or e
        j = j + 2
      end
    else
      local k = s:find('["\\]', j) or (#s + 1)
      out[#out + 1] = s:sub(j, k - 1)
      j = k
    end
  end
end

function decodeValue(s, i)
  i = skip(s, i)
  local c = s:sub(i, i)
  if c == "{" then
    local obj = {}
    i = skip(s, i + 1)
    if s:sub(i, i) == "}" then return obj, i + 1 end
    while true do
      if s:sub(i, i) ~= '"' then error("json: expected a key at " .. i) end
      local k
      k, i = decodeString(s, i)
      i = skip(s, i)
      if s:sub(i, i) ~= ":" then error("json: expected ':' at " .. i) end
      local v
      v, i = decodeValue(s, i + 1)
      obj[k] = v
      i = skip(s, i)
      local d = s:sub(i, i)
      if d == "}" then return obj, i + 1 end
      if d ~= "," then error("json: expected ',' or '}' at " .. i) end
      i = skip(s, i + 1)
    end
  elseif c == "[" then
    local arr = json.array({})
    i = skip(s, i + 1)
    if s:sub(i, i) == "]" then return arr, i + 1 end
    local n = 0
    while true do
      local v
      v, i = decodeValue(s, i)
      n = n + 1
      arr[n] = v
      i = skip(s, i)
      local d = s:sub(i, i)
      if d == "]" then return arr, i + 1 end
      if d ~= "," then error("json: expected ',' or ']' at " .. i) end
      i = i + 1
    end
  elseif c == '"' then
    return decodeString(s, i)
  elseif s:sub(i, i + 3) == "true" then
    return true, i + 4
  elseif s:sub(i, i + 4) == "false" then
    return false, i + 5
  elseif s:sub(i, i + 3) == "null" then
    return json.null, i + 4
  else
    local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
    if not num or num == "" then error("json: unexpected '" .. c .. "' at " .. i) end
    return tonumber(num), i + #num
  end
end

-- returns value, or nil and an error message
function json.decode(s)
  local ok, v, i = pcall(decodeValue, s, 1)
  if not ok then return nil, v end
  if skip(s, i) <= #s then return nil, "json: trailing data" end
  return v
end

return json
