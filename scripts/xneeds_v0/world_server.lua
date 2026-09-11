-- Direct, non-chat safety relay for sleep fast-forward.  A whole-game
-- timescale is permitted only for the local host while it is the sole client.

local function clientIdForUuid(uuid)
  for _, clientId in ipairs(universe.clientIds()) do
    if universe.clientUuid(clientId) == uuid then
      return clientId
    end
  end
end

local function sendFastForwardState(uuid, token)
  local clientId = clientIdForUuid(uuid)
  local allowed = clientId ~= nil
    and universe.numberOfClients() == 1
    and universe.isLocal(clientId)

  world.sendEntityMessage(
    uuid,
    "xneeds_v0.fastForwardState",
    token,
    allowed
  )
end

local function onFastForwardProbe(_, _, uuid, token)
  if type(uuid) ~= "string" or uuid == ""
      or type(token) ~= "string" or token == "" then
    return false
  end

  local clientId = clientIdForUuid(uuid)
  if clientId == nil or universe.clientWorld(clientId) ~= world.id() then
    return false
  end

  sendFastForwardState(uuid, token)
  return true
end

function init()
  message.setHandler("xneeds_v0.fastForwardProbe", onFastForwardProbe)
end
