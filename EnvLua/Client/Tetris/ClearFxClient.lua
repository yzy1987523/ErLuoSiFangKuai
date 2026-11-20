-- ClearFxClient：客户端本地消行/爆炸特效（2026-11-20）
-- 架构：照搬 GarbageFxClient 已验证范式——SceneEffectAPI 是 ServerOnly（Core/LuaHint 确认），
-- 客户端改用 CreativeGameAPI.CreateActor 生成"粒子组件已设 AutoActivate 的 ActorPreset"，
-- Actor 一生成粒子自动播；生成后显式设 transform（CreateActor 直传 transform 项目实测不生效），
-- 再用 host:AddTimerOnce 定时 CreativeGameAPI.DestroyActor。
-- 每个客户端各自生成一份，双方各自可见，不依赖服务端 actor channel / SceneEffect。
--
-- 三类特效：
--   PlayRow(renderer, rows, blastRows, host)  普通消行横条(3617487677) + 爆炸横条(100032)
--   PlayColumn(renderer, blastFx, host)       爆破竖版光束(100032, Pitch=-90)
--
-- 单位纪律：CreateActor 的 Location=米；K2_SetActorLocation=厘米(cmLoc 显式 ×100)。
-- 资源：ActorPresetKey 为占位，由用户在 WOW Editor 注册 + update preset 后填 key。
local Config = require("EnvLua.Common.Tetris.TetrisConfig")

local ClearFxClient = {}

local cl = Config.Clear or {}
local rCfg = Config.Render or {}
local STEP_M = (rCfg.CellSize or 1.0) + (rCfg.CellGap or 0.02)
local COLS = ((Config.Board or {}).Cols or 10)
local ROWS = ((Config.Board or {}).Rows or 20)
local W_M = (COLS - 1) * STEP_M

local function atan2compat(y, x)
    local ok, v = pcall(function() return math.atan2(y, x) end)
    if ok then return v end
    ok, v = pcall(function() return math.atan(y, x) end)
    if ok then return v end
    if x > 0 then return math.atan(y / x) end
    if x < 0 then return math.atan(y / x) + (y >= 0 and math.pi or -math.pi) end
    return (y >= 0) and (math.pi / 2) or (-math.pi / 2)
end

local function cmLoc(loc)
    return Game:ConstructFVectorByLuaTable({
        X = (loc.X or 0) * 100, Y = (loc.Y or 0) * 100, Z = (loc.Z or 0) * 100,
    })
end

local function setActorPos(actor, locM)
    return pcall(function() actor:K2_SetActorLocation(cmLoc(locM), false, nil, true) end)
end

-- 欧拉角 -> FRotator（MakeFromEuler(Z=yaw) 项目约定，与 GarbageFxClient/竖版光束一致）
local function rotEuler(xDeg, yDeg, zDeg)
    local ok, rot = pcall(function()
        if type(FRotator) == "table" and FRotator.MakeFromEuler then
            return FRotator.MakeFromEuler(Game:ConstructFVectorByLuaTable({
                X = xDeg or 0, Y = yDeg or 0, Z = zDeg or 0,
            }))
        end
        return nil
    end)
    if ok and rot then return rot end
    return nil
end

-- 盘面朝向 yaw（度）：forward=(-right.Y,right.X)，与服务端 PlayBlastFxForSeat 同一算法
local function boardYaw(renderer)
    local r = (renderer and renderer.rightM) or { X = 1, Y = 0, Z = 0 }
    local fx, fy = -(r.Y or 0), (r.X or 0)
    return math.deg(atan2compat(fy, fx)) or 0
end

