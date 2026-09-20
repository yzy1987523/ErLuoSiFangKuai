-- ServerGameMain: editor-only GameMain for first-wave sandbox users.
-- Provides readable examples for VP events and AddEnvControlEvent usage.
---@class ServerGameMain:WoWGameMain
local ServerGameMain = {}

function ServerGameMain:ctor()
    print("[ServerGameMain]ctor")
end

-- 玩法模块改为「首次使用时才 require」，不要在本文件的加载期 require。
-- 原因：加载期（下方三行契约之前）追踪 Core，会让引擎 require 层连带拉起内部模块
--（GameLua.Mod.CreativeBase.BinaryData.CreativeModePbUtility 被白名单拦截），
-- 且此时全局 WoWClass 尚未注入，Core/ 里形如 WoWClass(...) 的顶层调用会报
-- "attempt to call a nil value (global 'WoWClass')"。
-- 推迟到 OnStart（回调期）加载即可，底部三行契约保持不变。
local TetrisMatch = nil
local function GetTetrisMatch()
    if not TetrisMatch then
        TetrisMatch = require("EnvLua.Server.Tetris.TetrisMatch")
    end
    return TetrisMatch
end

--- OnStart: Primary game main start callback. Called from host bridge _OnStart after the default game-process listener is registered.
-- 方块格子（10x20 个 Actor）只需建一次，因此放在 OnStart 而非每回合重建。
function ServerGameMain:OnStart()
    print("[ServerGameMain]OnStart")
    local MatchClass = GetTetrisMatch()
    self.tetris = MatchClass:new(self)
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
