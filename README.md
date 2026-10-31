# Loot Glow Amplified

Brighter and larger glow over world loot: loot piles, notes and chests. Brightness, size, chests and items are set in config.lua, live in game.

A [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) Lua mod for Phantom Blade Zero (Unreal Engine 5.7), made with
game version `CL-301524_JKS-17219` and UE4SS `v3.0.1-1188-gf885e8d2`. This README is for developers; what the mod does and
how to install it are in [openmods.md](openmods.md), the mod page on [openmods](https://openmods.nexus).

## How it works

Every 2 seconds, on the game thread, `Scripts/main.lua` lists the loot actors (`BP_Rubbish_C` and its children, which
also hold notes and pages, and `BP_Chest_C`) with `GameplayStatics:GetAllActorsOfClass`, and reaches each one's glow:
its Niagara component (`Niagara`) and the component's effect (`GetAsset`). It walks the effect's emitters to their
renderers (`EmitterHandles` -> `VersionedInstance.Emitter` -> `VersionData` -> `RendererProperties`, and
`StatelessEmitter`) and changes the renderers listed in `SYSTEMS`:

| Part | Change (Brightness `b`, Size `s`) |
|---|---|
| Light renderer of each loot effect | `DiffuseScale`, `SpecularScale` x `b`; `RadiusScale` x (1 + `b`) / 2 |
| Listed sprite and mesh renderers | one more material parameter: `Emissive_Multiplier` (or `Emissive_Intensity`) = `b` |
| Each loot actor's Niagara component | `RelativeScale3D` x `s` |
| Piles with the shared `NS_Item_WhiteDust_001` | that component's `User.UE_LightIntensity` x `b`; the effect itself stays (NPCs and the player use it too) |

A renderer that had no material parameters draws with the shared material, so each loot component is asked once to
build its own material instances (`SetVariableMaterial` on a user parameter that no loot effect has). A value that
still holds what the mod wrote is the mod's; any other value is the game's own (a first load or a reload), so nothing
compounds. Turning a group off, or `Enable = false`, puts the game's values back. Effects and renderers are taken
fresh from the actors on every check, never kept: an effect unloads when its loot streams out. Only the two loot
classes are searched by name, at start, after a map load and while one is missing. After 10 failed checks in a row the
mod stops and puts back what it changed. The game's own distance culling still decides which glows draw.

The effects and renderers in `SYSTEMS` come from the construction scripts of `BP_Chest` and `BP_Rubbish` and from the
effects' materials (which renderer's master material has which emissive scalar).

## Deploy and test

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy.ps1     # copy the mod folder into the game's ue4ss\Mods
python tests\test_main.py                                 # offline test of main.lua (needs lupa)
```

`deploy.ps1` copies `src\phantombladezero_lootglowamplified\` to `<game folder>\platform\steam\ue4ss\Mods\phantombladezero_lootglowamplified\`. The game
folder is `$env:UE5_GAMES_DIR\PBZ`; `-GameDir` or `-ModsDir` override it. The mod folder holds
`enabled.txt`, so UE4SS starts it without an entry in `mods.txt`. An existing `Scripts\config.lua` in the game stays
(the tester's settings); `-ResetConfig` copies the shipped one. UE4SS loads Lua mods at game start. The mod writes
its lines into `ue4ss\UE4SS.log`, for example `[Loot Glow Amplified] 1.0 loaded.`

`tests\test_main.py` runs `main.lua` in Lua 5.4 ([lupa](https://pypi.org/project/lupa/)) with mocks of the UE4SS
functions that the script uses. It finds syntax and logic errors before a game start.

Versioning: every change raises the second number (1.0 -> 1.1) in `mod.json` and in `main.lua`:
`python scripts\bump_version.py`.

## Settings

`Scripts/config.lua` holds the player's settings, `DEFAULTS` in `main.lua` every setting with its default and
`LIMITS` the range of the number settings. The mod reads the file at start and again every 5 seconds (`ReadConfig`):
a changed file applies at the next check, a broken or half-saved one keeps the last settings, a missing one means the
defaults. Players and mod managers keep their own `config.lua` across updates, so a new `main.lua` can meet an older
file: a setting that the file lacks, or has with another type, keeps its default, and the log says so
(`ParseConfig`). Add each setting to
both files with the same value, and read it only from `Settings`, never as `config.X or default` (for a true/false
setting, `false or true` is true). `tests\test_main.py` checks that `config.lua` ships exactly the defaults, and runs
`main.lua` with a missing, empty, broken and wrong `config.lua`.

## Project layout

```
src/phantombladezero_lootglowamplified/   The UE4SS mod folder: Scripts/main.lua, Scripts/config.lua, enabled.txt
tests/test_main.py    Offline test of main.lua with mocks of UE4SS and the game
docs/                 Cover and screenshots
scripts/              bump_version.py
deploy.ps1            Copies the mod folder into the game's ue4ss\Mods
mod.json              Name, version, game, engine and UE4SS version
```

## License

MIT, see [LICENSE](LICENSE).
