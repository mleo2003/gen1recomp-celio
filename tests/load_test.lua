-- The mod through the engine's real headless loader, as a FireRed boot:
-- loads clean, exports its version, and takes over the attendant's linkup
-- and the wireless check without losing the engine's own.
--
--   luajit <mod>/tests/load_test.lua      (from the engine root)
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local here = (arg and arg[0] or ""):match("^(.*)/tests/[^/]+$") or "."
-- the modkit's file system is rooted at the engine; an absolute mod path
-- needs an empty root
local root = here:sub(1, 1) == "/" and "" or nil
local T = require("tests.modkit")
require("src.core.GameVersion").set("firered")

local LT = require("src.core.game3.link.trade")
local Link = require("src.core.game3.link")
local engineLinkup = LT.tryTradeLinkup
local engineAdapter = Link.isWirelessAdapterConnected

local run = T.sdk.loadMod(here, { data = T.sdk.gen3Data(), generation = 3, root = root })
T.eq(#run.errors, 0, "loads clean on a FireRed boot (" .. tostring(run.errors[1]) .. ")")
T.eq(run.loader.exports.gblink_celio.version, run.loader.mods.gblink_celio.manifest.version,
     "exports its manifest version")
T.check(LT.tryTradeLinkup ~= engineLinkup, "the attendant's TryTradeLinkup is the mod's")
T.eq(LT._celioTryTradeLinkup, engineLinkup, "the engine's own is kept for after the door")
T.check(Link.isWirelessAdapterConnected ~= engineAdapter, "the wireless check is wrapped")

-- a second boot (mods re-run every session) must not wrap a wrapper
local run2 = T.sdk.loadMod(here, { data = T.sdk.gen3Data(), generation = 3, root = root })
T.eq(#run2.errors, 0, "loads again")
T.eq(LT._celioTryTradeLinkup, engineLinkup, "still the engine's original underneath")

-- with mods on the engine's Wireless Club is closed: the attendant goes
-- straight to the cable services without a notice
local ctx = { specialVars = {}, stringVars = {} }
Link.liveProfile = function() return nil, "mods" end
local yielded, value = Link.isWirelessAdapterConnected(ctx, {})
T.eq(yielded, false, "no notice to wait on")
T.eq(value, 0, "VAR_RESULT 0: the cable path")

run.release()
run2.release()
T.finish("gblink_celio")
