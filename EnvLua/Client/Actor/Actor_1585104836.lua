---@class Actor_1585104836:WoWActor
local Actor_1585104836 = {}

local WoWActor = require("EnvLua.Core.WoWActor")

--- Callback after Actor construction is complete.
function Actor_1585104836:OnPostConstruct() 

end

--- Callback for Actor BeginPlay.
function Actor_1585104836:OnReceiveBeginPlay() 

end

--- Callback for Actor EndPlay.
---@param EndPlayReason EndPlayReason End play reason.
function Actor_1585104836:OnReceiveEndPlay(EndPlayReason) 

end

local CActor_1585104836 = WoWClass(WoWActor, nil, Actor_1585104836)
return CActor_1585104836
