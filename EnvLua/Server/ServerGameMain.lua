-- ServerGameMain: editor-only GameMain for first-wave sandbox users.
-- Provides readable examples for VP events and AddEnvControlEvent usage.
---@class ServerGameMain:WoWGameMain
local ServerGameMain = {}

function ServerGameMain:ctor()
    print("[ServerGameMain]ctor")
end

--- OnStart: Primary game main start callback. Called from host bridge _OnStart after the default game-process listener is registered.
function ServerGameMain:OnStart()
    print("[ServerGameMain]OnStart")
end

--- OnGameStart: Callback when game process enters start.
function ServerGameMain:OnGameStart()
    print("[ServerGameMain]OnGameStart")
end

--- OnRoundStart: Callback when a round starts.
---@param Round number Current round index.
function ServerGameMain:OnRoundStart(Round)
    print("[ServerGameMain]OnRoundStart", Round)
end

--- OnRoundEnd: Callback when a round ends.
---@param Round number Current round index.
function ServerGameMain:OnRoundEnd(Round)
    print("[ServerGameMain]OnRoundEnd", Round)
end

--- OnGameEnd: Callback when game process finishes.
function ServerGameMain:OnGameEnd()
    print("[ServerGameMain]OnGameEnd")
end

--- OnDestroy: Cleanup callback before sandbox VM release. VP events registered via AddVPEvent are auto-removed after this callback returns
function ServerGameMain:OnDestroy()
    print("[ServerGameMain]OnDestroy")
end

local CWoWGameMain = require("EnvLua.Core.WoWGameMain")
local CServerGameMain = WoWClass(CWoWGameMain, nil, ServerGameMain)
return CServerGameMain
