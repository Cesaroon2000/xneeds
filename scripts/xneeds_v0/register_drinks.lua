-- Runs after every asset source (including Workshop mods) has loaded.  Each
-- final consumable categorised as a drink receives a unique, invisible,
-- one-shot effect which reports the consumed item to the Needs player script.
-- Existing item assets and effect groups are extended, never replaced.

local function safeName(value)
  return string.gsub(string.lower(value), "[^a-z0-9_]", "_")
end

local function drinkPatch(effectName, effects)
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
local beverageConfig = type(needsConfig.beverages) == "table"
  and needsConfig.beverages
  or {}
local itemProfiles = type(beverageConfig.itemProfiles) == "table"
  and beverageConfig.itemProfiles
  or {}
local profileParameter = type(beverageConfig.profileParameter) == "string"
  and beverageConfig.profileParameter
  or "needsBeverageProfile"

for index, assetPath in ipairs(assets.byExtension("consumable")) do
  local item = assets.json(assetPath)
  local category = type(item.category) == "string" and string.lower(item.category) or ""
  local itemName = type(item.itemName) == "string" and item.itemName or ""
  local explicitProfile = item[profileParameter]
  local explicitlyConfigured = itemProfiles[string.lower(itemName)] ~= nil
    or type(explicitProfile) == "string"
    or explicitProfile == false

  if itemName ~= "" and (category == "drink" or explicitlyConfigured) then
    local suffix = string.format("%s_%s", safeName(itemName), index)
    local effectName = "xneedsdrink_" .. suffix
    local generatedRoot = "/xneeds_v0/generated/drinks/" .. suffix
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
    assets.add(patchPath, drinkPatch(effectName, item.effects))
    assets.patch(assetPath, patchPath)
  end
end
