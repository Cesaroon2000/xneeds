# Needs V1.9.0 development notes

## Architecture and persistence

Needs V1 remains a standalone xStarbound generic player-script context named
xneeds_v0. It does not replace vanilla, FU, or FrackinInterface assets and does
not ship individual consumable or furniture patches.

Persistent player data uses schema 2:

    storage.needs = {
      version = 2,
      thirst = 0,
      fatigue = 0,
      bladder = 0,
      hygiene = 100
    }

All values are clamped to 0 through 100. Higher Thirst, Fatigue, and Bladder
values are worse. Hygiene retains the original V0 convention: 100 is clean and
0 is filthy.

Migration from schema 1 preserves Fatigue, Bladder, and Hygiene and initializes
Thirst from defaults. Missing, partial, invalid, infinite, and out-of-range
fields are repaired through the same normalization path.

## Default simulation and recovery

All tuning is centralized in /xneeds_v0.config.

| Need | Passive default | Recovery |
| --- | --- | --- |
| Thirst | 0 to 100 in about 2 hours | Beverage-profile dependent |
| Fatigue | 0 to 100 in about 4 awake hours | Sleeping recovers 100 in about 3 minutes |
| Bladder | 0 to 100 in about 6 passive hours | Loungeable toilets relieve 5 points per second |
| Hygiene | 100 to 0 in about 8 inactive hours | Clean water, rain, and bathing fixtures restore Hygiene |

After all normal and Workshop asset sources load, xStarbound's post-load asset
preprocessor finds the final consumables whose category is drink. It appends an
invisible, one-shot notifier effect to every existing effect group and creates a
small generated status-effect definition for that item. On consumption the
effect messages the consumed item name to the persistent player context, which
then resolves the final item config. Existing item effects are preserved.

This route is necessary because xStarbound handles the hardcoded recordEvent
message inside the engine before generic player message handlers, while
statistics event scripts cannot access world or player callbacks. The default
category is drink.

## Beverage depth

Every detected drink resolves a configurable beverage profile. Consumables in
the drink category are detected automatically; exact item mappings and the
profile parameter also opt unconventional FU consumables into the system.
Resolution uses
the final merged item asset and follows this precedence:

1. The item's `needsBeverageProfile` parameter.
2. An exact `beverages.itemProfiles` entry.
3. The first matching configurable name, description, or effect rule.
4. The standard profile.

Default profiles are deliberately conservative starting points:

| Profile | Thirst change | Bladder change | Fatigue change | Caffeine |
| --- | ---: | ---: | ---: | ---: |
| Water | -35 | +20 | 0 | — |
| Juice | -28 | +16 | 0 | — |
| Milk/shake | -22 | +14 | 0 | — |
| Soda/cola | -18 | +18 | 0 | — |
| Coffee/caffeine | -18 | +20 | -12 | 300 seconds |
| Alcohol | -5 | +25 | +8 | — |
| Salty | +10 | +12 | 0 | — |
| Toxic | +20 | +10 | +5 | — |
| Standard | -25 | +15 | 0 | — |
| Solid food | 0 | +5 | 0 | — |

While the invisible `xneeds_caffeinated` effect is active, awake Fatigue gain
uses the configured multiplier, zero by default. Coffee therefore gives an
immediate temporary reduction and pauses further awake accumulation for five
minutes; it does not interfere with the item's existing effects. While the
effect is active, the `xneeds_caffeinated` effect script reports its own
remaining `effect.duration()` to the player script, which shows it in
`/xneeds get` and the Fatigue hover tooltip as m:ss. The readout therefore
follows the real status effect rather than a second countdown that could drift
from the game clock. The configured caffeine duration only seeds the display
until the first report arrives. Alcohol makes
the player somewhat more tired, provides little hydration, and fills the
Bladder more strongly. Salty and toxic profiles increase Thirst.

`needsThirstValue`, `needsBladderValue`, `needsFatigueChange`, and
`needsCaffeineDuration` provide signed per-item overrides. Setting one to false
disables that component. Exact item maps remain available for FU or other
Workshop exceptions without editing their assets.

Optional beverage feedback uses short status messages for caffeine, alcohol,
salty, toxic, or otherwise dehydrating drinks. A shared configurable cooldown
prevents rapid consumption from flooding the screen. The messages, cooldown,
and feature toggle are under `beverages.feedback`.