-- [诊断开关] FxDebugSpawnInFrontM：非 nil 时把所有特效强制放到"本地盘盘心正前方 N 米"。
-- 正前方 forward 用 ClientRenderer.bgTransform 同款算法：forward=(cos(posYaw),sin(posYaw))，
-- posYaw=frameYaw(-flip 时)，frameYaw=atan2(right.X,-right.Y) = boardYaw。
-- 用途：绕过行/列定位与朝向，直接验证"特效资源本身能否在玩家眼前渲染出来"。
local function applyDebugLoc(renderer, loc)
    local d = cl.FxDebugSpawnInFrontM
    if type(d) ~= "number" then return loc end
    local r = (renderer and renderer.rightM) or { X = 1, Y = 0, Z = 0 }
    local o = (renderer and renderer.originM) or { X = 0, Y = 0, Z = 0 }
    local board = Config.Board or {}
    local w = ((board.Cols or 10) - 1) * STEP_M
    local h = ((board.Rows or 20) - 1) * STEP_M
    -- 盘心
    local cx = o.X + (r.X or 0) * (w / 2)
    local cy = o.Y + (r.Y or 0) * (w / 2)
    local cz = o.Z - h / 2
    -- forward = boardYaw 方向（=bgTransform 的 posYaw，BoardFlipAxis180 默认 false）
    local yaw = boardYaw(renderer)
    local fx, fy = math.cos(math.rad(yaw)), math.sin(math.rad(yaw))
    local out = {
        X = cx + fx * d,
        Y = cy + fy * d,
        Z = cz,
    }
    if not ClearFxClient._dbgWarned then
        ClearFxClient._dbgWarned = true
        print("[ClearFxClient][DEBUG] FxDebugSpawnInFrontM=" .. tostring(d)
            .. " 强制落点=(" .. string.format("%.1f,%.1f,%.1f", out.X, out.Y, out.Z) .. ")"
            .. " 原落点=(" .. string.format("%.1f,%.1f,%.1f", loc.X or 0, loc.Y or 0, loc.Z or 0) .. ")")
    end
    return out
end

-- 生成一个特效 Actor（占位 key 未注册时 warn-once 并跳过，不影响玩法）
-- @param host WoWObject（提供 AddTimerOnce），通常传 Battle
-- @param key string ActorPresetKey（占位，用户填）
-- @param locM table 米坐标锚点
-- @param rot table|nil {X,Y,Z} 欧拉角（度）
-- @param scale table|nil {X,Y,Z}
-- @param dur number 存活时长（秒）
-- @param tag string 日志标签
local function spawnFx(host, key, locM, rot, scale, dur, tag)
    if not host or type(host.AddTimerOnce) ~= "function" then return end
    if type(CreativeGameAPI) ~= "table" or not CreativeGameAPI.CreateActor
        or not CreativeGameAPI.DestroyActor then return end
    local ref = (type(AssetRef) == "table" and key and AssetRef[key]) or nil
    print("[ClearFxClient] spawnFx tag=" .. tostring(tag) .. " key=" .. tostring(key)
        .. " AssetRef取到=" .. tostring(ref ~= nil)
        .. " AssetRef表=" .. tostring(type(AssetRef) == "table"))
    if not ref then
        -- 每次都打（不用 warn-once）：上一次的 warn-once 会吞掉后续不同 key 的失败，掩盖普通消行资源问题。
        print("[ClearFxClient][WARN] 资源未注册 AssetRef[" .. tostring(key)
            .. "] tag=" .. tostring(tag) .. " → 本条特效跳过（WOW Editor 注册 ActorPreset + update preset）")
        return
    end
    -- CreateActor 只传位置（米）；rot/scale 生成后显式设（项目实测直传 transform 不生效）
    local okA, actor = pcall(function()
        return CreativeGameAPI.CreateActor(ref, cmLoc(locM), nil, nil, nil)
    end)
    if not okA or not actor then
        if not ClearFxClient._spawnWarned then
            ClearFxClient._spawnWarned = true
            print("[ClearFxClient][WARN] CreateActor 失败 tag=" .. tostring(tag) .. " err=" .. tostring(actor))
        end
        return
    end
    local okPos = setActorPos(actor, locM)
    if rot then
        local r = rotEuler(rot.X, rot.Y, rot.Z)
        if r then pcall(function() actor:K2_SetActorRotation(r, false) end) end
    end
    if scale then
        pcall(function() actor:SetActorScale3D(Game:ConstructFVectorByLuaTable({
            X = scale.X or 1, Y = scale.Y or 1, Z = scale.Z or 1,
        })) end)
    end
    local destroyed = false
    host:AddTimerOnce(math.max(dur or 1.0, 0.1), function()
        if destroyed then return end
        destroyed = true
        pcall(function() CreativeGameAPI.DestroyActor(actor) end)
    end)
    print("[ClearFxClient] " .. tostring(tag) .. " 已生成 setOk=" .. tostring(okPos)
        .. " pos=(" .. string.format("%.1f,%.1f,%.1f", locM.X or 0, locM.Y or 0, locM.Z or 0) .. ")"
        .. " key=" .. tostring(key))
