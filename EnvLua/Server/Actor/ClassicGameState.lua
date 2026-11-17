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

-- [特效] 服务端播消行粒子特效（SceneEffectAPI 全类 ServerOnly，客户端不能调；世界空间粒子一次创建全员可见）。
-- P6 停掉旧 TetrisMatch 后，含 SceneEffectAPI 的 TetrisRenderer 渲染链路整条不再运行，故消行特效消失。
-- 本方法用 P7 已缓存的盘面几何 _boardGeom 按 seat 定位，坐标算法对齐 TetrisRenderer:PlayClearEffectAt。
-- 【重要】seat 语义是纯几何槽位（0=SpawnPointKey 前方盘，1=SpawnPointKey2 前方盘），
-- 不等于「我方/对方」——真人可能出生在任一 seat。调用方须用 _humanSeat/_oppSeat 传入，不能写死 0/1。
-- @param seat number 几何槽位 0 或 1（对应 _boardGeom.o0/o1）
-- @param rows table 被消除的行号列表（1 基，顶行=1）
function ClassicGameState:PlayClearFxForSeat(seat, rows)
    if type(rows) ~= "table" or #rows == 0 then return end
    if type(SceneEffectAPI) ~= "table" or not SceneEffectAPI.CreateSceneEffect then return end
    local okCfg, C = pcall(require, "EnvLua.Common.Tetris.TetrisConfig")
    if not okCfg or type(C) ~= "table" then return end
    local g = self._boardGeom
    if not g then
        print("[Fx][Server/GS][WARN] 盘面几何未就绪，跳过消行特效 seat=" .. tostring(seat))
        return
    end
    local o = (seat == 1) and g.o1 or g.o0
    local right = (seat == 1) and g.r1 or g.r0
    if not o or not right then return end

    local cl = C.Clear or {}
    local r = C.Render or {}
    local step = (r.CellSize or 1.0) + (r.CellGap or 0.02)
    local cols = ((C.Board or {}).Cols or 10)
    local w = (cols - 1) * step
    local key = cl.EffectPresetKey or "13_EffectPreset_3617487677"
    local ref = (type(AssetRef) == "table") and AssetRef[key] or nil
    if not ref then
        if not self._fxRefWarned then
            self._fxRefWarned = true
            print("[Fx][Server/GS][WARN] 消行特效资源未注册 AssetRef[" .. tostring(key) .. "]")
        end
        return
    end
    local side = (type(cl.EffectSideOffsetM) == "number") and cl.EffectSideOffsetM or 0
    local off = cl.EffectPositionOffset or {}
    local scale = cl.EffectScale or { X = 1, Y = 1, Z = 1 }
    local dur = cl.EffectDuration or 1.0
    -- 盘面水平中心（含 right 投影），竖直按行取 o.Z-(row-1)*step
    local cx = o.X + right.X * (w / 2)
    local cy = o.Y + right.Y * (w / 2)
    local made = 0
    for _, row in ipairs(rows) do
        local pos = {
            X = cx + right.X * side,
            Y = cy + right.Y * side,
            Z = o.Z - (row - 1) * step + (off.Z or 0),
        }
        local ok, id = pcall(function()
            return SceneEffectAPI.CreateSceneEffect(ref, Game:ConstructFVectorByLuaTable(pos), dur)
        end)
        if ok and id and id ~= 0 then
            pcall(function()
                SceneEffectAPI.SetSceneEffectScale(id, Game:ConstructFVectorByLuaTable({
                    X = scale.X or 1, Y = scale.Y or 1, Z = scale.Z or 1,
                }))
            end)
            made = made + 1
        end
    end
    print("[Fx][Server/GS] 消行粒子特效 seat=" .. tostring(seat) ..
        " (human=" .. tostring(self._humanSeat) .. "/opp=" .. tostring(self._oppSeat) .. ")" ..
        " 行数=" .. tostring(#rows) .. " 成功=" .. tostring(made) ..
        " pos0=(" .. tostring(cx) .. "," .. tostring(cy) .. "," .. tostring(o.Z) .. ")")
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
        self:RegisterServerFunction("Auth_Piece")            -- [P8] 客户端上报每块(type,rot,x,y)，服务端重放权威分数
        self:RegisterServerFunction("Auth_TopOut")           -- [P8] 客户端显式上报顶出，服务端据此权威判 over
    end)
    print("[P0][Server/GS] RegisterServerFunction = " .. tostring(okReg) .. " " .. tostring(errReg))

    -- 2) 延迟下发盘面基底（客户端据此建双盘；装置晚注入时内部重试）。
    -- 【时序修正】此处不再自动 StartAI：旧版开局 2s 就无条件拉起 AI，玩家还在开始界面未进战斗，
    -- AI 独自跑完整局并触发消行特效/快照刷屏。AI 现在只由客户端真正进入 Battle 后
    -- 经 P5_RequestAI 触发（单人分支，见 TetrisClientBattle:Start），未进战斗则 AI 不启动。
    -- 同时移除 P0/P2 早期验证性广播（ping/假快照），它们只是调试残留、开局刷日志。
    self:AddTimerOnce(2.0, function()
        self:BroadcastBoardTransform()
    end)
end