`beverages.returnItems` grants a container back when a listed item is consumed,
through `player.giveItem`. The default map returns an Empty Bottle for Bottled
Water. Entries are case-insensitive item-name pairs, the grant runs once on the
local consumption event, and the feature can be disabled with its `enabled`
flag. Foods or other drinks can be added the same way.

`/xneeds beverage <itemName>` reports the resolved profile and its source
(explicit item parameter, exact mapping, classification rule, or default). It
also reports every signed Needs change and whether each value came from the
profile, an item parameter, or an override map. This is the preferred way to
identify and correct FU exceptions.

Toilet relief requires the player to be lounging in an object whose name matches
the configured toilet patterns. The installed vanilla and FU toilet families use
those names. Objects may define needsBladderReliefRate to override or disable
relief.

Hygiene recovery accepts only configured liquid names. The defaults are water
and healingliquid; hazardous and specialty liquids are excluded. Loungeable
bath/tub objects also clean the player. Active vanilla showers and baths are
recognized through their nearby dripping helper objects. A fixture may define
needsHygieneRecoveryRate for explicit compatibility.

## Food layer

Eating is detected through the same generated notifier used for drinks.
`register_drinks.lua` registers consumables whose merged category matches either
`bladder.drinkCategory` (default drink) or `foods.category` (default food), plus
any item opted in through a profile parameter or exact `itemProfiles` mapping.
Each registered item gets one invisible one-shot effect that forwards its name
to the player script.

Resolution mirrors beverages with a separate `foods` section: item parameter,
exact `foods.itemProfiles`, then ordered `foods.classificationRules`, then
`foods.defaultProfile`. Food profiles carry the same four fields as drinks
(thirstRecovery, bladderGain, fatigueChange, caffeineDuration) and are applied by
the shared consumable path. The generic `needsThirstValue`, `needsBladderValue`,
`needsFatigueChange`, and `needsCaffeineDuration` parameters therefore work for
foods too, and a caffeinated food starts the same caffeine effect as a drink.

The default food profiles are conservative: meal and snack increase Thirst
slightly and add Bladder; juicy fruit restores Thirst; salty food increases it
strongly; sugary food reduces Fatigue briefly; heavy food adds Fatigue; raw meat
and toxic food are mild penalties. `/xneeds food <itemName>` and `/xneeds foods`
mirror the beverage diagnostics and audit so fallbacks and misclassifications
are easy to find and correct.

## Environmental Hygiene

Environmental Hygiene extends the same stored Hygiene value; the persistence
schema is unchanged.

- Running and jumping accumulate small additional decay based on actual time in
  those movement states.
- Damage taken and damage inflicted are read from heartbeat-based status
  notification APIs. Loss scales with damage and has a configurable per-update
  cap, so large or rapidly repeated attacks cannot create an unbounded spike.
- Explicit clean liquids restore Hygiene at per-liquid rates. Water defaults to
  2 points per second and healing liquid to 2.5.
- Dirty liquids are recognized by explicit names, configurable name fragments,
  or configured liquid status effects. Vanilla poison, swamp water, tar, slime,
  and fuel are dirty by default. This metadata route can also recognize many FU
  liquids without patching FU.
- Rain uses an active configured wet effect while the player is outside liquid
  and not underground as a client-safe proxy. xStarbound exposes the planet's
  possible weather list server-side but no client-side current-weather query.
  The default rain/wet recovery is 0.35 points per second.
- Biome and environmental-effect maps multiply passive and activity decay.
  Defaults cover common hot, toxic, swamp, tar, flesh, and volcanic conditions.

Cleaning suspends passive decay for that update, but activity, dirty-liquid,
and queued combat losses remain additive. All rates, classifications, biome
multipliers, and combat coefficients live under hygiene.environment and
hygiene.combat in /xneeds_v0.config.

## Thresholds and consequences

Every need uses four configurable problem thresholds:

| Tier | Default threshold |
| --- | ---: |
| Noticeable | 50 |
| Serious | 70 |
| Urgent | 85 |
| Critical | 95 |

Warnings occur only when crossing upward into a tier. Recovering below a
threshold rearms that tier. Each need and tier has its own configurable message.

Consequences are need-specific:

