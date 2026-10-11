# Bundled dependencies

- UE4SS v3.0.1-1164-g5e627997: official release archive from
  https://github.com/UE4SS-RE/RE-UE4SS/releases . SHA256:
  `3c72142a383e25e9f9553ac9e4d5677aa572e98cb369cac57200efb2e381e603`.
  Its license is inside the unchanged archive and installed with the loader.
- Lua 5.4.7 syntax checker, compiled locally from official https://www.lua.org/ftp/
  source. License and copyright notice: `licenses/lua-readme.html`.
- json.lua by rxi: https://github.com/rxi/json.lua . MIT license and copyright
  notice are retained at the top of `staging/runtime-adapter/deps/json.lua`.
  Pinned SHA256: `0eaccda57fabc0330736de25f45cf589821a42b5e0fe02e4e3125f7dc0bf2b7e`.

The existing environment supplies Python, websockets 13.1 and official
Archipelago 0.6.9. These are not bundled. Integration guidance references:
https://github.com/ArchipelagoMW/Archipelago/blob/main/docs/network%20protocol.md
and https://github.com/ArchipelagoMW/Archipelago/blob/main/docs/world%20api.md .
