-- 远景背景 3D UI 挂件（背景图）。
-- 与 TetrisBehindWidget 同思路：仅依赖「出生点装置(CreativeInstance) + ActorPreset(AssetRef)」，
-- 不依赖 renderer 的盘面基底（boardCenter/boardForward/boardYaw）；纯背景、不挂接 renderer、不依赖文本组件。
-- 由 TetrisMatch:Init()（OnStart，游戏加载即执行）调用，基于出生点装置的位置+朝向直接计算挂件
-- 的世界坐标与旋转并生成 Actor，使其在加载时即可生成；若出生点/资源在 OnStart 尚未就绪而失败，
-- 由 OnModeSelected→BuildGames 兜底再生成一次。
-- 用法完全照搬 TetrisBehindWidget；配置项在 TetrisConfig.BackgroundWidget（用户自行调整数值）。
local TetrisConfig = require("EnvLua.Server.Tetris.TetrisConfig")

-- 兼容 atan2：部分 Lua 环境（Lua 5.3）已移除 math.atan2，仅保留两参 math.atan。
local function atan2compat(y, x)
    local ok, v = pcall(function() return math.atan2(y, x) end)
    if ok then return v end
    ok, v = pcall(function() return math.atan(y, x) end)
    if ok then return v end
    return 0
end

-- 零旋转 FRotator（CreateActor 的 rot 参数不能为 nil）
local function zeroRotator()
    local ok, rot = pcall(function()
        if type(FRotator) == "table" and FRotator.MakeFromEuler then
            return FRotator.MakeFromEuler(Game:ConstructFVectorByLuaTable({ X = 0, Y = 0, Z = 0 }))
        end
    end)
    if ok and rot then return rot end
    return nil
end

local TetrisBackgroundWidget = {}

-- 基于出生点装置直接计算挂件世界位置与旋转（不依赖 renderer 盘面基底）。
-- 返回：ok, pos(米表), rot(FRotator|nil), reason。
function TetrisBackgroundWidget.ComputeTransform(spawnPointKey, boardIndex)
    local cfg = TetrisConfig.BackgroundWidget
    if not (cfg and cfg.Enabled) then return false, nil, nil, "未启用" end
    local so = TetrisConfig.SceneObjects
    local key = spawnPointKey or (so and so.SpawnPointKey)
    if not key or type(CreativeInstance) ~= "table" or type(InstanceAPI) ~= "table" then
        return false, nil, nil, "CreativeInstance/InstanceAPI 未注入"
    end
    local id = CreativeInstance[key]
    if id == nil then
        return false, nil, nil, "出生点装置未注入: " .. tostring(key)
    end
    local okL, loc = pcall(function() return InstanceAPI.GetInstanceLocation(id) end)
    if not (okL and loc and loc.X) then
        return false, nil, nil, "取出生点位置失败"
    end

    -- 装置朝向：从实例旋转取偏航推导 forward；基准 yaw +180° 修正装置正/背面（与盘面一致）。
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

    -- 复用与盘面一致的几何算法（前向/右向/距离/抬高），保证挂件位置与「盘面背后」重合。
    local r = TetrisConfig.Render
    local step = (r.CellSize + r.CellGap)
    local w = (TetrisConfig.Board.Cols - 1) * step
    local h = (TetrisConfig.Board.Rows - 1) * step
    local lift = (type(TetrisConfig.BoardHeightOffsetM) == "number") and TetrisConfig.BoardHeightOffsetM or 1.3
    local offDeg = (type(TetrisConfig.BoardYawOffsetDeg) == "number") and TetrisConfig.BoardYawOffsetDeg or 0
    local flipAxis = (type(TetrisConfig.BoardFlipAxis180) == "boolean") and TetrisConfig.BoardFlipAxis180 or false
    local len = math.sqrt(fx * fx + fy * fy)
    if len < 1e-6 then fx, fy = 0, 1 end
    fx, fy = fx / len, fy / len
    local posYaw = atan2compat(fy, fx) + offDeg * math.pi / 180
    local frameYaw = posYaw + (flipAxis and math.pi or 0)
    local frx, fry = math.cos(frameYaw), math.sin(frameYaw)
    local right = { X = fry, Y = -frx, Z = 0 }
    local ffx, ffy = math.cos(posYaw), math.sin(posYaw)
    local dist = (type(TetrisConfig.BoardForwardDistM) == "number") and TetrisConfig.BoardForwardDistM or 8
    local sideBoard = (type(TetrisConfig.BoardSideOffsetM) == "number") and TetrisConfig.BoardSideOffsetM or 0
    local center = {
        X = loc.X + ffx * dist + right.X * sideBoard,
        Y = loc.Y + ffy * dist + right.Y * sideBoard,
        Z = loc.Z + lift + h / 2,
    }

    -- 挂件相对盘面中心的偏移（Distance=盘后距离，side=横向，hgt=竖直），与 renderer 一致。
    local D = (type(cfg.DistanceBehindM) == "number") and cfg.DistanceBehindM or 4
    local sideW = (type(cfg.SideOffsetM) == "number") and cfg.SideOffsetM or 0
    local hgt = (type(cfg.HeightOffsetM) == "number") and cfg.HeightOffsetM or 0
    local pos = {
        X = center.X + ffx * D + right.X * sideW,
        Y = center.Y + ffy * D + right.Y * sideW,
        Z = center.Z + hgt,
    }

    -- 旋转：盘面朝向(frameYaw) + 每盘偏置（1号 +45°、2号 −45°）。
    local bias = 0
    if type(cfg.RotationBiasByIndex) == "table" then
        bias = cfg.RotationBiasByIndex[boardIndex] or 0
    end
    local yawDeg = frameYaw * 180 / math.pi + bias
    local rotObj = nil
    if type(FRotator) == "table" and FRotator.MakeFromEuler then
        rotObj = FRotator.MakeFromEuler(Game:ConstructFVectorByLuaTable({ X = 0, Y = 0, Z = yawDeg }))
    end
    if not rotObj then rotObj = zeroRotator() end
    return true, pos, rotObj, "ok"
