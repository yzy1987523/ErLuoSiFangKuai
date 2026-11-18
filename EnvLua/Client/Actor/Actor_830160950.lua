---@class Actor_830160950:WoWActor
local Actor_830160950 = {}

local WoWActor = require("EnvLua.Core.WoWActor")

--- Callback after Actor construction is complete.
function Actor_830160950:OnPostConstruct() 

end

--- Callback for Actor BeginPlay.
function Actor_830160950:OnReceiveBeginPlay() 

end

--- Callback for Actor EndPlay.
---@param EndPlayReason EndPlayReason End play reason.
function Actor_830160950:OnReceiveEndPlay(EndPlayReason) 

end

local CActor_830160950 = WoWClass(WoWActor, nil, Actor_830160950)
return CActor_830160950
