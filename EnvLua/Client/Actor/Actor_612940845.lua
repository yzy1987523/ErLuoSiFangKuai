---@class Actor_612940845:WoWActor
local Actor_612940845 = {}

local WoWActor = require("EnvLua.Core.WoWActor")

--- Callback after Actor construction is complete.
function Actor_612940845:OnPostConstruct() 

end

--- Callback for Actor BeginPlay.
function Actor_612940845:OnReceiveBeginPlay() 

end

--- Callback for Actor EndPlay.
---@param EndPlayReason EndPlayReason End play reason.
function Actor_612940845:OnReceiveEndPlay(EndPlayReason) 

end

local CActor_612940845 = WoWClass(WoWActor, nil, Actor_612940845)
return CActor_612940845
