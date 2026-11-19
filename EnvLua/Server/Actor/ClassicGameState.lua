---@class ClassicGameState:WoWClassicGameState
-- 服务端 GameState 挂载脚本。P0 验证：注册 C→S 白名单 + 向客户端广播 ping。
local ClassicGameState = {}

local WoWClassicGameState = require("EnvLua.Core.WoWClassicGameState")
local TetrisConfig = require("EnvLua.Common.Tetris.TetrisConfig")
-- [消行飘字] 3D Actor UI（ServerOnly 灌字）：复用旧 TetrisScorePopup 对象池
local okPopup, TetrisScorePopup = pcall(require, "EnvLua.Server.Tetris.TetrisScorePopup")
if not okPopup then TetrisScorePopup = nil end
-- [结算] 触发引擎胜负/积分/队伍 Domain API 注入（均 ServerOnly，须在服务端脚本 require）
pcall(require, "EnvLua.Core.LuaHint.GameOutcomeAPI")
pcall(require, "EnvLua.Core.LuaHint.BattleDataAPI")
pcall(require, "EnvLua.Core.LuaHint.PlayerAPI")
-- [P9] 设置存档：CustomSaveAPI（ServerOnly），须在服务端脚本 require 触发注入
pcall(require, "EnvLua.Core.LuaHint.CustomSaveAPI")
local SAVE_KEY_LANG = "Tetris.Lang"        -- 语言 1=zh / 2=en / 3=ar
local SAVE_KEY_BGM  = "Tetris.BgmVolume"   -- BGM 音量 0~1
local SAVE_KEY_SFX  = "Tetris.SfxVolume"   -- 音效音量 0~1
local TetrisBackgroundWidget = require("EnvLua.Server.Tetris.TetrisBackgroundWidget")  -- 正确版：基于出生点装置生成远景背景挂件
local TetrisScene3DUIServer = require("EnvLua.Server.Tetris.TetrisScene3DUIServer")

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

-- [消行飘字] 3D Actor UI（ServerOnly）：复用旧 TetrisScorePopup，按 seat 几何把 +XX / 连击评价
-- 弹在"被消行右侧"。renderer 表只需 TetrisScorePopup 用到的几个字段（origin/right/forward/center/yaw）。
-- @param seat number 几何槽位 0/1；@param rows 消行行号；@param delta 本次得分增量；@param combo 连击数
-- 构造给 TetrisScorePopup 用的兼容 renderer（只含它实际读取的几何字段）
function ClassicGameState:_popupRendererForSeat(seat)
    local okCfg, C = pcall(require, "EnvLua.Common.Tetris.TetrisConfig")
    if not okCfg or type(C) ~= "table" then return nil end
    local g = self._boardGeom
    if not g then return nil end
    local o = (seat == 1) and g.o1 or g.o0
    local right = (seat == 1) and g.r1 or g.r0
    if not o or not right then return nil end
    local r = C.Render or {}
    local step = (r.CellSize or 1.0) + (r.CellGap or 0.02)
    local cols = ((C.Board or {}).Cols or 10)
    local w = (cols - 1) * step
    -- right=(fry,-frx) → forward=(-right.Y, right.X)（对齐 resolveBoardTransform 的 posYaw）
    local forward = { X = -right.Y, Y = right.X, Z = 0 }
    local center = { X = o.X + right.X * (w / 2), Y = o.Y + right.Y * (w / 2), Z = o.Z }
    local yaw = math.deg(atan2compat(forward.Y, forward.X)) or 0
    return {
        origin = o, boardRight = right, boardForward = forward, boardCenter = center,
        boardYaw = yaw, boardIndex = (seat == 1) and 2 or 1,
        rot = nil, hideLoc = { X = o.X, Y = o.Y, Z = o.Z - 50 },
    }, C
end

function ClassicGameState:PlayScorePopupForSeat(seat, rows, delta, combo)
    if not TetrisScorePopup then return end
    local renderer, C = self:_popupRendererForSeat(seat)
    if not renderer or not C then return end
    local sp = C.ScorePopup or {}
    if sp.Enabled == false then return end
    local gain = tonumber(delta) or 0
    if gain <= 0 then return end
    local ok, res = pcall(function()
        return TetrisScorePopup.Show(self, renderer, rows, gain, combo)
    end)
    if not ok then
        print("[Popup][Server/GS][WARN] 飘字 Show 报错: " .. tostring(res))
        return
    end
    print("[Popup][Server/GS] 飘字 seat=" .. tostring(seat) .. " +" .. tostring(gain) ..
        " combo=" .. tostring(combo) .. " 显示=" .. tostring(res))
end

