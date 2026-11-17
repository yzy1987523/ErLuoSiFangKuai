---@class Actor_1269798043:WoWActor
local Actor_1269798043 = {}

local WoWActor = require("EnvLua.Core.WoWActor")

--- Callback after Actor construction is complete.
function Actor_1269798043:OnPostConstruct() 

end

--- Callback for Actor BeginPlay.
function Actor_1269798043:OnReceiveBeginPlay() 

end

--- Callback for Actor EndPlay.
---@param EndPlayReason EndPlayReason End play reason.
function Actor_1269798043:OnReceiveEndPlay(EndPlayReason) 

end

local CActor_1269798043 = WoWClass(WoWActor, nil, Actor_1269798043)
return CActor_1269798043