-- [P5-5b] 启动服务端 AI（幂等；单人模式由客户端 P5_RequestAI 触发）
function ClassicGameState:StartAI()
    if self._p3Driver and self._p3Driver.running then return end
    local okDrv, drvOrErr = pcall(function()
        local Driver = require("EnvLua.Server.Tetris.TetrisAIDriver")
        self._p3Driver = Driver:new(self, { quality = 0.8, tag = "AI-P3", interval = 0.1, snapshotEvery = 1 })
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
    -- [特效] 缓存真人所在 seat 与对手 seat：消行特效必须按「真人实际站位」定位，
    -- 不能写死 我方=seat0/对方=seat1（真人可能出生在 SpawnPoint2=seat1，写死会导致特效左右互换）。
    -- 单人时只有一个 seat 有真人(p~=0)，另一个即 AI 盘；双人有线时取第一个真人为我方。
    local humanSeat = nil
    if p0 ~= 0 then humanSeat = 0 elseif p1 ~= 0 then humanSeat = 1 end
    if humanSeat then
        self._humanSeat = humanSeat
        self._oppSeat = (humanSeat == 0) and 1 or 0
        print("[P7][Server/GS] seat 归属缓存: 我方(真人)=seat" .. tostring(self._humanSeat) ..
            " 对方(AI)=seat" .. tostring(self._oppSeat))
    end

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

-- ===== P8：服务端权威账本（客户端本地即时操作，随机源/每块落点由客户端上报，服务端重放得权威分数）=====
-- 客户端每落一块上报 (seq, type, rot, x, y) = Board.lockPiece 记录的 lastLockedPiece（含重力落定与硬降的实际位置）。
-- 影子 Board 直接把 active 设为该值再 lockPiece()，不调用 spawn()/hardDrop()，因此完全不依赖服务端随机、落点与客户端逐格一致。
-- lockPiece 内部无消行时会自己 spawn 下一块（随机），但下一次上报会直接覆盖 active，不影响权威判定。
-- 权威 score/lines/over 存于 self._authBoard，回 ack(seq, score, lines, over) 供客户端对账。
function ClassicGameState:Auth_Piece(seq, pieceType, rot, x, y)
    local okB, Board = pcall(require, "EnvLua.Common.Tetris.TetrisBoard")
    if not okB or not Board then return end
    if not self._authBoard then
        local okNew, b = pcall(function()
            local nb = Board:new()
            nb.isAI = false
            nb.suppressTopOut = true   -- 影子盘内部 spawn 的随机块不判 over，权威 over 由 Auth_TopOut 显式给
            return nb
        end)
        if not okNew or not b then
            print("[Auth][Server/GS] 影子盘创建失败: " .. tostring(b))
            return
        end
        self._authBoard = b
    end
    local b = self._authBoard
    seq = tonumber(seq) or 0
    if seq <= (self._authSeq or 0) then return end   -- 去重/乱序：只接受严格递增 seq
    self._authSeq = seq

    pcall(function()
        -- 直接按上报的落定状态摆好活动块再锁定，绕开 spawn() 的随机 type/nextQueue
        b.active = {
            type = pieceType,
            rot = tonumber(rot) or 1,
            x = tonumber(x) or 1,
            y = tonumber(y) or 1,
        }
        b:lockPiece()
        -- 同步消行状态机（对齐 ClientGame.tick：lockPaused→doClear→clearing→坍塌→出下一块）
        local guard = 0
        while guard < 8 and (b.lockPaused or b.clearing) do
            guard = guard + 1
            if b.lockPaused then pcall(function() b:doClear() end) end
            -- [特效] 我方盘消行：doClear 后取被消行号播粒子特效（ServerOnly，服务端播全员可见）。
            local rows = b:consumeClearedRows()
            if rows and #rows > 0 then
                -- [特效] 我方盘用真人实际 seat（可能 0 或 1），不写死，避免与对方盘特效互换
                local mySeat = self._humanSeat or 0
                pcall(function() self:PlayClearFxForSeat(mySeat, rows) end)
            end
            if b.clearing then
                pcall(function() b:applyClearCollapse() end)
                pcall(function() b:finishClear() end)
            end
        end
    end)

    pcall(function()
        self:CallClientFunctionMulticast("Auth_Ack", seq, b.score or 0, b.lines or 0, self._authTopOutReported == true)
    end)
    self._authLogged = (self._authLogged or 0) + 1
    if self._authLogged % 5 == 0 then
        print("[Auth][Server/GS] 重放 seq=" .. tostring(seq) .. " type=" .. tostring(pieceType) ..
            " rot=" .. tostring(rot) .. " x=" .. tostring(x) .. " y=" .. tostring(y) ..
            " → score=" .. tostring(b.score) .. " lines=" .. tostring(b.lines) ..
            " over=" .. tostring(self._authTopOutReported == true))
    end
end

-- [P8] 客户端显式上报顶出：服务端权威记 over，并回一帧 ack 让客户端确认。
function ClassicGameState:Auth_TopOut(authSeq)
    if self._authTopOutReported then return end
    self._authTopOutReported = true
    local b = self._authBoard
    local score, lines = b and (b.score or 0) or 0, b and (b.lines or 0) or 0
    pcall(function()
        self:CallClientFunctionMulticast("Auth_Ack", tonumber(authSeq) or (self._authSeq or 0), score, lines, true)
    end)
    print("[Auth][Server/GS] 权威顶出已确认 authSeq=" .. tostring(authSeq) ..
        " score=" .. tostring(score) .. " lines=" .. tostring(lines))
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
