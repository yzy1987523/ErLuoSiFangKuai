-- ClientGameMain: editor-only GameMain for first-wave sandbox users.
-- Provides readable examples for VP events and AddEnvControlEvent usage.
---@class ClientGameMain:WoWGameMain
local ClientGameMain = {}

function ClientGameMain:ctor()
    print("[ClientGameMain]ctor")
end

--- OnStart: Primary game main start callback. Called from host bridge _OnStart after the default game-process listener is registered.
function ClientGameMain:OnStart()
    print("[ClientGameMain]OnStart")
end

--- OnGameStart: Callback when game process enters start.
function ClientGameMain:OnGameStart()
    print("[ClientGameMain]OnGameStart")
end

--- OnRoundStart: Callback when a round starts.
---@param Round number Current round index.
function ClientGameMain:OnRoundStart(Round)
    print("[ClientGameMain]OnRoundStart", Round)
end

--- OnRoundEnd: Callback when a round ends.
---@param Round number Current round index.
function ClientGameMain:OnRoundEnd(Round)
    print("[ClientGameMain]OnRoundEnd", Round)
end

--- OnGameEnd: Callback when game process finishes.
function ClientGameMain:OnGameEnd()
    print("[ClientGameMain]OnGameEnd")
end

--- OnDestroy: Cleanup callback before sandbox VM release. VP events registered via AddVPEvent are auto-removed after this callback returns
function ClientGameMain:OnDestroy()
    print("[ClientGameMain]OnDestroy")
end

local CWoWGameMain = require("EnvLua.Core.WoWGameMain")
local CClientGameMain = WoWClass(CWoWGameMain, nil, ClientGameMain)
return CClientGameMain
