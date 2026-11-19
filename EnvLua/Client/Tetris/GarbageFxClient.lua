-- GarbageFxClient：客户端本地扔垃圾拖尾特效（2026-11-19）
-- 架构：官方案例模式——客户端 CreativeGameAPI.CreateActor 生成 EffectActor_Throw，
-- 该 Actor 的粒子组件 effect_throw_1 已在编辑器设 AutoActivate，Actor 一生成粒子自动播；
-- 用 K2_SetActorLocation(cm,false,nil,true) 逐帧传送 Actor 本体实现连续飞行（本地表现，双方各自生成各自可见）。
-- 每个客户端各自生成一份，因此双方都能看到，不依赖服务端 actor channel 复制。
--
-- 单位纪律：CreateActor 的 Location = 米；K2_SetActorLocation = 厘米（cmLoc 显式 ×100）。
-- 资源：AssetRef["46_ActorPreset_778521937"]（EffectActor_Throw，已注册）。
local Config = require("EnvLua.Common.Tetris.TetrisConfig")

local GarbageFxClient = {}

local gc = Config.GarbageEffect or {}
local STEP_M = ((Config.Render or {}).CellSize or 1.0) + ((Config.Render or {}).CellGap or 0.02)

-- 米 -> 厘米 FVector（Class API K2_SetActorLocation 用厘米）
local function cmLoc(loc)
    return Game:ConstructFVectorByLuaTable({
        X = (loc.X or 0) * 100, Y = (loc.Y or 0) * 100, Z = (loc.Z or 0) * 100,
    })
end

-- 已验证的客户端 Actor 定位法（ClientRenderer._place/_placeClearFrame 同款）：
-- K2_SetActorLocation 四参，第三参 nil 是隐藏 FHitResult& 输出占位，必须传齐。
local function setActorPos(actor, locM)
    return pcall(function() actor:K2_SetActorLocation(cmLoc(locM), false, nil, true) end)
end

-- 位置回读诊断（cm -> m）：区分"Actor 没动"与"Actor 动了但粒子不跟随"
local function readActorPosM(actor)
    if type(actor.K2_GetActorLocation) ~= "function" then return nil end
    local ok, loc = pcall(function() return actor:K2_GetActorLocation() end)
    if ok and loc and loc.X then
        return { X = loc.X / 100, Y = loc.Y / 100, Z = loc.Z / 100 }
    end
    return nil
end

-- yaw(度) -> FRotator（沿用项目 MakeFromEuler(Z=yaw) 约定）；失败返回 nil
local function rotYaw(yawDeg)
    local ok, rot = pcall(function()
        if type(FRotator) == "table" and FRotator.MakeFromEuler then
            return FRotator.MakeFromEuler(Game:ConstructFVectorByLuaTable({ X = 0, Y = 0, Z = yawDeg or 0 }))
        end
        return nil
    end)
    if ok and rot then return rot end
    return nil
end

-- 该盘"外侧"沿 right 的符号：本地盘(origin.X<0)外侧=-right，对手盘(origin.X>0)外侧=+right。
-- 两盘 right 都朝 +X、分居 X 轴两侧，故用 origin.X 符号即可自动定向，谁扔都正确。
local function outwardSign(renderer)
    local o = renderer and renderer.originM
    if o and type(o.X) == "number" and o.X < 0 then return -1 end
    return 1
end

-- 把米坐标沿某盘外侧推开 dist 米（改 X/Y，不动 Z）。
local function pushOutward(loc, renderer, dist)
    if not loc or not dist or dist == 0 then return loc end
    local r = (renderer and renderer.rightM) or { X = 1, Y = 0, Z = 0 }
    local k = outwardSign(renderer) * dist
    return {
        X = loc.X + (r.X or 0) * k,
        Y = loc.Y + (r.Y or 0) * k,
        Z = loc.Z,
    }
end