- Thirst primarily reduces energy regeneration, then power and speed.
- Fatigue reduces power, movement, jumping, and at high levels energy regeneration.
- Bladder pressure primarily reduces movement and jumping, with a modest power
  penalty at high levels.
- Dirtiness modestly reduces protection and power.

When several needs are elevated their multipliers combine multiplicatively.
Configurable safety floors prevent the combined result from dropping below 60%
speed, 65% jump effectiveness, 50% power, 25% energy regeneration, or 65%
protection with the default tuning. No tier deals direct damage or kills the
player. Movement modifiers are submitted per frame; stat modifiers use the
unique xneeds_v1_penalties persistent category.

No visible status icons, buffs, sounds, or animations are added. Generated drink
notifier effects are invisible and expire immediately after forwarding the item
name. The persistent modifier category is cleared whenever needs return below
warning, penalties are disabled, or the script unloads. Before uninstalling
while a character is currently penalized, set penalties.enabled to false, load
that character once, save, and exit cleanly so the namespaced modifier is
cleared.

## Sleeping

Sleeping is detected exactly as before: the player is lounging and either using
the sleep emote, under a configured bed effect, or lounging in an object whose
`sitEmote` is sleep. Detection is defined by `sleep.bedEffects` in
/xneeds_v0.config.

While sleeping, Fatigue recovers at `fatigue.sleepRecoveryPerSecond`, tuned so a
full 0-to-100 recharge takes about three minutes. Awake Fatigue gain is
unaffected, and caffeine still pauses awake gain.

Sleep acceleration and all application time-scale changes were removed in V1.7.
Earlier builds changed the whole-game `/timescale` and, in multiplayer, ran a
Needs-only fallback coordinated by a world-server probe. In singleplayer that
path could show a false multiplayer message, break world interaction after
leaving the bed, and hang on Save & Quit. The mod now never touches the game
clock, sends no chat commands, and adds no world-server or universe callbacks,
so sleeping is safe to interrupt and Save & Quit is unaffected.

## Circadian rhythm and environment

Fatigue gain while awake is multiplied by several independent factors that are
combined multiplicatively with the caffeine factor:

- Sleeping recovery is unaffected; these only apply while awake.
- `fatigue.circadian` uses `world.timeOfDay()` (0.0 to 1.0) and the configurable
  `nightStart` / `nightEnd` window to choose `nightGainMultiplier` or
  `dayGainMultiplier`. The window wraps when `nightStart` is greater than
  `nightEnd`. A missing or unavailable time query falls back to the day value.
- `fatigue.rested` tracks how long the player has been sleeping. On waking from
  at least `minimumSleepSeconds`, it applies the invisible `xneeds_rested`
  status effect for `durationSeconds`, which sets `gainMultiplier` (below 1)
  while active. An optional message is shown once.
- `thirst.environment` and `fatigue.environment` mirror the Hygiene environment
  maps. `biomeGainMultipliers` key on `world.biomeAt`, and
  `environmentEffectGainMultipliers` key on `world.environmentStatusEffects`
  names. Both default to 1 and the larger of the two is used.

Biome matching is exact-name first, then an ordered pattern fallback. Each
`biomeGainMultiplierPatterns` (or `biomeDecayMultiplierPatterns` for Hygiene)
entry supplies a `multiplier` and a list of case-insensitive, plain-text
`patterns`; the first pattern contained in the lowercased biome name wins. This
lets modded variants inherit a base multiplier without listing every world, for
example `aliendesert` and `desertoasis` match `desert`, and
`arcticoceanfloor` matches `arctic`. Exact `biomeGainMultipliers` keys always
take precedence, and any biome matching neither an exact key nor a pattern
stays at 1.0, so a new or unsupported biome is neutral rather than an error.

Environment multipliers scale passive Thirst gain and awake Fatigue gain; they
do not affect sleeping recovery, beverage values, or penalties. The `/xneeds
get` result reports `night`, `circadianMultiplier`, `rested`,
`thirstEnvironmentMultiplier`, and `fatigueEnvironmentMultiplier`.

## HUD

The HUD uses xStarbound's named full-window canvas API. The engine-controlled
health, energy, hunger, status, FU, and FrackinInterface widgets are untouched.

At runtime the script reads the final loaded
/interface/windowconfig/teambar.config and derives the active foodBar position
and width. This follows vanilla, FU, or FrackinInterface geometry and inherits
interface scale, resolution, window mode, and normal HUD hiding.

