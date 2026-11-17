---@class Actor_776862623:WoWActor
local Actor_776862623 = {}

local WoWActor = require("EnvLua.Core.WoWActor")

--- Callback after Actor construction is complete.
function Actor_776862623:OnPostConstruct() 

end

--- Callback for Actor BeginPlay.
function Actor_776862623:OnReceiveBeginPlay() 

end

--- Callback for Actor EndPlay.
---@param EndPlayReason EndPlayReason End play reason.
function Actor_776862623:OnReceiveEndPlay(EndPlayReason) 

end

local CActor_776862623 = WoWClass(WoWActor, nil, Actor_776862623)
return CActor_776862623
