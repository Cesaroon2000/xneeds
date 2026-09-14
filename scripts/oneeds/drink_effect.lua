function init()
  local itemName = config.getParameter("itemName")
  if type(itemName) == "string" and itemName ~= "" then
    world.sendEntityMessage(entity.id(), "oneeds.consume", itemName)
  end
  effect.expire()
end
