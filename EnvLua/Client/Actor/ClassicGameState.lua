---@class ClassicGameState:WoWClassicGameState
local ClassicGameState = {}

local WoWClassicGameState = require("EnvLua.Core.WoWClassicGameState")

-- ===== P0 验证：S→C 广播接收（服务端 CallClientFunctionMulticast 会调本端同名方法）=====
function ClassicGameState:P0_OnServerPing(msg)
    print("[P0][Client/GS] P0_OnServerPing 收到服务端广播: " .. tostring(msg))
end

-- ===== P9：设置读档回传（语言/音量）。服务端 multicast，按 playerKey 过滤只应用自己的 =====
function ClassicGameState:P9_SettingsData(key, lang, bgm, sfx, hasSave)
    local okC, Client = pcall(require, "EnvLua.Client.Tetris.TetrisClient")
    if not okC or not Client.Current then return end
    if key ~= nil and Client.Current.selfKey ~= nil and key ~= Client.Current.selfKey then return end
    pcall(Client.Current.OnSettingsLoaded, Client.Current, lang, bgm, sfx, hasSave)
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

-- ===== 对战事件接收（服务端 P5_VersusEvent 中转广播）→ 转给 Battle 的 OnVersusEvent =====
function ClassicGameState:P5_VersusEvent(kind, n, fromKey, payload)
    local okBT, Battle = pcall(require, "EnvLua.Client.Tetris.TetrisClientBattle")
    if okBT and Battle.Current and Battle.Current.OnVersusEvent then
        pcall(Battle.Current.OnVersusEvent, Battle.Current, kind, n, fromKey, payload)
    end
end

-- ===== P7：双方就绪广播（服务端仲裁双方/AI都准备好后下发，两端一起进 loading）=====
function ClassicGameState:P7_AllReady(gen)
    print("[P7][Ready][Client/GS] AllReady 收到 gen=" .. tostring(gen))
    local okC, Client = pcall(require, "EnvLua.Client.Tetris.TetrisClient")
    if not okC or not Client.Current or not Client.Current.OnAllReady then
        print("[P7][Ready][Client/GS][WARN] TetrisClient.Current 不可用，AllReady 未转发")
        return
    end
    pcall(Client.Current.OnAllReady, Client.Current, gen)
end

-- ===== P7：玩家信息（服务端分配的名字+头像序号）=====
function ClassicGameState:P7_PlayerInfo(list)
    print("[P7][Client/GS] 玩家信息收到, 人数=" .. tostring(type(list) == "table" and #list or 0))
    local okBT, Battle = pcall(require, "EnvLua.Client.Tetris.TetrisClientBattle")
    if okBT and Battle.Current and Battle.Current.OnPlayerInfo then
        pcall(Battle.Current.OnPlayerInfo, Battle.Current, list)
    end
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

-- ===== P7：盘面基底（服务端按出生点计算，扁平标量下发）=====
-- 开局广播时 Battle 可能尚未创建，先存模块级 Pending；Battle:Start 会主动取用。
function ClassicGameState:P7_BoardTransform(p0, o0x, o0y, o0z, r0x, r0y, r0z,
                                            p1, o1x, o1y, o1z, r1x, r1y, r1z)
    local seats = {
        { playerKey = p0, origin = { X = o0x, Y = o0y, Z = o0z }, right = { X = r0x, Y = r0y, Z = r0z } },
        { playerKey = p1, origin = { X = o1x, Y = o1y, Z = o1z }, right = { X = r1x, Y = r1y, Z = r1z } },
    }
    print("[P7][Client/GS] BoardTransform 收到 p0=" .. tostring(p0) .. " p1=" .. tostring(p1) ..
        " origin0=(" .. tostring(o0x) .. "," .. tostring(o0y) .. "," .. tostring(o0z) .. ")")
    local okBT, Battle = pcall(require, "EnvLua.Client.Tetris.TetrisClientBattle")
    if not okBT then return end
    if Battle.Current then
        pcall(Battle.Current.OnBoardTransform, Battle.Current, seats)
    else
        Battle.PendingBoardTransform = seats
        print("[P7][Client/GS] BoardTransform 已缓存到 Pending（Battle 未创建）")
    end
end

-- ===== P8：服务端权威 ack（每块重放后的权威 score/lines/over），转给 Battle 对账 =====
function ClassicGameState:Auth_Ack(seq, score, lines, over)
    local okBT, Battle = pcall(require, "EnvLua.Client.Tetris.TetrisClientBattle")
    if okBT and Battle.Current and Battle.Current.OnAuthAck then
        pcall(Battle.Current.OnAuthAck, Battle.Current, seq, score, lines, over)
    end
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