end

-- 普通/爆炸横行：每行生成一个横条 Actor。
-- 普通行锚盘心 + EffectSideOffsetM、无旋转、scale=EffectScale；
-- 爆炸行锚盘面右端(origin+right*W) + BlastRowEffectSideOffsetM、yaw=boardYaw+180、scale=BlastRowEffectScale。
-- 行号 1 基（顶行=1），Z 由 renderer:cellLocM 按 row 给出（顶行最高）。
function ClearFxClient.PlayRow(renderer, rows, blastRows, host)
    if cl.FxSpawnSide ~= nil and cl.FxSpawnSide ~= "Client" then return end
    if type(rows) ~= "table" or #rows == 0 then return end
    if not renderer or type(renderer.cellLocM) ~= "function" then
        if not ClearFxClient._geomWarned then
            ClearFxClient._geomWarned = true
            print("[ClearFxClient][WARN] 盘面基底未就绪，跳过横行特效")
        end
        return
    end
    local isBlast = {}
    if type(blastRows) == "table" then
        for _, br in ipairs(blastRows) do isBlast[br] = true end
    end
    local r = renderer.rightM or { X = 1, Y = 0, Z = 0 }
    local o = renderer.originM or { X = 0, Y = 0, Z = 0 }
    local by = boardYaw(renderer)
    local flip = cl.BlastRowYawFlip180
    if flip == nil then flip = true end
    local durNormal = (type(cl.EffectDuration) == "number") and cl.EffectDuration or 0.5
    local durBlast = (type(cl.BlastEffectDuration) == "number") and cl.BlastEffectDuration or 1.0
    for _, row in ipairs(rows) do
        local blast = (isBlast[row] == true)
        local dur = blast and durBlast or durNormal
        local key = blast
            and (cl.BlastRowFxActorPresetKey or cl.FxActorPresetKey or "__FILL_ME_BlastRowFx__")
            or (cl.FxActorPresetKey or "__FILL_ME_ClearFx__")
        local scale = blast and (cl.BlastRowEffectScale or cl.EffectScale) or cl.EffectScale
        local loc
        -- [2026-11-20 修复] 普通行也必须设 yaw 对齐盘面：新 ActorPreset(1877399573) 有默认朝向，
        -- rot=nil 时条侧对相机几乎不可见（服务端 SceneEffect 有自己的朝向故旧版能看到）。
        -- 普通行默认用 boardYaw（+EffectRowYawAdd 微调）；爆炸行用 boardYaw+BlastRowYawFlip180。
        local rot = { X = 0, Y = 0, Z = by + (type(cl.EffectRowYawAdd) == "number" and cl.EffectRowYawAdd or 0) }
        if blast then
            -- 爆炸横条：左端锚 origin（cellLocM(row,1) 即 origin + 该行 Z），条沿 +right 铺满整行
            loc = renderer:cellLocM(row, 1)
            local side = type(cl.BlastRowEffectSideOffsetM) == "number" and cl.BlastRowEffectSideOffsetM or 0
            loc = {
                X = loc.X + (r.X or 0) * side,
                Y = loc.Y + (r.Y or 0) * side,
                Z = loc.Z + ((cl.BlastRowEffectPositionOffset or {}).Z or 0),
            }
            rot = { X = 0, Y = 0, Z = by + (flip and 180 or 0) }
        else
            -- [2026-11-20 位置修复] 新 ActorPreset(1877399573) 是端点轴心的条，必须锚在盘面端点，
            -- 否则锚盘心(W/2)会让长为盘宽的条整条偏出盘面→看不见（旧 SceneEffect 3617487677 是中心轴心才用盘心）。
            -- EffectRowAnchorMode="end"(默认)=锚 col=1 端点；"center"=旧盘心行为（回退对比）。
            loc = renderer:cellLocM(row, 1)
            local anchorMode = cl.EffectRowAnchorMode or "end"
            local side = type(cl.EffectSideOffsetM) == "number" and cl.EffectSideOffsetM or 0
            if anchorMode == "center" then
                side = W_M / 2 + side
            end
            loc = {
                X = loc.X + (r.X or 0) * side,
                Y = loc.Y + (r.Y or 0) * side,
                Z = loc.Z + ((cl.EffectPositionOffset or {}).Z or 0),
            }
        end
        -- [诊断] FxDebugSpawnInFrontM 只作用于普通消行(blast=false)；爆炸横条保持原定位，不干扰观察。
        local finalLoc = (not blast) and applyDebugLoc(renderer, loc) or loc
        spawnFx(host, key, finalLoc, rot, scale, dur,
            "横行 row=" .. tostring(row) .. " blast=" .. tostring(blast))
    end
