-- ServerGameMain: editor-only GameMain for first-wave sandbox users.
-- Provides readable examples for VP events and AddEnvControlEvent usage.
---@class ServerGameMain:WoWGameMain
local ServerGameMain = {}

function ServerGameMain:ctor()
    print("[ServerGameMain]ctor")
end

--- OnStart: 服务端不执行任何 UI 操作。
-- 玩法逻辑全部在客户端（Client/Tetris）；原生 UI 的显隐由编辑器端配置，代码不再屏蔽。
-- 旧的 TetrisMatch 服务端玩法不再启动，其文件保留作备份（不物理删除）。
function ServerGameMain:OnStart()
    print("[ServerGameMain]OnStart (client-authoritative: 无 UI 操作)")
    -- 构建版本确认：由 wow-sync.ps1 每次 push/sync 自增，用来确认当前跑的是否为最新上传版本
    local okVer, ver = pcall(function() return require("EnvLua.Common.BuildVersion") end)
    print("[BuildVersion] Server = " .. tostring(okVer and ver or ("读取失败:" .. tostring(ver))))
end

--- OnGameStart: Callback when game process enters start.
function ServerGameMain:OnGameStart()
    print("[ServerGameMain]OnGameStart")
end

--- OnRoundStart: Callback when a round starts.
---@param Round number Current round index.
function ServerGameMain:OnRoundStart(Round)
    print("[ServerGameMain]OnRoundStart", Round)
    -- 玩法已在客户端启动；服务端 AI/数据桥由 GameState 挂载脚本负责。
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
