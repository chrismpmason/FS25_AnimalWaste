# FS25_AnimalWaste

A small Farming Simulator 25 mod that lets you scale up cow-shed manure and liquid manure production. Pick 1x, 2x or 3x.

> **⚠ Public beta (v0.1.0.1).** This is the first release out in the wild. Tested on my own save and it behaves, but the second pair of eyes are yours. Please file anything odd via [GitHub Issues](https://github.com/chrismpmason/FS25_AnimalWaste/issues) — small details welcome (game version, other mods active, what you did, what you saw).

## What it does

Scales straw consumption and manure / liquid manure output on cow sheds by a single multiplier. Straw goes faster too, so the trade is real — pick 3x and your bedding bales drain three times as quick.

Useful if you've got a big dairy or beef operation, the lagoon space to soak it up, and vanilla rates feel a bit miserly.

## Installation

1. Download `FS25_AnimalWaste.zip` from the [Releases page](https://github.com/chrismpmason/FS25_AnimalWaste/releases).
2. Drop it into your FS25 mods folder:
   `Documents\My Games\FarmingSimulator2025\mods\`
3. Launch FS25, enable the mod in your savegame's mod list, load the save.

## Setup

Once in-game, hit `Esc` → **Settings** and scroll down. You'll find a new section called **Animal Waste** with one row, **Husbandry Production Rate**. Pick 1x, 2x or 3x. The choice is saved per-savegame and applies on the next in-game hour.

## Compatibility

- **Realistic Livestock (Ritter fork)**: confirmed compatible. The two mods touch different parts of the husbandry pipeline. Tested on a heavily-modded Oakwell save with RL active.
- **BetterHusbandry, Realistic Milking Time, etc.**: not explicitly tested but no reason to expect a conflict — none of them touch the spec function this mod hooks. If you find a conflict, file an issue.
- **Cow sheds only**: pigs, horses, sheep and chickens stay vanilla in v0.1. Other animals are on the roadmap, not in this release.
- **Singleplayer only** for v0.1. The mod's modDesc declares `multiplayer supported="false"` so the game won't let you load it in MP.

## Known issues / things to keep an eye on

- If you change the multiplier mid-save, the new rate applies on the next in-game hourly tick, not immediately. This is by design (production is hourly) but can feel like nothing happened for a minute.
- The mod silently swallows a pre-existing engine-side error in `PlaceableHusbandryMilk.updateOutput` that fires on some cow-shed configurations. This isn't caused by this mod — vanilla + RL together trigger it — but you might see the error in your `log.txt` next to this mod's lines. Manure scaling still works through it.
- If anything else looks off — manure not scaling, settings row missing, errors with the `[FS25_AnimalWaste]` prefix in `log.txt` — please file an issue with the log snippet.

## Reporting bugs / requesting features

[GitHub Issues](https://github.com/chrismpmason/FS25_AnimalWaste/issues). Please include:

- FS25 version
- Mod version (currently 0.1.0.1)
- Other mods you have active (especially anything husbandry-related)
- The relevant lines from `log.txt` (filter for `[FS25_AnimalWaste]`)
- What you expected vs. what happened

Feature requests welcome too — pigs / horses / per-shed control / multiplayer are all known asks for later versions.

## License

MIT — see [LICENSE](LICENSE).

## Author

Chris Mason (Hartwell Farm).
