local reportInterval = 0.5
local reportAccumulator = reportInterval

function init()
end

function update(dt)
  if type(dt) ~= "number" or dt <= 0 then
    return
  end

  reportAccumulator = reportAccumulator + dt
  if reportAccumulator < reportInterval then
    return
  end
  reportAccumulator = 0

  local ok, remaining = pcall(effect.duration)
  if ok and type(remaining) == "number" and remaining == remaining then
    world.sendEntityMessage(entity.id(), "oneeds.caffeine", remaining)
  end
end

function uninit()
end