-- 目标盘落点（米）：默认最下一行(Board.Rows)的边缘列(TargetCol)，用 renderer.cellLocM 按真实基底算，
-- 再沿目标盘外侧推开 TargetSideOffsetM（避开 3D 大框侧面）。
local function boardTarget(renderer)
    if not renderer or type(renderer.cellLocM) ~= "function" then return nil end
    local rowsN = (Config.Board or {}).Rows or 20
    local colsN = (Config.Board or {}).Cols or 10
    local row = (type(gc.TargetRow) == "number") and gc.TargetRow or rowsN
    local col = (type(gc.TargetCol) == "number") and gc.TargetCol or 1
    local loc = renderer:cellLocM(row, col)
    return pushOutward(loc, renderer, gc.TargetSideOffsetM)
end

-- 投掷起点：fromRenderer 盘最左列(第1列)、竖直取 rows 中行(米)；无 rows 取盘中行。
local function throwStart(fromRenderer, rows)
    if not fromRenderer or type(fromRenderer.cellLocM) ~= "function" then return nil end
    local minRow, maxRow
    for _, row in ipairs(rows or {}) do
        local n = tonumber(row)
        if n then minRow = math.min(n, minRow or n); maxRow = math.max(n, maxRow or n) end
    end
    local midRow = minRow and ((minRow + maxRow) / 2) or (((Config.Board or {}).Rows or 20) / 2)
    local loc = fromRenderer:cellLocM(midRow, 1)
    -- 沿起点盘外侧推开 SideOffsetM（自动定向，避开 3D 大框侧面）+ Z 微调
    local pushed = pushOutward(loc, fromRenderer, gc.SideOffsetM)
    return {
        X = pushed.X,
        Y = pushed.Y,
        Z = pushed.Z + (type(gc.HeightOffsetM) == "number" and gc.HeightOffsetM or 0),
    }
end

-- 飞行朝向 yaw：从起点指向终点（度），叠加配置 bias。
local function flyYaw(from, to)
    if not from or not to then return 0 end
    local dx, dy = (to.X or 0) - (from.X or 0), (to.Y or 0) - (from.Y or 0)
    local yaw = 0
    if math.abs(dx) > 1e-6 or math.abs(dy) > 1e-6 then
        local ok, v = pcall(function()
            if math.atan2 then return math.atan2(dy, dx) end
            return math.atan(dy, dx)
        end)
        if ok and v then yaw = math.deg(v) end
    end
    return yaw + (type(gc.ActorRotationBiasDeg) == "number" and gc.ActorRotationBiasDeg or 0)
end

