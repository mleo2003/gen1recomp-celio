# GB-Link Celio Trades

Trade Pokémon from FireRed or LeafGreen with a real GBA, an emulator, or
another game that [celio.gblink.io](https://celio.gblink.io) links, over the
internet. The Pokémon Center 2F **Trade Center** opens a four-digit Celio
room instead of waiting for a cable, and the trade itself runs on the game's
own Trade Center: the trade menu, STATS, the animation, trade evolutions and
the save.

**Persona: the Bridge Builder.** The engine already has a complete FireRed
Cable Club; this mod gives it a different kind of peer. To the other GBA it
is a GBA on the other end of a link cable, playing the link leader exactly
as pokefirered does; to the engine it is the far machine of its own link.
It changes no game rules.

A mod for the [Pokemon Gen 1 Recompilation Project](https://github.com/bryanthaboi/gen1recomp)
by BOIS CLUB GAMES, LLC. Its Red/Blue/Yellow and Gold/Silver/Crystal sibling
is [GB-Link Online Trades](https://github.com/mleo2003/gen1recomp-gblink).

## Install

1. Download `gblink_celio-<version>.zip` from this repo's
   [Releases](https://github.com/mleo2003/gen1recomp-celio/releases/latest).
2. In the game's launcher: **MODS > Import mod .zip**, pick the file, and
   enable **GB-Link Celio Trades**.

The Celio server only takes secure connections (wss://), so the game needs
its TLS helper: the official Windows and Android builds have it. A source
checkout on macOS or Linux needs `gen1tls` built from the engine's
`native/tls_dial` and placed next to the game folder.

## Use

1. In any Pokémon Center, go upstairs and talk to the **Cable Club**
   attendant (the right-hand desk). Choose **TRADE CENTER** and save.
2. The **GBA LINK ONLINE (CELIO)** door opens:
   - **MAKE A ROOM** shows a four-digit number: your friend joins it.
   - **JOIN A ROOM**: type the number your friend's page shows (Up/Down
     change a digit, Left/Right move), then A.
3. Wait for the friend's game to link (below). **B** gives up at any time.
4. Once linked, the attendant walks you into the Trade Center as usual.
   Sit in a chair; when your friend sits too, the trade menu opens.

Trade as many times as you like. After **both** players choose CANCEL you
are back in the room: sit down again, or walk out through the door at the
bottom. If your friend walks out, you are shown out too.

### The other player

On [celio.gblink.io](https://celio.gblink.io), choose *Online Link*, then
**Join Session** with your room number (or **Create Session** and give you
theirs to type in), and connect their game:

- **A real GBA** on a Celio (GB-Link) adapter.
- **mGBA Celio edition** with its `mGBACelioServer.lua` script, connected
  from the page's emulator option.

Then, on their game: Pokémon Center 2F, the Cable Club attendant,
**TRADE CENTER**, and save. From there it is an ordinary cable trade on
their side.

### How long a trade takes

Each game saves after a trade. This mod lets your game commit the trade
only **after the other game has saved its side**: if the connection drops
in the middle, neither game has traded and nothing is lost or copied.
So after both players say YES, the other game plays its animation and saves
first (its player presses A through its evolution messages, if any), and
then yours does. While the other game waits for yours, it shows
"Communication standby".

## Tested

- gen1recomp FireRed (macOS, LÖVE window) with FireRed (USA, Europe) Rev 1
  in mGBA Celio edition 2.0.0 (Windows) through celio.gblink.io: two-way
  trade, both cancel, the cartridge side walking out. Both saves pass
  PKHeX's legality check.
- The protocol layer against the same FireRed, with trade evolutions on the
  cartridge (Kadabra, Machoke) and walking out from either side.

Not tested yet: LeafGreen (on either side), a real GBA on an adapter, Ruby,
Sapphire or Emerald partners, and the Switch.

## Known limits

- Two copies of this game cannot meet over Celio: both would lead the link.
  Use the game's own online play for that.
- The other player's avatar stays by the door in your Trade Center (and
  yours in theirs); sitting down still works on both sides.
- The Colosseum (battles) is not offered.
- Mail from the other game arrives with its Pokémon; mail your Pokémon carry
  is sent too.

## Options

**SERVER**: the Celio server's address (default
`wss://celio-server.up.railway.app`, the one celio.gblink.io uses).

## Development

The tests run from the engine's root with plain LuaJIT. The ones that need
FireRed data look for an imported FireRed (set `POKEPORT_IDENTITY` to the
profile that has it, or `POKEPORT_GBA_CACHE`).

```
luajit <mod>/tests/codec3_test.lua    # party structs, mail, cards vs the engine's codec
luajit <mod>/tests/bridge3_test.lua   # the engine's Trade Center vs a scripted FireRed
luajit <mod>/tests/load_test.lua      # the mod through the real loader
CELIO_URL=ws://127.0.0.1:<port> luajit <mod>/tests/celio_test.lua   # a local Celio server
```

`tests/e2e/` has the live tools: `recomp3_driver.lua` plays the game in a
LÖVE window (`POKEPORT_DRIVER`), `virtual_cart.lua` is a headless virtual
FireRed for testing the link layer against a real one.

## Credits

- GB-Link and Celio: [celio.gblink.io](https://celio.gblink.io), the relay
  server, the adapter and the mGBA script. This mod speaks their protocol;
  none of their code is included.
- [pret/pokefirered](https://github.com/pret/pokefirered): the cable club,
  link and trade routines the link layer follows.
- [PKHeX](https://github.com/kwsch/PKHeX): save checks during testing.

## License

MIT, see [LICENSE](LICENSE).
