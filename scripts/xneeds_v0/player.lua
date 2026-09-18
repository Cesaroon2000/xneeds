local storageVersion = 2
local consequenceCategory = "xneeds_v1_penalties"

local needsConfig
local updateAccumulator = 0
local hudCanvas
local hudLayout
local cleanLiquidIds = {}
local dirtyLiquidIds = {}
local liquidClassifications = {}
local warningLevels = {}
local appliedConsequenceSignature
local damageTakenHeartbeat
local damageInflictedHeartbeat
local pendingCombatDirtiness = 0
local pendingRunningSeconds = 0
local pendingJumpingSeconds = 0
local lastHygieneEnvironment = {}
local beverageFeedbackCooldown = 0
local caffeineRemainingSeconds = 0
local sleepAccumulatedSeconds = 0
local wasSleeping = false
local hudBarRects = {}
local pulseTimers = {}
local pulseDuration = 1.2
local settingsOpen = false
local hudDragging = false
local hudDragMouseStart = {0, 0}
local hudDragOffsetStart = {0, 0}
local hudDragHandleRect

local needNames = {
  thirst = true,
  fatigue = true,
  bladder = true,
  hygiene = true
}

local consequenceDimensions = {
  "speed",
  "jump",
  "power",
  "energyRegen",
  "protection"
}

local function isFiniteNumber(value)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
end

local function clampNeed(value)
  return math.max(0, math.min(100, value))
end

local function formatDuration(seconds)
  seconds = math.max(0, math.floor(seconds + 0.5))
  return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local localizedStrings

local function strings()
  if localizedStrings == nil then
    local ok, value = pcall(root.assetJson, "/xneeds_v0.strings")
    localizedStrings = ok and type(value) == "table" and value or {}
  end
  return localizedStrings
end

local function stringFor(path, default)
  local node = strings()
  for part in string.gmatch(path, "[^.]+") do
    if type(node) ~= "table" then
      return default
    end
    node = node[part]
  end
  if type(node) == "string" and node ~= "" then
    return node
  end
  return default
end

local function requireNumber(value, path)
  if not isFiniteNumber(value) then
    error(string.format("[xneeds_v0] %s must be a finite number", path))
  end
  return value
end

local function requirePositiveNumber(value, path)
  value = requireNumber(value, path)
  if value <= 0 then
    error(string.format("[xneeds_v0] %s must be greater than zero", path))
  end
  return value
end

local function requireNonnegativeNumber(value, path)
  value = requireNumber(value, path)
  if value < 0 then
    error(string.format("[xneeds_v0] %s must not be negative", path))
  end
  return value
end

local function requireMultiplier(value, path)
  value = requirePositiveNumber(value, path)
  if value > 1 then
    error(string.format("[xneeds_v0] %s must not exceed 1", path))
  end
  return value
end

local function requireStringList(value, path)
  if type(value) ~= "table" then
    error(string.format("[xneeds_v0] %s must be a list", path))
  end
  for index, entry in ipairs(value) do
    if type(entry) ~= "string" or entry == "" then
      error(string.format("[xneeds_v0] %s[%s] must be a non-empty string", path, index))
    end
  end
end

local function requirePositiveNumberMap(value, path)
  if type(value) ~= "table" then
    error(string.format("[xneeds_v0] %s must be an object", path))
  end
  for key, entry in pairs(value) do
    if type(key) ~= "string" or key == "" then
      error(string.format("[xneeds_v0] %s keys must be non-empty strings", path))
    end
    requirePositiveNumber(entry, path .. "." .. key)
  end
end

local function requireBiomePatternRules(value, path)
  if type(value) ~= "table" then
    error(string.format("[xneeds_v0] %s must be a list", path))
  end
  for index, rule in ipairs(value) do
    local rulePath = string.format("%s[%s]", path, index)
    if type(rule) ~= "table" then
      error(string.format("[xneeds_v0] %s must be an object", rulePath))
    end
    requirePositiveNumber(rule.multiplier, rulePath .. ".multiplier")
    requireStringList(rule.patterns, rulePath .. ".patterns")
  end
end

local function requireColor(value, path)
  if type(value) ~= "table" or #value ~= 4 then
    error(string.format("[xneeds_v0] %s must be an RGBA color", path))
  end
  for index, channel in ipairs(value) do
    requireNumber(channel, string.format("%s[%s]", path, index))
    if channel < 0 or channel > 255 then
      error(string.format("[xneeds_v0] %s channels must be between 0 and 255", path))
    end
  end
end

local function requireConsumableProfiles(section, path)
  if type(section.defaultProfile) ~= "string"
      or section.defaultProfile == ""
      or type(section.profiles) ~= "table"
      or type(section.itemProfiles) ~= "table"
      or type(section.classificationRules) ~= "table" then
    error(string.format("[xneeds_v0] %s configuration is invalid", path))
  end

  for profileName, profile in pairs(section.profiles) do
    local profilePath = path .. ".profiles." .. tostring(profileName)
    if type(profileName) ~= "string" or profileName == ""
        or type(profile) ~= "table" then
      error(string.format("[xneeds_v0] %s profile names and values must be valid", path))
    end
    requireNumber(profile.thirstRecovery, profilePath .. ".thirstRecovery")
    requireNumber(profile.bladderGain, profilePath .. ".bladderGain")
    requireNumber(profile.fatigueChange, profilePath .. ".fatigueChange")
    requireNonnegativeNumber(profile.caffeineDuration, profilePath .. ".caffeineDuration")
  end
  if type(section.profiles[section.defaultProfile]) ~= "table" then
    error(string.format("[xneeds_v0] %s.defaultProfile does not name a profile", path))
  end

  for itemName, profileName in pairs(section.itemProfiles) do
    if type(itemName) ~= "string" or itemName == ""
        or type(profileName) ~= "string"
        or type(section.profiles[profileName]) ~= "table" then
      error(string.format("[xneeds_v0] %s.itemProfiles contains an invalid mapping", path))
    end
  end
  for index, rule in ipairs(section.classificationRules) do
    local rulePath = string.format("%s.classificationRules[%s]", path, index)
    if type(rule) ~= "table"
        or type(rule.profile) ~= "string"
        or type(section.profiles[rule.profile]) ~= "table" then
      error("[xneeds_v0] " .. rulePath .. " has an invalid profile")
    end
    requireStringList(rule.patterns, rulePath .. ".patterns")
  end
end

local function requireConsumableFeedback(section, path)
  local feedback = section.feedback
  if type(feedback) ~= "table"
      or type(feedback.enabled) ~= "boolean"
      or type(feedback.profileMessages) ~= "table"
      or type(feedback.dehydratingMessage) ~= "string"
      or feedback.dehydratingMessage == "" then
    error(string.format("[xneeds_v0] %s.feedback configuration is invalid", path))
  end
  requireNonnegativeNumber(feedback.cooldownSeconds, path .. ".feedback.cooldownSeconds")
  for profileName, messageText in pairs(feedback.profileMessages) do
    if type(section.profiles[profileName]) ~= "table"
        or type(messageText) ~= "string"
        or messageText == "" then
      error(string.format("[xneeds_v0] %s.feedback.profileMessages contains an invalid entry", path))
    end
  end
end