Four thin problem meters are drawn below hunger:

1. Thirst
2. Fatigue
3. Bladder
4. Dirtiness, rendered as 100 minus Hygiene

The default layout starts below the horizontal status-effect icon row, so any
number of normal status icons can extend to the right without crossing the Needs
meters. The HUD reuses vanilla 16-pixel status artwork at half scale: a blue
droplet for Thirst, the sleep bubble for Fatigue, a palette-shifted yellow
droplet for Bladder, and a sparkle for Hygiene. Their nine-pixel row pitch
leaves one pixel between eight-pixel icons while retaining three-pixel bars.
Paths, scale, logical size, and spacing are configurable under `hud`; no vanilla
or FU texture is replaced. Set hud.enabled to false to disable only the HUD. If another
interface mod removes paneLayout.foodBar, visualization disables itself with a
warning while simulation continues.

Each draw pass records the four meter hit rectangles, expanding each by half the
row gap so the thin bars are easy to hover without overlapping adjacent rows.
When hud.tooltips.enabled is true and the cursor is inside one of those
rectangles, a compact border-and-fill panel is drawn to the right of the meter
icons. It lists the need name, the problem-aligned numeric value, the current
tier, any active recovery state, and the active penalty dimensions for that
need. The panel is clamped to the canvas, and if there is not enough room to the
right it is placed to the left instead. It is anchored to the hovered row and
drawn only while hovered, so no permanent labels are added. Tooltip geometry,
fonts, and tier colors live under hud.tooltips; disabling it leaves the meters
and all other HUD behavior untouched. Hygiene recovery source selection is
tracked while the environment is evaluated so the tooltip can report whether a
clean liquid, bath/tub, shower/bath, or rain is actively cleaning the player.

## Debug commands

The local xStarbound slash command is enabled by debug.commandsEnabled:

    /xneeds
    /xneeds get
    /xneeds set thirst 95
    /xneeds set fatigue 70
    /xneeds set bladder 85
    /xneeds set hygiene 25
    /xneeds set dirtiness 75
    /xneeds set all 85
    /xneeds add bladder -20
    /xneeds beverage coffee
    /xneeds beverage bottledwater
    /xneeds beverages
    /xneeds beverages all
    /xneeds beverages details
    /xneeds beverages alcohol
    /xneeds food cookedmeat
    /xneeds foods
    /xneeds foods all
    /xneeds foods details
    /xneeds foods juicy
    /xneeds preset normal
    /xneeds preset noticeable
    /xneeds preset serious
    /xneeds preset urgent
    /xneeds preset critical
    /xneeds reset

Hygiene is stored as cleanliness, while dirtiness matches the problem-oriented
HUD fill. Setting all or applying a preset assigns the requested problem value
to Thirst, Fatigue, Bladder, and Dirtiness. Values and additions are clamped to
0 through 100. Commands are local to the current player and do not require
safeScripts to be disabled.

The `/xneeds beverages` and `/xneeds foods` audits enumerate the final loaded
consumable assets with `root.assetsByExtension`, keep the ones whose merged
category is the relevant kind (or that opt in through the profile parameter or an
exact item mapping), and resolve each through the same profile logic used at
consumption time. With no argument they list only items whose resolution source
is the plain default, which are the candidates for a new `itemProfiles`
exception. Passing `all`, a profile name, or a name fragment changes the listing;
`details` additionally prints each fallback's asset path, source mod via
`root.assetSource`, and the description and effect text used by classification.
The result is cached per session, so later runs are instant.

Known drink exceptions live in `beverages.itemProfiles`: Corvex Drink and Code
Zerchesium resolve to soda, Beakeasy Moonshine to alcohol, Blood Chalice to
standard, and Chewable Magnet plus the raw-meat items whose mod category is
`drink` (Jarred Fetus, Meat Smoothie, Orphan Paste) resolve to the `solid`
profile so they give no hydration. Food exceptions go in `foods.itemProfiles`.

