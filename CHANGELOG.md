# Changelog

All notable changes to Needs are documented here. Versions follow Semantic
Versioning while the mod remains in active development.

## [1.8.0] - 2026-09-11

### Added

- Day/night Fatigue: awake Fatigue gain increases at night through
  `fatigue.circadian`, with configurable night and day multipliers.
- Temporary Rested bonus: sleeping for at least the configured minimum applies
  an invisible `xneeds_rested` effect that reduces awake Fatigue gain for its
  duration.
- Environment-driven Thirst and Fatigue: biome and environment-effect gain
  multipliers under `thirst.environment` and `fatigue.environment`, matching the
  existing Hygiene environment system.
- Ordered biome pattern fallback for Thirst, Fatigue, and Hygiene, so modded
  biome variants inherit a base multiplier (`aliendesert` matches `desert`).
  Exact keys take precedence and unmatched biomes stay neutral at 1.0.
- `/xneeds get` now reports night/day, Rested state, and the current thirst and
  fatigue environment multipliers. The Fatigue and Thirst hover tooltips show
  the active circadian/rested/environment state.

## [1.7.0] - 2026-09-11

### Added

- Configurable container returns under `beverages.returnItems`. By default,
  drinking Bottled Water gives back an Empty Bottle.

### Changed

- Normal sleeping now fully restores Fatigue in about three minutes.
- Sleep no longer changes the application time scale. Sleeping uses normal game
  speed, which removes the broken interaction and Save & Quit hang observed
  after whole-game acceleration in singleplayer.

### Removed

- The clickable sleep fast-forward button, the `/timescale` path, the silent
  fast-forward probes, and the world-server relay script and patch. The mod now
  adds only its player script context.

## [1.6.0] - 2026-09-11

### Added

- Optional hover-only HUD tooltips for each Needs meter. Hovering a meter shows
  the need name, numeric value, current tier, any active recovery state, and the
  active penalties for that need.
- `hud.tooltips` configuration for enabling the tooltips, sizing, and tier
  colors. Disabled tooltips leave the existing meters unchanged.
- Remaining caffeine time is reported by `/xneeds get` and shown in the Fatigue
  hover tooltip.
- `/xneeds beverages` audit lists every detected drink with its resolved profile
  and source, defaulting to the items that fall back to `standard`. Accepts
  `all`, `details`, a profile name, or a name fragment. `details` also reports
  the asset path, source mod, and the text the classifier sees.
- A `solid` beverage profile for FU food items that are technically category
  `drink` but give no hydration.
- Exact item mappings for the previously unclassified Workshop drinks
  `corvexdrink` and `codezerches` (soda), `anom_beakeasymoonshine` (alcohol),
  `fubloodchalice` (standard), and `chewablemagnet`, `jarredfetus`,
  `meatsmoothie`, and `orphanpaste` (solid).

### Changed

- Hygiene recovery now records and reports its active source (clean liquid,
  bath/tub, shower/bath, or rain) for the hover details.

## [1.5.0] - 2026-09-11

### Added

- Native Starbound HUD artwork for Thirst, Fatigue, Bladder, and Hygiene.
- Configurable icon paths, scale, logical size, and spacing.

### Changed

- Increased meter row spacing to prevent icon crowding while retaining thin
  bars.

## [1.4.1] - 2026-09-11

### Added

- Cooldown-controlled contextual feedback for caffeine, alcohol, salty, toxic,
  and dehydrating drinks.
- Detailed `/xneeds beverage <itemName>` profile and override diagnostics.
- Explicit opt-in support for modded consumables outside the normal `drink`
  category.

### Fixed

- Explicit FU beverage exceptions now receive their resolved profile defaults.

## [1.4.0] - 2026-09-11

### Added

- Configurable beverage profiles for water, juice, milk, soda, caffeine,
  alcohol, salty, toxic, and standard drinks.
- Temporary caffeine effect with immediate Fatigue relief and suppressed awake
  Fatigue accumulation.
- Alcohol Fatigue, hydration, and bladder-pressure behavior.
- Item parameters and exact mapping hooks for FU and Workshop compatibility.

## [1.3.3] - 2026-09-11

### Changed

- Set optional sleep acceleration to 1.5x.
- Tuned normal sleeping to recover full Fatigue in approximately five minutes.

## [1.3.2] - 2026-09-11

### Changed

- Removed universe disconnect callbacks from the final design to avoid work
  during save-and-quit teardown.
- Temporarily reduced sleep acceleration to 2x and doubled base sleeping
  recovery during tuning.

## [1.3.1] - 2026-09-11

### Changed

- Replaced chat-based safety responses with silent direct world-server
  messages, eliminating repeated empty chat entries.
- Reduced initial sleep acceleration from 4x to 3x.
- Increased Needs HUD simulation refresh frequency to four updates per game
  second.

## [1.3.0] - 2026-09-11

### Added

- Clickable sleep fast-forward control.
- Single-player detection and multiplayer-safe Needs-only fallback.

## [1.2.0] - 2026-09-11

### Added

- Hygiene changes from running, jumping, combat, rain, clean and dirty liquids,
  biome conditions, and environmental effects.
- Configurable shower, bath, and toilet recognition.

## [1.1.0] - 2026-09-11

### Added

- Four configurable severity thresholds and crossing warnings.
- Need-specific movement, jump, power, energy-regeneration, and protection
  consequences with safety floors.
- Local `/xneeds` testing commands.

## [1.0.0] - 2026-09-11

### Added

- Persistent Thirst, Fatigue, Bladder, and Hygiene simulation.
- Beverage consumption integration and recovery interactions.
- Adaptive HUD meters anchored beneath the vanilla/FU hunger bar.