end

-- 爆破竖版光束：按列锚该列盘底，旋转 X=-90( Pitch,立起 ) + Yaw=boardYaw，scale=BlastEffectScale。
-- blastFx 为 { {col,bottom,top}, ... }（Board:clearLines 写、调用方 consumeBlastFx 取）。
function ClearFxClient.PlayColumn(renderer, blastFx, host)
    if cl.FxSpawnSide ~= nil and cl.FxSpawnSide ~= "Client" then return end
    if type(blastFx) ~= "table" or #blastFx == 0 then return end
    if not renderer or type(renderer.cellLocM) ~= "function" then
        if not ClearFxClient._geomWarned then
            ClearFxClient._geomWarned = true
            print("[ClearFxClient][WARN] 盘面基底未就绪，跳过竖版光束")
        end
        return
    end
    local key = cl.BlastColumnFxActorPresetKey or cl.BlastRowFxActorPresetKey
        or cl.FxActorPresetKey or "__FILL_ME_BlastColumnFx__"
    local erot = cl.BlastEffectRot or { X = -90, Y = 0, Z = 0 }
    local scale = cl.BlastEffectScale or { X = 7, Y = 2.5, Z = 1 }
    local off = cl.BlastEffectOffset or {}
    local by = boardYaw(renderer)
    local dur = (type(cl.BlastEffectDuration) == "number") and cl.BlastEffectDuration or 1.0
    for _, bf in ipairs(blastFx) do
        local col = tonumber(bf.col) or 1
        local bottom = tonumber(bf.bottom) or ROWS
        local loc = renderer:cellLocM(bottom, col)
        loc = {
            X = loc.X + (off.X or 0),
            Y = loc.Y + (off.Y or 0),
            Z = loc.Z + (off.Z or 0),
        }
        -- [诊断] 竖版光束属爆炸特效，保持原定位，不受 FxDebugSpawnInFrontM 影响。
        spawnFx(host, key, loc,
            { X = erot.X or -90, Y = erot.Y or 0, Z = by + (erot.Z or 0) },
            scale, dur, "竖版光束 col=" .. tostring(col))
    end
end

return ClearFxClient