local function loadConfig()
  local config = root.assetJson("/xneeds_v0.config")
  local requiredSections = {
    "defaults",
    "thirst",
    "fatigue",
    "bladder",
    "beverages",
    "foods",
    "hygiene",
    "sleep",
    "thresholds",
    "consequences",
    "warnings",
    "hud",
    "debug"
  }

  if type(config) ~= "table" then
    error("[xneeds_v0] xneeds_v0.config is invalid")
  end
  for _, section in ipairs(requiredSections) do
    if type(config[section]) ~= "table" then
      error(string.format("[xneeds_v0] xneeds_v0.config is missing %s", section))
    end
  end

  requireNumber(config.schemaVersion, "schemaVersion")
  if config.schemaVersion ~= storageVersion then
    error(string.format(
      "[xneeds_v0] config schema %s does not match storage schema %s",
      config.schemaVersion,
      storageVersion
    ))
  end

  requirePositiveNumber(config.updateInterval, "updateInterval")
  requirePositiveNumber(config.maxCatchupSeconds, "maxCatchupSeconds")
  if config.maxCatchupSeconds < config.updateInterval then
    error("[xneeds_v0] maxCatchupSeconds must be at least updateInterval")
  end

  for needName in pairs(needNames) do
    requireNumber(config.defaults[needName], "defaults." .. needName)
    config.defaults[needName] = clampNeed(config.defaults[needName])
  end

  requireNonnegativeNumber(config.thirst.passiveGainPerSecond, "thirst.passiveGainPerSecond")
  requireNonnegativeNumber(config.fatigue.awakeGainPerSecond, "fatigue.awakeGainPerSecond")
  requireNonnegativeNumber(config.fatigue.sleepRecoveryPerSecond, "fatigue.sleepRecoveryPerSecond")

  for _, needName in ipairs({"thirst", "fatigue"}) do
    local needEnvironment = config[needName].environment
    if type(needEnvironment) ~= "table" then
      error(string.format("[xneeds_v0] %s.environment configuration is missing", needName))
    end
    requirePositiveNumberMap(
      needEnvironment.biomeGainMultipliers,
      needName .. ".environment.biomeGainMultipliers"
    )
    requireBiomePatternRules(
      needEnvironment.biomeGainMultiplierPatterns,
      needName .. ".environment.biomeGainMultiplierPatterns"
    )
    requirePositiveNumberMap(
      needEnvironment.environmentEffectGainMultipliers,
      needName .. ".environment.environmentEffectGainMultipliers"
    )
  end

  local circadian = config.fatigue.circadian
  if type(circadian) ~= "table" or type(circadian.enabled) ~= "boolean" then
    error("[xneeds_v0] fatigue.circadian configuration is invalid")
  end
  for _, key in ipairs({"nightStart", "nightEnd"}) do
    requireNumber(circadian[key], "fatigue.circadian." .. key)
    if circadian[key] < 0 or circadian[key] > 1 then
      error("[xneeds_v0] fatigue.circadian." .. key .. " must be between 0 and 1")
    end
  end
  requirePositiveNumber(circadian.nightGainMultiplier, "fatigue.circadian.nightGainMultiplier")
  requirePositiveNumber(circadian.dayGainMultiplier, "fatigue.circadian.dayGainMultiplier")

  local rested = config.fatigue.rested
  if type(rested) ~= "table" or type(rested.enabled) ~= "boolean"
      or type(rested.effect) ~= "string" or rested.effect == ""
      or type(rested.message) ~= "string" then
    error("[xneeds_v0] fatigue.rested configuration is invalid")
  end
  requirePositiveNumber(rested.gainMultiplier, "fatigue.rested.gainMultiplier")
  requirePositiveNumber(rested.durationSeconds, "fatigue.rested.durationSeconds")
  requireNonnegativeNumber(rested.minimumSleepSeconds, "fatigue.rested.minimumSleepSeconds")

  requireNonnegativeNumber(config.bladder.passiveGainPerSecond, "bladder.passiveGainPerSecond")
  requireNonnegativeNumber(config.bladder.reliefRatePerSecond, "bladder.reliefRatePerSecond")
  requireNonnegativeNumber(config.hygiene.decayPerSecond, "hygiene.decayPerSecond")
  requireNonnegativeNumber(config.hygiene.waterRecoveryPerSecond, "hygiene.waterRecoveryPerSecond")
  requireNonnegativeNumber(config.hygiene.fixtureRecoveryPerSecond, "hygiene.fixtureRecoveryPerSecond")
  requireNumber(config.hygiene.minimumLiquidPercentage, "hygiene.minimumLiquidPercentage")
  if config.hygiene.minimumLiquidPercentage < 0
      or config.hygiene.minimumLiquidPercentage > 1 then
    error("[xneeds_v0] hygiene.minimumLiquidPercentage must be between 0 and 1")
  end
  requireNonnegativeNumber(config.hygiene.fixtureSearchRadius, "hygiene.fixtureSearchRadius")
  if type(config.hygiene.environment) ~= "table"
      or type(config.hygiene.combat) ~= "table" then
    error("[xneeds_v0] hygiene environment or combat configuration is missing")
  end
  requirePositiveNumberMap(
    config.hygiene.cleanLiquidRecoveryRates,
    "hygiene.cleanLiquidRecoveryRates"
  )

  local environment = config.hygiene.environment
  requireNumber(environment.minimumLiquidPercentage, "hygiene.environment.minimumLiquidPercentage")
  if environment.minimumLiquidPercentage < 0
      or environment.minimumLiquidPercentage > 1 then
    error("[xneeds_v0] hygiene.environment.minimumLiquidPercentage must be between 0 and 1")
  end
  requireNonnegativeNumber(environment.dirtyLiquidRatePerSecond, "hygiene.environment.dirtyLiquidRatePerSecond")
  requireNonnegativeNumber(environment.rainRecoveryPerSecond, "hygiene.environment.rainRecoveryPerSecond")
  requireNonnegativeNumber(environment.runningExtraDecayPerSecond, "hygiene.environment.runningExtraDecayPerSecond")
  requireNonnegativeNumber(environment.jumpingExtraDecayPerSecond, "hygiene.environment.jumpingExtraDecayPerSecond")
  requireStringList(environment.dirtyLiquidNames, "hygiene.environment.dirtyLiquidNames")
  requireStringList(environment.dirtyLiquidNamePatterns, "hygiene.environment.dirtyLiquidNamePatterns")
  requireStringList(environment.dirtyLiquidStatusEffects, "hygiene.environment.dirtyLiquidStatusEffects")
  requireStringList(environment.rainStatusEffects, "hygiene.environment.rainStatusEffects")
  requirePositiveNumberMap(environment.biomeDecayMultipliers, "hygiene.environment.biomeDecayMultipliers")
  requireBiomePatternRules(
    environment.biomeDecayMultiplierPatterns,
    "hygiene.environment.biomeDecayMultiplierPatterns"
  )
  requirePositiveNumberMap(
    environment.environmentEffectDecayMultipliers,
    "hygiene.environment.environmentEffectDecayMultipliers"
  )

  local combat = config.hygiene.combat
  requireNonnegativeNumber(combat.damageTakenBaseLoss, "hygiene.combat.damageTakenBaseLoss")
  requireNonnegativeNumber(combat.damageTakenPerHealth, "hygiene.combat.damageTakenPerHealth")
  requireNonnegativeNumber(combat.damageInflictedBaseLoss, "hygiene.combat.damageInflictedBaseLoss")
  requireNonnegativeNumber(combat.damageInflictedPerDamage, "hygiene.combat.damageInflictedPerDamage")
  requireNonnegativeNumber(combat.maximumLossPerUpdate, "hygiene.combat.maximumLossPerUpdate")

  local stringSettings = {
    {config.thirst.overrideParameter, "thirst.overrideParameter"},
    {config.bladder.drinkCategory, "bladder.drinkCategory"},
    {config.bladder.overrideParameter, "bladder.overrideParameter"},
    {config.bladder.reliefOverrideParameter, "bladder.reliefOverrideParameter"},
    {config.beverages.profileParameter, "beverages.profileParameter"},
    {config.beverages.fatigueChangeParameter, "beverages.fatigueChangeParameter"},
    {config.beverages.caffeineDurationParameter, "beverages.caffeineDurationParameter"},
    {config.beverages.caffeineEffect, "beverages.caffeineEffect"},
    {config.foods.category, "foods.category"},
    {config.foods.profileParameter, "foods.profileParameter"},
    {config.hygiene.fixtureOverrideParameter, "hygiene.fixtureOverrideParameter"}
  }
  for _, setting in ipairs(stringSettings) do
    if type(setting[1]) ~= "string" or setting[1] == "" then
      error(string.format("[xneeds_v0] %s must be a non-empty string", setting[2]))
    end
  end

  if type(config.thirst.itemOverrides) ~= "table"
      or type(config.bladder.itemOverrides) ~= "table" then
    error("[xneeds_v0] itemOverrides settings must be objects")
  end

  local beverages = config.beverages
  requireConsumableProfiles(beverages, "beverages")
  requireNumber(
    beverages.caffeineAwakeGainMultiplier,
    "beverages.caffeineAwakeGainMultiplier"
  )
  if beverages.caffeineAwakeGainMultiplier < 0
      or beverages.caffeineAwakeGainMultiplier > 1 then
    error("[xneeds_v0] beverages.caffeineAwakeGainMultiplier must be between 0 and 1")
  end
  requireConsumableFeedback(beverages, "beverages")

  local returnItems = beverages.returnItems
  if type(returnItems) ~= "table" or type(returnItems.enabled) ~= "boolean"
      or type(returnItems.items) ~= "table" then
    error("[xneeds_v0] beverages.returnItems configuration is invalid")
  end
  for consumedName, grantedName in pairs(returnItems.items) do
    if type(consumedName) ~= "string" or consumedName == ""
        or type(grantedName) ~= "string" or grantedName == "" then
      error("[xneeds_v0] beverages.returnItems contains an invalid mapping")
    end
  end

  local foods = config.foods
  if type(foods.enabled) ~= "boolean" then
    error("[xneeds_v0] foods.enabled must be a boolean")
  end
  requireConsumableProfiles(foods, "foods")
  requireConsumableFeedback(foods, "foods")

  requireStringList(config.bladder.reliefObjectNamePatterns, "bladder.reliefObjectNamePatterns")
  requireStringList(config.hygiene.cleanLiquidNames, "hygiene.cleanLiquidNames")
  requireStringList(config.hygiene.activeFixtureObjectNames, "hygiene.activeFixtureObjectNames")
  requireStringList(config.hygiene.loungeObjectNamePatterns, "hygiene.loungeObjectNamePatterns")
  requireStringList(config.sleep.bedEffects, "sleep.bedEffects")

  if type(config.warnings.enabled) ~= "boolean"
      or type(config.warnings.messages) ~= "table" then
    error("[xneeds_v0] warnings configuration is invalid")
  end

  if #config.thresholds == 0 then
    error("[xneeds_v0] thresholds must contain at least one tier")
  end

  local previousThreshold = 0
  local thresholdKeys = {}
  for index, threshold in ipairs(config.thresholds) do
    local path = string.format("thresholds[%s]", index)
    if type(threshold) ~= "table"
        or type(threshold.key) ~= "string"
        or threshold.key == "" then
      error(string.format("[xneeds_v0] %s must have a non-empty key", path))
    end
    if thresholdKeys[threshold.key] then
      error(string.format("[xneeds_v0] duplicate threshold key: %s", threshold.key))
    end
    thresholdKeys[threshold.key] = true

    requireNumber(threshold.value, path .. ".value")
    if threshold.value <= previousThreshold or threshold.value > 100 then
      error("[xneeds_v0] thresholds must be strictly increasing within 0 through 100")
    end
    previousThreshold = threshold.value
  end

  if type(config.consequences.enabled) ~= "boolean"
      or type(config.consequences.minimumMultipliers) ~= "table"
      or type(config.consequences.profiles) ~= "table" then
    error("[xneeds_v0] consequences configuration is invalid")
  end

  for _, dimension in ipairs(consequenceDimensions) do
    requireMultiplier(
      config.consequences.minimumMultipliers[dimension],
      "consequences.minimumMultipliers." .. dimension
    )
  end

  for needName in pairs(needNames) do
    local profiles = config.consequences.profiles[needName]
    local messages = config.warnings.messages[needName]
    if type(profiles) ~= "table" or type(messages) ~= "table" then
      error(string.format("[xneeds_v0] consequence or warning profile missing for %s", needName))
    end

    for _, threshold in ipairs(config.thresholds) do
      local profile = profiles[threshold.key]
      if type(profile) ~= "table" then
        error(string.format(
          "[xneeds_v0] consequences.profiles.%s.%s must be an object",
          needName,
          threshold.key
        ))
      end
      for _, dimension in ipairs(consequenceDimensions) do
        if profile[dimension] ~= nil then
          requireMultiplier(
            profile[dimension],
            string.format("consequences.profiles.%s.%s.%s", needName, threshold.key, dimension)
          )
        end
      end

      if type(messages[threshold.key]) ~= "string" or messages[threshold.key] == "" then
        error(string.format("[xneeds_v0] warning message missing for %s.%s", needName, threshold.key))
      end
    end
  end

  if type(config.hud.enabled) ~= "boolean"
      or type(config.hud.canvasName) ~= "string"
      or config.hud.canvasName == "" then
    error("[xneeds_v0] hud.enabled or hud.canvasName is invalid")
  end
  requirePositiveNumber(config.hud.barHeight, "hud.barHeight")
  requireNonnegativeNumber(config.hud.barGap, "hud.barGap")
  requireNonnegativeNumber(config.hud.topGap, "hud.topGap")
  requireNonnegativeNumber(config.hud.leftInset, "hud.leftInset")
  requireNonnegativeNumber(config.hud.iconGap, "hud.iconGap")
  requirePositiveNumber(config.hud.iconScale, "hud.iconScale")
  requirePositiveNumber(config.hud.iconSize, "hud.iconSize")
  if type(config.hud.icons) ~= "table" then
    error("[xneeds_v0] hud.icons must be an object")
  end
  for needName in pairs(needNames) do
    if type(config.hud.icons[needName]) ~= "string"
        or config.hud.icons[needName] == "" then
      error("[xneeds_v0] hud.icons." .. needName .. " must be an image path")
    end
  end
  requireColor(config.hud.backgroundColor, "hud.backgroundColor")
  requireColor(config.hud.borderColor, "hud.borderColor")
  requireColor(config.hud.thirstColor, "hud.thirstColor")
  requireColor(config.hud.fatigueColor, "hud.fatigueColor")
  requireColor(config.hud.bladderColor, "hud.bladderColor")
  requireColor(config.hud.hygieneColor, "hud.hygieneColor")

  -- hud.tooltips is optional so a config without it simply disables the
  -- hover details instead of failing initialization.
  local tooltips = config.hud.tooltips
  if tooltips == nil then
    tooltips = { enabled = false }
    config.hud.tooltips = tooltips
  end
  if type(tooltips) ~= "table" or type(tooltips.enabled) ~= "boolean" then
    error("[xneeds_v0] hud.tooltips.enabled must be a boolean")
  end
  if tooltips.enabled then
    requireNonnegativeNumber(tooltips.gap, "hud.tooltips.gap")
    requirePositiveNumber(tooltips.width, "hud.tooltips.width")
    requireNonnegativeNumber(tooltips.padding, "hud.tooltips.padding")
    requirePositiveNumber(tooltips.lineHeight, "hud.tooltips.lineHeight")
    requirePositiveNumber(tooltips.fontSize, "hud.tooltips.fontSize")
    requireColor(tooltips.textColor, "hud.tooltips.textColor")
    if type(tooltips.tierColors) ~= "table" then
      error("[xneeds_v0] hud.tooltips.tierColors must be an object")
    end
    requireColor(tooltips.tierColors.normal, "hud.tooltips.tierColors.normal")
    for _, threshold in ipairs(config.thresholds) do
      requireColor(
        tooltips.tierColors[threshold.key],
        "hud.tooltips.tierColors." .. threshold.key
      )
    end
  end

  if type(config.debug.commandsEnabled) ~= "boolean" then
    error("[xneeds_v0] debug.commandsEnabled must be a boolean")
  end

  config.bladder.drinkCategory = string.lower(config.bladder.drinkCategory)
  config.foods.category = string.lower(config.foods.category)
  return config
end

local function normalizedStoredValue(value, defaultValue)
  if not isFiniteNumber(value) then
    return defaultValue
  end
  return clampNeed(value)
end

local function migrateNeeds(rawNeeds)
  if type(rawNeeds) ~= "table" then
    rawNeeds = {}
  end

  -- Schema 1 had fatigue, bladder, and hygiene. Schema 2 preserves those
  -- values and initializes the newly introduced thirst field.
  return {
    version = storageVersion,
    thirst = normalizedStoredValue(rawNeeds.thirst, needsConfig.defaults.thirst),
    fatigue = normalizedStoredValue(rawNeeds.fatigue, needsConfig.defaults.fatigue),
    bladder = normalizedStoredValue(rawNeeds.bladder, needsConfig.defaults.bladder),
    hygiene = normalizedStoredValue(rawNeeds.hygiene, needsConfig.defaults.hygiene)
  }
end

local function normalizeStorage()
  storage.needs = migrateNeeds(storage.needs)
end

local function needSnapshot()
  normalizeStorage()
  return {
    version = storage.needs.version,
    thirst = storage.needs.thirst,
    fatigue = storage.needs.fatigue,
    bladder = storage.needs.bladder,
    hygiene = storage.needs.hygiene
  }
end

local settingsVersion = 2

local function newHudSettings()
  local tooltips = needsConfig.hud.tooltips
  return {
    enabled = needsConfig.hud.enabled ~= false,
    tooltips = type(tooltips) == "table" and tooltips.enabled ~= false or false,
    compact = false,
    alwaysShowValues = false,
    pulse = true,
    showThirst = true,
    showFatigue = true,
    showBladder = true,
    showHygiene = true,
    hudOffsetX = 0,
    hudOffsetY = 0
  }
end

local function newGameplaySettings()
  return {
    warnings = needsConfig.warnings.enabled ~= false,
    consequences = needsConfig.consequences.enabled ~= false,
    feedback = needsConfig.beverages.feedback.enabled ~= false,
    circadian = needsConfig.fatigue.circadian.enabled ~= false,
    rested = needsConfig.fatigue.rested.enabled ~= false,
    environment = true,
    rateScale = 1.0,
    sleepSpeed = 1.0,
    thirstEnabled = true,
    fatigueEnabled = true,
    bladderEnabled = true,
    hygieneEnabled = true
  }
end

local function normalizeSettingsTable(settings, defaults)
  if type(settings) ~= "table" then
    settings = {}
  end
  for key, value in pairs(defaults) do
    if type(settings[key]) ~= type(value) then
      settings[key] = value
    end
  end
  return settings
end

local function normalizeSettings(settings)
  -- Migrate the V1.11 flat HUD table into the structured form.
  if type(settings) == "table" and settings.version == nil
      and settings.enabled ~= nil then
    settings = { version = settingsVersion, hud = settings }
  end

  if type(settings) ~= "table" then
    settings = {}
  end
  settings.version = settingsVersion
  settings.hud = normalizeSettingsTable(settings.hud, newHudSettings())
  settings.gameplay = normalizeSettingsTable(settings.gameplay, newGameplaySettings())
  return settings
end

local function settings()
  storage.xneedsSettings = normalizeSettings(storage.xneedsSettings)
  return storage.xneedsSettings
end

local function hudSettings()
  return settings().hud
end

local function gameplaySettings()
  return settings().gameplay
end

local function rateScale()
  local scale = gameplaySettings().rateScale
  if not isFiniteNumber(scale) or scale <= 0 then
    return 1
  end
  return scale
end

local function sleepRecoveryScale()
  local scale = gameplaySettings().sleepSpeed
  if not isFiniteNumber(scale) or scale <= 0 then
    return 1
  end
  return scale
end

local function needEnabled(needName)
  return gameplaySettings()[needName .. "Enabled"] ~= false
end

local function safeCurrentEmoteIsSleep()
  if type(player.currentEmote) ~= "function" then
    return false
  end
  local ok, emote = pcall(player.currentEmote)
  return ok and type(emote) == "string" and string.lower(emote) == "sleep"
end

local function hasBedEffect()
  for _, effectName in ipairs(needsConfig.sleep.bedEffects) do
    if status.uniqueStatusEffectActive(effectName) then
      return true
    end
  end
  return false
end

local function objectParameter(objectId, parameterName)
  if not objectId then
    return nil
  end
  local ok, value = pcall(world.getObjectParameter, objectId, parameterName)
  if ok then
    return value
  end
end

local function objectName(objectId)
  if not objectId then
    return nil
  end
  local ok, value = pcall(world.entityName, objectId)
  if ok and type(value) == "string" then
    return string.lower(value)
  end
end

local function nameMatchesPatterns(name, patterns)
  if type(name) ~= "string" then
    return false
  end
  for _, pattern in ipairs(patterns) do
    if string.find(name, string.lower(pattern), 1, true) then
      return true
    end
  end
  return false