-- [特效] 扔垃圾拖尾特效（ServerOnly 粒子）：起点=fromSeat 盘最左列/消行中行，终点=对手盘心。
-- 受 SceneEffectAPI 无有效位移接口所限（旧版 SetSceneEffectPosition 实跑原地不动），
-- 这里用「起点粒子 + 延迟在目标盘播到达粒子」两段式近似飞行，避免引入隐形载体 Actor 的复杂度。
-- @param fromSeat number 投掷方几何槽位 0/1
-- @param rows table|nil 本次消行行号（决定起点竖直位置，nil 取盘中行）
function ClassicGameState:PlayGarbageFx(fromSeat, rows)
    if type(SceneEffectAPI) ~= "table" or not SceneEffectAPI.CreateSceneEffect then return end
    local okCfg, C = pcall(require, "EnvLua.Common.Tetris.TetrisConfig")
    if not okCfg or type(C) ~= "table" then return end
    local gc = C.GarbageEffect or {}
    if gc.Enabled == false then return end
    local g = self._boardGeom
    if not g then
        if not self._gfxGeomWarned then
            self._gfxGeomWarned = true
            print("[Fx][Server/GS] 垃圾特效跳过：盘面几何未就绪")
        end
        return
    end
    local key = gc.PresetKey or "13_EffectPreset_1193030723"
    local ref = (type(AssetRef) == "table" and AssetRef[key]) or nil
    if not ref then
        if not self._gfxRefWarned then
            self._gfxRefWarned = true
            print("[Fx][Server/GS][WARN] 垃圾特效资源未注册 AssetRef[" .. tostring(key) .. "]")
        end
        return
    end

    local targetSeat = (fromSeat == 1) and 0 or 1
    local o = (fromSeat == 1) and g.o1 or g.o0
    local right = (fromSeat == 1) and g.r1 or g.r0
    local to = (targetSeat == 1) and g.o1 or g.o0
    local toRight = (targetSeat == 1) and g.r1 or g.r0
    if not o or not right or not to or not toRight then return end

    local r = C.Render or {}
    local step = (r.CellSize or 1.0) + (r.CellGap or 0.02)
    local cols = ((C.Board or {}).Cols or 10)
    local halfW = (cols - 1) * step / 2
    local side = -(halfW + (type(gc.SideOffsetM) == "number" and gc.SideOffsetM or 0))
    local D = (type(gc.DistanceFrontM) == "number") and gc.DistanceFrontM or 0
    local hgt = (type(gc.HeightOffsetM) == "number") and gc.HeightOffsetM or 0

    local minRow, maxRow
    for _, row in ipairs(rows or {}) do
        local n = tonumber(row)
        if n then minRow = math.min(n, minRow or n); maxRow = math.max(n, maxRow or n) end
    end
    local midRow = minRow and ((minRow + maxRow) / 2) or (((C.Board or {}).Rows or 20) / 2)
    -- 起点：盘心沿 -right 到最左列，再沿 forward 前置 D（近似用 right 方向叠加）
    local fromPos = {
        X = o.X + right.X * (side + D),
        Y = o.Y + right.Y * (side + D),
        Z = o.Z - (midRow - 1) * step + hgt,
    }
    -- 终点：目标盘心
    local targetPos = {
        X = to.X + toRight.X * halfW,
        Y = to.Y + toRight.Y * halfW,
        Z = to.Z + (type(gc.TargetHeightOffsetM) == "number" and gc.TargetHeightOffsetM or 0),
    }
    local scale = gc.Scale or { X = 3, Y = 3, Z = 3 }
    local travel = (type(gc.TravelDuration) == "number") and gc.TravelDuration or 0.6
    local dur = (type(gc.Duration) == "number") and gc.Duration or 1.0

    -- 起点粒子
    local function spawnAt(pos)
        local ok, id = pcall(function()
            return SceneEffectAPI.CreateSceneEffect(ref, Game:ConstructFVectorByLuaTable(pos), dur)
        end)
        if ok and id and id ~= 0 then
            pcall(function()
                SceneEffectAPI.SetSceneEffectScale(id, Game:ConstructFVectorByLuaTable({
                    X = scale.X or 1, Y = scale.Y or 1, Z = scale.Z or 1,
                }))
            end)
        end
    end
    pcall(function() spawnAt(fromPos) end)
    -- 延迟在目标盘播"到达"粒子，形成投掷方向感
    self:AddTimerOnce(travel, function() pcall(function() spawnAt(targetPos) end) end)
    print("[Fx][Server/GS] 扔垃圾拖尾 fromSeat=" .. tostring(fromSeat) ..
        " → targetSeat=" .. tostring(targetSeat) .. " 行数=" .. tostring(#(rows or {})))
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
        self:RegisterServerFunction("P7_ReportBigFrame")     -- [BigFrame3D] 客户端上报 hold/next/backlight，服务端灌 3D 大框
        self:RegisterServerFunction("P7_PlayerReady")        -- [P7] 双方就绪：客户端选完技能上报，服务端仲裁后广播 AllReady
        self:RegisterServerFunction("P5_VersusEvent")        -- [对战] 技能/垃圾/减益跨端事件中转
        self:RegisterServerFunction("P9_SaveSettings")       -- [P9] 保存语言/音量到存档
        self:RegisterServerFunction("P9_RequestSettings")    -- [P9] 开局读取语言/音量存档
    end)
    print("[P0][Server/GS] RegisterServerFunction = " .. tostring(okReg) .. " " .. tostring(errReg))

    -- 2) 正确版远景背景挂件：加载期（BeginPlay）即基于出生点装置生成（与 TetrisMatch:Init 同流程）。
    self:_initBackgroundWidgets()

    -- 3) 延迟下发盘面基底（客户端据此建双盘；装置晚注入时内部重试）。
    -- 【时序修正】此处不再自动 StartAI：旧版开局 2s 就无条件拉起 AI，玩家还在开始界面未进战斗，
    -- AI 独自跑完整局并触发消行特效/快照刷屏。AI 现在只由客户端真正进入 Battle 后
    -- 经 P5_RequestAI 触发（单人分支，见 TetrisClientBattle:Start），未进战斗则 AI 不启动。
    -- 同时移除 P0/P2 早期验证性广播（ping/假快照），它们只是调试残留、开局刷日志。
    self:AddTimerOnce(2.0, function()
        self:BroadcastBoardTransform()
    end)
