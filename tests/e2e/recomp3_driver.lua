-- gen1recomp FireRed in a real LÖVE window, trading over Celio with a real
-- FireRed (mGBA Celio edition behind celio.gblink.io, or a GBA on a Celio
-- adapter), through the game's own UI: the attendant, the mod's door, the
-- Trade Center, the trade menu, the animation and the save.  The other
-- side is played by hand (or by a script) while this waits for it.
--
--   POKEPORT_VERSION=firered POKEPORT_DRIVER=<mod>/tests/e2e/recomp3_driver.lua love <engine>
--   CELIO_CODE   the room to join (made on the other side's page); unset: make one
--   CELIO_PARTY  600 B of party structs to start with (e.g. a PKHeX dump)
--   CELIO_GIVE   our slot to trade (1-based, default 1); round 2 cancels
--   CELIO_MOD    the mod folder (for its codec)
--   POKEPORT_SHOT_DIR  screenshots, saves and the log of parties
local U = require("tests.drivers.util")
local DIR = os.getenv("POKEPORT_SHOT_DIR") or "/tmp/celio_e2e"
local CODE = os.getenv("CELIO_CODE")
local PARTY = os.getenv("CELIO_PARTY")
local GIVE = tonumber(os.getenv("CELIO_GIVE") or "1") or 1
local MOD = os.getenv("CELIO_MOD") or "."

local CENTER_2F = "FR_VIRIDIAN_CITY_POKEMON_CENTER_2F"
local TRADE_CENTER = "FR_TRADE_CENTER"
local FLAG_SYS_POKEDEX_GET = 0x829

local failures = 0
local function log(...) print("[e2e]", ...) io.stdout:flush() end
local function result(ok, label)
  print((ok and "PASS " or "FAIL ") .. label)
  io.stdout:flush()
  if not ok then failures = failures + 1 end
  return ok
end

return function(game)
  for _ = 1, 900 do
    if game.phase == "boot" and game.boot then break end
    U.wait(1)
  end
  game:_handleBootAction({ action = "new_game", name = "RECOMP" })
  U.wait(240)

  local Runtime = require("src.core.game3.runtime")
  local Map = require("src.core.game3.map")
  local Space = require("src.core.game3.scripting.space")
  local Flags = require("src.core.game3.scripting.flags")
  local Player = require("src.core.game3.player")
  local Link = require("src.core.game3.link")
  local LT = require("src.core.game3.link.trade")
  local Stack = require("src.ui.game3.stack")
  local Message = require("src.ui.game3.message")
  local Menu = require("src.ui.game3.link_trade_menu")
  local Codec3 = dofile(MOD .. "/lib/codec3.lua")
  local codec = Codec3.new("firered")

  local session = Runtime.getSession()
  if not result(session ~= nil, "a new FireRed game reached the field") then love.event.quit(1) return end
  session.name, session.trainerId, session.secretId, session.gender = "RECOMP", 44444, 1000, 0
  local function ctx() return Space.vm and Space.vm.ctx end
  Flags.setFlag(Space.store, ctx(), FLAG_SYS_POKEDEX_GET, true)
  if PARTY then
    local f = assert(io.open(PARTY, "rb"))
    local _, records = codec:packParty(f:read("*a"))
    f:close()
    session.party = {}
    for i, c in ipairs(records) do
      local m = codec.G3.toPortMon(c, true)
      codec.SaveMon.normalize(m)
      session.party[i] = m
    end
  end
  local function partyLine(party)
    local out = {}
    for i, m in ipairs(party or {}) do out[i] = ("%s L%d"):format(tostring(m.species), tonumber(m.level) or 0) end
    return table.concat(out, ", ")
  end
  local function exportSave(name)
    local SaveConvert = require("src.save_convert.SaveConvert")
    local okE, bytes, why = pcall(SaveConvert.exportSav, game.save, "firered")
    if okE and bytes then
      local f = io.open(DIR .. "/" .. name, "wb")
      if f then f:write(bytes) f:close() log("wrote " .. name) end
    else
      log("export failed: " .. tostring(okE and why or bytes))
    end
  end
  log("party: " .. partyLine(session.party))

  local function place(x, y, facing)
    Player.cellX, Player.cellY = x, y
    Player.px, Player.py = x * 16, y * 16
    Player.targetX, Player.targetY = x, y
    Player.facing = facing
    if game.session then game.session.x, game.session.y, game.session.facing = x, y, facing end
  end
  local function waitFor(pred, limit, every)
    for _ = 1, limit or 600 do
      if pred() then return true end
      if every then every() end
      U.wait(1)
    end
    return pred()
  end

  -- the Direct Corner attendant (Viridian 2F)
  Map.load(nil, game, CENTER_2F, { x = 10, y = 4, facing = "up" })
  place(10, 4, "up")
  U.wait(60)
  U.shot(game, DIR .. "/01_desk.png")
  U.tap(game, "a")
  -- through the welcome, TRADE CENTER, "save the game?" YES, to the door
  local doorUp = waitFor(function() return Stack.has("gblink_celio_door") end, 3600, function()
    if Message.isOpen() and Message.isTyping and Message.isTyping() then Message.skipReveal() end
    if U.frame() % 20 == 0 then U.tap(game, "a") end
  end)
  if not result(doorUp, "the attendant's TRADE CENTER opened the Celio door") then
    U.shot(game, DIR .. "/99_no_door.png")
    love.event.quit(1)
    return
  end
  exportSave("recomp_before.sav")
  U.shot(game, DIR .. "/02_door.png")
  local door
  for _, layer in ipairs(Stack._layers) do if layer.id == "gblink_celio_door" then door = layer.mod end end
  if CODE then
    U.tap(game, "down")
    U.tap(game, "a")
    U.wait(5)
    local digits = door.screen.digits
    for i = 1, #CODE do
      local want = tonumber(CODE:sub(i, i))
      for _ = 1, 10 do
        if digits[i] == want then break end
        U.tap(game, "up")
        U.wait(2)
      end
      U.tap(game, "right")
      U.wait(2)
    end
    U.shot(game, DIR .. "/03_code.png")
    U.tap(game, "a")
    log("joining room " .. CODE)
  else
    U.tap(game, "a")
    waitFor(function() local v = door.visit() return v and v.code end, 1200)
    log("ROOM CODE " .. tostring(door.visit() and door.visit().code))
  end
  -- the other side links: their attendant, TRADE CENTER, save
  local linked = waitFor(function() return not Stack.has("gblink_celio_door") end, 60 * 600, function()
    if U.frame() % 600 == 0 then
      local v = door.visit()
      log("door: " .. tostring(v and v.state))
    end
  end)
  U.shot(game, DIR .. "/04_linked.png")
  local visit = door.visit()
  result(linked and visit and visit.state == "open", "linked with " .. tostring(visit and visit.partnerName))
  if not (visit and visit.state == "open") then love.event.quit(1) return end

  -- into the Trade Center (the attendant's script walks us in)
  result(waitFor(function() return Space.mapId == TRADE_CENTER end, 1800, function()
    if U.frame() % 20 == 0 and Message.isOpen() then U.tap(game, "a") end
  end), "the player is in the TRADE CENTER")
  U.wait(90)
  U.shot(game, DIR .. "/05_trade_center.png")
  -- sit down in chair 0 (4,5)
  place(4, 7, "up")
  U.wait(20)
  local seated = waitFor(function() return LT.state == "menu" and Menu.cb == "main" and Menu.fade == 0 end, 60 * 300,
    function()
      if LT.state ~= "seat" and LT.state ~= "menu" and not Player.moving and Player.cellY > 5 and U.frame() % 15 == 0 then
        U.hold(game, "up", 12)
      end
    end)
  U.shot(game, DIR .. "/06_menu.png")
  if not result(seated, "both sat down: the trade menu shows the other party") then love.event.quit(1) return end
  log("their party: " .. partyLine(LT.peerParty))
  log("our party:   " .. partyLine(session.party))
  local gave = session.party[GIVE]

  -- our pick
  for _ = 1, GIVE - 1 do
    U.tap(game, Menu.pos % 2 == 0 and "right" or "down")
    U.wait(2)
  end
  U.tap(game, "a")
  U.wait(5)
  U.tap(game, "down")
  U.wait(2)
  U.tap(game, "a")
  result(LT.state == "ready_wait" or LT.state == "confirm", "we offered slot " .. GIVE)
  -- the other player's pick, then "Is this trade okay?"
  local asked = waitFor(function() return Menu.confirming end, 60 * 600)
  U.shot(game, DIR .. "/07_is_this_okay.png")
  if not result(asked, "both picked: Is this trade okay?") then love.event.quit(1) return end
  U.tap(game, "a")
  log("YES; waiting for the other game to save before ours commits")
  local completed = LT.completed
  local done = waitFor(function() return LT.completed > completed and LT.state == "menu" and Menu.cb == "main" end,
    60 * 900, function()
      if U.frame() % 300 == 0 then log("trade: " .. tostring(LT.state)) end
      if LT.state == "menu" then return end
      if Message.isOpen() and U.frame() % 30 == 0 then U.tap(game, "a") end
    end)
  U.shot(game, DIR .. "/08_after_trade.png")
  result(done, "the trade finished and the menu came back")
  local got = session.party[GIVE]
  log("our party now: " .. partyLine(session.party))
  result(got ~= gave, "slot " .. GIVE .. " holds the POKéMON we got")
  exportSave("recomp_after.sav")

  -- round 2: cancel.  DOWN alone can cycle inside the left column (with
  -- three POKéMON 0 <-> 2, pokefirered trade.c sCursorMoveDestinations):
  -- step into the right column first when DOWN does not reach CANCEL
  for _ = 1, 6 do
    if Menu.pos == 12 then break end
    local before = Menu.pos
    U.tap(game, "down")
    U.wait(3)
    if Menu.pos ~= 12 and Menu.pos <= before then
      U.tap(game, "right")
      U.wait(3)
    end
  end
  result(Menu.pos == 12, "the cursor is on CANCEL")
  U.tap(game, "a")
  U.wait(5)
  U.tap(game, "a")
  result(waitFor(function() return LT.state == "exit" end, 60 * 600), "both canceled")
  U.shot(game, DIR .. "/09_both_cancel.png")
  -- the other player walks out; we follow
  local out = waitFor(function() return Link.link == nil and Space.mapId == CENTER_2F end, 60 * 600, function()
    if Message.isOpen() and U.frame() % 30 == 0 then U.tap(game, "a") end
  end)
  U.wait(120)
  U.shot(game, DIR .. "/10_back_at_the_desk.png")
  result(out, "the other player left; we are back at the desk")
  result(waitFor(function() return visit.state == "ended" end, 60 * 30), "the visit ended")
  exportSave("recomp_end.sav")
  print(failures == 0 and "PASS celio_e2e" or ("FAIL celio_e2e failures=" .. failures))
  io.stdout:flush()
  love.event.quit(failures == 0 and 0 or 1)
end
