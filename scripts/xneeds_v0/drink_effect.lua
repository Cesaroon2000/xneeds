function init()
  local itemName = config.getParameter("itemName")
  if type(itemName) == "string" and itemName ~= "" then
    world.sendEntityMessage(entity.id(), "xneeds_v0.consume", itemName)
  end
  effect.expire()
end