end

local function nameMatchesList(name, names)
  if type(name) ~= "string" then
    return false
  end
  for _, candidate in ipairs(names) do
    if name == string.lower(candidate) then
      return true
    end
  end
  return false
end

local function loungingObjectUsesSleepEmote()
  local loungeId = player.loungingIn()
  local sitEmote = objectParameter(loungeId, "sitEmote")
  return type(sitEmote) == "string" and string.lower(sitEmote) == "sleep"
end

local function isSleeping()
  if not player.isLounging() then
    return false
  end
  return safeCurrentEmoteIsSleep()
    or hasBedEffect()
    or loungingObjectUsesSleepEmote()
end

local function pointInsideRect(point, rect)
  return type(point) == "table"
    and type(rect) == "table"
    and point[1] >= rect[1]
    and point[1] <= rect[3]
    and point[2] >= rect[2]
    and point[2] <= rect[4]
end

local function bladderReliefRate()
  if not player.isLounging() then
    return 0
  end

  local loungeId = player.loungingIn()
  local override = objectParameter(loungeId, needsConfig.bladder.reliefOverrideParameter)
  if isFiniteNumber(override) then
    return math.max(0, override)
  end
  if override == false then
    return 0
  end

  if nameMatchesPatterns(objectName(loungeId), needsConfig.bladder.reliefObjectNamePatterns) then
    return needsConfig.bladder.reliefRatePerSecond
  end
  return 0
end

local function resolveHygieneLiquidIds()
  cleanLiquidIds = {}
  dirtyLiquidIds = {}
  liquidClassifications = {}

  for _, liquidName in ipairs(needsConfig.hygiene.cleanLiquidNames) do
    local ok, liquidId = pcall(root.liquidId, liquidName)
    if ok and isFiniteNumber(liquidId) then
      cleanLiquidIds[liquidId] = true
    else
      sb.logWarn("[xneeds_v0] unknown clean liquid name: %s", liquidName)
    end
  end

  for _, liquidName in ipairs(needsConfig.hygiene.environment.dirtyLiquidNames) do
    local ok, liquidId = pcall(root.liquidId, liquidName)
    if ok and isFiniteNumber(liquidId) then
      dirtyLiquidIds[liquidId] = true
    else
      sb.logWarn("[xneeds_v0] unknown dirty liquid name: %s", liquidName)
    end
  end
end

local function liquidNameAndClass(liquidId)
  if liquidClassifications[liquidId] then
    local cached = liquidClassifications[liquidId]
    return cached.name, cached.class
  end

  local ok, liquidName = pcall(root.liquidName, liquidId)
  if not ok or type(liquidName) ~= "string" then
    liquidName = "unknown"
  else
    liquidName = string.lower(liquidName)
  end

  local classification = "neutral"
  if cleanLiquidIds[liquidId] then
    classification = "clean"
  elseif dirtyLiquidIds[liquidId]
      or nameMatchesPatterns(liquidName, needsConfig.hygiene.environment.dirtyLiquidNamePatterns) then
    classification = "dirty"
  else
    local effectsOk, liquidEffects = pcall(root.liquidStatusEffects, liquidId)
    if effectsOk and type(liquidEffects) == "table" then
      for _, liquidEffect in ipairs(liquidEffects) do
        local effectName = liquidEffect
        if type(liquidEffect) == "table" then
          effectName = liquidEffect.effect
        end
        if type(effectName) == "string"
            and nameMatchesList(
              string.lower(effectName),
              needsConfig.hygiene.environment.dirtyLiquidStatusEffects
            ) then
          classification = "dirty"
          break
        end
      end
    end
  end

  liquidClassifications[liquidId] = {
    name = liquidName,
    class = classification
  }
  return liquidName, classification
end

local function loungeHygieneRecoveryRate()
  if not player.isLounging() then
    return 0
  end

  local loungeId = player.loungingIn()
  local override = objectParameter(loungeId, needsConfig.hygiene.fixtureOverrideParameter)
  if isFiniteNumber(override) then
    return math.max(0, override)
  end
  if override == false then
    return 0
  end

  if nameMatchesPatterns(objectName(loungeId), needsConfig.hygiene.loungeObjectNamePatterns) then
    return needsConfig.hygiene.fixtureRecoveryPerSecond
  end
  return 0
end

local function nearbyActiveFixtureRecoveryRate()
  local bestRate = 0
  local objectIds = world.objectQuery(
    mcontroller.position(),
    needsConfig.hygiene.fixtureSearchRadius
  )

  for _, objectId in ipairs(objectIds) do
    local override = objectParameter(objectId, needsConfig.hygiene.fixtureOverrideParameter)
    if isFiniteNumber(override) then
      bestRate = math.max(bestRate, math.max(0, override))
    elseif override ~= false
        and nameMatchesList(objectName(objectId), needsConfig.hygiene.activeFixtureObjectNames) then
      bestRate = math.max(bestRate, needsConfig.hygiene.fixtureRecoveryPerSecond)
    end
  end
  return bestRate
end

local function activeConfiguredStatusEffect(effectNames)
  for _, effectName in ipairs(effectNames) do
    if status.uniqueStatusEffectActive(effectName) then
      return effectName
    end
  end
end

local function currentBiome()
  local position = mcontroller.position()
  local tilePosition = {math.floor(position[1]), math.floor(position[2])}
  local ok, biomeName = pcall(world.biomeAt, tilePosition, true)
  if ok and type(biomeName) == "string" then
    return string.lower(biomeName)
  end
end

local function configuredBiomeMultiplier(biomeName, multipliers, patterns)
  local exact = type(multipliers) == "table" and multipliers[biomeName] or nil
  if isFiniteNumber(exact) then
    return exact
  end

  if type(patterns) == "table" then
    for _, rule in ipairs(patterns) do
      if type(rule) == "table" and isFiniteNumber(rule.multiplier) then
        for _, pattern in ipairs(rule.patterns) do
          if string.find(biomeName, string.lower(pattern), 1, true) then
            return rule.multiplier
          end
        end
      end
    end
  end
  return 1
end

local function environmentDecayMultiplier(biomeName)
  if not gameplaySettings().environment then
    return 1
  end
  local environment = needsConfig.hygiene.environment
  local multiplier = configuredBiomeMultiplier(
    biomeName,
    environment.biomeDecayMultipliers,
    environment.biomeDecayMultiplierPatterns
  )
  local ok, environmentEffects = pcall(world.environmentStatusEffects, mcontroller.position())
  if ok and type(environmentEffects) == "table" then
    for _, effectName in ipairs(environmentEffects) do
      if type(effectName) == "string" then
        multiplier = math.max(
          multiplier,
          needsConfig.hygiene.environment.environmentEffectDecayMultipliers[
            string.lower(effectName)
          ] or 1
        )
      end
    end
  end
  return multiplier
end

local function hygieneEnvironment(elapsed)
  local environment = needsConfig.hygiene.environment
  local liquidPercentage = mcontroller.liquidPercentage()
  local liquidName = "none"
  local liquidClass = "none"

  if liquidPercentage >= environment.minimumLiquidPercentage then
    liquidName, liquidClass = liquidNameAndClass(mcontroller.liquidId())
  end

  local rate = loungeHygieneRecoveryRate()
  local recoverySource = rate > 0 and "bath/tub" or nil
  if liquidClass == "clean"
      and liquidPercentage >= needsConfig.hygiene.minimumLiquidPercentage then
    local liquidRate = needsConfig.hygiene.cleanLiquidRecoveryRates[liquidName]
      or needsConfig.hygiene.waterRecoveryPerSecond
    if liquidRate > rate then
      rate = liquidRate
      recoverySource = "clean " .. liquidName
    end
  end

  local fixtureRate = nearbyActiveFixtureRecoveryRate()
  if fixtureRate > rate then
    rate = fixtureRate
    recoverySource = "shower/bath"
  end

  local rainEffect
  if liquidPercentage < environment.minimumLiquidPercentage then
    local undergroundOk, underground = pcall(world.underground, mcontroller.position())
    if not undergroundOk or not underground then
      rainEffect = activeConfiguredStatusEffect(environment.rainStatusEffects)
      if rainEffect and environment.rainRecoveryPerSecond > rate then
        rate = environment.rainRecoveryPerSecond
        recoverySource = "rain"
      end
    end
  end

  local biomeName = currentBiome() or "none"
  local decayMultiplier = environmentDecayMultiplier(biomeName)
  local scale = rateScale()
  local passiveLoss = needsConfig.hygiene.decayPerSecond * elapsed * decayMultiplier * scale
  local activityLoss = (
    environment.runningExtraDecayPerSecond * pendingRunningSeconds
      + environment.jumpingExtraDecayPerSecond * pendingJumpingSeconds
  ) * decayMultiplier * scale
  local contaminationLoss = 0
  if liquidClass == "dirty" then
    contaminationLoss = environment.dirtyLiquidRatePerSecond
      * liquidPercentage
      * elapsed
  end
  local combatLoss = math.min(
    pendingCombatDirtiness,
    needsConfig.hygiene.combat.maximumLossPerUpdate
  )

  return {
    biome = biomeName,
    biomeMultiplier = decayMultiplier,
    liquid = liquidName,
    liquidClass = liquidClass,
    liquidPercentage = liquidPercentage,
    rainEffect = rainEffect,
    recoveryRate = rate,
    recoverySource = recoverySource,
    passiveLoss = passiveLoss,
    activityLoss = activityLoss,
    contaminationLoss = contaminationLoss,
    combatLoss = combatLoss
  }
end

local function pollCombatDirtiness()
  local combat = needsConfig.hygiene.combat
  local notifications

  notifications, damageTakenHeartbeat = status.damageTakenSince(damageTakenHeartbeat)
  for _, notification in ipairs(notifications) do
    local healthLost = isFiniteNumber(notification.healthLost)
      and math.max(0, notification.healthLost) or 0
    if healthLost > 0 then
      pendingCombatDirtiness = pendingCombatDirtiness
        + combat.damageTakenBaseLoss
        + healthLost * combat.damageTakenPerHealth
    end
  end

  notifications, damageInflictedHeartbeat = status.inflictedDamageSince(damageInflictedHeartbeat)
  for _, notification in ipairs(notifications) do
    local damageDealt = isFiniteNumber(notification.damageDealt)
      and math.max(0, notification.damageDealt) or 0
    if damageDealt > 0 then
      pendingCombatDirtiness = pendingCombatDirtiness
        + combat.damageInflictedBaseLoss
        + damageDealt * combat.damageInflictedPerDamage
    end
  end

  pendingCombatDirtiness = math.min(
    pendingCombatDirtiness,
    combat.maximumLossPerUpdate
  )
end

local function trackHygieneActivity(dt)
  if mcontroller.running() then
    pendingRunningSeconds = pendingRunningSeconds + dt
  end
  if mcontroller.jumping() then
    pendingJumpingSeconds = pendingJumpingSeconds + dt
  end
end

local function problemValue(needName)
  if needName == "hygiene" then
    return 100 - storage.needs.hygiene
  end
  return storage.needs[needName]
end

local function needLevel(value)
  local level = 0
  for index, threshold in ipairs(needsConfig.thresholds) do
    if value >= threshold.value then
      level = index
    else
      break
    end
  end
  return level
end

local function refreshWarningLevels(notify)
  for needName in pairs(needNames) do
    if not needEnabled(needName) then
      warningLevels[needName] = 0
    else
      local newLevel = needLevel(problemValue(needName))
      local previousLevel = warningLevels[needName] or 0

      if notify and gameplaySettings().warnings and newLevel > previousLevel then
        local messages = needsConfig.warnings.messages[needName]
        local key = needsConfig.thresholds[newLevel].key
        local messageText = type(messages) == "table" and messages[key] or nil
        if type(messageText) == "string" and messageText ~= "" then
          player.queueStatusMessage(messageText)
        end
        if hudSettings().pulse then
          pulseTimers[needName] = pulseDuration
        end
      end

      warningLevels[needName] = newLevel
    end
  end
end

local function highestConsequenceLevel()
  local level = 0
  for needName in pairs(needNames) do
    if needEnabled(needName) then
      level = math.max(level, needLevel(problemValue(needName)))
    end
  end
  return level
end

local function currentConsequences()
  local result = {
    levels = {},
    speed = 1,
    jump = 1,
    power = 1,
    energyRegen = 1,
    protection = 1
  }

  local consequencesEnabled = gameplaySettings().consequences

  for needName in pairs(needNames) do
    local level = 0
    if needEnabled(needName) then
      level = needLevel(problemValue(needName))
    end
    result.levels[needName] = level

    if consequencesEnabled and level > 0 then
      local tierKey = needsConfig.thresholds[level].key
      local profile = needsConfig.consequences.profiles[needName][tierKey]
      for _, dimension in ipairs(consequenceDimensions) do
        result[dimension] = result[dimension] * (profile[dimension] or 1)
      end
    end
  end

  if consequencesEnabled then
    for _, dimension in ipairs(consequenceDimensions) do
      result[dimension] = math.max(
        result[dimension],
        needsConfig.consequences.minimumMultipliers[dimension]
      )
    end
  end

  return result
end

local function consequenceSignature(consequences)
  return string.format(
    "%.6f:%.6f:%.6f:%.6f:%.6f",
    consequences.speed,
    consequences.jump,
    consequences.power,
    consequences.energyRegen,
    consequences.protection
  )
end

local function applyConsequences()
  local consequences = currentConsequences()

  if consequences.speed < 1 or consequences.jump < 1 then
    mcontroller.controlModifiers({
      speedModifier = consequences.speed,
      airJumpModifier = consequences.jump
    })
  end

  local signature = consequenceSignature(consequences)
  if appliedConsequenceSignature ~= signature then
    local modifiers = {}
    if consequences.power < 1 then
      table.insert(modifiers, {
        stat = "powerMultiplier",
        effectiveMultiplier = consequences.power
      })
    end
    if consequences.energyRegen < 1 then
      table.insert(modifiers, {
        stat = "energyRegenPercentageRate",
        effectiveMultiplier = consequences.energyRegen
      })
    end
    if consequences.protection < 1 then
      table.insert(modifiers, {
        stat = "protection",
        effectiveMultiplier = consequences.protection
      })
    end

    if #modifiers > 0 then
      status.setPersistentEffects(consequenceCategory, modifiers)
    else
      status.clearPersistentEffects(consequenceCategory)
    end
    appliedConsequenceSignature = signature
  end
