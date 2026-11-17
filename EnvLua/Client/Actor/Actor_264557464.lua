---@class Actor_264557464:WoWActor
local Actor_264557464 = {}

local WoWActor = require("EnvLua.Core.WoWActor")

--- Callback after Actor construction is complete.
function Actor_264557464:OnPostConstruct() 

end

--- Callback for Actor BeginPlay.
function Actor_264557464:OnReceiveBeginPlay() 

end

--- Callback for Actor EndPlay.
---@param EndPlayReason EndPlayReason End play reason.
function Actor_264557464:OnReceiveEndPlay(EndPlayReason) 

end

local CActor_264557464 = WoWClass(WoWActor, nil, Actor_264557464)
return CActor_264557464
