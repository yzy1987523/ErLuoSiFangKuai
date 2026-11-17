---@class ClassicGameState:WoWClassicGameState
-- 服务端 GameState 挂载脚本。P0 验证：注册 C→S 白名单 + 向客户端广播 ping。
local ClassicGameState = {}

local WoWClassicGameState = require("EnvLua.Core.WoWClassicGameState")

-- 排行榜类型：CustomRank[RankType]，未注入时回退数字（与 TetrisMatch:LeaderboardRankType 一致）
local function rankType(Config)
    local name = (Config.Leaderboard and Config.Leaderboard.RankType) or "Rank1"
    if type(CustomRank) ~= "table" then pcall(require, "EnvLua.Core.Define.CommonDefine") end
    if type(CustomRank) == "table" and CustomRank[name] ~= nil then return CustomRank[name] end
    local map = { Rank1 = 1, Rank2 = 2, Rank3 = 3, Rank4 = 4, Rank5 = 5 }
    return map[name] or 1
end

-- 兼容 atan2：部分 Lua 环境（Lua 5.3）已移除 math.atan2，仅保留两参 math.atan。
local function atan2compat(y, x)
    local ok, v = pcall(function() return math.atan2(y, x) end)
    if ok then return v end
    ok, v = pcall(function() return math.atan(y, x) end)
    if ok then return v end
    if x > 0 then return math.atan(y / x) end
    if x < 0 then return math.atan(y / x) + (y >= 0 and math.pi or -math.pi) end
    if y > 0 then return math.pi / 2 end
    if y < 0 then return -math.pi / 2 end
    return 0
end

-- [P7] 读出出生点装置世界位置（米）。用于按「玩家实际站位离哪个出生点近」判定我方/对方。
-- InstanceAPI 为 ServerOnly（Core/LuaHint/InstanceAPI.lua L3），必须服务端读；不可读返回 nil。
local function spawnPointLocM(spawnKey)
    if type(CreativeInstance) ~= "table" or not spawnKey or type(InstanceAPI) ~= "table" then return nil end
    local id = CreativeInstance[spawnKey]
    if id == nil then return nil end
    local ok, loc = pcall(function() return InstanceAPI.GetInstanceLocation(id) end)
    if ok and loc and loc.X ~= nil and loc.Y ~= nil then
        return { X = loc.X, Y = loc.Y, Z = loc.Z or 0 }
    end
    return nil
end

-- [P7] 按出生点装置算盘面基底（origin=左上角、right=横向单位向量，单位米）。
-- 移植自旧 TetrisRenderer:ResolveOrigin 的 settle（L149-180），只保留客户端 ClientRenderer 需要的 origin/right。
-- InstanceAPI 为 ServerOnly，必须服务端算；装置未就绪/不可读时返回 nil，由调用方重试。
local function resolveBoardTransform(spawnKey)
    local okCfg, C = pcall(require, "EnvLua.Common.Tetris.TetrisConfig")
    if not okCfg or type(C) ~= "table" then return nil end
    local so = C.SceneObjects or {}
    local key = spawnKey or so.SpawnPointKey
    if type(CreativeInstance) ~= "table" or not key then return nil end
    local id = CreativeInstance[key]
    if id == nil or type(InstanceAPI) ~= "table" then return nil end

    local okL, loc = pcall(function() return InstanceAPI.GetInstanceLocation(id) end)
    if not okL or not loc or loc.X == nil then return nil end

    local R = C.Render or {}
    local step = (R.CellSize or 1.0) + (R.CellGap or 0.02)
    local w = (((C.Board or {}).Cols or 10) - 1) * step
    local h = (((C.Board or {}).Rows or 20) - 1) * step
    local lift = (type(C.BoardHeightOffsetM) == "number") and C.BoardHeightOffsetM or 1.3
    local dist = (type(C.BoardForwardDistM) == "number") and C.BoardForwardDistM or 8
    local offDeg = (type(C.BoardYawOffsetDeg) == "number") and C.BoardYawOffsetDeg or 0
    local side = (type(C.BoardSideOffsetM) == "number") and C.BoardSideOffsetM or 0
    local flipAxis = (C.BoardFlipAxis180 == true)

    -- 装置朝向：实测 +Yaw 指向装置背面，基准补 180°（与旧 ResolveOrigin 一致）。
    local fx, fy = 0, 1
    local okR, rot = pcall(function() return InstanceAPI.GetInstanceRotation(id) end)
    if okR and rot and rot.Yaw then
        local yr = math.rad((rot.Yaw or 0) + 180)
        if rot.Pitch then
            local pr = math.rad(rot.Pitch or 0)
            fx, fy = math.cos(pr) * math.cos(yr), math.cos(pr) * math.sin(yr)
        else
            fx, fy = math.cos(yr), math.sin(yr)
        end
    end
    local len = math.sqrt(fx * fx + fy * fy)
    if len < 1e-6 then fx, fy = 0, 1 else fx, fy = fx / len, fy / len end

    local posYaw = atan2compat(fy, fx) + offDeg * math.pi / 180
    local frameYaw = posYaw + (flipAxis and math.pi or 0)
    local frx, fry = math.cos(frameYaw), math.sin(frameYaw)
    local right = { X = fry, Y = -frx, Z = 0 }
    local ffx, ffy = math.cos(posYaw), math.sin(posYaw)
    local cx = loc.X + ffx * dist + right.X * side
    local cy = loc.Y + ffy * dist + right.Y * side
    local cz = loc.Z + lift + h / 2
    local origin = { X = cx - right.X * (w / 2), Y = cy - right.Y * (w / 2), Z = cz + h / 2 }
    return origin, right
