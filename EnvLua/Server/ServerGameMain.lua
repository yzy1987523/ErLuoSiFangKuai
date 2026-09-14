-- ServerGameMain: editor-only GameMain for first-wave sandbox users.
-- Provides readable examples for VP events and AddEnvControlEvent usage.
---@class ServerGameMain:WoWGameMain
local ServerGameMain = {}

function ServerGameMain:ctor()
    print("[ServerGameMain]ctor")
end

local TetrisGame = require("EnvLua.Server.Tetris.TetrisGame")

--- OnStart: Primary game main start callback. Called from host bridge _OnStart after the default game-process listener is registered.
-- 方块格子（10x20 个 Actor）只需建一次，因此放在 OnStart 而非每回合重建。
function ServerGameMain:OnStart()
    print("[ServerGameMain]OnStart")
    self.tetris = TetrisGame:new(self)
    self.tetris:Init()
end

--- OnGameStart: Callback when game process enters start.
function ServerGameMain:OnGameStart()
    print("[ServerGameMain]OnGameStart")
end

--- OnRoundStart: Callback when a round starts.
---@param Round number Current round index.
function ServerGameMain:OnRoundStart(Round)
    print("[ServerGameMain]OnRoundStart", Round)
    if self.tetris then
        self.tetris:Start()
    end
end

--- OnRoundEnd: Callback when a round ends.
---@param Round number Current round index.
function ServerGameMain:OnRoundEnd(Round)
    print("[ServerGameMain]OnRoundEnd", Round)
    if self.tetris then
        self.tetris:Stop()
    end
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
