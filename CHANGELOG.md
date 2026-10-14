# Changelog

Format: [keep a changelog](https://keepachangelog.com/en/1.1.0/).
Version headings match `manifest.json`'s `version`.

## 0.1.1

### Fixed

- The door no longer says a Switch can link: that path is not tested.

## 0.1.0

### Added

- **FireRed and LeafGreen over Celio.** The Pokémon Center 2F Cable Club's
  TRADE CENTER opens a Celio room (MAKE A ROOM / JOIN A ROOM, four digits,
  the rooms celio.gblink.io uses). The other side links like a cable: the
  LinkPlayer exchange, trainer cards, the Trade Center room and its seats,
  the party, mail and ribbon blocks, the trade menu, the trade, the save
  standbys, the room re-link after both cancel, and walking out.
- The trade runs on the engine's own Trade Center (menu, STATS, animation,
  trade evolutions, save).
- The engine commits a trade only after the other game has saved its side,
  so a dropped connection leaves both games as they were.
- Mod option SERVER.