end

local function caffeineActive()
  local ok, active = pcall(
    status.uniqueStatusEffectActive,
    needsConfig.beverages.caffeineEffect
  )
  return ok and active == true
end

local function caffeineRemaining()
  if not caffeineActive() then
    caffeineRemainingSeconds = 0
  end
  return caffeineRemainingSeconds
end

local function onCaffeineUpdate(_, _, remaining)
  -- The xneeds_caffeinated effect reports its own remaining duration here, so
  -- the readout follows the real status effect instead of a second countdown.
  if not isFiniteNumber(remaining) or remaining < 0 or remaining > 86400 then
    return
  end
  caffeineRemainingSeconds = remaining
end

local function needEnvironmentMultiplier(needName, biomeName)
  if not gameplaySettings().environment then
    return 1
  end
  local needConfig = needsConfig[needName]
  local environment = type(needConfig) == "table" and needConfig.environment or nil
  if type(environment) ~= "table" then
    return 1
  end

  local multiplier = configuredBiomeMultiplier(
    biomeName,
    environment.biomeGainMultipliers,
    environment.biomeGainMultiplierPatterns
  )
  local ok, environmentEffects = pcall(world.environmentStatusEffects, mcontroller.position())
  if ok and type(environmentEffects) == "table" then
    for _, effectName in ipairs(environmentEffects) do
      if type(effectName) == "string" then
        multiplier = math.max(
          multiplier,
          environment.environmentEffectGainMultipliers[string.lower(effectName)] or 1
        )
      end
    end
  end
  return multiplier
end

local function isNightTime()
  local circadian = needsConfig.fatigue.circadian
  if not circadian.enabled or not gameplaySettings().circadian then
    return false
  end

  local ok, timeOfDay = pcall(world.timeOfDay)
  if not ok or not isFiniteNumber(timeOfDay) then
    return false
  end

  if circadian.nightStart <= circadian.nightEnd then
    return timeOfDay >= circadian.nightStart and timeOfDay < circadian.nightEnd
  end
  return timeOfDay >= circadian.nightStart or timeOfDay < circadian.nightEnd
end

local function circadianGainMultiplier()
  local circadian = needsConfig.fatigue.circadian
  if not circadian.enabled or not gameplaySettings().circadian then
    return 1
  end
  if isNightTime() then
    return circadian.nightGainMultiplier
  end
  return circadian.dayGainMultiplier
end

local function restedActive()
  local rested = needsConfig.fatigue.rested
  if not rested.enabled or not gameplaySettings().rested then
    return false
  end
  local ok, active = pcall(status.uniqueStatusEffectActive, rested.effect)
  return ok and active == true
end

local function restedGainMultiplier()
  if restedActive() then
    return needsConfig.fatigue.rested.gainMultiplier
  end
  return 1
end

local function trackSleepRest(sleeping, dt)
  if sleeping then
    sleepAccumulatedSeconds = sleepAccumulatedSeconds + dt
    wasSleeping = true
    return
  end

  if wasSleeping then
    wasSleeping = false
    local rested = needsConfig.fatigue.rested
    if rested.enabled and gameplaySettings().rested
        and sleepAccumulatedSeconds >= rested.minimumSleepSeconds then
      status.addEphemeralEffect(rested.effect, rested.durationSeconds, entity.id())
      if rested.message ~= "" then
        player.queueStatusMessage(stringFor("messages.rested", rested.message))
      end
    end
    sleepAccumulatedSeconds = 0
  end
end

local function advanceNeeds(elapsed)
  normalizeStorage()

  local biomeName = currentBiome() or "none"
  local scale = rateScale()
  local reliefRate = 0
  local hygieneState

  if needEnabled("fatigue") then
    if isSleeping() then
      storage.needs.fatigue = storage.needs.fatigue
        - needsConfig.fatigue.sleepRecoveryPerSecond * sleepRecoveryScale() * elapsed
    else
      local fatigueGainMultiplier = 1
      if caffeineActive() then
        fatigueGainMultiplier = fatigueGainMultiplier
          * needsConfig.beverages.caffeineAwakeGainMultiplier
      end
      fatigueGainMultiplier = fatigueGainMultiplier
        * circadianGainMultiplier()
        * restedGainMultiplier()
        * needEnvironmentMultiplier("fatigue", biomeName)
      storage.needs.fatigue = storage.needs.fatigue
        + needsConfig.fatigue.awakeGainPerSecond
        * fatigueGainMultiplier * scale * elapsed
    end
  end

  if needEnabled("thirst") then
    storage.needs.thirst = storage.needs.thirst
      + needsConfig.thirst.passiveGainPerSecond
      * needEnvironmentMultiplier("thirst", biomeName)
      * scale * elapsed
  end

  if needEnabled("bladder") then
    reliefRate = bladderReliefRate()
    if reliefRate > 0 then
      storage.needs.bladder = storage.needs.bladder - reliefRate * elapsed
    else
      storage.needs.bladder = storage.needs.bladder
        + needsConfig.bladder.passiveGainPerSecond * scale * elapsed
    end
  end

  if needEnabled("hygiene") then
    hygieneState = hygieneEnvironment(elapsed)
    if hygieneState.recoveryRate > 0 then
      storage.needs.hygiene = storage.needs.hygiene
        + hygieneState.recoveryRate * elapsed
    else
      storage.needs.hygiene = storage.needs.hygiene
        - hygieneState.passiveLoss
    end
    storage.needs.hygiene = storage.needs.hygiene
      - hygieneState.activityLoss
      - hygieneState.contaminationLoss
      - hygieneState.combatLoss

    lastHygieneEnvironment = hygieneState
    pendingCombatDirtiness = math.max(0, pendingCombatDirtiness - hygieneState.combatLoss)
  else
    pendingCombatDirtiness = 0
  end
  pendingRunningSeconds = 0
  pendingJumpingSeconds = 0

  for needName in pairs(needNames) do
    storage.needs[needName] = clampNeed(storage.needs[needName])
  end

  if needsConfig.debug.logRecoveryEvents then
    if reliefRate > 0 then
      sb.logInfo("[xneeds_v0] bladder relief rate: %s", reliefRate)
    end
    if hygieneState and hygieneState.recoveryRate > 0 then
      sb.logInfo("[xneeds_v0] hygiene recovery rate: %s", hygieneState.recoveryRate)
    end
    if hygieneState then
      local environmentalLoss = hygieneState.activityLoss
        + hygieneState.contaminationLoss
        + hygieneState.combatLoss
      if environmentalLoss > 0 then
        sb.logInfo(
          "[xneeds_v0] environmental hygiene loss: %s (activity %s, liquid %s, combat %s)",
          environmentalLoss,
          hygieneState.activityLoss,
          hygieneState.contaminationLoss,
          hygieneState.combatLoss
        )
      end
    end
  end

  refreshWarningLevels(true)
end

local function itemDetails(itemName)
  if type(itemName) ~= "string" or itemName == "" then
    return nil
  end

  local ok, itemConfig = pcall(root.itemConfig, {name = itemName, count = 1})
  if not ok or type(itemConfig) ~= "table" then
    return nil
  end

  return {
    parameters = type(itemConfig.parameters) == "table" and itemConfig.parameters or {},
    config = type(itemConfig.config) == "table" and itemConfig.config or {}
  }
end

local function configuredItemValue(itemName, details, parameterName, overrides, defaultValue)
  local value = details.parameters[parameterName]
  if value == nil then
    value = details.config[parameterName]
  end
  if isFiniteNumber(value) then
    return value, "item parameter " .. parameterName
  elseif value == false then
    return nil, "disabled by item parameter " .. parameterName
  end

  value = overrides[itemName]
  if isFiniteNumber(value) then
    return value, "item override map"
  elseif value == false then
    return nil, "disabled by item override map"
  end
  return defaultValue, "resolved profile"
end

local function appendBeverageEffectNames(parts, effects)
  if type(effects) ~= "table" then
    return
  end

  for _, group in ipairs(effects) do
    if type(group) == "table" then
      for _, descriptor in ipairs(group) do
        if type(descriptor) == "string" then
          table.insert(parts, descriptor)
        elseif type(descriptor) == "table" and type(descriptor.effect) == "string" then
          table.insert(parts, descriptor.effect)
        end
      end
    end
  end
end

local function consumableSearchText(itemName, details)
  local parts = {itemName}
  local textFields = {"shortdescription", "description"}
  for _, field in ipairs(textFields) do
    if type(details.parameters[field]) == "string" then
      table.insert(parts, details.parameters[field])
    end
    if type(details.config[field]) == "string" then
      table.insert(parts, details.config[field])
    end
  end
  appendBeverageEffectNames(parts, details.parameters.effects)
  appendBeverageEffectNames(parts, details.config.effects)
  return " " .. string.lower(table.concat(parts, " ")) .. " "
end

local function normalizedInlineProfile(value)
  if type(value) ~= "table"
      or not isFiniteNumber(value.thirstRecovery)
      or not isFiniteNumber(value.bladderGain)
      or not isFiniteNumber(value.fatigueChange) then
    return nil
  end

  local caffeine = value.caffeineDuration
  if caffeine ~= nil and not isFiniteNumber(caffeine) then
    return nil
  end

  return {
    thirstRecovery = value.thirstRecovery,
    bladderGain = value.bladderGain,
    fatigueChange = value.fatigueChange,
    caffeineDuration = caffeine or 0
  }
end

local function profileFor(section, itemName, details)
  local explicit = details.parameters[section.profileParameter]
  if explicit == nil then
    explicit = details.config[section.profileParameter]
  end

  if explicit == false then
    return section.defaultProfile,
      section.profiles[section.defaultProfile],
      "default forced by item parameter"
  elseif type(explicit) == "string" and section.profiles[explicit] then
    return explicit, section.profiles[explicit], "item parameter"
  elseif type(explicit) == "table" then
    local inline = normalizedInlineProfile(explicit)
    if inline then
      return "inline", inline, "item parameter (inline profile)"
    end
  end

  local mapped = section.itemProfiles[string.lower(itemName)]
  if mapped and section.profiles[mapped] then
    return mapped, section.profiles[mapped], "exact item mapping"
  end

  local searchText = consumableSearchText(itemName, details)
  for _, rule in ipairs(section.classificationRules) do
    for _, pattern in ipairs(rule.patterns) do
      if string.find(searchText, string.lower(pattern), 1, true) then
        return rule.profile,
          section.profiles[rule.profile],
          "classification rule: " .. pattern
      end
    end
  end

  return section.defaultProfile,
    section.profiles[section.defaultProfile],
    "default"
end

local function beverageProfile(itemName, details)
  return profileFor(needsConfig.beverages, itemName, details)
end

local function foodProfile(itemName, details)
  return profileFor(needsConfig.foods, itemName, details)
end

local function configuredBeverageValue(details, parameterName, defaultValue)
  local value = details.parameters[parameterName]
  if value == nil then
    value = details.config[parameterName]
  end
  if isFiniteNumber(value) then
    return value, "item parameter " .. parameterName
  elseif value == false then
    return 0, "disabled by item parameter " .. parameterName
  end
  return defaultValue, "resolved profile"
end

local function queueConsumableFeedback(feedback, profileName, thirstRecovery)
  if not feedback.enabled or not gameplaySettings().feedback
      or beverageFeedbackCooldown > 0 then
    return
  end

  local messageText = feedback.profileMessages[profileName]
  if not messageText and isFiniteNumber(thirstRecovery) and thirstRecovery < 0 then
    messageText = feedback.dehydratingMessage
  end
  if messageText then
    player.queueStatusMessage(messageText)
    beverageFeedbackCooldown = feedback.cooldownSeconds
  end
end

local function grantConsumedReturn(itemName)
  local returnItems = needsConfig.beverages.returnItems
  if not returnItems.enabled then
    return
  end

  local grantedName = returnItems.items[string.lower(itemName)]
  if type(grantedName) ~= "string" or grantedName == "" then
    return
  end

  player.giveItem({name = grantedName, count = 1})
  if needsConfig.debug.logDrinkEvents then
    sb.logInfo("[xneeds_v0] returned %s for %s", grantedName, itemName)
  end
end

local function consumableKind(itemName, details)
  local lowerName = string.lower(itemName)
  local beverages = needsConfig.beverages
  local foods = needsConfig.foods

  local explicitBeverage = details.parameters[beverages.profileParameter]
  if explicitBeverage == nil then
    explicitBeverage = details.config[beverages.profileParameter]
  end
  if explicitBeverage ~= nil or beverages.itemProfiles[lowerName] ~= nil then
    return "drink"
  end

  if foods.enabled then
    local explicitFood = details.parameters[foods.profileParameter]
    if explicitFood == nil then
      explicitFood = details.config[foods.profileParameter]
    end
    if explicitFood ~= nil or foods.itemProfiles[lowerName] ~= nil then
      return "food"
    end
  end

  local category = details.config.category
  if type(category) ~= "string" then
    category = details.parameters.category
  end
  category = type(category) == "string" and string.lower(category) or ""
  if category == needsConfig.bladder.drinkCategory then
    return "drink"
  end
  if foods.enabled and category == foods.category then
    return "food"
  end
end

