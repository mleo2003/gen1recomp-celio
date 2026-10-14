-- The Cable Club attendant's "Please wait…" with no link open: the door to
-- a Celio room.  It runs inside the TryTradeLinkup special and holds the
-- script there, as the engine's own cable lobby does
-- (src/core/game3/link/cable_entry.lua): MAKE A ROOM (show its number) or
-- JOIN A ROOM (type one), wait for the friend and their GBA, then open the
-- engine's link on the bridge and hand the special back to the engine.
--
--   Door3.run(ctx, adapters, env) -> yielded
--   env: Link, LT, Natives, Stack, Window, Font, Strings (engine modules),
--        original (the engine's TryTradeLinkup), newVisit() -> lib/visit3.lua,
--        game() -> the Game3, lastCode() / saveCode(code), log

local Door3 = { ID = "gblink_celio_door" }

local CODE_LENGTH = 4

local REASONS = {
  ["Session not found"] = "There is no room with that number.",
  ["Session is full"] = "That room already has two players.",
  ["Session already exists"] = "The server could not make a room.\nTry again.",
  partner_left = "Your friend left the room.",
  no_tls = "This build of the game can't make\nsecure connections (wss://).",
  no_socket = "This build of the game has no\nnetwork library.",
}

local function reasonText(why)
  why = tostring(why or "")
  for k, v in pairs(REASONS) do
    if why == k or why:find(k, 1, true) then return v end
  end
  if why:find("other device also asked to lead", 1, true) then
    return "The other side is not a GBA.\nBoth sides can't be this game."
  end
  if why:find("link type", 1, true) then
    return "Your friend chose something\nother than the TRADE CENTER."
  end
  return "The connection was lost."
end
Door3.reasonText = reasonText

function Door3.run(ctx, adapters, env)
  local Link, Stack, Window, Font, Strings = env.Link, env.Stack, env.Window, env.Font, env.Strings
  local S = Strings or function(s) return s end
  local screen = { mode = "menu", cursor = 1, pos = 1 }
  local visit, done, open, handedOff = nil, false, false, false

  local seed = tostring(env.lastCode and env.lastCode() or "")
  screen.digits = {}
  for i = 1, CODE_LENGTH do screen.digits[i] = tonumber(seed:sub(i, i)) or 0 end

  -- the screen's state is on the module for drivers and tests
  local M = { screen = screen }
  function M.visit() return visit end
  local function close()
    if open then
      open = false
      Stack.pop(Door3.ID)
    end
  end
  local function finish(code)
    close()
    Link.setResult(ctx, code)
    done = true
  end
  local function cancel()
    if visit then visit:cancel() end
    finish(Link.LINKUP.FAILED)
  end
  local function start(create)
    local v, why = env.newVisit()
    if not v then
      screen.mode, screen.error = "error", why
      return
    end
    visit = v
    if create then
      visit:create()
    else
      local code = ""
      for i = 1, CODE_LENGTH do code = code .. screen.digits[i] end
      if env.saveCode then env.saveCode(code) end
      visit:join(code)
    end
    screen.mode = "wait"
  end

  local function pressed(input, key)
    if type(input) ~= "table" then return false end
    if input.wasPressed then return input:wasPressed(key) and true or false end
    return input.new and input.new[key] and true or false
  end

  function M.handleInput(input)
    if done then return end
    local mode = screen.mode
    if mode == "menu" then
      if pressed(input, "b") then return cancel() end
      if pressed(input, "up") or pressed(input, "down") then screen.cursor = 3 - screen.cursor end
      if pressed(input, "a") then
        if screen.cursor == 1 then start(true) else screen.mode = "code" end
      end
    elseif mode == "code" then
      local d = screen.digits
      if pressed(input, "b") then screen.mode = "menu"; return end
      if pressed(input, "left") then screen.pos = math.max(1, screen.pos - 1) end
      if pressed(input, "right") then screen.pos = math.min(CODE_LENGTH, screen.pos + 1) end
      if pressed(input, "up") then d[screen.pos] = (d[screen.pos] + 1) % 10 end
      if pressed(input, "down") then d[screen.pos] = (d[screen.pos] + 9) % 10 end
      if pressed(input, "a") or pressed(input, "start") then start(false) end
    elseif mode == "wait" then
      if pressed(input, "b") then return cancel() end
    elseif mode == "error" then
      if pressed(input, "a") or pressed(input, "b") then
        if visit then visit:cancel() end
        finish(Link.LINKUP.CONNECTION_ERROR)
      end
    end
  end

  -- while a screen is up the field (and the script VM with it) stands
  -- still, so the screen ticks the special's poll itself, as the engine's
  -- cable lobby does
  local poll
  function M.update()
    if poll and ctx.nativePoll == poll then poll() end
  end

  local function lines(text, x, y)
    for line in (tostring(text) .. "\n"):gmatch("([^\n]*)\n") do
      Font.draw(line, x, y, { colors = Font.COLOR and Font.COLOR.NORMAL })
      y = y + 15
    end
    return y
  end

  -- above the attendant's "Please wait… B Button: Cancel" box, which
  -- stays on screen underneath and already says how to leave
  function M.draw()
    if not open then return end
    Window.stdFrame(Window.template(1, 1, 28, 12))
    local x, y = 16, 12
    local mode = screen.mode
    y = lines(S("GBA LINK ONLINE (CELIO)"), x, y) + 4
    if mode == "menu" then
      y = lines(S("Trade with a GBA, an emulator or a\nSwitch through celio.gblink.io."), x, y) + 4
      local rows = { S("MAKE A ROOM"), S("JOIN A ROOM") }
      for i, label in ipairs(rows) do
        Font.draw((i == screen.cursor and "> " or "  ") .. label, x + 8, y)
        y = y + 15
      end
    elseif mode == "code" then
      y = lines(S("Type the room number your friend\nsees on celio.gblink.io."), x, y) + 2
      for i = 1, CODE_LENGTH do
        local dx = x + 72 + (i - 1) * 20
        Font.draw(tostring(screen.digits[i]), dx, y)
        if i == screen.pos then Font.draw("^", dx, y + 10) end
      end
      lines(S("UP/DOWN: number   A: JOIN"), x, y + 22)
    elseif mode == "wait" then
      local st = visit and visit.state or "connecting"
      if st == "connecting" or st == "joining" then
        lines(S("Connecting to the Celio server..."), x, y)
      elseif st == "room" then
        lines(S("ROOM %s: your friend opens\ncelio.gblink.io, chooses JOIN and\ntypes %s, then connects.",
                visit.code or "----", visit.code or "----"), x, y)
      else
        lines(S("Your friend is in the room. On\ntheir game: the Cable Club,\nTRADE CENTER, then save."), x, y)
      end
    elseif mode == "error" then
      y = lines(reasonText(screen.error), x, y)
      lines(S("A: OK"), x, math.max(y + 2, 79))
    end
  end

  env.Natives.yieldHost(ctx, adapters, function() end)
  Link.setResult(ctx, Link.LINKUP.ONGOING)
  poll = function()
    if handedOff then return false end
    if done then return true end
    if visit and screen.mode == "wait" then
      if visit.state == "failed" then
        screen.mode, screen.error = "error", visit.error
      elseif visit.state == "linked" then
        close()
        local game = env.game and env.game()
        local live = visit:attach(Link, game)
        if not live then
          visit:cancel()
          finish(Link.LINKUP.CONNECTION_ERROR)
          return true
        end
        env.LT.loopbackCommit = true
        if env.log then env.log("door: linked with %s; the engine takes over", tostring(visit.partnerName)) end
        -- the engine's own linkup over the open link; it takes the special
        -- from here (its poll replaces ours)
        local yielded, value = env.original(ctx, adapters)
        if not yielded then
          Link.setResult(ctx, value or Link.getVar(ctx, Link.VAR_RESULT))
          done = true
          return true
        end
        handedOff = true
        return false
      end
    end
    return false
  end
  ctx.nativePoll = poll
  open = true
  Stack.push(Door3.ID, M, { hideBelow = false, drawUnder = true })
  return true
end

return Door3
