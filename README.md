# Needs

Needs is an xStarbound survival-simulation mod that adds Thirst, Fatigue,
Bladder, and Hygiene to the player without replacing the vanilla or Frackin'
Universe HUD.

Current version: **1.8.0**

![Needs HUD preview](_previewimage.png)

## Requirements

- Starbound running through xStarbound.
- The bundled `xSBassets` dependency.

This mod uses xStarbound-specific player contexts, full-window canvases, world
server messaging, and post-load asset processing. Stock Starbound is not
supported.

## Features

- Persistent Thirst, Fatigue, Bladder, and Hygiene values.
- Four thin, scale-aware meters anchored beneath the existing hunger bar.
- Native Starbound-style icons and compatibility with FU/FrackinInterface HUD
  geometry.
- Optional hover-only HUD details for each meter: name, value, tier, active
  recovery state, and active penalties. Hidden until hovered, with no permanent
  labels.
- Configurable thresholds, warnings, and nonlethal gameplay consequences.
- Automatic detection of vanilla, FU, and Workshop beverages after all assets
  load.
- Water, juice, milk, soda, caffeine, alcohol, salty, toxic, standard, and
  solid-food profiles, with exact mappings for misclassified FU items.
- Caffeine relief with remaining-time reporting, alcohol fatigue, dehydration,
  and bladder effects.
- Configurable container returns, such as getting an Empty Bottle back after
  drinking Bottled Water.
- Toilet relief and Hygiene recovery from baths, showers, clean liquids, and
  rain.
- Hygiene loss from activity, combat, dirty liquids, and harsh environments.
- Normal sleeping fully restores Fatigue in about three minutes, and a
  qualifying sleep grants a temporary Rested bonus.
- Day/night Fatigue: staying awake at night adds Fatigue faster.
- Environment-driven Thirst and Fatigue from hot, cold, toxic, and other biomes.
- Local testing and beverage-diagnostic commands.

## Installation

Place this directory directly in the Starbound `mods` directory:

```text
Starbound/
  mods/
    xneeds_v0/
      _metadata
      xneeds_v0.config
      ...
```

Restart xStarbound after installing or updating the mod. Existing characters
initialize missing Needs data automatically.

## Configuration

All gameplay and presentation tuning is centralized in
[`xneeds_v0.config`](xneeds_v0.config).

Important sections include:

- `beverages`: profiles, classification rules, FU exceptions, caffeine,
  feedback, and container returns.
- `thresholds`, `consequences`, and `warnings`: severity and penalties.
- `hygiene.environment` and `hygiene.combat`: environmental Dirtiness.
- `sleep.bedEffects` and `fatigue.sleepRecoveryPerSecond`: sleep detection and
  rest recovery.
- `fatigue.circadian` and `fatigue.rested`: day/night Fatigue and the temporary
  Rested bonus.
- `thirst.environment` and `fatigue.environment`: biome and environment effect
  gain multipliers, with exact keys plus pattern fallback for modded biome
  variants.
- `hud`: visibility, spacing, colors, native icon paths, and the optional
  hover tooltips.
- `debug`: local testing controls and logging.

### HUD hover details

Hovering any Needs meter displays a compact tooltip beside the meters with the
need name, numeric value, current tier, any active recovery state, and the
active penalties for that need. Tooltips are hover-only, reuse the existing HUD
styling, and add no permanent labels or separate panel. Set
`hud.tooltips.enabled` to `false` to disable them while keeping the meters.

## Testing commands

Commands are local to the current player and do not require disabling
xStarbound safe scripts.

```text
/xneeds
/xneeds get
/xneeds set fatigue 70
/xneeds set thirst 90
/xneeds set bladder 85
/xneeds set hygiene 25
/xneeds set dirtiness 75
/xneeds set all 85
/xneeds add bladder -20
/xneeds preset critical
/xneeds beverage coffee
/xneeds beverage <itemName>
/xneeds beverages
/xneeds beverages all
/xneeds beverages details
/xneeds beverages <profile>
/xneeds reset
```

The beverage command reports the selected profile, classification source,
signed Needs changes, caffeine duration, and any item-specific overrides.

The beverages audit lists every detected drink with its resolved profile and
source. With no argument it lists only the items that fall back to the default
profile, which are the best candidates for an exact `beverages.itemProfiles`
exception. Pass `all`, a profile name, or a name fragment to change the listing.
`details` adds each fallback's asset path, source mod, and the description and
effect text the classifier sees, which makes it easy to identify unfamiliar
items or patched asset sources.

## Sleeping

Sleeping in a recognized bed accelerates Fatigue recovery so a full recharge
takes about three minutes. The mod never changes the application time scale or
sends chat commands, avoiding the interaction and save-and-quit problems that
game-clock acceleration caused. Leaving the bed stops the recovery.

## Compatibility

- The mod adds its own player script context only.
- It reads the final loaded hunger-bar geometry instead of replacing
  `teambar.config`.
- Drink hooks are appended after Workshop assets load; existing effects remain
  intact.
- FU files, FrackinInterface files, and vanilla interface files are not
  overwritten.
- Exact exceptions can be added through `beverages.itemProfiles` when a modded
  drink cannot be classified reliably.

## Safe removal

For the cleanest uninstall while consequences are active:

1. Set `consequences.enabled` to `false`.
2. Start the affected character once.
3. Save and quit normally.
4. Remove the mod.

This allows the player script to clear its namespaced persistent modifiers.
Core Needs values are stored only in the mod's player-script storage and do not
replace vanilla resources.

## Development

Implementation details, extension parameters, and compatibility boundaries are
documented in [`docs/V1_DEVELOPMENT.md`](docs/V1_DEVELOPMENT.md).

Pack the directory itself with xStarbound's `asset_packer`; generated `.pak`
files are intentionally ignored by Git.

## License

Released under the [MIT License](LICENSE).