local function onConsumedItem(_, isLocal, itemName)
  -- The generated one-shot consumable effect forwards the consumed item here.
  if not isLocal then
    return
  end

  local details = itemDetails(itemName)
  if not details then
    return
  end

  local kind = consumableKind(itemName, details)
  if not kind then
    return
  end

  grantConsumedReturn(itemName)

  local profileName, profile, feedback
  if kind == "drink" then
    profileName, profile = beverageProfile(itemName, details)
    feedback = needsConfig.beverages.feedback
  else
    profileName, profile = foodProfile(itemName, details)
    feedback = needsConfig.foods.feedback
  end

  local bladderGain = configuredItemValue(
    itemName,
    details,
    needsConfig.bladder.overrideParameter,
    needsConfig.bladder.itemOverrides,
    profile.bladderGain
  )
  local thirstRecovery = configuredItemValue(
    itemName,
    details,
    needsConfig.thirst.overrideParameter,
    needsConfig.thirst.itemOverrides,
    profile.thirstRecovery
  )
  local fatigueChange = configuredBeverageValue(
    details,
    needsConfig.beverages.fatigueChangeParameter,
    profile.fatigueChange
  )
  local caffeineDuration = configuredBeverageValue(
    details,
    needsConfig.beverages.caffeineDurationParameter,
    profile.caffeineDuration
  )

  if not isFiniteNumber(bladderGain)
      and not isFiniteNumber(thirstRecovery)
      and not isFiniteNumber(fatigueChange) then
    return
  end

  normalizeStorage()
  if isFiniteNumber(bladderGain) and needEnabled("bladder") then
    storage.needs.bladder = clampNeed(storage.needs.bladder + bladderGain)
  end
  if isFiniteNumber(thirstRecovery) and needEnabled("thirst") then
    storage.needs.thirst = clampNeed(storage.needs.thirst - thirstRecovery)
  end
  if isFiniteNumber(fatigueChange) and needEnabled("fatigue") then
    storage.needs.fatigue = clampNeed(storage.needs.fatigue + fatigueChange)
  end
  if isFiniteNumber(caffeineDuration) and caffeineDuration > 0 and needEnabled("fatigue") then
    status.addEphemeralEffect(
      needsConfig.beverages.caffeineEffect,
      caffeineDuration,
      entity.id()
    )
    caffeineRemainingSeconds = math.max(caffeineRemainingSeconds, caffeineDuration)
  end
  queueConsumableFeedback(feedback, profileName, thirstRecovery)
  refreshWarningLevels(true)

  if needsConfig.debug.logDrinkEvents then
    sb.logInfo(
      "[xneeds_v0] consume event: %s (%s) profile %s, bladder %+g, thirst recovery %+g, fatigue %+g, caffeine %gs",
      itemName,
      kind,
      profileName,
      bladderGain or 0,
      thirstRecovery or 0,
      fatigueChange or 0,
      caffeineDuration or 0
    )
  end
end

local function localOnly(isLocal)
  if not isLocal then
    return {
      ok = false,
      error = "xneeds_v0 debug messages are local-only"
    }
  end
end

local function debugGet(_, isLocal)
  local rejected = localOnly(isLocal)
  if rejected then
    return rejected
  end

  local result = needSnapshot()
  result.ok = true
  result.sleeping = isSleeping()
  result.caffeinated = caffeineActive()
  local caffeineTime = caffeineRemaining()
  result.caffeineRemainingSeconds = caffeineTime
  result.caffeineRemaining = formatDuration(caffeineTime)
  result.bladderReliefRate = bladderReliefRate()
  local hygieneState = hygieneEnvironment(needsConfig.updateInterval)
  result.hygieneRecoveryRate = hygieneState.recoveryRate
  result.hygieneEnvironment = hygieneState
  result.lastHygieneEnvironment = lastHygieneEnvironment
  result.pendingCombatDirtiness = pendingCombatDirtiness
  result.restRecoveryPerSecond = needsConfig.fatigue.sleepRecoveryPerSecond
  local biomeName = currentBiome() or "none"
  result.night = isNightTime()
  result.circadianMultiplier = circadianGainMultiplier()
  result.rested = restedActive()
  result.thirstEnvironmentMultiplier = needEnvironmentMultiplier("thirst", biomeName)
  result.fatigueEnvironmentMultiplier = needEnvironmentMultiplier("fatigue", biomeName)
  local gameplay = gameplaySettings()
  result.settings = {
    warnings = gameplay.warnings,
    consequences = gameplay.consequences,
    feedback = gameplay.feedback,
    circadian = gameplay.circadian,
    rested = gameplay.rested,
    environment = gameplay.environment,
    rateScale = gameplay.rateScale,
    sleepSpeed = gameplay.sleepSpeed,
    thirstEnabled = gameplay.thirstEnabled,
    fatigueEnabled = gameplay.fatigueEnabled,
    bladderEnabled = gameplay.bladderEnabled,
    hygieneEnabled = gameplay.hygieneEnabled
  }
  local consequences = currentConsequences()
  result.penaltyLevel = highestConsequenceLevel()
  result.consequenceLevels = consequences.levels
  result.consequenceMultipliers = {
    speed = consequences.speed,
    jump = consequences.jump,
    power = consequences.power,
    energyRegen = consequences.energyRegen,
    protection = consequences.protection
  }
  return result
end

local function debugSet(_, isLocal, needName, value)
  local rejected = localOnly(isLocal)
  if rejected then
    return rejected
  end
  if not needNames[needName] then
    return {
      ok = false,
      error = "need must be thirst, fatigue, bladder, or hygiene"
    }
  end
  if not isFiniteNumber(value) then
    return {
      ok = false,
      error = "value must be a finite number"
    }
  end

  normalizeStorage()
  storage.needs[needName] = clampNeed(value)
  refreshWarningLevels(false)

  local result = needSnapshot()
  result.ok = true
  return result
end

local function debugReset(_, isLocal)
  local rejected = localOnly(isLocal)
  if rejected then
    return rejected
  end

  storage.needs = migrateNeeds({})
  pendingCombatDirtiness = 0
  pendingRunningSeconds = 0
  pendingJumpingSeconds = 0
  lastHygieneEnvironment = {}
  refreshWarningLevels(false)
  local result = needSnapshot()
  result.ok = true
  return result
end

local function tierLabel(level)
  if level <= 0 then
    return "normal"
  end
  return needsConfig.thresholds[level].key
end

local function commandStatus()
  normalizeStorage()
  local consequences = currentConsequences()
  local hygieneState = hygieneEnvironment(needsConfig.updateInterval)
  return string.format(
    "^#f3d36a;<Needs V1.14>^reset;\n"
      .. "Thirst: ^cyan;%.1f^reset; [%s]\n"
      .. "Fatigue: ^cyan;%.1f^reset; [%s]\n"
      .. "Bladder: ^cyan;%.1f^reset; [%s]\n"
      .. "Hygiene: ^cyan;%.1f^reset; (dirtiness %.1f) [%s]\n"
      .. "Caffeinated: %s\n"
      .. "Circadian: %s, rested %s\n"
      .. "Multipliers: speed %.0f%%, jump %.0f%%, power %.0f%%, energy regen %.0f%%, protection %.0f%%\n"
      .. "Environment: biome %s x%.2f, thirst gain x%.2f, fatigue gain x%.2f, liquid %s (%s), rain/wet %s\n"
      .. "Settings: difficulty x%.2f, sleep x%.2f, warnings %s, consequences %s, feedback %s, circadian %s, rested %s, environment %s\n"
      .. "Hygiene next tick: recovery +%.2f, passive -%.3f, activity -%.3f, liquid -%.3f, combat -%.3f",
    storage.needs.thirst,
    tierLabel(consequences.levels.thirst),
    storage.needs.fatigue,
    tierLabel(consequences.levels.fatigue),
    storage.needs.bladder,
    tierLabel(consequences.levels.bladder),
    storage.needs.hygiene,
    100 - storage.needs.hygiene,
    tierLabel(consequences.levels.hygiene),
    caffeineActive()
      and ("yes (" .. formatDuration(caffeineRemaining()) .. " remaining)")
      or "no",
    isNightTime() and "night" or "day",
    restedActive() and "yes" or "no",
    consequences.speed * 100,
    consequences.jump * 100,
    consequences.power * 100,
    consequences.energyRegen * 100,
    consequences.protection * 100,
    hygieneState.biome,
    hygieneState.biomeMultiplier,
    needEnvironmentMultiplier("thirst", hygieneState.biome),
    needEnvironmentMultiplier("fatigue", hygieneState.biome),
    hygieneState.liquid,
    hygieneState.liquidClass,
    hygieneState.rainEffect and "yes" or "no",
    gameplaySettings().rateScale,
    gameplaySettings().sleepSpeed,
    gameplaySettings().warnings and "on" or "off",
    gameplaySettings().consequences and "on" or "off",
    gameplaySettings().feedback and "on" or "off",
    gameplaySettings().circadian and "on" or "off",
    gameplaySettings().rested and "on" or "off",
    gameplaySettings().environment and "on" or "off",
    hygieneState.recoveryRate * needsConfig.updateInterval,
    hygieneState.passiveLoss,
    hygieneState.activityLoss,
    hygieneState.contaminationLoss,
    hygieneState.combatLoss
  )
end

local function commandHelp(errorText)
  local prefix = errorText and ("^red;" .. errorText .. "^reset;\n") or ""
  return prefix
    .. "^#f3d36a;</xneeds>^reset; local testing commands\n"
    .. "^cyan;/xneeds get^reset;\n"
    .. "^cyan;/xneeds set <thirst|fatigue|bladder|hygiene|dirtiness|all> <0-100>^reset;\n"
    .. "^cyan;/xneeds add <need> <amount>^reset;\n"
    .. "^cyan;/xneeds beverage <itemName>^reset;\n"
    .. "^cyan;/xneeds beverages [all|details|<profile>|<text>]^reset;\n"
    .. "^cyan;/xneeds food <itemName>^reset;\n"
    .. "^cyan;/xneeds foods [all|details|<profile>|<text>]^reset;\n"
    .. "^cyan;/xneeds options^reset;\n"
    .. "^cyan;/xneeds help [needs|tiers|drinks|foods|hygiene|sleep|settings|commands]^reset;\n"
    .. "^cyan;/xneeds preset <normal|noticeable|serious|urgent|critical>^reset;\n"
    .. "^cyan;/xneeds reset^reset;"
end

local helpTopics = {
  "needs",
  "tiers",
  "drinks",
  "foods",
  "hygiene",
  "sleep",
  "settings",
  "commands"
}

local function needsHelp(topic)
  if type(topic) ~= "string" or topic == "" then
    return stringFor(
      "help.overview",
      "Type /xneeds help <topic>. Topics: "
        .. table.concat(helpTopics, ", ")
        .. "."
    )
  end
  if topic == "commands" then
    return stringFor("help.commands", "Commands:") .. "\n" .. commandHelp()
  end
  local text = stringFor("help." .. topic, nil)
  if text then
    return text
  end
  return commandHelp(
    "Unknown help topic. Topics: " .. table.concat(helpTopics, ", ")
  )
end

local function commandNeedName(name)
  name = type(name) == "string" and string.lower(name) or ""
  if needNames[name] or name == "dirtiness" or name == "all" then
    return name
  end
end

local function setCommandNeed(name, value)
  normalizeStorage()
  value = clampNeed(value)

  if name == "all" then
    storage.needs.thirst = value
    storage.needs.fatigue = value
    storage.needs.bladder = value
    storage.needs.hygiene = 100 - value
  elseif name == "dirtiness" then
    storage.needs.hygiene = 100 - value
  else
    storage.needs[name] = value
  end
  refreshWarningLevels(false)
end

local function addCommandNeed(name, amount)
  normalizeStorage()
  if name == "all" then
    setCommandNeed("thirst", storage.needs.thirst + amount)
    setCommandNeed("fatigue", storage.needs.fatigue + amount)
    setCommandNeed("bladder", storage.needs.bladder + amount)
    setCommandNeed("dirtiness", 100 - storage.needs.hygiene + amount)
  elseif name == "dirtiness" then
    setCommandNeed(name, 100 - storage.needs.hygiene + amount)
  else
    setCommandNeed(name, storage.needs[name] + amount)
  end
end

local function beverageDiagnosticLine(label, value, source, invert)
  if not isFiniteNumber(value) then
    return string.format("%s: disabled [%s]", label, source or "unknown")
  end
  if invert then
    value = -value
  end
  return string.format("%s: %+g [%s]", label, value, source or "unknown")
end

local consumableAuditCache = {}

local function auditConfig(kind)
  if kind == "food" then
    return needsConfig.foods, needsConfig.foods.category,
      needsConfig.foods.profileParameter, "Food"
  end
  return needsConfig.beverages, needsConfig.bladder.drinkCategory,
    needsConfig.beverages.profileParameter, "Beverage"
end

local function detectedConsumableItems(kind)
  if consumableAuditCache[kind] then
    return consumableAuditCache[kind]
  end

  local section, category, profileParameter = auditConfig(kind)
  local items = {}
  local seen = {}
  local ok, assetPaths = pcall(root.assetsByExtension, "consumable")
  if ok and type(assetPaths) == "table" then
    for _, assetPath in ipairs(assetPaths) do
      local assetOk, item = pcall(root.assetJson, assetPath)
      if assetOk and type(item) == "table" then
        local itemName = type(item.itemName) == "string" and item.itemName or ""
        local itemCategory = type(item.category) == "string"
          and string.lower(item.category) or ""
        local explicitProfile = item[profileParameter]
        local explicitlyConfigured = section.itemProfiles[string.lower(itemName)] ~= nil
          or type(explicitProfile) == "string"
          or explicitProfile == false
        if itemName ~= "" and not seen[itemName]
            and (itemCategory == category or explicitlyConfigured) then
          seen[itemName] = true
          table.insert(items, {
            name = itemName,
            path = assetPath
          })
        end
      end
    end
  end

  table.sort(items, function(a, b)
    return a.name < b.name
  end)
  consumableAuditCache[kind] = items
  return items
end

local function consumableAuditText(details)
  local parts = {}
  local function addText(value)
    if type(value) == "string" and value ~= "" then
      table.insert(parts, value)
    end
  end

  addText(details.parameters.shortdescription)
  addText(details.config.shortdescription)
  addText(details.parameters.description)
  addText(details.config.description)

  local effects = {}
  appendBeverageEffectNames(effects, details.parameters.effects)
  appendBeverageEffectNames(effects, details.config.effects)
  if #effects > 0 then
    table.insert(parts, "effects: " .. table.concat(effects, ", "))
  end

  local text = table.concat(parts, " | ")
  text = string.gsub(text, "%s+", " ")
  if #text > 160 then
    text = string.sub(text, 1, 157) .. "..."
  end
  return text
