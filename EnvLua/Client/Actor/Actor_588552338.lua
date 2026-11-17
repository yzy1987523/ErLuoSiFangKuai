---@class Actor_588552338:WoWActor
local Actor_588552338 = {}

local WoWActor = require("EnvLua.Core.WoWActor")

--- Callback after Actor construction is complete.
function Actor_588552338:OnPostConstruct() 

end

--- Callback for Actor BeginPlay.
function Actor_588552338:OnReceiveBeginPlay() 

end

--- Callback for Actor EndPlay.
---@param EndPlayReason EndPlayReason End play reason.
function Actor_588552338:OnReceiveEndPlay(EndPlayReason) 

end

local CActor_588552338 = WoWClass(WoWActor, nil, Actor_588552338)
return CActor_588552338
