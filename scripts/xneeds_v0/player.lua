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
local hudBarRects = {}

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

local function loadConfig()
  local config = root.assetJson("/xneeds_v0.config")
  local requiredSections = {
    "defaults",
    "thirst",
    "fatigue",
    "bladder",
    "beverages",
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
  if type(beverages.defaultProfile) ~= "string"
      or beverages.defaultProfile == ""
      or type(beverages.profiles) ~= "table"
      or type(beverages.itemProfiles) ~= "table"
      or type(beverages.classificationRules) ~= "table" then
    error("[xneeds_v0] beverages configuration is invalid")
  end
  requireNumber(
    beverages.caffeineAwakeGainMultiplier,
    "beverages.caffeineAwakeGainMultiplier"
  )
  if beverages.caffeineAwakeGainMultiplier < 0
      or beverages.caffeineAwakeGainMultiplier > 1 then
    error("[xneeds_v0] beverages.caffeineAwakeGainMultiplier must be between 0 and 1")
  end

  for profileName, profile in pairs(beverages.profiles) do
    local path = "beverages.profiles." .. tostring(profileName)
    if type(profileName) ~= "string" or profileName == ""
        or type(profile) ~= "table" then
      error("[xneeds_v0] beverage profile names and values must be valid")
    end
    requireNumber(profile.thirstRecovery, path .. ".thirstRecovery")
    requireNumber(profile.bladderGain, path .. ".bladderGain")
    requireNumber(profile.fatigueChange, path .. ".fatigueChange")
    requireNonnegativeNumber(profile.caffeineDuration, path .. ".caffeineDuration")
  end
  if type(beverages.profiles[beverages.defaultProfile]) ~= "table" then
    error("[xneeds_v0] beverages.defaultProfile does not name a profile")
  end

  for itemName, profileName in pairs(beverages.itemProfiles) do
    if type(itemName) ~= "string" or itemName == ""
        or type(profileName) ~= "string"
        or type(beverages.profiles[profileName]) ~= "table" then
      error("[xneeds_v0] beverages.itemProfiles contains an invalid mapping")
    end
  end
  for index, rule in ipairs(beverages.classificationRules) do
    local path = string.format("beverages.classificationRules[%s]", index)
    if type(rule) ~= "table"
        or type(rule.profile) ~= "string"
        or type(beverages.profiles[rule.profile]) ~= "table" then
      error("[xneeds_v0] " .. path .. " has an invalid profile")
    end
    requireStringList(rule.patterns, path .. ".patterns")
  end
  local feedback = beverages.feedback
  if type(feedback) ~= "table"
      or type(feedback.enabled) ~= "boolean"
      or type(feedback.profileMessages) ~= "table"
      or type(feedback.dehydratingMessage) ~= "string"
      or feedback.dehydratingMessage == "" then
    error("[xneeds_v0] beverages.feedback configuration is invalid")
  end
  requireNonnegativeNumber(
    feedback.cooldownSeconds,
    "beverages.feedback.cooldownSeconds"
  )
  for profileName, messageText in pairs(feedback.profileMessages) do
    if type(beverages.profiles[profileName]) ~= "table"
        or type(messageText) ~= "string"
        or messageText == "" then
      error("[xneeds_v0] beverages.feedback.profileMessages contains an invalid entry")
    end
  end

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

local function environmentDecayMultiplier(biomeName)
  local multiplier = needsConfig.hygiene.environment.biomeDecayMultipliers[biomeName] or 1
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
  local passiveLoss = needsConfig.hygiene.decayPerSecond * elapsed * decayMultiplier
  local activityLoss = (
    environment.runningExtraDecayPerSecond * pendingRunningSeconds
      + environment.jumpingExtraDecayPerSecond * pendingJumpingSeconds
  ) * decayMultiplier
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
    local newLevel = needLevel(problemValue(needName))
    local previousLevel = warningLevels[needName] or 0

    if notify and needsConfig.warnings.enabled and newLevel > previousLevel then
      local messages = needsConfig.warnings.messages[needName]
      local key = needsConfig.thresholds[newLevel].key
      local messageText = type(messages) == "table" and messages[key] or nil
      if type(messageText) == "string" and messageText ~= "" then
        player.queueStatusMessage(messageText)
      end
    end

    warningLevels[needName] = newLevel
  end
end

local function highestConsequenceLevel()
  local level = 0
  for needName in pairs(needNames) do
    level = math.max(level, needLevel(problemValue(needName)))
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

  for needName in pairs(needNames) do
    local level = needLevel(problemValue(needName))
    result.levels[needName] = level

    if needsConfig.consequences.enabled and level > 0 then
      local tierKey = needsConfig.thresholds[level].key
      local profile = needsConfig.consequences.profiles[needName][tierKey]
      for _, dimension in ipairs(consequenceDimensions) do
        result[dimension] = result[dimension] * (profile[dimension] or 1)
      end
    end
  end

  if needsConfig.consequences.enabled then
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

local function advanceNeeds(elapsed)
  normalizeStorage()

  if isSleeping() then
    storage.needs.fatigue = storage.needs.fatigue
      - needsConfig.fatigue.sleepRecoveryPerSecond * elapsed
  else
    local fatigueGainMultiplier = caffeineActive()
      and needsConfig.beverages.caffeineAwakeGainMultiplier
      or 1
    storage.needs.fatigue = storage.needs.fatigue
      + needsConfig.fatigue.awakeGainPerSecond * fatigueGainMultiplier * elapsed
  end

  storage.needs.thirst = storage.needs.thirst
    + needsConfig.thirst.passiveGainPerSecond * elapsed

  local reliefRate = bladderReliefRate()
  if reliefRate > 0 then
    storage.needs.bladder = storage.needs.bladder - reliefRate * elapsed
  else
    storage.needs.bladder = storage.needs.bladder
      + needsConfig.bladder.passiveGainPerSecond * elapsed
  end

  local hygieneState = hygieneEnvironment(elapsed)
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
  pendingRunningSeconds = 0
  pendingJumpingSeconds = 0

  for needName in pairs(needNames) do
    storage.needs[needName] = clampNeed(storage.needs[needName])
  end

  if needsConfig.debug.logRecoveryEvents then
    if reliefRate > 0 then
      sb.logInfo("[xneeds_v0] bladder relief rate: %s", reliefRate)
    end
    if hygieneState.recoveryRate > 0 then
      sb.logInfo("[xneeds_v0] hygiene recovery rate: %s", hygieneState.recoveryRate)
    end
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

local function beverageSearchText(itemName, details)
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

local function beverageProfile(itemName, details)
  local beverages = needsConfig.beverages
  local explicit = details.parameters[beverages.profileParameter]
  if explicit == nil then
    explicit = details.config[beverages.profileParameter]
  end

  if explicit == false then
    return beverages.defaultProfile,
      beverages.profiles[beverages.defaultProfile],
      "default forced by item parameter"
  elseif type(explicit) == "string" and beverages.profiles[explicit] then
    return explicit, beverages.profiles[explicit], "item parameter"
  end

  local mapped = beverages.itemProfiles[string.lower(itemName)]
  if mapped and beverages.profiles[mapped] then
    return mapped, beverages.profiles[mapped], "exact item mapping"
  end

  local searchText = beverageSearchText(itemName, details)
  for _, rule in ipairs(beverages.classificationRules) do
    for _, pattern in ipairs(rule.patterns) do
      if string.find(searchText, string.lower(pattern), 1, true) then
        return rule.profile,
          beverages.profiles[rule.profile],
          "classification rule: " .. pattern
      end
    end
  end

  return beverages.defaultProfile,
    beverages.profiles[beverages.defaultProfile],
    "default"
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

local function queueBeverageFeedback(profileName, thirstRecovery)
  local feedback = needsConfig.beverages.feedback
  if not feedback.enabled or beverageFeedbackCooldown > 0 then
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

local function onConsumedItem(_, isLocal, itemName)
  -- The generated one-shot drink effect forwards the consumed item name here.
  if not isLocal then
    return
  end

  local details = itemDetails(itemName)
  if not details then
    return
  end

  grantConsumedReturn(itemName)

  local profileName, profile = beverageProfile(itemName, details)

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
  if isFiniteNumber(bladderGain) then
    storage.needs.bladder = clampNeed(storage.needs.bladder + bladderGain)
  end
  if isFiniteNumber(thirstRecovery) then
    storage.needs.thirst = clampNeed(storage.needs.thirst - thirstRecovery)
  end
  if isFiniteNumber(fatigueChange) then
    storage.needs.fatigue = clampNeed(storage.needs.fatigue + fatigueChange)
  end
  if isFiniteNumber(caffeineDuration) and caffeineDuration > 0 then
    status.addEphemeralEffect(
      needsConfig.beverages.caffeineEffect,
      caffeineDuration,
      entity.id()
    )
    caffeineRemainingSeconds = math.max(caffeineRemainingSeconds, caffeineDuration)
  end
  queueBeverageFeedback(profileName, thirstRecovery)
  refreshWarningLevels(true)

  if needsConfig.debug.logDrinkEvents then
    sb.logInfo(
      "[xneeds_v0] drink event: %s profile %s, bladder %+g, thirst recovery %+g, fatigue %+g, caffeine %gs",
      itemName,
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
    "^#f3d36a;<Needs V1.7>^reset;\n"
      .. "Thirst: ^cyan;%.1f^reset; [%s]\n"
      .. "Fatigue: ^cyan;%.1f^reset; [%s]\n"
      .. "Bladder: ^cyan;%.1f^reset; [%s]\n"
      .. "Hygiene: ^cyan;%.1f^reset; (dirtiness %.1f) [%s]\n"
      .. "Caffeinated: %s\n"
      .. "Multipliers: speed %.0f%%, jump %.0f%%, power %.0f%%, energy regen %.0f%%, protection %.0f%%\n"
      .. "Environment: biome %s x%.2f, liquid %s (%s), rain/wet %s\n"
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
    consequences.speed * 100,
    consequences.jump * 100,
    consequences.power * 100,
    consequences.energyRegen * 100,
    consequences.protection * 100,
    hygieneState.biome,
    hygieneState.biomeMultiplier,
    hygieneState.liquid,
    hygieneState.liquidClass,
    hygieneState.rainEffect and "yes" or "no",
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
    .. "^cyan;/xneeds preset <normal|noticeable|serious|urgent|critical>^reset;\n"
    .. "^cyan;/xneeds reset^reset;"
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

local drinkAuditCache

local function detectedDrinkItems()
  if drinkAuditCache then
    return drinkAuditCache
  end

  local items = {}
  local seen = {}
  local beverages = needsConfig.beverages
  local ok, assetPaths = pcall(root.assetsByExtension, "consumable")
  if ok and type(assetPaths) == "table" then
    for _, assetPath in ipairs(assetPaths) do
      local assetOk, item = pcall(root.assetJson, assetPath)
      if assetOk and type(item) == "table" then
        local itemName = type(item.itemName) == "string" and item.itemName or ""
        local category = type(item.category) == "string"
          and string.lower(item.category) or ""
        local explicitProfile = item[beverages.profileParameter]
        local explicitlyConfigured = beverages.itemProfiles[string.lower(itemName)] ~= nil
          or type(explicitProfile) == "string"
          or explicitProfile == false
        if itemName ~= "" and not seen[itemName]
            and (category == "drink" or explicitlyConfigured) then
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
  drinkAuditCache = items
  return items
end

local function beverageAuditText(details)
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

local function beverageAudit(arguments)
  local items = detectedDrinkItems()
  if #items == 0 then
    return "Beverage audit: no detected drinks."
  end

  local showDetails = arguments[2] == "details"
  local filter = showDetails and nil or arguments[2]
  local profileFilter
  local nameFilter
  if filter and filter ~= "all" then
    if needsConfig.beverages.profiles[filter] then
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
      local profileName, _, source = beverageProfile(itemName, details)
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
            beverageAuditText(details)
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
    "Beverage audit: %d detected. Profiles: %s\n%s (%d):\n%s",
    #items,
    table.concat(profileSummary, ", "),
    scope,
    #matches,
    table.concat(lines, "\n")
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
      return commandHelp("Unknown beverage item.")
    end
    local profileName, profile, profileSource = beverageProfile(itemName, details)
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
    return string.format("Beverage %s\nProfile: %s [%s]\n%s\n%s\n%s\n%s",
      itemName,
      profileName,
      profileSource,
      beverageDiagnosticLine("Thirst", thirstRecovery, thirstSource, true),
      beverageDiagnosticLine("Bladder", bladderGain, bladderSource, false),
      beverageDiagnosticLine("Fatigue", fatigueChange, fatigueSource, false),
      beverageDiagnosticLine("Caffeine seconds", caffeineDuration, caffeineSource, false)
    )
  elseif operation == "beverages" then
    return beverageAudit(arguments)
  elseif operation == "help" then
    return commandHelp()
  elseif operation == "reset" then
    storage.needs = migrateNeeds({})
    pendingCombatDirtiness = 0
    pendingRunningSeconds = 0
    pendingJumpingSeconds = 0
    lastHygieneEnvironment = {}
    refreshWarningLevels(false)
    return "Needs reset.\n" .. commandStatus()
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
      return commandHelp("Unknown preset.")
    end
    setCommandNeed("all", value)
    return string.format("Applied %s preset.\n%s", arguments[2], commandStatus())
  elseif operation == "set" or operation == "add" then
    local needName = commandNeedName(arguments[2])
    local value = tonumber(arguments[3])
    if not needName or not isFiniteNumber(value) then
      return commandHelp("Missing or invalid need/value.")
    end
    if operation == "set" then
      setCommandNeed(needName, value)
    else
      addCommandNeed(needName, value)
    end
    return commandStatus()
  end

  return commandHelp("Unknown operation.")
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
  return needsConfig.hud.tooltips.tierColors[key]
    or needsConfig.hud.tooltips.textColor
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
  if not needsConfig.consequences.enabled then
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
  local problem = problemValue(needName)
  local level = needLevel(problem)
  local textColor = needsConfig.hud.tooltips.textColor
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
  local anchorX = hudLayout.x
    + hudLayout.width
    + needsConfig.hud.iconGap
    + needsConfig.hud.iconSize
    + tooltips.gap
  if anchorX + width > canvasSize[1] - 2 then
    anchorX = math.max(2, hudLayout.x - tooltips.gap - width)
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
  local x = hudLayout.x
  local width = hudLayout.width
  local height = needsConfig.hud.barHeight

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
        color
      )
    end
  end

  local iconSize = needsConfig.hud.iconSize
  local iconCenter = {
    x + width + needsConfig.hud.iconGap + iconSize / 2,
    y + height / 2
  }
  hudCanvas:drawImage(
    iconPath,
    iconCenter,
    needsConfig.hud.iconScale,
    {255, 255, 255, 255},
    true
  )

  local step = height + needsConfig.hud.barGap
  local hoverPad = math.max(0, (step - height) / 2)
  hudBarRects[needName] = {
    x,
    y - hoverPad,
    x + width + needsConfig.hud.iconGap + iconSize,
    y + height + hoverPad
  }
end

local function drawHud(sleeping)
  if not hudCanvas then
    return
  end

  hudCanvas:clear()
  hudBarRects = {}

  local canvasSize = hudCanvas:size()
  local height = needsConfig.hud.barHeight
  local step = height + needsConfig.hud.barGap
  local firstY = canvasSize[2] + hudLayout.topOffset - height

  if needsConfig.hud.enabled then
    drawNeedBar(
      "thirst",
      firstY,
      storage.needs.thirst,
      needsConfig.hud.thirstColor,
      needsConfig.hud.icons.thirst
    )
    drawNeedBar(
      "fatigue",
      firstY - step,
      storage.needs.fatigue,
      needsConfig.hud.fatigueColor,
      needsConfig.hud.icons.fatigue
    )
    drawNeedBar(
      "bladder",
      firstY - step * 2,
      storage.needs.bladder,
      needsConfig.hud.bladderColor,
      needsConfig.hud.icons.bladder
    )
    drawNeedBar(
      "hygiene",
      firstY - step * 3,
      100 - storage.needs.hygiene,
      needsConfig.hud.hygieneColor,
      needsConfig.hud.icons.hygiene
    )
  end

  if needsConfig.hud.enabled and needsConfig.hud.tooltips.enabled then
    local hovered = hoveredNeedName()
    if hovered then
      local hoverRect = hudBarRects[hovered]
      drawNeedTooltip(hovered, sleeping, hoverRect[4])
    end
  end
end

function init()
  needsConfig = loadConfig()
  normalizeStorage()
  resolveHygieneLiquidIds()
  _, damageTakenHeartbeat = status.damageTakenSince()
  _, damageInflictedHeartbeat = status.inflictedDamageSince()
  refreshWarningLevels(false)

  if needsConfig.hud.enabled then
    hudLayout = loadHudLayout()
    if hudLayout then
      hudCanvas = interface.bindCanvas(needsConfig.hud.canvasName)
      if not hudCanvas then
        sb.logWarn("[xneeds_v0] HUD disabled: xStarbound canvas could not be bound")
      end
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
  if not isFiniteNumber(dt) or dt <= 0 then
    return
  end

  beverageFeedbackCooldown = math.max(0, beverageFeedbackCooldown - dt)

  local sleeping = isSleeping()
  local needsDt = dt

  pollCombatDirtiness()
  trackHygieneActivity(needsDt)

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
  status.clearPersistentEffects(consequenceCategory)
  if hudCanvas then
    hudCanvas:clear()
  end
end