end

local function consumableAudit(kind, arguments)
  local section, _, _, label = auditConfig(kind)
  local items = detectedConsumableItems(kind)
  if #items == 0 then
    return label .. " audit: no detected items."
  end

  local showDetails = false
  local filter
  for index = 2, #arguments do
    local argument = arguments[index]
    if argument == "details" then
      showDetails = true
    elseif filter == nil then
      filter = argument
    end
  end

  local profileFilter
  local nameFilter
  if filter and filter ~= "all" then
    if section.profiles[filter] then
      profileFilter = filter
    else
      nameFilter = filter
    end
  end

  local counts = {}
  local matches = {}
  for _, record in ipairs(items) do
    local itemName = record.name
    local details = itemDetails(itemName)
    if details then
      local profileName, _, source = profileFor(section, itemName, details)
      counts[profileName] = (counts[profileName] or 0) + 1

      local include
      if profileFilter then
        include = profileName == profileFilter
      elseif nameFilter then
        include = string.find(string.lower(itemName), nameFilter, 1, true) ~= nil
      else
        include = source == "default"
      end
      if include then
        local entry = string.format(
          "%s -> %s [%s]",
          itemName,
          profileName,
          source
        )
        if showDetails then
          local sourceOk, sourcePath = pcall(root.assetSource, record.path)
          entry = string.format(
            "%s\n    path: %s\n    mod: %s\n    text: %s",
            entry,
            record.path,
            sourceOk and sourcePath or "unknown",
            consumableAuditText(details)
          )
        end
        table.insert(matches, entry)
      end
    end
  end

  local profileSummary = {}
  for profileName, count in pairs(counts) do
    table.insert(profileSummary, string.format("%s %d", profileName, count))
  end
  table.sort(profileSummary)

  local scope
  if profileFilter then
    scope = "profile " .. profileFilter
  elseif nameFilter then
    scope = "name matching " .. nameFilter
  elseif showDetails then
    scope = "default fallbacks with details"
  else
    scope = "default fallbacks"
  end

  local limit = showDetails and 12 or 40
  local shown = math.min(#matches, limit)
  local lines = {}
  for index = 1, shown do
    table.insert(lines, "  " .. matches[index])
  end
  if shown == 0 then
    table.insert(lines, "  (none)")
  elseif #matches > shown then
    table.insert(lines, string.format("  ...and %d more", #matches - shown))
  end

  return string.format(
    "%s audit: %d detected. Profiles: %s\n%s (%d):\n%s",
    label,
    #items,
    table.concat(profileSummary, ", "),
    scope,
    #matches,
    table.concat(lines, "\n")
  )
end

local function beverageAudit(arguments)
  return consumableAudit("drink", arguments)
end

local function foodAudit(arguments)
  return consumableAudit("food", arguments)
end

local function consumableDiagnostic(label, itemName, profileName, profile, profileSource)
  local details = itemDetails(itemName)
  local bladderGain, bladderSource = configuredItemValue(
    itemName,
    details,
    needsConfig.bladder.overrideParameter,
    needsConfig.bladder.itemOverrides,
    profile.bladderGain
  )
  local thirstRecovery, thirstSource = configuredItemValue(
    itemName,
    details,
    needsConfig.thirst.overrideParameter,
    needsConfig.thirst.itemOverrides,
    profile.thirstRecovery
  )
  local fatigueChange, fatigueSource = configuredBeverageValue(
    details,
    needsConfig.beverages.fatigueChangeParameter,
    profile.fatigueChange
  )
  local caffeineDuration, caffeineSource = configuredBeverageValue(
    details,
    needsConfig.beverages.caffeineDurationParameter,
    profile.caffeineDuration
  )
  return string.format("%s %s\nProfile: %s [%s]\n%s\n%s\n%s\n%s",
    label,
    itemName,
    profileName,
    profileSource,
    beverageDiagnosticLine("Thirst", thirstRecovery, thirstSource, true),
    beverageDiagnosticLine("Bladder", bladderGain, bladderSource, false),
    beverageDiagnosticLine("Fatigue", fatigueChange, fatigueSource, false),
    beverageDiagnosticLine("Caffeine seconds", caffeineDuration, caffeineSource, false)
  )
end

local function needsCommand(rawArguments)
  local arguments = {}
  for argument in string.gmatch(rawArguments or "", "%S+") do
    table.insert(arguments, string.lower(argument))
  end

  local operation = arguments[1] or "get"
  if operation == "get" then
    return commandStatus()
  elseif operation == "beverage" then
    local itemName = arguments[2]
    local details = itemDetails(itemName)
    if not details then
      return commandHelp(stringFor("messages.unknownBeverage", "Unknown beverage item."))
    end
    local profileName, profile, profileSource = beverageProfile(itemName, details)
    return consumableDiagnostic("Beverage", itemName, profileName, profile, profileSource)
  elseif operation == "food" then
    local itemName = arguments[2]
    local details = itemDetails(itemName)
    if not details then
      return commandHelp(stringFor("messages.unknownFood", "Unknown food item."))
    end
    local profileName, profile, profileSource = foodProfile(itemName, details)
    return consumableDiagnostic("Food", itemName, profileName, profile, profileSource)
  elseif operation == "beverages" then
    return beverageAudit(arguments)
  elseif operation == "foods" then
    return foodAudit(arguments)
  elseif operation == "options" then
    settingsOpen = not settingsOpen
    if settingsOpen then
      return stringFor(
        "messages.settingsOpened",
        "Needs settings opened. Use the Close button or /xneeds options to close."
      )
    end
    return stringFor("messages.settingsClosed", "Needs settings closed.")
  elseif operation == "help" then
    return needsHelp(arguments[2])
  elseif operation == "reset" then
    storage.needs = migrateNeeds({})
    pendingCombatDirtiness = 0
    pendingRunningSeconds = 0
    pendingJumpingSeconds = 0
    lastHygieneEnvironment = {}
    refreshWarningLevels(false)
    return stringFor("messages.reset", "Needs reset.") .. "\n" .. commandStatus()
  elseif operation == "preset" then
    local presets = {
      normal = 0,
      noticeable = 50,
      serious = 70,
      urgent = 85,
      critical = 95
    }
    local value = presets[arguments[2] or ""]
    if value == nil then
      return commandHelp(stringFor("messages.unknownPreset", "Unknown preset."))
    end
    setCommandNeed("all", value)
    return string.format("Applied %s preset.\n%s", arguments[2], commandStatus())
  elseif operation == "set" or operation == "add" then
    local needName = commandNeedName(arguments[2])
    local value = tonumber(arguments[3])
    if not needName or not isFiniteNumber(value) then
      return commandHelp(stringFor("messages.missingValue", "Missing or invalid need/value."))
    end
    if operation == "set" then
      setCommandNeed(needName, value)
    else
      addCommandNeed(needName, value)
    end
    return commandStatus()
  end

  return commandHelp(stringFor("messages.unknownOperation", "Unknown operation."))
end

local tooltipNeedOrder = { "thirst", "fatigue", "bladder", "hygiene" }

local needDisplayNames = {
  thirst = "Thirst",
  fatigue = "Fatigue",
  bladder = "Bladder",
  hygiene = "Hygiene"
}

local consequenceLabels = {
  speed = "Speed",
  jump = "Jump",
  power = "Power",
  energyRegen = "Energy",
  protection = "Protection"
}

local function needDisplayName(needName)
  return needDisplayNames[needName] or needName
end

local function needHudColor(needName)
  return needsConfig.hud[needName .. "Color"]
end

local function tierDisplayName(level)
  if level <= 0 then
    return "Normal"
  end
  local key = needsConfig.thresholds[level].key
  return string.upper(string.sub(key, 1, 1)) .. string.sub(key, 2)
end

local function tierHudColor(level)
  local key = level <= 0 and "normal" or needsConfig.thresholds[level].key
  local tooltips = needsConfig.hud.tooltips
  if type(tooltips) == "table" and type(tooltips.tierColors) == "table" then
    return tooltips.tierColors[key] or tooltips.textColor or needsConfig.hud.borderColor
  end
  return needsConfig.hud.borderColor
end

local function needRecoveryState(needName, sleeping)
  if needName == "fatigue" then
    if sleeping then
      return "Recovery: sleeping"
    end
    if caffeineActive() then
      local remaining = formatDuration(caffeineRemaining())
      if needsConfig.beverages.caffeineAwakeGainMultiplier <= 0 then
        return "Caffeine: fatigue paused (" .. remaining .. ")"
      end
      return "Caffeine: " .. remaining .. " left"
    end
    if restedActive() then
      return "Rested: reduced fatigue gain"
    end
    local biomeName = currentBiome() or "none"
    if isNightTime() then
      return "Night: faster fatigue gain"
    end
    if needEnvironmentMultiplier("fatigue", biomeName) > 1 then
      return "Environment: faster fatigue"
    end
  elseif needName == "thirst" then
    local biomeName = currentBiome() or "none"
    if needEnvironmentMultiplier("thirst", biomeName) > 1 then
      return "Environment: faster thirst"
    end
  elseif needName == "bladder" then
    if bladderReliefRate() > 0 then
      return "Relief: toilet"
    end
  elseif needName == "hygiene" then
    local state = lastHygieneEnvironment
    if isFiniteNumber(state.recoveryRate) and state.recoveryRate > 0 then
      if type(state.recoverySource) == "string" and state.recoverySource ~= "" then
        return "Recovery: " .. state.recoverySource
      end
      return "Recovery: cleaning"
    end
  end
end

local function appendNeedConsequenceLines(lines, needName, textColor)
  if not gameplaySettings().consequences then
    table.insert(lines, { text = "Penalties disabled", color = textColor })
    return
  end

  local level = needLevel(problemValue(needName))
  if level <= 0 then
    table.insert(lines, { text = "No active penalty", color = textColor })
    return
  end

  local tierKey = needsConfig.thresholds[level].key
  local profile = needsConfig.consequences.profiles[needName][tierKey]
  local count = 0
  for _, dimension in ipairs(consequenceDimensions) do
    local multiplier = profile[dimension]
    if isFiniteNumber(multiplier) and multiplier < 1 then
      table.insert(lines, {
        text = string.format(
          "%s %+d%%",
          consequenceLabels[dimension],
          math.floor((multiplier - 1) * 100 + 0.5)
        ),
        color = textColor
      })
      count = count + 1
    end
  end
  if count == 0 then
    table.insert(lines, { text = "No active penalty", color = textColor })
  end
end

local function needTooltipLines(needName, sleeping)
  local textColor = needsConfig.hud.tooltips.textColor
  if not needEnabled(needName) then
    return {
      {
        text = needDisplayName(needName),
        color = needHudColor(needName)
      },
      {
        text = "Disabled",
        color = textColor
      }
    }
  end

  local problem = problemValue(needName)
  local level = needLevel(problem)
  local lines = {
    {
      text = needDisplayName(needName),
      color = needHudColor(needName)
    },
    {
      text = needName == "hygiene"
        and string.format("Dirtiness %d / 100", math.floor(problem + 0.5))
        or string.format("Value %d / 100", math.floor(problem + 0.5)),
      color = textColor
    },
    {
      text = "Tier: " .. tierDisplayName(level),
      color = tierHudColor(level)
    }
  }

  local recovery = needRecoveryState(needName, sleeping)
  if recovery then
    table.insert(lines, { text = recovery, color = textColor })
  end
  appendNeedConsequenceLines(lines, needName, textColor)
  return lines
end

local function hudBarWidth()
  if not hudLayout then
    return 0
  end
  if hudSettings().compact then
    return math.max(12, math.floor(hudLayout.width * 0.4))
  end
  return hudLayout.width
end

local function hudIconSize()
  if hudSettings().compact then
    return 0
  end
  return needsConfig.hud.iconSize
end

local function hudOffsetX()
  local value = hudSettings().hudOffsetX
  if not isFiniteNumber(value) then
    return 0
  end
  return value
end

local function hudOffsetY()
  local value = hudSettings().hudOffsetY
  if not isFiniteNumber(value) then
    return 0
  end
  return value
end

local function hudAnchorX()
  return hudLayout.x + hudOffsetX()
end

local function hudTopOffset()
  return hudLayout.topOffset + hudOffsetY()
end

local function hudTextColor()
  local tooltips = needsConfig.hud.tooltips
  if type(tooltips) == "table" and type(tooltips.textColor) == "table" then
    return tooltips.textColor
  end
  return needsConfig.hud.borderColor
end

local function hudAccentColor()
  local tooltips = needsConfig.hud.tooltips
  if type(tooltips) == "table"
      and type(tooltips.tierColors) == "table"
      and type(tooltips.tierColors.noticeable) == "table" then
    return tooltips.tierColors.noticeable
  end
  return needsConfig.hud.borderColor
end

local function pulseColor(color, remaining)
  local fraction = math.max(0, math.min(1, remaining / pulseDuration))
  if fraction <= 0 then
    return color
  end
  local highlight = 0.6 * fraction
  return {
    math.floor(math.min(255, color[1] + (255 - color[1]) * highlight)),
    math.floor(math.min(255, color[2] + (255 - color[2]) * highlight)),
    math.floor(math.min(255, color[3] + (255 - color[3]) * highlight)),
    color[4]
  }
end

local function hoveredNeedName()
  if not hudCanvas then
    return nil
  end
  local mousePosition = hudCanvas:mousePosition()
  for _, needName in ipairs(tooltipNeedOrder) do
    if pointInsideRect(mousePosition, hudBarRects[needName]) then
      return needName
    end
  end
end

local function drawNeedTooltip(needName, sleeping, topY)
  local tooltips = needsConfig.hud.tooltips
  local lines = needTooltipLines(needName, sleeping)
  local width = tooltips.width
  local height = tooltips.padding * 2 + #lines * tooltips.lineHeight

  local canvasSize = hudCanvas:size()
  local anchorX = hudAnchorX()
    + hudBarWidth()
    + needsConfig.hud.iconGap
    + hudIconSize()
    + tooltips.gap
  if anchorX + width > canvasSize[1] - 2 then
    anchorX = math.max(2, hudAnchorX() - tooltips.gap - width)
  end

  local anchorY = topY
  local maximumY = canvasSize[2] - height - 2
  if anchorY > maximumY then
    anchorY = maximumY
  end
  if anchorY < 2 then
    anchorY = 2
  end

  hudCanvas:drawRect(
    {anchorX, anchorY, anchorX + width, anchorY + height},
    needsConfig.hud.borderColor
  )
  hudCanvas:drawRect(
    {anchorX + 1, anchorY + 1, anchorX + width - 1, anchorY + height - 1},
    needsConfig.hud.backgroundColor
  )

  local textX = anchorX + tooltips.padding
  local textY = anchorY + height - tooltips.padding
  for _, line in ipairs(lines) do
    hudCanvas:drawText(
      line.text,
      {
        position = {textX, textY},
        horizontalAnchor = "left",
        verticalAnchor = "top",
        wrapWidth = width - tooltips.padding * 2
      },
      tooltips.fontSize,
      line.color
    )
    textY = textY - tooltips.lineHeight
  end
end

local function loadHudLayout()
  local teamBar = root.assetJson("/interface/windowconfig/teambar.config")
  local foodBar = teamBar
    and teamBar.paneLayout
    and teamBar.paneLayout.foodBar

  if type(foodBar) ~= "table"
      or type(foodBar.position) ~= "table"
      or type(foodBar.size) ~= "table"
      or not isFiniteNumber(foodBar.position[1])
      or not isFiniteNumber(foodBar.position[2])
      or not isFiniteNumber(foodBar.size[1])
      or foodBar.size[1] <= 0 then
    sb.logWarn("[xneeds_v0] HUD disabled: unable to derive placement from teambar.config foodBar")
    return nil
  end

  local leftInset = math.min(
    needsConfig.hud.leftInset,
    math.max(0, foodBar.size[1] - 3)
  )
  return {
    x = foodBar.position[1] + leftInset,
    topOffset = foodBar.position[2] - needsConfig.hud.topGap,
    width = foodBar.size[1] - leftInset
  }
end

local function drawNeedBar(needName, y, ratio, color, iconPath)
  local x = hudAnchorX()
  local width = hudBarWidth()
  local height = needsConfig.hud.barHeight
  local settings = hudSettings()

  hudCanvas:drawRect(
    {x, y, x + width, y + height},
    needsConfig.hud.borderColor
  )

  if width > 2 and height > 2 then
    local innerLeft = x + 1
    local innerBottom = y + 1
    local innerWidth = width - 2
    local innerTop = y + height - 1

    hudCanvas:drawRect(
      {innerLeft, innerBottom, innerLeft + innerWidth, innerTop},
      needsConfig.hud.backgroundColor
    )

    local fillWidth = math.floor(innerWidth * clampNeed(ratio) / 100 + 0.5)
    if fillWidth > 0 then
      hudCanvas:drawRect(
        {innerLeft, innerBottom, innerLeft + fillWidth, innerTop},
        pulseColor(color, pulseTimers[needName] or 0)
      )
    end
  end

  local iconSize = hudIconSize()
  if iconSize > 0 then
    hudCanvas:drawImage(
      iconPath,
      {
        x + width + needsConfig.hud.iconGap + iconSize / 2,
        y + height / 2
      },
      needsConfig.hud.iconScale,
      {255, 255, 255, 255},
      true
    )
  end

  local trailing = iconSize > 0 and (needsConfig.hud.iconGap + iconSize) or 0
  if settings.alwaysShowValues then
    hudCanvas:drawText(
      string.format("%d", math.floor(clampNeed(ratio) + 0.5)),
      {
        position = {x + width + trailing + 3, y + height / 2},
        horizontalAnchor = "left",
        verticalAnchor = "mid"
      },
      7,
      hudTextColor()
    )
  end

  local step = height + needsConfig.hud.barGap
  local hoverPad = math.max(0, (step - height) / 2)
  hudBarRects[needName] = {
    x,
    y - hoverPad,
    x + width + trailing,
    y + height + hoverPad
  }
end

local dragHandleSize = 12

local function hudVisibleRowCount(settings)
  local rows = 0
  for _, key in ipairs({"showThirst", "showFatigue", "showBladder", "showHygiene"}) do
    if settings[key] then
      rows = rows + 1
    end
  end
  return rows
end

local function drawHudDragHandle()
  local rect = hudDragHandleRect
  if not rect then
    return
  end

  local hovered = hudDragging or pointInsideRect(hudCanvas:mousePosition(), rect)
  hudCanvas:drawRect(rect, needsConfig.hud.borderColor)
  hudCanvas:drawRect(
    {rect[1] + 1, rect[2] + 1, rect[3] - 1, rect[4] - 1},
    hovered and hudAccentColor() or needsConfig.hud.backgroundColor
  )

  local color = hovered and {255, 255, 255, 255} or hudTextColor()
  local cx = (rect[1] + rect[3]) / 2
  local cy = (rect[2] + rect[4]) / 2
  local arm = 3
  hudCanvas:drawRect({cx - arm, cy - 1, cx + arm, cy + 1}, color)
  hudCanvas:drawRect({cx - 1, cy - arm, cx + 1, cy + arm}, color)

  local head = 2
  for index = 0, head - 1 do
    local half = head - index
    hudCanvas:drawRect({cx - half, cy + arm + index, cx + half, cy + arm + index + 1}, color)
    hudCanvas:drawRect({cx - half, cy - arm - index - 1, cx + half, cy - arm - index}, color)
    hudCanvas:drawRect({cx + arm + index, cy - half, cx + arm + index + 1, cy + half}, color)
    hudCanvas:drawRect({cx - arm - index - 1, cy - half, cx - arm - index, cy + half}, color)
  end
end

local function clampNumber(value, minimum, maximum)
  if value < minimum then
    return minimum
  end
  if value > maximum then
    return maximum
  end
  return value
end

local function clampHudOffset(offsetX, offsetY)
  if not hudLayout or not hudCanvas then
    return offsetX, offsetY
  end

  local canvasSize = hudCanvas:size()
  local settings = hudSettings()
  local rows = math.max(1, hudVisibleRowCount(settings))
  local height = needsConfig.hud.barHeight
  local step = height + needsConfig.hud.barGap
  local iconSize = hudIconSize()
  local trailing = iconSize > 0 and (needsConfig.hud.iconGap + iconSize) or 0
  local totalWidth = hudBarWidth() + trailing + 3 + dragHandleSize

  local minOffsetX = 2 - hudLayout.x
  local maxOffsetX = (canvasSize[1] - 2) - (hudLayout.x + totalWidth)
  if maxOffsetX < minOffsetX then
    maxOffsetX = minOffsetX
  end
  offsetX = clampNumber(offsetX, minOffsetX, maxOffsetX)

  local minOffsetY = 2 - canvasSize[2] - hudLayout.topOffset + height + dragHandleSize + 2
  local maxOffsetY = -2 - hudLayout.topOffset - step * (rows - 1)
  if maxOffsetY < minOffsetY then
    maxOffsetY = minOffsetY
  end
  offsetY = clampNumber(offsetY, minOffsetY, maxOffsetY)

  return offsetX, offsetY
end

local function handleHudDrag()
  if not hudCanvas or not hudLayout or type(input) ~= "table" then
    return
  end

  local settings = hudSettings()
  if not settings.enabled then
    hudDragging = false
    return
  end

  local positionOk, mouse = pcall(function()
    return hudCanvas:mousePosition()
  end)
  if not positionOk then
    return
  end

  if hudDragging then
    local offsetX, offsetY = clampHudOffset(
      hudDragOffsetStart[1] + (mouse[1] - hudDragMouseStart[1]),
      hudDragOffsetStart[2] + (mouse[2] - hudDragMouseStart[2])
    )
    settings.hudOffsetX = offsetX
    settings.hudOffsetY = offsetY

    local released = false
    if type(input.mouseUp) == "function" then
      local upOk, releases = pcall(input.mouseUp, "MouseLeft")
      if upOk and type(releases) == "table" and #releases > 0 then
        released = true
      end
    end
    if not released and type(input.mouseHeld) == "function" then
      local heldOk, held = pcall(input.mouseHeld, "MouseLeft")
      if not heldOk or held ~= true then
        released = true
      end
    end
    if released then
      hudDragging = false
    end
    return
  end

  if settingsOpen or not hudDragHandleRect then
    return
  end
  if type(input.mouseDown) ~= "function" then
    return
  end

  local downOk, clicks = pcall(input.mouseDown, "MouseLeft")
  if not downOk or type(clicks) ~= "table" or #clicks == 0 then
    return
  end
  if pointInsideRect(mouse, hudDragHandleRect) then
    hudDragging = true
    hudDragMouseStart = {mouse[1], mouse[2]}
    hudDragOffsetStart = {settings.hudOffsetX, settings.hudOffsetY}
  end
end

local difficultyOptions = {
  { label = "Casual", value = 0.75 },
  { label = "Realistic", value = 1.0 },
  { label = "Hardcore", value = 1.5 }
}

local sleepSpeedOptions = {
  { label = "Slow", value = 0.5 },
  { label = "Normal", value = 1.0 },
  { label = "Fast", value = 2.0 }
}

local function settingsTable(name)
  if name == "gameplay" then
    return gameplaySettings()
  end
  return hudSettings()
end

local function buildSettingsRows()
  return {
    { kind = "header", label = "HUD" },
    { kind = "toggle", label = "HUD meters", table = "hud", key = "enabled" },
    { kind = "toggle", label = "Hover tooltips", table = "hud", key = "tooltips" },
    { kind = "toggle", label = "Compact bars", table = "hud", key = "compact" },
    { kind = "toggle", label = "Always show values", table = "hud", key = "alwaysShowValues" },
    { kind = "toggle", label = "Pulse on threshold", table = "hud", key = "pulse" },
    { kind = "toggle", label = "Thirst bar", table = "hud", key = "showThirst" },
    { kind = "toggle", label = "Fatigue bar", table = "hud", key = "showFatigue" },
    { kind = "toggle", label = "Bladder bar", table = "hud", key = "showBladder" },
    { kind = "toggle", label = "Hygiene bar", table = "hud", key = "showHygiene" },
    { kind = "button", label = "Reset HUD position", action = "resetHudPosition" },
    { kind = "header", label = "Needs" },
    { kind = "toggle", label = "Thirst", table = "gameplay", key = "thirstEnabled" },
    { kind = "toggle", label = "Fatigue", table = "gameplay", key = "fatigueEnabled" },
    { kind = "toggle", label = "Bladder", table = "gameplay", key = "bladderEnabled" },
    { kind = "toggle", label = "Hygiene", table = "gameplay", key = "hygieneEnabled" },
    { kind = "header", label = "Gameplay" },
    { kind = "toggle", label = "Warnings", table = "gameplay", key = "warnings" },
    { kind = "toggle", label = "Consequences", table = "gameplay", key = "consequences" },
    { kind = "toggle", label = "Feedback", table = "gameplay", key = "feedback" },
    { kind = "toggle", label = "Day/night fatigue", table = "gameplay", key = "circadian" },
    { kind = "toggle", label = "Rested bonus", table = "gameplay", key = "rested" },
    { kind = "toggle", label = "Environment effects", table = "gameplay", key = "environment" },
    { kind = "cycle", label = "Difficulty", table = "gameplay", key = "rateScale", options = difficultyOptions },
    { kind = "cycle", label = "Sleep recovery", table = "gameplay", key = "sleepSpeed", options = sleepSpeedOptions }
  }
end

local function cycleLabel(options, value)
  for _, option in ipairs(options) do
    if math.abs(option.value - value) < 0.001 then
      return option.label
    end
  end
  return string.format("%.2f", value)
end

local function advanceCycle(options, value)
  local current = 1
  for index, option in ipairs(options) do
    if math.abs(option.value - value) < 0.001 then
      current = index
      break
    end
  end
  local nextIndex = current + 1
  if nextIndex > #options then
    nextIndex = 1
  end
  return options[nextIndex].value
end

local settingsRowRects = {}
local settingsCloseRect

local settingsRowHeight = 15
local settingsPadding = 12
local settingsTitleHeight = 22
local settingsCloseArea = 42
local settingsColumnWidth = 224
local settingsMinColumnWidth = 150
local settingsColumnGap = 16
local settingsMargin = 6

local function settingsSectionGroups(rows, columnCount)
  local sections = {}
  for index, row in ipairs(rows) do
    if row.kind == "header" or #sections == 0 then
      table.insert(sections, {})
    end
    table.insert(sections[#sections], index)
  end

  local sectionCount = #sections
  if columnCount > sectionCount then
    columnCount = sectionCount
  end
  if columnCount <= 1 then
    local group = {}
    for index = 1, #rows do
      table.insert(group, index)
    end
    return {group}
  end

  local bestMax
  local bestSpread
  local bestGroups

  local function evaluate(groups)
    local maxCount = 0
    local minCount = math.huge
    for _, group in ipairs(groups) do
      local count = 0
      for _, sectionIndex in ipairs(group) do
        count = count + #sections[sectionIndex]
      end
      if count > maxCount then
        maxCount = count
      end
      if count < minCount then
        minCount = count
      end
    end
    local spread = maxCount - minCount
    if bestMax == nil or maxCount < bestMax
        or (maxCount == bestMax and spread < bestSpread) then
      bestMax = maxCount
      bestSpread = spread
      bestGroups = {}
      for groupIndex, group in ipairs(groups) do
        local saved = {}
        for _, sectionIndex in ipairs(group) do
          table.insert(saved, sectionIndex)
        end
        bestGroups[groupIndex] = saved
      end
    end
  end

  local function recurse(startSection, remaining, groups)
    if remaining <= 1 then
      local group = {}
      for sectionIndex = startSection, sectionCount do
        table.insert(group, sectionIndex)
      end
      table.insert(groups, group)
      evaluate(groups)
      table.remove(groups)
      return
    end
    local lastStart = sectionCount - remaining + 1
    for endSection = startSection, lastStart do
      local group = {}
      for sectionIndex = startSection, endSection do
        table.insert(group, sectionIndex)
      end
      table.insert(groups, group)
      recurse(endSection + 1, remaining - 1, groups)
      table.remove(groups)
    end
  end

  recurse(1, columnCount, {})

  local result = {}
  for groupIndex, group in ipairs(bestGroups) do
    local rowGroup = {}
    for _, sectionIndex in ipairs(group) do
      for _, rowIndex in ipairs(sections[sectionIndex]) do
        table.insert(rowGroup, rowIndex)
      end
    end
    result[groupIndex] = rowGroup
  end
  return result
end

local function computeSettingsLayout(rows, canvasSize)
  local availableHeight = canvasSize[2] - 2 * settingsMargin
  local maxColumnsByWidth = math.floor(
    (canvasSize[1] - 2 * settingsMargin + settingsColumnGap)
      / (settingsMinColumnWidth + settingsColumnGap)
  )
  if maxColumnsByWidth < 1 then
    maxColumnsByWidth = 1
  end
  local maxColumns = math.min(maxColumnsByWidth, #rows)
  if maxColumns < 1 then
    maxColumns = 1
  end

  local chosenGroups
  local chosenHeight
  for columnCount = 1, maxColumns do
    local groups = settingsSectionGroups(rows, columnCount)
    local maxRows = 0
    for _, group in ipairs(groups) do
      if #group > maxRows then
        maxRows = #group
      end
    end
    chosenGroups = groups
    chosenHeight = settingsTitleHeight + maxRows * settingsRowHeight
      + settingsCloseArea + settingsPadding
    if chosenHeight <= availableHeight then
      break
    end
  end

  local columnCount = #chosenGroups
  local columnWidth = math.min(
    settingsColumnWidth,
    math.floor(
      (canvasSize[1] - 2 * settingsMargin - (columnCount - 1) * settingsColumnGap)
        / columnCount
    )
  )
  if columnWidth < 120 then
    columnWidth = 120
  end
  local panelWidth = columnCount * columnWidth
    + (columnCount - 1) * settingsColumnGap
  local panelLeft = math.floor((canvasSize[1] - panelWidth) / 2)
  if panelLeft < settingsMargin then
    panelLeft = settingsMargin
  end
  local panelBottom = math.floor((canvasSize[2] - chosenHeight) / 2)
  local maxBottom = canvasSize[2] - chosenHeight - settingsMargin
  if maxBottom < settingsMargin then
    maxBottom = settingsMargin
  end
  if panelBottom > maxBottom then
    panelBottom = maxBottom
  end
  if panelBottom < settingsMargin then
    panelBottom = settingsMargin
  end
  local panelTop = panelBottom + chosenHeight

  local firstRowTop = panelTop - settingsTitleHeight - 4
  local rowRects = {}
  for columnIndex, group in ipairs(chosenGroups) do
    local contentLeft = panelLeft + settingsPadding
      + (columnIndex - 1) * (columnWidth + settingsColumnGap)
    local contentRight = contentLeft + columnWidth - 2 * settingsPadding
    for localIndex, rowIndex in ipairs(group) do
      local rowTop = firstRowTop - (localIndex - 1) * settingsRowHeight
      rowRects[rowIndex] = {
        contentLeft,
        rowTop - settingsRowHeight,
        contentRight,
        rowTop
      }
    end
  end

  local closeTop = panelBottom + settingsPadding + 16
  return {
    panel = {panelLeft, panelBottom, panelLeft + panelWidth, panelTop},
    centerX = panelLeft + panelWidth / 2,
    titleY = panelTop - settingsTitleHeight / 2 - 2,
    hintY = closeTop + 8,
    rowRects = rowRects,
    closeRect = {
      panelLeft + panelWidth / 2 - 30,
      closeTop - 16,
      panelLeft + panelWidth / 2 + 30,
      closeTop
    }
  }
end

local function drawSettingsOverlay()
  local rows = buildSettingsRows()
  local canvasSize = hudCanvas:size()
  local layout = computeSettingsLayout(rows, canvasSize)
  local panel = layout.panel
  local left, bottom, right, top = panel[1], panel[2], panel[3], panel[4]
  local textColor = hudTextColor()

  hudCanvas:drawRect({0, 0, canvasSize[1], canvasSize[2]}, {0, 0, 0, 150})
  hudCanvas:drawRect(panel, needsConfig.hud.borderColor)
  hudCanvas:drawRect(
    {left + 1, bottom + 1, right - 1, top - 1},
    needsConfig.hud.backgroundColor
  )
  hudCanvas:drawText(
    "Needs Settings",
    {
      position = {layout.centerX, layout.titleY},
      horizontalAnchor = "mid",
      verticalAnchor = "mid"
    },
    9,
    hudAccentColor()
  )

  local mouse = hudCanvas:mousePosition()
  settingsRowRects = layout.rowRects
  for index, row in ipairs(rows) do
    local rowRect = layout.rowRects[index]

    if row.kind == "header" then
      hudCanvas:drawText(
        row.label,
        {
          position = {rowRect[1] + 2, rowRect[2] + settingsRowHeight / 2},
          horizontalAnchor = "left",
          verticalAnchor = "mid"
        },
        8,
        hudAccentColor()
      )
    elseif row.kind == "button" then
      local buttonRect = {rowRect[1], rowRect[2] + 1, rowRect[3], rowRect[4] - 1}
      local hovered = pointInsideRect(mouse, buttonRect)
      hudCanvas:drawRect(buttonRect, needsConfig.hud.borderColor)
      hudCanvas:drawRect(
        {buttonRect[1] + 1, buttonRect[2] + 1, buttonRect[3] - 1, buttonRect[4] - 1},
        hovered and hudAccentColor() or needsConfig.hud.backgroundColor
      )
      hudCanvas:drawText(
        row.label,
        {
          position = {(buttonRect[1] + buttonRect[3]) / 2, buttonRect[2] + settingsRowHeight / 2},
          horizontalAnchor = "mid",
          verticalAnchor = "mid"
        },
        8,
        textColor
      )
    else
      if pointInsideRect(mouse, rowRect) then
        hudCanvas:drawRect(rowRect, {22, 51, 75, 200})
      end

      local target = settingsTable(row.table)
      local boxSize = 9
      local boxLeft = rowRect[1] + 2
      local boxBottom = rowRect[2] + (settingsRowHeight - boxSize) / 2
      hudCanvas:drawRect(
        {boxLeft, boxBottom, boxLeft + boxSize, boxBottom + boxSize},
        needsConfig.hud.borderColor
      )

      local label = row.label
      if row.kind == "toggle" then
        if target[row.key] then
          hudCanvas:drawRect(
            {boxLeft + 2, boxBottom + 2, boxLeft + boxSize - 2, boxBottom + boxSize - 2},
            textColor
          )
        end
      else
        label = row.label .. ": " .. cycleLabel(row.options, target[row.key])
      end

      hudCanvas:drawText(
        label,
        {
          position = {boxLeft + boxSize + 6, rowRect[2] + settingsRowHeight / 2},
          horizontalAnchor = "left",
          verticalAnchor = "mid"
        },
        8,
        textColor
      )
    end
  end

  hudCanvas:drawText(
    stringFor("settings.helpHint", "Type /xneeds help for details"),
    {
      position = {layout.centerX, layout.hintY},
      horizontalAnchor = "mid",
      verticalAnchor = "mid"
    },
    7,
    needsConfig.hud.borderColor
  )
  settingsCloseRect = layout.closeRect
  local closeHovered = pointInsideRect(mouse, settingsCloseRect)
  hudCanvas:drawRect(settingsCloseRect, needsConfig.hud.borderColor)
  hudCanvas:drawRect(
    {
      settingsCloseRect[1] + 1,
      settingsCloseRect[2] + 1,
      settingsCloseRect[3] - 1,
      settingsCloseRect[4] - 1
    },
    closeHovered and hudAccentColor() or needsConfig.hud.backgroundColor
  )
  hudCanvas:drawText(
    "Close",
    {
      position = {layout.centerX, settingsCloseRect[2] + 8},
      horizontalAnchor = "mid",
      verticalAnchor = "mid"
    },
    8,
    textColor
  )
end

local function handleSettingsClick()
  if type(input) ~= "table" or type(input.mouseDown) ~= "function" then
    return
  end
  local ok, clicks = pcall(input.mouseDown, "MouseLeft")
  if not ok or type(clicks) ~= "table" or #clicks == 0 then
    return
  end
  local positionOk, mouse = pcall(function()
    return hudCanvas:mousePosition()
  end)
  if not positionOk then
    return
  end

  if pointInsideRect(mouse, settingsCloseRect) then
    settingsOpen = false
    return
  end

  local rows = buildSettingsRows()
  for index, rowRect in ipairs(settingsRowRects) do
    if pointInsideRect(mouse, rowRect) then
      local row = rows[index]
      if row then
        if row.kind == "toggle" then
          local target = settingsTable(row.table)
          target[row.key] = not target[row.key]
        elseif row.kind == "cycle" then
          local target = settingsTable(row.table)
          target[row.key] = advanceCycle(row.options, target[row.key])
        elseif row.kind == "button" and row.action == "resetHudPosition" then
          local hud = hudSettings()
          hud.hudOffsetX = 0
          hud.hudOffsetY = 0
        end
      end
      return
    end
  end
end

local function drawHud(sleeping)
  if not hudCanvas then
    return
  end

  hudCanvas:clear()
  hudBarRects = {}
  hudDragHandleRect = nil

  local settings = hudSettings()

  if hudLayout and settings.enabled then
    local canvasSize = hudCanvas:size()
    local height = needsConfig.hud.barHeight
    local step = height + needsConfig.hud.barGap
    local firstY = canvasSize[2] + hudTopOffset() - height

    local bars = {
      {
        name = "thirst",
        show = settings.showThirst,
        ratio = storage.needs.thirst,
        color = needsConfig.hud.thirstColor,
        icon = needsConfig.hud.icons.thirst
      },
      {
        name = "fatigue",
        show = settings.showFatigue,
        ratio = storage.needs.fatigue,
        color = needsConfig.hud.fatigueColor,
        icon = needsConfig.hud.icons.fatigue
      },
      {
        name = "bladder",
        show = settings.showBladder,
        ratio = storage.needs.bladder,
        color = needsConfig.hud.bladderColor,
        icon = needsConfig.hud.icons.bladder
      },
      {
        name = "hygiene",
        show = settings.showHygiene,
        ratio = 100 - storage.needs.hygiene,
        color = needsConfig.hud.hygieneColor,
        icon = needsConfig.hud.icons.hygiene
      }
    }

    local row = 0
    for _, bar in ipairs(bars) do
      if bar.show then
        drawNeedBar(bar.name, firstY - step * row, bar.ratio, bar.color, bar.icon)
        row = row + 1
      end
    end

    if row > 0 then
      local iconSize = hudIconSize()
      local trailing = iconSize > 0 and (needsConfig.hud.iconGap + iconSize) or 0
      local left = hudAnchorX() + hudBarWidth() + trailing + 3
      local bottom = firstY - dragHandleSize - 2
      hudDragHandleRect = {left, bottom, left + dragHandleSize, bottom + dragHandleSize}
      drawHudDragHandle()
    end

    if settings.tooltips then
      local hovered = hoveredNeedName()
      if hovered then
        local hoverRect = hudBarRects[hovered]
        drawNeedTooltip(hovered, sleeping, hoverRect[4])
      end
    end
  end

  if settingsOpen then
    drawSettingsOverlay()
  end
end

local function xStarboundAvailable()
  return type(interface) == "table" and type(root.assetsByExtension) == "function"
end

function init()
  if not xStarboundAvailable() then
    sb.logWarn("[xneeds_v0] xStarbound is required; Needs is disabled on this client.")
    return
  end

  needsConfig = loadConfig()
  normalizeStorage()
  resolveHygieneLiquidIds()
  _, damageTakenHeartbeat = status.damageTakenSince()
  _, damageInflictedHeartbeat = status.inflictedDamageSince()
  refreshWarningLevels(false)

  hudLayout = loadHudLayout()
  if type(interface) == "table" and type(interface.bindCanvas) == "function" then
    hudCanvas = interface.bindCanvas(needsConfig.hud.canvasName)
    if not hudCanvas then
      sb.logWarn("[xneeds_v0] HUD disabled: xStarbound canvas could not be bound")
    end
  end

  message.setHandler("xneeds_v0.consume", onConsumedItem)
  message.setHandler("xneeds_v0.caffeine", onCaffeineUpdate)
  message.setHandler("xneeds_v0.get", debugGet)
  message.setHandler("xneeds_v0.set", debugSet)
  message.setHandler("xneeds_v0.reset", debugReset)
  if needsConfig.debug.commandsEnabled then
    message.setHandler({
      name = "/xneeds",
      passName = false,
      localOnly = true
    }, needsCommand)
  end

  if needsConfig.debug.logInitialization then
    sb.logInfo("[xneeds_v0] initialized storage schema %s", storage.needs.version)
  end
end

function update(dt)
  if not needsConfig then
    return
  end
  if not isFiniteNumber(dt) or dt <= 0 then
    return
  end

  beverageFeedbackCooldown = math.max(0, beverageFeedbackCooldown - dt)

  for needName, remaining in pairs(pulseTimers) do
    pulseTimers[needName] = math.max(0, remaining - dt)
  end

  if settingsOpen then
    handleSettingsClick()
  end

  handleHudDrag()

  local sleeping = isSleeping()
  local needsDt = dt

  if needEnabled("fatigue") then
    trackSleepRest(sleeping, dt)
  end

  if needEnabled("hygiene") then
    pollCombatDirtiness()
    trackHygieneActivity(needsDt)
  else
    pendingCombatDirtiness = 0
    pendingRunningSeconds = 0
    pendingJumpingSeconds = 0
  end

  updateAccumulator = math.min(
    updateAccumulator + needsDt,
    needsConfig.maxCatchupSeconds
  )

  if updateAccumulator >= needsConfig.updateInterval then
    local elapsed = updateAccumulator
    updateAccumulator = 0
    advanceNeeds(elapsed)
  end

  applyConsequences()
  drawHud(sleeping)
end

function uninit()
  if not needsConfig then
    return
  end
  status.clearPersistentEffects(consequenceCategory)
  if hudCanvas then
    hudCanvas:clear()
  end
end
