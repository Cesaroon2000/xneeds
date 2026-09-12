-- Runs after every asset source (including Workshop mods) has loaded.  Each
-- final consumable categorised as a drink or food receives a unique, invisible,
-- one-shot effect which reports the consumed item to the Needs player script.
-- Existing item assets and effect groups are extended, never replaced.

local function safeName(value)
  return string.gsub(string.lower(value), "[^a-z0-9_]", "_")
end

local function consumablePatch(effectName, effects)
  local descriptor = {
    effect = effectName,
    duration = 0.1
  }
  local operations = {}

  if type(effects) == "table" and #effects > 0 then
    for index, group in ipairs(effects) do
      if type(group) == "table" then
        table.insert(operations, {
          op = "add",
          path = string.format("/effects/%s/-", index - 1),
          value = descriptor
        })
      end
    end
  end

  if #operations == 0 then
    table.insert(operations, {
      op = "add",
      path = "/effects",
      value = { { descriptor } }
    })
  end

  return operations
end

local needsConfig = assets.json("/xneeds_v0.config")
local beverages = type(needsConfig.beverages) == "table" and needsConfig.beverages or {}
local foods = type(needsConfig.foods) == "table" and needsConfig.foods or {}

local bladder = type(needsConfig.bladder) == "table" and needsConfig.bladder or {}
local drinkCategory = type(bladder.drinkCategory) == "string"
  and string.lower(bladder.drinkCategory)
  or "drink"
local beverageProfiles = type(beverages.itemProfiles) == "table" and beverages.itemProfiles or {}
local beverageParameter = type(beverages.profileParameter) == "string"
  and beverages.profileParameter
  or "needsBeverageProfile"

local foodsEnabled = foods.enabled == true
local foodCategory = type(foods.category) == "string"
  and string.lower(foods.category)
  or "food"
local foodProfiles = type(foods.itemProfiles) == "table" and foods.itemProfiles or {}
local foodParameter = type(foods.profileParameter) == "string"
  and foods.profileParameter
  or "needsFoodProfile"

local function itemParameter(item, parameter)
  local value = item[parameter]
  if value == nil and type(item.parameters) == "table" then
    value = item.parameters[parameter]
  end
  return value
end

local function isExplicitlyConfigured(value, itemProfiles, lowerName)
  return type(value) == "string"
    or value == false
    or type(value) == "table"
    or itemProfiles[lowerName] ~= nil
end

for index, assetPath in ipairs(assets.byExtension("consumable")) do
  local item = assets.json(assetPath)
  local category = type(item.category) == "string" and string.lower(item.category) or ""
  local itemName = type(item.itemName) == "string" and item.itemName or ""
  local lowerName = string.lower(itemName)

  local explicitBeverage = itemParameter(item, beverageParameter)
  local isDrink = category == drinkCategory
    or isExplicitlyConfigured(explicitBeverage, beverageProfiles, lowerName)

  local explicitFood = itemParameter(item, foodParameter)
  local isFood = foodsEnabled
    and (category == foodCategory
      or isExplicitlyConfigured(explicitFood, foodProfiles, lowerName))

  if itemName ~= "" and (isDrink or isFood) then
    local suffix = string.format("%s_%s", safeName(itemName), index)
    local effectName = "xneedsdrink_" .. suffix
    local generatedRoot = "/xneeds_v0/generated/consumables/" .. suffix
    local effectPath = generatedRoot .. ".statuseffect"
    local patchPath = generatedRoot .. ".patch"

    assets.add(effectPath, {
      name = effectName,
      defaultDuration = 0.1,
      scripts = { "/scripts/xneeds_v0/drink_effect.lua" },
      effectConfig = {
        itemName = itemName
      }
    })
    assets.add(patchPath, consumablePatch(effectName, item.effects))
    assets.patch(assetPath, patchPath)
  end
end
