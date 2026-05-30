# FS25_AnimalWaste

A small Farming Simulator 25 mod that lets you scale up cow-shed manure and liquid manure production. Pick 1x, 2x or 3x.

> **⚠ Public beta (v0.1.0.2).** v0.1.0.2 fixes a significant bug: earlier builds silently stopped milk production on cow sheds (see Known issues below) — please update. Tested on my own save and it behaves, but the second pair of eyes are yours. Please file anything odd via [GitHub Issues](https://github.com/chrismpmason/FS25_AnimalWaste/issues) — small details welcome (game version, other mods active, what you did, what you saw).

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
- **Red Tape (Ozz)**: confirmed compatible (audited against v1.0.2.4). The two mods hook different parts of the husbandry pipeline and don't conflict. See the gameplay note below for how the multiplier interacts with Red Tape's policies.
- **BetterHusbandry, Realistic Milking Time, etc.**: not explicitly tested but no reason to expect a conflict — as of v0.1.0.2 this mod no longer overwrites any husbandry production function. It only appends to the husbandry's hourly update and tops up the extra manure / liquid manure in storage, so it stays clear of the milk and other output paths entirely. If you find a conflict, file an issue.
- **Cow sheds only**: pigs, horses, sheep and chickens stay vanilla in v0.1. Other animals are on the roadmap, not in this release.
- **Singleplayer only** for v0.1. The mod's modDesc declares `multiplayer supported="false"` so the game won't let you load it in MP.

**Running with Realistic Livestock:** Note: when running with Realistic Livestock, RL's 'Products per day' panel will continue to show vanilla (1x) production predictions even when AnimalWaste is set to 2x or 3x. This is a cosmetic display mismatch - the actual production rates DO scale correctly (verify by watching your manure storage fill level). RL's display calculates its prediction from a different point in the husbandry code than where AnimalWaste applies its multiplier, so the two paths don't meet. The storage fill rate is the ground truth.

**Running with Red Tape:** AnimalWaste's multiplier stacks naturally with Red Tape's policies. The slurry-pit full penalty fires roughly N× as often at N× multiplier (because you fill a fixed-capacity pit faster — realistic). The manure-spreading threshold policy is ratio-based, so it doesn't fire more often. If you're running AnimalWaste at 2x or 3x with Red Tape, plan a larger slurry pit and a tighter spreading schedule — that's the trade-off.

## Known issues / things to keep an eye on

- If you change the multiplier mid-save, the new rate applies on the next in-game hourly tick, not immediately. This is by design (production is hourly) but can feel like nothing happened for a minute.
- **Fixed in v0.1.0.2 — milk stopping on cow sheds.** Earlier builds (v0.1.0.1) overwrote a shared husbandry production function, and as a side effect silently zeroed milk output on cow sheds. Manure and liquid manure kept scaling, so it was easy to miss, and it showed up as `PlaceableHusbandryMilk.updateOutput` errors in `log.txt`. To be clear: this **was** caused by this mod — not by vanilla or Realistic Livestock, as v0.1.0.1's notes wrongly claimed. v0.1.0.2 fixes it by no longer touching the production chain at all (it now appends to the hourly update instead). If you ran v0.1.0.1 with cows, update to v0.1.0.2 and milk returns to normal.
- If anything else looks off — manure not scaling, settings row missing, errors with the `[FS25_AnimalWaste]` prefix in `log.txt` — please file an issue with the log snippet.

## Reporting bugs / requesting features

[GitHub Issues](https://github.com/chrismpmason/FS25_AnimalWaste/issues). Please include:

- FS25 version
- Mod version (currently 0.1.0.2)
- Other mods you have active (especially anything husbandry-related)
- The relevant lines from `log.txt` (filter for `[FS25_AnimalWaste]`)
- What you expected vs. what happened

Feature requests welcome too — pigs / horses / per-shed control / multiplayer are all known asks for later versions.

## License

MIT — see [LICENSE](LICENSE).

## Author

Chris Mason (Hartwell Farm).