end

--- Callback after Actor BeginPlay.
-- 延迟广播，确保客户端 GameState 已就绪并能收到同名方法调用。
function ClassicGameState:OnReceiveBeginPlay()
    print("[P0][Server/GS] OnReceiveBeginPlay 触发")

    -- 1) 注册 C→S 白名单方法（后续客户端可 CallServerFunction("P0_OnClientPing")）
    local okReg, errReg = pcall(function()
        self:RegisterServerFunction("P0_OnClientPing")
        self:RegisterServerFunction("P2_OnSnapshotAck")  -- [P2] 快照回执白名单
        self:RegisterServerFunction("P5_ReportResult")       -- [P5] 结算上报
        self:RegisterServerFunction("P5_RequestLeaderboard") -- [P5] 排行榜请求
        self:RegisterServerFunction("P5_RequestAI")          -- [P5-5b] 单人请求启动 AI
        self:RegisterServerFunction("P5_ReportSnapshot")     -- [P5-5b] 双人快照中转
        self:RegisterServerFunction("P7_HideMasks")          -- [P7] 选完技能后隐藏 Mask 场景对象（ServerOnly）
        self:RegisterServerFunction("P7_RequestPlayerInfo")  -- [P7] 请求玩家名字+头像序号（服务端分配）
        self:RegisterServerFunction("P7_RequestBoardTransform") -- [P7] 请求盘面基底（出生点几何，ServerOnly 计算）
    end)
    print("[P0][Server/GS] RegisterServerFunction = " .. tostring(okReg) .. " " .. tostring(errReg))

    -- 2) 延迟 2 秒向客户端广播 S→C（触发客户端 ClassicGameState:P0_OnServerPing）
    local selfRef = self
    self:AddTimerOnce(2.0, function()
        local okCall, errCall = pcall(function()
            selfRef:CallClientFunctionMulticast("P0_OnServerPing", "hello-from-server")
        end)
        print("[P0][Server/GS] CallClientFunctionMulticast 发送 = " .. tostring(okCall) .. " " .. tostring(errCall))

        -- [P2] 构造真实 Board 快照并广播，验证 table 参数能否跨端传输
        local okSnap, snapOrErr = pcall(function()
            local Snapshot = require("EnvLua.Common.Tetris.TetrisSnapshot")
            local Board = require("EnvLua.Common.Tetris.TetrisBoard")
            local b = Board:new()
            -- 造几个格子，让快照非空、便于校验
            pcall(function() b.grid[20][1] = { color = 1 }; b.grid[20][2] = { color = 2 } end)
            return Snapshot.Capture(b, { tag = "P2-ai-test" })
        end)
        if okSnap and type(snapOrErr) == "table" then
            print("[P2][Server/GS] 快照已构造: rows=" .. tostring(snapOrErr.rows) ..
                " cols=" .. tostring(snapOrErr.cols) .. " gridLen=" .. tostring(#snapOrErr.grid))
            local okSend, errSend = pcall(function()
                selfRef:CallClientFunctionMulticast("P2_OnBoardSnapshot", snapOrErr)
            end)
            print("[P2][Server/GS] 广播快照(table参数) = " .. tostring(okSend) .. " " .. tostring(errSend))
        else
            print("[P2][Server/GS] 快照构造失败: " .. tostring(snapOrErr))
        end

        -- [P7] 下发按出生点计算的盘面基底（客户端据此建双盘；装置晚注入时内部重试）
        self:BroadcastBoardTransform()

        -- [P5-5b] 仅单人时启动 AI（双人进入后才开始游戏，此处数人数判断）
        local playerCount = 0
        pcall(function()
            local ps = Game:GetAllPlayerStates()
            if ps and ps.Num then playerCount = ps:Num() end
        end)
        print("[P5][Server/GS] 延迟检查玩家数=" .. tostring(playerCount))
        if playerCount < 2 then
            self:StartAI()
        else
            print("[P5][Server/GS] 双人模式，不启动 AI")
        end
    end)
end

-- [P5-5b] 启动服务端 AI（幂等；单人模式由客户端 P5_RequestAI 触发）
function ClassicGameState:StartAI()
    if self._p3Driver and self._p3Driver.running then return end
    local okDrv, drvOrErr = pcall(function()
        local Driver = require("EnvLua.Server.Tetris.TetrisAIDriver")
        self._p3Driver = Driver:new(self, { quality = 0.8, tag = "AI-P3", interval = 0.5, snapshotEvery = 3 })
        self._p3Driver:Start()
        return self._p3Driver
    end)
    print("[P5][Server/GS] StartAI = " .. tostring(okDrv) .. " " .. tostring(okDrv and "" or drvOrErr))
end

-- ===== P7：盘面基底下发（按出生点计算，扁平 13 标量，避免嵌套 table 跨端风险）=====
-- seat0 = SpawnPointKey（playerKey 较小者用），seat1 = SpawnPointKey2（较大者用；单人时该值为 0，客户端当 AI 盘）。
-- 出生点装置晚注入时 0.5s 重试最多 10 次；几何只算一次并缓存，playerKey 每次重读（玩家可能晚进入）。
function ClassicGameState:BroadcastBoardTransform()
    local okCfg, C = pcall(require, "EnvLua.Common.Tetris.TetrisConfig")
    if not okCfg or type(C) ~= "table" then return end
    local so = C.SceneObjects or {}

    -- 几何只算一次（出生点固定）；playerKey 每次重读，保证晚进入的玩家也能拿到正确 seat
    local g = self._boardGeom
    if not g then
        local o0, r0 = resolveBoardTransform(so.SpawnPointKey)
        local o1, r1 = resolveBoardTransform(so.SpawnPointKey2)
        if not o0 or not r0 or not o1 or not r1 then
            self._boardRetry = (self._boardRetry or 0) + 1
            if self._boardRetry <= 10 then
                print("[P7][Server/GS] 出生点尚未就绪，盘面基底重试 " .. tostring(self._boardRetry) .. "/10")
                self:AddTimerOnce(0.5, function() self:BroadcastBoardTransform() end)
            else
                print("[P7][Server/GS] 出生点持续不可用，放弃盘面基底下发（客户端用占位基底兜底）")
            end
            return
        end
        g = { o0 = o0, r0 = r0, o1 = o1, r1 = r1 }
        self._boardGeom = g
    end
    local o0, r0, o1, r1 = g.o0, g.r0, g.o1, g.r1

    -- 按「玩家实际站位离哪个出生点近」分配 seat（playerKey 大小与出生点无必然关系，不能按 key 排序猜）。
    -- pawns 为 LuaArray（:Num()/:Get(i) 0 基）；pawn:GetPlayerState() 取 key；K2_GetActorLocation 厘米→米。
    local loc0 = spawnPointLocM(so.SpawnPointKey)
    local loc1 = spawnPointLocM(so.SpawnPointKey2)
    local function dist2M(loc, xm, ym)
        if not loc then return math.huge end
        local dx, dy = (loc.X or 0) - xm, (loc.Y or 0) - ym
        return dx * dx + dy * dy
    end
    local keyBySeat = { [0] = 0, [1] = 0 }   -- 0 = 该 seat 无真人（单人时 AI 盘占位）
    local okPawns, pawns = pcall(function() return Game:GetAllPlayerPawns() end)
    if okPawns and pawns and pawns.Num then
        for i = 0, pawns:Num() - 1 do
            local pawn = pawns:Get(i)
            if pawn then
                local key = 0
                pcall(function()
                    local ps = pawn:GetPlayerState()
                    if ps and ps.GetPlayerKey then key = ps:GetPlayerKey() or 0 end
                end)
                local locCM = nil
                pcall(function() locCM = pawn:K2_GetActorLocation() end)
                if locCM and locCM.X and loc0 and loc1 then
                    local xm, ym = locCM.X / 100.0, locCM.Y / 100.0   -- Class API 厘米 → 米
                    local d0, d1 = dist2M(loc0, xm, ym), dist2M(loc1, xm, ym)
                    local seat = (d0 <= d1) and 0 or 1
                    keyBySeat[seat] = key
                    print("[P7][Server/GS] 玩家 key=" .. tostring(key) ..
                        " 站位m=(" .. tostring(xm) .. "," .. tostring(ym) .. ")" ..
                        " d0=" .. tostring(math.sqrt(d0)) .. " d1=" .. tostring(math.sqrt(d1)) ..
                        " → seat" .. tostring(seat))
                else
                    print("[P7][Server/GS][WARN] 玩家 key=" .. tostring(key) .. " 站位/出生点读取失败，跳过距离判定")
                end
            end
        end
    end
    local p0, p1 = keyBySeat[0] or 0, keyBySeat[1] or 0

    local okSend, err = pcall(function()
        self:CallClientFunctionMulticast("P7_BoardTransform",
            p0, o0.X, o0.Y, o0.Z, r0.X, r0.Y, r0.Z,
            p1, o1.X, o1.Y, o1.Z, r1.X, r1.Y, r1.Z)
    end)
    print("[P7][Server/GS] BoardTransform 下发=" .. tostring(okSend) ..
        " 出生点0=" .. (loc0 and ("(" .. tostring(loc0.X) .. "," .. tostring(loc0.Y) .. ")") or "nil") ..
        " 出生点1=" .. (loc1 and ("(" .. tostring(loc1.X) .. "," .. tostring(loc1.Y) .. ")") or "nil") ..
        " seat0[玩家" .. tostring(p0) .. "] origin=(" .. tostring(o0.X) .. "," .. tostring(o0.Y) .. "," .. tostring(o0.Z) .. ")" ..
        " right=(" .. tostring(r0.X) .. "," .. tostring(r0.Y) .. "," .. tostring(r0.Z) .. ")" ..
        " seat1[玩家" .. tostring(p1) .. "] origin=(" .. tostring(o1.X) .. "," .. tostring(o1.Y) .. "," .. tostring(o1.Z) .. ")" ..
        (okSend and "" or (" err=" .. tostring(err))))
end

-- [P7] 客户端兜底请求（开局广播丢包/晚到时重发缓存）
function ClassicGameState:P7_RequestBoardTransform()
    self:BroadcastBoardTransform()
end

-- [P2] 客户端回执：客户端 ApplySnapshot 后可调此白名单方法回报。
function ClassicGameState:P2_OnSnapshotAck(tag, ok)
    print("[P2][Server/GS] P2_OnSnapshotAck 收到: tag=" .. tostring(tag) .. " ok=" .. tostring(ok))
end

-- C→S 接收端：客户端调用时触发，验证反向通道。
function ClassicGameState:P0_OnClientPing(msg)
    print("[P0][Server/GS] P0_OnClientPing 收到客户端调用: " .. tostring(msg))
end

-- ===== P5：结算上报（胜数榜：赢 +1，输不扣）=====
-- 一局结束客户端调一次；单人打 AI 也走这里（win=true 时 playerKey 是本地玩家）。
function ClassicGameState:P5_ReportResult(win, playerKey)
    print("[P5][Server/GS] ReportResult win=" .. tostring(win) .. " playerKey=" .. tostring(playerKey))
    if type(RankAPI) ~= "table" then return end
    local okCfg, Config = pcall(require, "EnvLua.Common.Tetris.TetrisConfig")
    if not okCfg or not Config then return end
    local rt = rankType(Config)
    local players = Game:GetAllPlayerStates()
    if not players or not players.Num then return end
    for i = 0, players:Num() - 1 do
        local ps = players:Get(i)
        if ps and ps.GetPlayerKey and ps:GetPlayerKey() == playerKey then
            if win then
                local cur = 0
                if RankAPI.GetPlayerScore then
                    local okScore, v = pcall(function() return RankAPI.GetPlayerScore(ps, rt) end)
                    if okScore and type(v) == "number" then cur = v end
                end
                local newVal = cur + 1
                pcall(function() RankAPI.SubmitScore(ps, rt, newVal) end)
                print("[P5][Server/GS] 玩家 " .. tostring(playerKey) .. " 胜数 " .. tostring(cur) .. " → " .. tostring(newVal))
            else
                print("[P5][Server/GS] 玩家 " .. tostring(playerKey) .. " 输，不扣胜数")
            end
            break
        end
    end
    if RankAPI.RefreshRank then pcall(function() RankAPI.RefreshRank(rt) end) end
end

-- ===== P5：排行榜读取（GetTopN → S2C 回传）=====
function ClassicGameState:P5_RequestLeaderboard()
    if type(RankAPI) ~= "table" or not RankAPI.GetTopN then return end
    local okCfg, Config = pcall(require, "EnvLua.Common.Tetris.TetrisConfig")
    if not okCfg or not Config then return end
    local okGet, list = pcall(function() return RankAPI.GetTopN(rankType(Config), 10) end)
    if okGet and type(list) == "table" then
        pcall(function() self:CallClientFunctionMulticast("P5_LeaderboardData", list) end)
        print("[P5][Server/GS] 排行榜已回传, 条数=" .. tostring(#list))
    else
        print("[P5][Server/GS] 排行榜读取失败: " .. tostring(list))
    end
end

-- ===== P5-5b：单人请求启动 AI =====
function ClassicGameState:P5_RequestAI()
    local playerCount = 0
    pcall(function()
        local ps = Game:GetAllPlayerStates()
        if ps and ps.Num then playerCount = ps:Num() end
    end)
    if playerCount >= 2 then
        print("[P5][Server/GS] P5_RequestAI 忽略：当前是双人模式(" .. tostring(playerCount) .. "人)")
        return
    end
    print("[P5][Server/GS] P5_RequestAI 单人模式，启动 AI")
    self:StartAI()
end

-- ===== P5-5b：双人快照中转（广播给所有客户端；客户端按 senderKey 过滤自己）=====
function ClassicGameState:P5_ReportSnapshot(snap)
    if type(snap) ~= "table" then return end
    local okSend, err = pcall(function()
        self:CallClientFunctionMulticast("P5_OpponentSnapshot", snap)
    end)
    if not okSend then print("[P5][Server/GS] 快照中转失败: " .. tostring(err)) end
end

-- ===== P7：选完技能后隐藏 Mask 场景对象（对齐历史 TetrisSkillSelect:HideSceneObjectsOnce）=====
-- Mask1/Mask2 是场景对象，InstanceAPI.ToggleInstanceVisible 为 ServerOnly，必须留在服务端。
-- 任意玩家点完技能即触发，全程只执行一次（场景对象为共享世界对象，隐藏影响全体玩家）。
function ClassicGameState:P7_HideMasks()
    if self._masksHidden then return end
    self._masksHidden = true
    if type(InstanceAPI) ~= "table" or type(InstanceAPI.ToggleInstanceVisible) ~= "function" then
        print("[P7][Server/GS] P7_HideMasks 跳过：InstanceAPI 不可用")
        return
    end
    local okCfg, Config = pcall(require, "EnvLua.Common.Tetris.TetrisConfig")
    if not okCfg or not Config then return end
    local list = Config.HideAfterSkill
    if type(list) ~= "table" then return end
    local hidden = 0
    for _, key in ipairs(list) do
        local id = (type(CreativeInstance) == "table" and CreativeInstance[key]) or nil
        if id ~= nil then
            local ok = pcall(function() InstanceAPI.ToggleInstanceVisible(id, false) end)
            if ok then hidden = hidden + 1 end
        end
    end
    print("[P7][Server/GS] P7_HideMasks 已隐藏 Mask 场景对象 " .. tostring(hidden) .. "/" .. tostring(#list))
end

-- ===== P7：玩家名字 + 头像序号（服务端分配，保证每人不同）=====
-- 头像不传图片本身，只分配序号 index（0/1/...），客户端按序号从 AvatarUI.AvatarPresets 选图。
-- 按 playerKey 排序后按序分配，保证双端一致、序号稳定不重复。
-- 单人 AI 对手由客户端自行用 aiName + 一个避开真人的序号填充（这里只下发真人）。
function ClassicGameState:P7_RequestPlayerInfo()
    local players = Game:GetAllPlayerStates()
    if not players or not players.Num then return end
    local list = {}
    for i = 0, players:Num() - 1 do
        local ps = players:Get(i)
        if ps then
            local key, name = 0, ""
            pcall(function() if ps.GetPlayerKey then key = ps:GetPlayerKey() or 0 end end)
            pcall(function() name = ps.PlayerName or "" end)
            list[#list + 1] = { playerKey = key, name = tostring(name), avatarIndex = 0 }
        end
    end
    table.sort(list, function(a, b) return a.playerKey < b.playerKey end)
    for i, e in ipairs(list) do e.avatarIndex = i - 1 end   -- 0 基序号
    for _, e in ipairs(list) do
        print("[P7][Server/GS] 玩家信息 key=" .. tostring(e.playerKey) ..
            " name=" .. tostring(e.name) .. " avatarIndex=" .. tostring(e.avatarIndex))
    end
    local okSend, err = pcall(function() self:CallClientFunctionMulticast("P7_PlayerInfo", list) end)
    if not okSend then print("[P7][Server/GS] P7_PlayerInfo 广播失败: " .. tostring(err)) end
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