end

-- 生成挂件 Actor：成功返回 actor，失败返回 nil 并打印原因（供判断 Init 是否已就绪）。
function TetrisBackgroundWidget.Spawn(spawnPointKey, boardIndex)
    local cfg = TetrisConfig.BackgroundWidget
    if not (cfg and cfg.Enabled) then return nil end
    local ok, pos, rot, reason = TetrisBackgroundWidget.ComputeTransform(spawnPointKey, boardIndex)
    if not ok then
        print(string.format("[Tetris][BGWidget][WARN] 生成跳过(基于出生点): %s | key=%s index=%s",
            tostring(reason), tostring(spawnPointKey), tostring(boardIndex)))
        return nil
    end
    local ref = (type(AssetRef) == "table" and AssetRef[cfg.PresetKey])
             or (type(CreativeAsset) == "table" and CreativeAsset[cfg.PresetKey])
    if not ref then
        print(string.format("[Tetris][BGWidget][WARN] 资源键无引用: %s（请在编辑器注册并执行 update preset）",
            tostring(cfg.PresetKey)))
        return nil
    end
    local scaleVec = Game:ConstructFVectorByLuaTable({
        X = (cfg.Scale and cfg.Scale.X) or 1,
        Y = (cfg.Scale and cfg.Scale.Y) or 1,
        Z = (cfg.Scale and cfg.Scale.Z) or 1,
    })
    local actor = nil
    local pcallOk, res = pcall(function()
        if type(CreativeGameAPI) == "table" and CreativeGameAPI.CreateActor then
            return CreativeGameAPI.CreateActor(ref, Game:ConstructFVectorByLuaTable(pos), rot, scaleVec, nil)
        end
        return nil
    end)
    if pcallOk and res then actor = res end
    if actor then
        pcall(function() if actor.SetActorHiddenInGame then actor:SetActorHiddenInGame(false) end end)
        print(string.format("[Tetris][BGWidget] 远景背景 3D UI 挂件已生成 (D=%.1f index=%s 基于出生点)",
            (type(cfg.DistanceBehindM) == "number" and cfg.DistanceBehindM or 4), tostring(boardIndex)))
    else
        print("[Tetris][BGWidget][WARN] CreateActor 失败（资源/接口未就绪）")
    end
    return actor
end

-- 重定位已存在的挂件（出生点装置晚注入、基准变化时使用；算法与生成一致，位置不变则无副作用）。
function TetrisBackgroundWidget.Reanchor(actor, spawnPointKey, boardIndex)
    if not actor or type(actor.K2_TeleportTo) ~= "function" then return end
    local ok, pos, rot = TetrisBackgroundWidget.ComputeTransform(spawnPointKey, boardIndex)
    if not ok or not pos then return end
    pcall(function() actor:K2_TeleportTo(Game:ConstructFVectorByLuaTable(pos), rot or zeroRotator()) end)
end

return TetrisBackgroundWidget
