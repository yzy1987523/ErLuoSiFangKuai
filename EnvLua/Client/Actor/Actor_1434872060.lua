---@class Actor_1434872060:WoWActor
local Actor_1434872060 = {}

local WoWActor = require("EnvLua.Core.WoWActor")

--- Callback after Actor construction is complete.
function Actor_1434872060:OnPostConstruct() 

end

--- Callback for Actor BeginPlay.
function Actor_1434872060:OnReceiveBeginPlay() 

end

--- Callback for Actor EndPlay.
---@param EndPlayReason EndPlayReason End play reason.
function Actor_1434872060:OnReceiveEndPlay(EndPlayReason) 

end

local CActor_1434872060 = WoWClass(WoWActor, nil, Actor_1434872060)
return CActor_1434872060
