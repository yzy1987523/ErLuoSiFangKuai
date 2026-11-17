---@class Actor_2074770:WoWActor
local Actor_2074770 = {}

local WoWActor = require("EnvLua.Core.WoWActor")

--- Callback after Actor construction is complete.
function Actor_2074770:OnPostConstruct() 

end

--- Callback for Actor BeginPlay.
function Actor_2074770:OnReceiveBeginPlay() 

end

--- Callback for Actor EndPlay.
---@param EndPlayReason EndPlayReason End play reason.
function Actor_2074770:OnReceiveEndPlay(EndPlayReason) 

end

local CActor_2074770 = WoWClass(WoWActor, nil, Actor_2074770)
return CActor_2074770