end

-- ===== 远景背景 3D UI 挂件：完全复刻正确版 TetrisMatch 的调用链 =====
-- 正确版基于「出生点装置(CreativeInstance + InstanceAPI)」用 TetrisBackgroundWidget.Spawn 生成，
-- 不依赖盘面基底；near best 无 TetrisMatch（客户端权威架构），故把其 Init/重试/兜底/刷图四环节搬到这里。
local function bgSpawnKeys()
    local so = TetrisConfig.SceneObjects or {}
    local keys = {}
    if so.SpawnPointKey then keys[#keys + 1] = { key = so.SpawnPointKey, index = 1 } end
    if so.SpawnPointKey2 then keys[#keys + 1] = { key = so.SpawnPointKey2, index = 2 } end
    return keys
end

-- 对应正确版 TetrisMatch:Init 内的远景挂件生成段。
function ClassicGameState:_initBackgroundWidgets()
    local cfg = TetrisConfig.BackgroundWidget
    if not (cfg and cfg.Enabled) then return end
    self._bgWidgets = {}
    for _, sk in ipairs(bgSpawnKeys()) do
        self._bgWidgets[sk.index] = TetrisBackgroundWidget.Spawn(sk.key, sk.index)
    end
    -- 准备阶段重试：等待出生点装置与 ActorPreset 注入就绪（0.2s×150）。
    self._bgRetry = { pending = {}, tries = 0, max = 150 }
    for i, actor in pairs(self._bgWidgets) do
        if not actor then self._bgRetry.pending[i] = true end
    end
    if next(self._bgRetry.pending) then
        self:_retryBackgroundWidgets()
    end
end

-- 对应正确版 TetrisMatch:_retryBackgroundWidgets。
function ClassicGameState:_retryBackgroundWidgets()
    if not self._bgRetry or not next(self._bgRetry.pending) then return end
    self._bgRetry.tries = (self._bgRetry.tries or 0) + 1
    if self._bgRetry.tries > (self._bgRetry.max or 150) then
        print(string.format("[BGWidget][GS][WARN] 准备阶段重试超时(%d次)，交由开局兜底", self._bgRetry.tries))
        self._bgRetry.pending = {}
        return
    end
    local keys = bgSpawnKeys()
    for i in pairs(self._bgRetry.pending) do
        for _, sk in ipairs(keys) do
            if sk.index == i then
                local actor = TetrisBackgroundWidget.Spawn(sk.key, sk.index)
                if actor then
                    self._bgWidgets[i] = actor
                    self._bgRetry.pending[i] = nil
                    print(string.format("[BGWidget][GS] 准备阶段重试成功 index=%s (第%d次)", tostring(i), self._bgRetry.tries))
                end
                break
            end
        end
    end
    if next(self._bgRetry.pending) then
        self:AddTimerOnce(0.2, function() self:_retryBackgroundWidgets() end)
    end
end

-- 对应正确版 TetrisMatch:BuildGames 里的兜底补生成（盘面基底就绪/难度键注入时再补一次）。
-- near best 无分阶段构建接管，故兜底不设 _bgBuildStarted 终止重试，而是继续补生成 + 刷图。
function ClassicGameState:_ensureBackgroundWidgetsFallback()
    local cfg = TetrisConfig.BackgroundWidget
    if not (cfg and cfg.Enabled) then return end
    self._bgWidgets = self._bgWidgets or {}
    for _, sk in ipairs(bgSpawnKeys()) do
        if not self._bgWidgets[sk.index] then
            self._bgWidgets[sk.index] = TetrisBackgroundWidget.Spawn(sk.key, sk.index)
            -- 兜底生成成功则清掉对应重试 pending（若重试仍在跑）
            if self._bgWidgets[sk.index] and self._bgRetry then
                self._bgRetry.pending[sk.index] = nil
            end
        end
    end
    self:RefreshBackgroundOpponentImages()
end

-- 对应正确版 TetrisMatch:RefreshBackgroundOpponentImages + _applyBgOpponentImages。
function ClassicGameState:RefreshBackgroundOpponentImages()
    local cfg = TetrisConfig.BackgroundWidget
    if not (cfg and cfg.Enabled and cfg.ImageChildName and cfg.OpponentImages) then return end
    if not self._bgWidgets then return end
    local kind = self._bgImageKey or "Human"
    local key = cfg.OpponentImages[kind] or cfg.OpponentImages.Human
    if not key then return end
    local imgID = (type(AssetRef) == "table" and AssetRef[key]) or key
    local pending = {}
    for i, actor in pairs(self._bgWidgets) do
        if actor then pending[#pending + 1] = { actor = actor, name = cfg.ImageChildName, imgID = imgID } end
    end
    if #pending > 0 then self:_applyBgOpponentImages(pending, 0) end
end

function ClassicGameState:_applyBgOpponentImages(pending, tries)
    if not pending or #pending == 0 then return end
    local remain = {}
    for _, p in ipairs(pending) do
        local ok = false
        pcall(function() ok = TetrisBackgroundWidget.SetChildImage(p.actor, p.name, p.imgID) end)
        if not ok then remain[#remain + 1] = p end
    end
    if #remain > 0 and tries < 10 then
        self:AddTimerOnce(0.3, function() self:_applyBgOpponentImages(remain, tries + 1) end)
    end
end

-- [P5-5b] 启动服务端 AI（单人模式由客户端 P5_RequestAI 触发）
-- 每局都新建 Driver/Board：上一局若真人先顶出，AI 未自停，旧 driver.running 仍为 true，
-- 若只看 running 做幂等会跳过 new，导致第二局 AI 盘沿用上局残局 → 表现为「AI 盘没初始化」。
function ClassicGameState:StartAI()
    local okDrv, drvOrErr = pcall(function()
        local Driver = require("EnvLua.Server.Tetris.TetrisAIDriver")
        if self._p3Driver then
            pcall(function() self._p3Driver:Stop() end)  -- 停旧定时器/推进
            self._p3Driver = nil
        end
        self._p3Driver = Driver:new(self, { quality = self._aiQuality or 0.8, tag = "AI-P3", interval = 0.1, snapshotEvery = 1 })
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
        -- [飘字] 几何就绪即预热消行飘字 3D Actor 池（资源未注册时静默跳过，注册后自动生效）
        if TetrisScorePopup then
            pcall(function()
                local renderer = self:_popupRendererForSeat(0)
                if renderer then TetrisScorePopup.Prewarm(renderer) end
            end)
        end
        -- [BGS] 几何首次就绪即生成远景背景挂件（服务端生成+灌图，实跑验证可显示）
        self:_ensureBackgroundWidgets(0)
        -- [S3D] 几何首次就绪即生成其余场景 3D UI（BigFrame3D/BehindBoardWidget/BoardBackdrop3D）
        pcall(function()
            TetrisScene3DUIServer.Ensure(self, g)
            -- 大框生成后，若客户端已上报过 hold/next，补灌一次（避免上报早于大框生成而丢失）
            if self._bigFrameData then
                for idx, d in pairs(self._bigFrameData) do
                    TetrisScene3DUIServer.SetBigFrameHoldNext(self, idx, d[1], d[2], d[3])
                end
            end
        end)
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
    -- [BigFrame3D] 缓存 seat→playerKey（bigframe_1=seat0, bigframe_2=seat1），供 hold/next 上报按 playerKey 定位大框
    self._seatKeys = { [0] = p0, [1] = p1 }
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
    -- [BigFrame3D] seat 刚确定：补灌「seat 未定时暂存」的 hold/next，消除大框初秒默认图
    self:_flushBigFramePending()

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

-- [BGS] 远景背景挂件：改为正确版调用链（出生点装置 + TetrisBackgroundWidget）。
-- 保留此函数名作为兼容转发：几何就绪 / 难度键注入时都走「兜底生成 + 按难度刷图」。
-- 难度图键 _bgImageKey 由单人 P5_RequestAI(quality) 注入，双人时固定 Human。
function ClassicGameState:_ensureBackgroundWidgets(tries)
    self:_ensureBackgroundWidgetsFallback()
end

-- [P7] 客户端兜底请求（开局广播丢包/晚到时重发缓存）
function ClassicGameState:P7_RequestBoardTransform()
    self:BroadcastBoardTransform()
end

-- [BigFrame3D] 客户端上报自己盘的 hold/next/backlight，服务端灌对应盘的 3D 大框。
-- 参数：selfKey（玩家标识，用于定位 seat）、holdType/nextType（1..7/道具 9..11/nil）、backlight（bool）。
function ClassicGameState:P7_ReportBigFrame(selfKey, holdType, nextType, backlight)
    local k = tonumber(selfKey) or 0
    local seat = nil
    if self._seatKeys then
        if self._seatKeys[0] == k then seat = 0
        elseif self._seatKeys[1] == k then seat = 1 end
    end
    -- 单人兜底：selfKey 为 0/未匹配时，用缓存的真人 seat
    if not seat and self._humanSeat ~= nil then seat = self._humanSeat end
    if seat == nil then
        -- seat 尚未确定（盘面基底还没算出）：按 playerKey 暂存，seat 就绪后由 _flushBigFramePending 补灌，
        -- 避免首帧上报因 seat 未定被直接丢弃导致大框初秒是默认图。
        self._bigFramePendingByKey = self._bigFramePendingByKey or {}
        self._bigFramePendingByKey[k] = { holdType, nextType, backlight }
        print("[BigFrame3D][Server] seat 未定，暂存 playerKey=" .. tostring(k) .. " 的 hold/next，待 seat 就绪补灌")
        return
    end
    local boardIndex = seat + 1  -- seat0→bigframe_1, seat1→bigframe_2
    -- 缓存最新值：大框若尚未生成，Ensure 生成后会用该缓存补灌一次
    self._bigFrameData = self._bigFrameData or {}
    self._bigFrameData[boardIndex] = { holdType, nextType, backlight }
    pcall(function()
        TetrisScene3DUIServer.SetBigFrameHoldNext(self, boardIndex, holdType, nextType, backlight)
    end)
end

-- [BigFrame3D] seat 就绪后，把「seat 未定时按 playerKey 暂存」的 hold/next 转成 boardIndex 补灌。
-- 调用点：BroadcastBoardTransform 算出 _seatKeys/_humanSeat 之后。
function ClassicGameState:_flushBigFramePending()
    local pending = self._bigFramePendingByKey
    if not pending or not self._seatKeys then return end
    for key, d in pairs(pending) do
        local seat = nil
        if self._seatKeys[0] == key then seat = 0
        elseif self._seatKeys[1] == key then seat = 1 end
        if seat == nil and self._humanSeat ~= nil then seat = self._humanSeat end
        if seat ~= nil then
            local boardIndex = seat + 1
            self._bigFrameData = self._bigFrameData or {}
            self._bigFrameData[boardIndex] = d
            pcall(function()
                TetrisScene3DUIServer.SetBigFrameHoldNext(self, boardIndex, d[1], d[2], d[3])
            end)
            pending[key] = nil
            print("[BigFrame3D][Server] 补灌暂存 hold/next playerKey=" .. tostring(key) ..
                " → bigframe_" .. tostring(boardIndex))
        end
    end
end

-- ===== P8：服务端权威账本（客户端本地即时操作，随机源/每块落点由客户端上报，服务端重放得权威分数）=====
-- 客户端每落一块上报 (seq, type, rot, x, y) = Board.lockPiece 记录的 lastLockedPiece（含重力落定与硬降的实际位置）。
-- 影子 Board 直接把 active 设为该值再 lockPiece()，不调用 spawn()/hardDrop()，因此完全不依赖服务端随机、落点与客户端逐格一致。
-- lockPiece 内部无消行时会自己 spawn 下一块（随机），但下一次上报会直接覆盖 active，不影响权威判定。
-- 权威 score/lines/over 存于 self._authBoard，回 ack(seq, score, lines, over) 供客户端对账。
function ClassicGameState:Auth_Piece(seq, pieceType, rot, x, y)
    local okB, Board = pcall(require, "EnvLua.Common.Tetris.TetrisBoard")
    if not okB or not Board then return end
    seq = tonumber(seq) or 0
    -- [重开] 新局客户端 seq 从 1 重新开始：检测到回退即认定新局，重置权威影子盘/顶出标志，
    -- 避免上局残留导致下局误判胜负、seq 被旧值挡住无法重放。
    if seq < (self._authSeq or 0) then
        print("[Auth][Server/GS] 检测到新局(seq=" .. tostring(seq) .. "<" .. tostring(self._authSeq) ..
            ")，重置权威盘与顶出标志")
        self._authBoard = nil
        self._authTopOutReported = false
        self._authSeq = 0
    end
    if seq <= (self._authSeq or 0) then return end   -- 去重/乱序：只接受严格递增 seq
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
            local scoreBefore = b.score or 0
            if b.lockPaused then pcall(function() b:doClear() end) end
            -- [特效] 我方盘消行：doClear 后取被消行号播粒子特效（ServerOnly，服务端播全员可见）。
            local rows = b:consumeClearedRows()
            if rows and #rows > 0 then
                -- [特效] 我方盘用真人实际 seat（可能 0 或 1），不写死，避免与对方盘特效互换
                local mySeat = self._humanSeat or 0
                pcall(function() self:PlayClearFxForSeat(mySeat, rows) end)
                -- [飘字] 3D Actor 弹 +XX / 连击评价（delta=本次消行得分增量）
                local delta = (b.score or 0) - scoreBefore
                pcall(function()
                    self:PlayScorePopupForSeat(mySeat, rows, delta, b.combo or 0)
                end)
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

-- ===== P5：结算上报（胜数榜 + 引擎胜负/积分 + 权威判定）=====
-- 一局结束客户端调一次；单人打 AI 也走这里（win=true 时 playerKey 是本地玩家）。
-- 【权威判定】单人模式用服务端影子盘的 Auth_TopOut 标记覆盖客户端自报：真人被权威判顶出→必输，
-- 防止客户端误判/虚报。双人模式影子盘只有一份（混双盘），权威标记不可靠，仍沿用客户端上报。
-- 【引擎上报】GameOutcomeAPI.SetTeamRoundOutcome / BattleDataAPI.SetPlayerIntegral 均 ServerOnly，
-- 只能在这里调；队伍 ID 取 PlayerAPI.GetPlayerTeamID，取不到回退玩家列表序号。
function ClassicGameState:P5_ReportResult(win, playerKey)
    print("[P5][Server/GS] ReportResult 自报win=" .. tostring(win) .. " playerKey=" .. tostring(playerKey))
    -- [结算] 停掉服务端 AI：真人先顶出时 AI 不会自停，否则它继续推进/广播快照；
    -- 同时确保下局 StartAI 一定 new 出全新棋盘（配合 StartAI 的强制重建）。
    if self._p3Driver then
        pcall(function() self._p3Driver:Stop() end)
        self._p3Driver = nil
    end
    local okCfg, Config = pcall(require, "EnvLua.Common.Tetris.TetrisConfig")
    if not okCfg or not Config then return end
    local players = Game:GetAllPlayerStates()
    if not players or not players.Num then return end

    -- 真人数（LuaArray 0 基）：单人(含 AI)才启用权威覆盖
    local playerCount = players:Num()
    local finalWin = (win == true)
    if playerCount < 2 and self._authTopOutReported then
        if finalWin then
            print("[P5][Server/GS] 权威改判：客户端自报赢，但服务端权威顶出已确认 → 改判输")
        end
        finalWin = false
    end

    -- ===== 胜数榜（赢 +1，输不扣）=====
    local rt = rankType(Config)
    for i = 0, players:Num() - 1 do
        local ps = players:Get(i)
        if ps and ps.GetPlayerKey and ps:GetPlayerKey() == playerKey then
            if type(RankAPI) == "table" then
                if finalWin then
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
            end
            break
        end
    end
    if type(RankAPI) == "table" and RankAPI.RefreshRank then pcall(function() RankAPI.RefreshRank(rt) end) end

    -- ===== 引擎胜负/积分上报（ServerOnly，仅服务端）=====
    local settle = Config.Settle or {}
    if settle.ReportOutcome == false then return end
    if type(GameOutcomeAPI) ~= "table" or type(GameOutcomeAPI.SetTeamRoundOutcome) ~= "function" then
        print("[Outcome][Server/GS][WARN] GameOutcomeAPI 不可用，跳过引擎胜负上报")
        return
    end
    local O = settle.OutcomeType or { Win = 1, Lose = 2, Draw = 3 }
    for i = 0, players:Num() - 1 do
        local ps = players:Get(i)
        if ps then
            -- 队伍 ID：真人队伍取 PlayerAPI 真实 teamID；取不到回退玩家列表序号（稳定唯一）
            local teamID = nil
            pcall(function()
                if type(PlayerAPI) == "table" and type(PlayerAPI.GetPlayerTeamID) == "function" then
                    teamID = PlayerAPI.GetPlayerTeamID(ps)
                end
            end)
            if type(teamID) ~= "number" then teamID = i + 1 end
            -- 结算发起方按权威结果定胜负；其余真人（双人对手）取反。单人只有发起方一个真人。
            local key = 0
            pcall(function() if ps.GetPlayerKey then key = ps:GetPlayerKey() or 0 end end)
            -- 显式判断，避免 `(a) and finalWin or (not finalWin)` 在 finalWin=false 时被 or 分支翻转
            local thisWin
            if key == playerKey then
                thisWin = finalWin
            else
                thisWin = not finalWin
            end
            local outcome = thisWin and O.Win or O.Lose
            local okReport, errReport = pcall(function()
                GameOutcomeAPI.SetTeamRoundOutcome(teamID, outcome, thisWin)
            end)
            print("[Outcome][Server/GS] 队伍#" .. tostring(teamID) .. " key=" .. tostring(key) ..
                " outcome=" .. tostring(outcome) .. " endFighting=" .. tostring(thisWin) ..
                " ok=" .. tostring(okReport) .. (okReport and "" or (" err=" .. tostring(errReport))))
            -- 积分：推权威盘分数（单人准；双人影子盘混合，仅作参考）
            if type(BattleDataAPI) == "table" and type(BattleDataAPI.SetPlayerIntegral) == "function" then
                local score = (self._authBoard and self._authBoard.score) or 0
                pcall(function() BattleDataAPI.SetPlayerIntegral(ps, score) end)
            end
        end
    end
end

-- ===== P9：设置存档（语言/音量）。CustomSaveAPI 仅 ServerOnly，客户端经 RPC 桥接 =====
-- 回传用 multicast + playerKey 过滤，避免依赖未验证的单播 PC 获取。
local function findPlayerStateByKey(key)
    if type(key) ~= "number" then return nil end
    local ok, arr = pcall(function() return Game:GetAllPlayerStates() end)
    if not ok or not arr or not arr.Num then return nil end
    for i = 0, arr:Num() - 1 do
        local ps = arr:Get(i)
        if ps and ps.GetPlayerKey then
            local okKey, k = pcall(function() return ps:GetPlayerKey() end)
            if okKey and k == key then return ps end
        end
    end
    return nil
end

-- C→S：保存当前语言/音量到玩家存档
function ClassicGameState:P9_SaveSettings(key, lang, bgm, sfx)
    if type(CustomSaveAPI) ~= "table" then return end
    local ps = findPlayerStateByKey(key)
    if not ps then return end
    local L = (type(lang) == "number" and lang >= 1 and lang <= 3) and math.floor(lang) or nil
    local B = (type(bgm) == "number") and math.max(0, math.min(1, bgm)) or nil
    local S = (type(sfx) == "number") and math.max(0, math.min(1, sfx)) or nil
    if L then pcall(function() CustomSaveAPI.SetPlayerCustomSaveData(ps, SAVE_KEY_LANG, L) end) end
    if B then pcall(function() CustomSaveAPI.SetPlayerCustomSaveData(ps, SAVE_KEY_BGM, B) end) end
    if S then pcall(function() CustomSaveAPI.SetPlayerCustomSaveData(ps, SAVE_KEY_SFX, S) end) end
    print("[P9][Server/GS] 存档已写 key=" .. tostring(key) .. " lang=" .. tostring(L) ..
        " bgm=" .. tostring(B) .. " sfx=" .. tostring(S))
end

-- C→S：开局读取语言/音量并回传客户端；无存档回退默认 2 / 0.6 / 0.6
function ClassicGameState:P9_RequestSettings(key)
    if type(CustomSaveAPI) ~= "table" then return end
    local ps = findPlayerStateByKey(key)
    if not ps then return end
    -- 先留原始返回值：三个键全为 nil 即首次玩（无任何存档），hasSave 回传供客户端识别。
    local rawLang, rawBgm, rawSfx = nil, nil, nil
    pcall(function() rawLang = CustomSaveAPI.GetPlayerCustomSaveData(ps, SAVE_KEY_LANG) end)
    pcall(function() rawBgm = CustomSaveAPI.GetPlayerCustomSaveData(ps, SAVE_KEY_BGM) end)
    pcall(function() rawSfx = CustomSaveAPI.GetPlayerCustomSaveData(ps, SAVE_KEY_SFX) end)
    local hasSave = (rawLang ~= nil or rawBgm ~= nil or rawSfx ~= nil)
    local lang = (type(rawLang) == "number" and rawLang >= 1 and rawLang <= 3) and rawLang or 2
    local bgm  = (type(rawBgm) == "number") and rawBgm or 0.6
    local sfx  = (type(rawSfx) == "number") and rawSfx or 0.6
    lang, bgm, sfx = math.floor(lang), math.max(0, math.min(1, bgm)), math.max(0, math.min(1, sfx))
    pcall(function() self:CallClientFunctionMulticast("P9_SettingsData", key, lang, bgm, sfx, hasSave) end)
    print("[P9][Server/GS] 存档已读并回传 key=" .. tostring(key) .. " lang=" .. tostring(lang) ..
        " bgm=" .. tostring(bgm) .. " sfx=" .. tostring(sfx) .. " hasSave=" .. tostring(hasSave))
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
function ClassicGameState:P5_RequestAI(quality)
    local playerCount = 0
    pcall(function()
        local ps = Game:GetAllPlayerStates()
        if ps and ps.Num then playerCount = ps:Num() end
    end)
    -- [BGS] 背景图键：单人按 AI quality 映射，双人固定 Human
    local q = tonumber(quality) or 0.8
    self._bgImageKey = (q <= 0.6 and "Easy") or (q <= 0.9 and "Normal") or "Hard"
    if playerCount >= 2 then
        self._bgImageKey = "Human"
        print("[P5][Server/GS] P5_RequestAI 忽略：当前是双人模式(" .. tostring(playerCount) .. "人)")
    else
        print("[P5][Server/GS] P5_RequestAI 单人模式，启动 AI quality=" .. tostring(q) .. " bgKey=" .. tostring(self._bgImageKey))
        self._aiQuality = q
        self:StartAI()
    end
    -- 难度键就绪后刷新背景灌图（几何可能早于本请求就绪，Ensure 内部幂等）
    self:_ensureBackgroundWidgets(0)
end

-- ===== P5-5b：双人快照中转（广播给所有客户端；客户端按 senderKey 过滤自己）=====
function ClassicGameState:P5_ReportSnapshot(snap)
    if type(snap) ~= "table" then return end
    local okSend, err = pcall(function()
        self:CallClientFunctionMulticast("P5_OpponentSnapshot", snap)
    end)
    if not okSend then print("[P5][Server/GS] 快照中转失败: " .. tostring(err)) end
end

-- ===== 对战事件中转：技能减益/垃圾行/落石 C→S→C 广播 =====
-- 客户端施法方把 (kind, n, fromKey, payload) 上报，服务端广播给所有客户端；
-- 各客户端 OnVersusEvent 按 fromKey 过滤自己后，把效果写进本地镜像盘。
-- 【单人兜底】单人打 AI 时没有真人接收方；减益直接作用于本地 AI 盘由客户端 AIDriver 决定，
-- 这里仅做中转，不额外处理。payload 保留给未来的扩展（如 swapLanded 回执）。
function ClassicGameState:P5_VersusEvent(kind, n, fromKey, payload)
    if type(kind) ~= "string" then return end
    local cnt = tonumber(n) or 0
    local from = tonumber(fromKey) or 0
    local ok, err = pcall(function()
        self:CallClientFunctionMulticast("P5_VersusEvent", kind, cnt, from, payload)
    end)
    if not ok then
        print("[Versus][Server/GS] 中转失败: " .. tostring(err))
        return
    end
    print("[Versus][Server/GS] 中转 kind=" .. tostring(kind) .. " n=" .. tostring(cnt) ..
        " fromKey=" .. tostring(from))

    -- [单人 AI 桥接] 真人扔出的垃圾/减益：客户端 multicast 会被自己过滤，AI 盘在服务端必须这里直接落地。
    -- 只有单人（有 AI driver）才处理；双人有真人接收方，交由客户端 ApplyVersusEffect。
    local drv = self._p3Driver
    if not drv or not drv.running or not drv.board then return end
    if kind == "garbage" and cnt > 0 then
        pcall(function() drv.board:addGarbage(cnt) end)
        -- [特效] 真人盘扔垃圾：用真人 seat 播拖尾特效（起点真人盘、终点 AI 盘）
        if type(self.PlayGarbageFx) == "function" then
            pcall(function() self:PlayGarbageFx(self._humanSeat or 0, nil) end)
        end
        print("[Versus][Server/GS] 单人桥接：真人→AI 注入垃圾 +" .. tostring(cnt) .. " 行")
    elseif kind == "noRotate" then
        pcall(function() drv.board.noRotateNext = (drv.board.noRotateNext or 0) + cnt end)
    elseif kind == "swap" then
        pcall(function() drv.board.swapRequested = true; drv.board.pendingSwapNext = true end)
        -- AI 块的 swapLanded 回执：真人需要解 SK08 CD；AI 落地后由 driver 侧发（简化：定时回执）
    elseif kind == "rockfall" then
        pcall(function() drv.board:queueRockfall(cnt) end)
        print("[Rockfall][Server/GS] 单人桥接：真人→AI 落石 +" .. tostring(cnt) .. " 列")
    end
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

-- ===== P7：双方就绪握手（真人对战等双方选完技能再一起开局；单人把 AI 视为就绪）=====
-- 客户端选完技能后 CallServerFunction("P7_PlayerReady", selfKey, gen)；服务端按 playerKey 去重记账，
-- 全员就绪（need = min(真人数,2)，单人 need=1 即 AI 恒就绪）后广播 P7_AllReady(gen)，两端同时进 loading。
-- gen 代号防跨局/重发串扰：广播成功后 gen+1 且清空 ready 表，旧 gen 的上报被忽略；
-- 若客户端 gen 落后（漏收广播，多为晚进入者），补发一次上一次广播的 gen（multicast，客户端侧幂等）。
function ClassicGameState:P7_PlayerReady(playerKey, gen)
    self._readyGen = self._readyGen or 0   -- 当前期望代号（本局广播将用这个值）
    local g = tonumber(gen) or 0
    local key = tonumber(playerKey) or 0

    if g < self._readyGen then
        -- 客户端 gen 落后 = 没收到上一次 AllReady（晚进入/广播漏收）→ 补发上一版广播，客户端 OnAllReady 幂等
        local lastGen = self._readyGen - 1
        pcall(function() self:CallClientFunctionMulticast("P7_AllReady", lastGen) end)
        print("[P7][Ready][Server] 客户端 gen 落后(" .. tostring(g) .. "<" .. tostring(self._readyGen) ..
            ") 补发 AllReady gen=" .. tostring(lastGen) .. " playerKey=" .. tostring(key))
        return
    end
    if g > self._readyGen then
        print("[P7][Ready][Server][WARN] 客户端 gen 超前(" .. tostring(g) .. ">" .. tostring(self._readyGen) ..
            ")，忽略 playerKey=" .. tostring(key))
        return
    end

    self._readyKeys = self._readyKeys or {}
    if self._readyKeys[key] then
        print("[P7][Ready][Server] 重复 ready 忽略 playerKey=" .. tostring(key) .. " gen=" .. tostring(g))
        return
    end
    self._readyKeys[key] = true

    -- 服务端权威统计真人数（LuaArray :Num() 0 基），单人 need=1（AI 视为恒就绪）
    local playerCount = 0
    pcall(function()
        local ps = Game:GetAllPlayerStates()
        if ps and ps.Num then playerCount = ps:Num() end
    end)
    local need = math.max(1, math.min(playerCount, 2))
    local readyCount = 0
    for _ in pairs(self._readyKeys) do readyCount = readyCount + 1 end
    print("[P7][Ready][Server] 收到 ready playerKey=" .. tostring(key) ..
        " 已就绪=" .. tostring(readyCount) .. "/" .. tostring(need) ..
        " 真人数=" .. tostring(playerCount) .. " gen=" .. tostring(g))

    if readyCount < need then return end   -- 还有人没就绪：等（WaitHint 由客户端维持显示）

    local sendGen = self._readyGen
    local ok, err = pcall(function() self:CallClientFunctionMulticast("P7_AllReady", sendGen) end)
    print("[P7][Ready][Server] 全员就绪 → 广播 P7_AllReady gen=" .. tostring(sendGen) ..
        " ok=" .. tostring(ok) .. (ok and "" or (" err=" .. tostring(err))))
    if ok then
        self._readyGen = sendGen + 1   -- 本局就绪已完成，下一局需重新握手
        self._readyKeys = {}
    end
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
    -- [飘字] 回合结束强制回收 3D Actor 池，避免跨局残留旧分数
    if TetrisScorePopup then pcall(function() TetrisScorePopup.Reset() end) end
end

local CClassicGameState = WoWClass(WoWClassicGameState, nil, ClassicGameState)
return CClassicGameState