-- 播放一份拖尾：fromRenderer 盘 → toRenderer 盘。
-- @param host WoWObject（提供 AddTimerOnce），通常传 Battle（self.host）
-- @param fromRenderer ClientRenderer 投掷方盘（用于起点）
-- @param toRenderer ClientRenderer 目标方盘（用于终点盘心）
-- @param rows table|nil 本次消除行号（决定起点竖直位置）
function GarbageFxClient.Play(host, fromRenderer, toRenderer, rows)
    if gc.Enabled == false then return end
    if gc.SpawnSide ~= nil and gc.SpawnSide ~= "Client" then return end
    if not host or type(host.AddTimerOnce) ~= "function" then return end
    if type(CreativeGameAPI) ~= "table" or not CreativeGameAPI.CreateActor
        or not CreativeGameAPI.DestroyActor then return end
    local key = gc.ActorPresetKey or "46_ActorPreset_778521937"
    local ref = (type(AssetRef) == "table" and AssetRef[key]) or nil
    if not ref then
        if not GarbageFxClient._refWarned then
            GarbageFxClient._refWarned = true
            print("[GarbageFxClient][WARN] 资源未注册 AssetRef[" .. tostring(key) .. "]")
        end
        return
    end

    local fromPos = throwStart(fromRenderer, rows)
    local toPos = boardTarget(toRenderer)
    if not fromPos or not toPos then
        if not GarbageFxClient._geomWarned then
            GarbageFxClient._geomWarned = true
            print("[GarbageFxClient][WARN] 盘面基底未就绪，跳过拖尾")
        end
        return
    end
    toPos = {
        X = toPos.X, Y = toPos.Y,
        Z = toPos.Z + (type(gc.TargetHeightOffsetM) == "number" and gc.TargetHeightOffsetM or 0),
    }

    local aScale = gc.ActorScale or { X = 1, Y = 1, Z = 1 }
    local scaleVec = Game:ConstructFVectorByLuaTable({
        X = aScale.X or 1, Y = aScale.Y or 1, Z = aScale.Z or 1,
    })
    local spawnRot = rotYaw(flyYaw(fromPos, toPos)) or rotYaw(0)
    -- [修复] CreateActor 只传位置(米)，rot/scale 先不传——项目实测直传 transform 不生效。
    local okA, actor = pcall(function()
        return CreativeGameAPI.CreateActor(ref, Game:ConstructFVectorByLuaTable(fromPos), nil, nil, nil)
    end)
    if not okA or not actor then
        if not GarbageFxClient._spawnWarned then
            GarbageFxClient._spawnWarned = true
            print("[GarbageFxClient][WARN] CreateActor 失败: " .. tostring(actor))
        end
        return
    end
    -- 生成后显式设 transform（对齐 ClientRenderer 已验证路径）
    local okInitPos = setActorPos(actor, fromPos)
    if spawnRot then pcall(function() actor:K2_SetActorRotation(spawnRot, false) end) end
    pcall(function() actor:SetActorScale3D(scaleVec) end)
    local initRead = readActorPosM(actor)
    print("[GarbageFxClient][DIAG] 初始定位 setOk=" .. tostring(okInitPos)
        .. " expect=(" .. string.format("%.1f,%.1f,%.1f", fromPos.X, fromPos.Y, fromPos.Z)
        .. ") actual=" .. (initRead and string.format("%.1f,%.1f,%.1f", initRead.X, initRead.Y, initRead.Z) or "nil"))

    local travel = (type(gc.TravelDuration) == "number") and gc.TravelDuration or 0.6
    local dur = (type(gc.Duration) == "number") and gc.Duration or 1.0
    local step = (type(gc.TravelStep) == "number" and gc.TravelStep > 0) and gc.TravelStep or 0.03
    if dur < travel then dur = travel end
    local destroyed = false
    local function destroyFx()
        if destroyed then return end
        destroyed = true
        pcall(function() CreativeGameAPI.DestroyActor(actor) end)
    end

    if travel > 0 then
        local elapsed = 0
        local firstLogged, doneLogged = false, false
        local function move()
            if destroyed then return end
            elapsed = elapsed + step
            local t = elapsed / travel
            if t > 1 then t = 1 end
            local p = {
                X = fromPos.X + (toPos.X - fromPos.X) * t,
                Y = fromPos.Y + (toPos.Y - fromPos.Y) * t,
                Z = fromPos.Z + (toPos.Z - fromPos.Z) * t,
            }
            local okMove = setActorPos(actor, p)
            if not firstLogged then
                firstLogged = true
                local read = readActorPosM(actor)
                print("[GarbageFxClient][DIAG] first tick t=" .. string.format("%.2f", t)
                    .. " setOk=" .. tostring(okMove)
                    .. " expect=(" .. string.format("%.1f,%.1f,%.1f", p.X, p.Y, p.Z)
                    .. ") actual=" .. (read and string.format("%.1f,%.1f,%.1f", read.X, read.Y, read.Z) or "nil"))
            end
            if t >= 1 and not doneLogged then
                doneLogged = true
                local read = readActorPosM(actor)
                print("[GarbageFxClient][DIAG] travel done"
                    .. " expect=(" .. string.format("%.1f,%.1f,%.1f", toPos.X, toPos.Y, toPos.Z)
                    .. ") actual=" .. (read and string.format("%.1f,%.1f,%.1f", read.X, read.Y, read.Z) or "nil"))
            end
            if t < 1 then host:AddTimerOnce(step, move) end
        end
        host:AddTimerOnce(step, move)
    end
    host:AddTimerOnce(dur, destroyFx)
    print("[GarbageFxClient] 拖尾已生成 from=(" .. string.format("%.1f,%.1f,%.1f", fromPos.X, fromPos.Y, fromPos.Z)
        .. ") to=(" .. string.format("%.1f,%.1f,%.1f", toPos.X, toPos.Y, toPos.Z)
        .. ") travel=" .. tostring(travel) .. " dur=" .. tostring(dur))
end

return GarbageFxClient