The original message interface remains available through xStarbound /exec:

    /exec return world.sendEntityMessage(player.id(),"xneeds_v0.get"):result()
    /exec return world.sendEntityMessage(player.id(),"xneeds_v0.set","thirst",75):result()
    /exec return world.sendEntityMessage(player.id(),"xneeds_v0.set","fatigue",75):result()
    /exec return world.sendEntityMessage(player.id(),"xneeds_v0.set","bladder",75):result()
    /exec return world.sendEntityMessage(player.id(),"xneeds_v0.set","hygiene",25):result()
    /exec return world.sendEntityMessage(player.id(),"xneeds_v0.reset"):result()

The get result includes sleeping, caffeinated, caffeineRemainingSeconds,
caffeineRemaining, bladderReliefRate, hygieneRecoveryRate, restRecoveryPerSecond,
night, circadianMultiplier, rested, thirstEnvironmentMultiplier,
fatigueEnvironmentMultiplier, hygieneEnvironment, lastHygieneEnvironment,
pendingCombatDirtiness, penaltyLevel, consequenceLevels, and
consequenceMultipliers. The command output
also reports the current biome multiplier, liquid classification, rain/wet
state, and projected next-tick Hygiene breakdown. Debug handlers reject
non-local messages.

## Compatibility boundaries

The player.config.patch adds /genericScriptContexts/xneeds_v0. A
post-load preprocessor generates additive
patches for final category-drink and category-food consumables after FU and
Workshop content are loaded. It appends a notifier to their effect groups; it
does not replace item files or existing effects. FU's deployment and status
scripts are not edited.
FrackinInterface and FU may continue to own teambar.config and its textures
because Needs reads the effective geometry without patching it.

Object and item extension parameters are optional and uniquely prefixed. V1 adds
no new furniture, consumables, effect-status icons, menus, sounds, or
animations. The four Needs meter icons are HUD-only uses of existing vanilla
artwork.

## Singleplayer validation checklist

Run these after any change to script, config, or generated patches. Everything
here is singleplayer only; multiplayer is out of scope for V1.

Persistence and teardown:

1. Load an existing character and confirm Thirst, Fatigue, Bladder, and Hygiene
   restore and the HUD appears with no red script errors.
2. Force each need into a penalty tier, save, and quit. Confirm the game exits
   promptly with no hang and no error during universe shutdown.
3. Reload the character. Confirm needs, warning tiers, and the namespaced
   modifier category are consistent and the HUD returns.

Sleep and time:

1. Sleep in a bed and confirm no button appears and the game remains at normal
   speed (`/timescale` reads `1.000000` throughout).
2. Confirm sleeping restores Fatigue from 100 to 0 in roughly three minutes.
3. Sleep for more than the rested minimum, wake, and confirm the Rested message
   appears and `/xneeds get` reports `rested: true`.
4. Wait for night and confirm `/xneeds get` reports `night: true` and a
   `circadianMultiplier` above 1.
5. Get out of the bed and confirm movement and world interaction still work.
6. Confirm a caffeine drink counts down from `5:00` at 1x wall-clock while
   `/xneeds get` reports `Caffeinated: yes (m:ss remaining)`.

Recovery and environment:

1. Lounge on a toilet and confirm Bladder drops at the configured rate.
2. Stand in clean water and in an active shower/bath and confirm Hygiene rises
   and the hover tooltip names the recovery source.
3. Take damage and run/jump and confirm Dirtiness rises without unbounded spikes.
4. Visit a hot and a cold biome and confirm `/xneeds get` reports the expected
   `thirstEnvironmentMultiplier` / `fatigueEnvironmentMultiplier` values and the
   matching hover tooltip lines.

Beverages, food, and HUD:

1. Run `/xneeds beverages` and `/xneeds foods` and confirm each reports
   `default fallbacks (0)`.
2. Spot-check water, coffee, soda, alcohol, salty, and toxic examples with
   `/xneeds beverage <itemName>`.
3. Eat a plain meal, a juicy fruit, a salty food, and a sugary food and confirm
   the expected Thirst/Bladder/Fatigue changes with `/xneeds food <itemName>`.
4. Hover each need meter and confirm name, value, tier, recovery, and penalty
   rows are correct and do not overlap the status row.
5. Change interface scale and window size and confirm the meters and tooltips
   stay aligned.

Safe removal:

1. Set `consequences.enabled` to `false`, load the penalized character once, and
   save and quit cleanly so `xneeds_v1_penalties` is cleared.
2. Remove the mod and confirm the character loads without leftover modifiers.
