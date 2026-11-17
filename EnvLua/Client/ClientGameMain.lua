-- ClientGameMain: editor-only GameMain for first-wave sandbox users.
-- Provides readable examples for VP events and AddEnvControlEvent usage.
---@class ClientGameMain:WoWGameMain
local ClientGameMain = {}

function ClientGameMain:ctor()
    print("[ClientGameMain]ctor")
end

--- OnStart: Primary game main start callback. Called from host bridge _OnStart after the default game-process listener is registered.
-- 延迟 require TetrisClient（加载期 require 会因 WoWClass 未注入 / Core 内部模块白名单报错）
local TetrisClient = nil
local function GetTetrisClient()
    if not TetrisClient then
        TetrisClient = require("EnvLua.Client.Tetris.TetrisClient")
    end
    return TetrisClient
end

function ClientGameMain:OnStart()
    print("[ClientGameMain]OnStart")
    -- 创建客户端总控（准备界面流程 + UI + 音效；对局交给 Battle）
    local ok, err = pcall(function()
        local Client = GetTetrisClient()
        self.client = Client:new(self)
        self.client:Init()
    end)
    if not ok then print("[ClientGameMain] 创建 TetrisClient 失败: " .. tostring(err)) end
end

--- OnGameStart: Callback when game process enters start.
function ClientGameMain:OnGameStart()
    print("[ClientGameMain]OnGameStart")
end

--- OnRoundStart: Callback when a round starts.
---@param Round number Current round index.
function ClientGameMain:OnRoundStart(Round)
    print("[ClientGameMain]OnRoundStart", Round)
    -- 转发给总控：显示准备界面（点开始→难度→技能→Loading→Battle 双盘对战）
    if self.client then pcall(function() self.client:OnRoundStart() end) end
end

--- OnRoundEnd: Callback when a round ends.
---@param Round number Current round index.
function ClientGameMain:OnRoundEnd(Round)
    print("[ClientGameMain]OnRoundEnd", Round)
    if self.client then pcall(function() self.client:OnRoundEnd() end) end
end

--- OnGameEnd: Callback when game process finishes.
function ClientGameMain:OnGameEnd()
    print("[ClientGameMain]OnGameEnd")
end

--- OnDestroy: Cleanup callback before sandbox VM release. VP events registered via AddVPEvent are auto-removed after this callback returns
function ClientGameMain:OnDestroy()
    print("[ClientGameMain]OnDestroy")
    if self.client then pcall(function() self.client:OnDestroy() end) end
end

local CWoWGameMain = require("EnvLua.Core.WoWGameMain")
local CClientGameMain = WoWClass(CWoWGameMain, nil, ClientGameMain)
return CClientGameMain
