---@class Actor_2125630218:WoWActor
local Actor_2125630218 = {}

local WoWActor = require("EnvLua.Core.WoWActor")

--- Callback after Actor construction is complete.
function Actor_2125630218:OnPostConstruct() 

end

--- Callback for Actor BeginPlay.
function Actor_2125630218:OnReceiveBeginPlay() 

end

--- Callback for Actor EndPlay.
---@param EndPlayReason EndPlayReason End play reason.
function Actor_2125630218:OnReceiveEndPlay(EndPlayReason) 

end

local CActor_2125630218 = WoWClass(WoWActor, nil, Actor_2125630218)
return CActor_2125630218
