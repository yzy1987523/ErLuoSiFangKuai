---@class ClassicGameState:WoWClassicGameState
local ClassicGameState = {}

local WoWClassicGameState = require("EnvLua.Core.WoWClassicGameState")

-- ===== P0 验证：S→C 广播接收（服务端 CallClientFunctionMulticast 会调本端同名方法）=====
function ClassicGameState:P0_OnServerPing(msg)
    print("[P0][Client/GS] P0_OnServerPing 收到服务端广播: " .. tostring(msg))
end

-- ===== P5-5b：双人对手快照（服务端中转广播；过滤自己）=====
function ClassicGameState:P5_OpponentSnapshot(snap)
    local okBT, Battle = pcall(require, "EnvLua.Client.Tetris.TetrisClientBattle")
    if not okBT or not Battle.Current then return end
    -- 过滤自己发出的快照（multicast 会广播回发送者）
    local selfKey = Battle.Current.selfKey or 0
    if type(snap) == "table" and snap.senderKey and snap.senderKey ~= 0 and snap.senderKey == selfKey then
        return
    end
    pcall(Battle.Current.OnOpponentSnapshot, Battle.Current, snap)
end

-- ===== P5：排行榜数据回传（服务端 GetTopN → 广播）=====
function ClassicGameState:P5_LeaderboardData(list)
    print("[P5][Client/GS] 排行榜数据收到, 条数=" .. tostring(type(list) == "table" and #list or 0))
    if type(list) == "table" then
        for i = 1, math.min(3, #list) do
            local e = list[i]
            print("[P5][Client/GS]   #" .. tostring(i) .. " " .. tostring(e and e.Name) .. " = " .. tostring(e and e.Value))
        end
    end
    -- 转给 Battle（供后续 UI 面板用）
    local okBT, Battle = pcall(require, "EnvLua.Client.Tetris.TetrisClientBattle")
    if okBT and Battle.Current and Battle.Current.OnLeaderboard then
        pcall(Battle.Current.OnLeaderboard, Battle.Current, list)
    end
end

-- ===== P3 验证：接收服务端 AI 快照，Apply 到本地镜像 Board 并观察连续演进 =====
function ClassicGameState:P3_OnAISnapshot(snap)
    -- [P5-5b] 双人模式忽略 AI 快照（服务端可能误启 AI，双人对手盘只认真人快照）
    local okV, BattleV = pcall(require, "EnvLua.Client.Tetris.TetrisClientBattle")
    if okV and BattleV.Current and BattleV.Current.isVersus then return end

    self._p3mirror = self._p3mirror or nil
    local okInit, Board = pcall(require, "EnvLua.Common.Tetris.TetrisBoard")
    if okInit and not self._p3mirror then self._p3mirror = Board:new() end
    local okApply = false
    local okSnap, Snapshot = pcall(require, "EnvLua.Common.Tetris.TetrisSnapshot")
    if okSnap then
        okApply = pcall(Snapshot.ApplyToBoard, snap, self._p3mirror)
    end
    -- [P4] 转发快照给 Battle 驱动，画右侧对手盘
    local okBT, Battle = pcall(require, "EnvLua.Client.Tetris.TetrisClientBattle")
    if okBT and Battle.Current then
        pcall(Battle.Current.OnOpponentSnapshot, Battle.Current, snap)
    end
    self._p3recv = (self._p3recv or 0) + 1
    -- 限频打印：每 5 帧一次，便于看 score/lines 是否随 AI 演进变化
    if self._p3recv % 5 == 0 and self._p3mirror then
        print("[P3][Client/GS] AI快照#=" .. tostring(self._p3recv) ..
            " Apply=" .. tostring(okApply) ..
            " score=" .. tostring(self._p3mirror.score) ..
            " lines=" .. tostring(self._p3mirror.lines) ..
            " active=" .. tostring(self._p3mirror.active and self._p3mirror.active.type or "nil") ..
            " over=" .. tostring(self._p3mirror.isGameOver))
    end
end

-- ===== P2 验证：S→C 快照接收 + ApplySnapshot 烟测 =====
function ClassicGameState:P2_OnBoardSnapshot(snap)
    print("[P2][Client/GS] P2_OnBoardSnapshot 收到, 类型=" .. type(snap))
    local okDescribe, desc = pcall(function()
        local Snapshot = require("EnvLua.Common.Tetris.TetrisSnapshot")
        return Snapshot.Describe(snap)
    end)
    print("[P2][Client/GS] ApplySnapshot 校验 = " .. tostring(okDescribe and desc or desc))

    -- 回执服务端（验证 C2S 带参数 + 确认客户端确实收到快照）
    local tag = (type(snap) == "table" and snap.tag) or "?"
    local selfRef = self
    pcall(function()
        selfRef:CallServerFunction("P2_OnSnapshotAck", tostring(tag), tostring(okDescribe))
    end)
end

-- ===== P0 验证：C→S 实发（服务端需已 RegisterServerFunction 白名单）=====
function ClassicGameState:OnReceiveBeginPlay()
    local selfRef = self
    self:AddTimerOnce(1.5, function()
        local ok, err = pcall(function()
            selfRef:CallServerFunction("P0_OnClientPing", "hello-from-client")
        end)
        print("[P0][Client/GS] CallServerFunction 发送 = " .. tostring(ok) .. " " .. tostring(err))
    end)
end

--- Callback after Actor construction is complete.
function ClassicGameState:OnPostConstruct() 

end

--- Callback for Actor EndPlay.
---@param EndPlayReason EndPlayReason End play reason.
function ClassicGameState:OnReceiveEndPlay(EndPlayReason) 

end

local CClassicGameState = WoWClass(WoWClassicGameState, nil, ClassicGameState)
return CClassicGameState
