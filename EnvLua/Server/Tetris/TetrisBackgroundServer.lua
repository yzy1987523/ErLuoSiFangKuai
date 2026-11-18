-- 远景背景 3D UI 挂件（服务端生成 + 灌图）。
-- 根因：客户端 3D 挂件 GetUserWidgetObject() 恒为 nil（即便 SetWidget ok=true，实跑 try0..12 全 nil），
-- 无法在客户端给 3D WidgetComponent 灌图；而服务端 GetUserWidgetObject(pawn) + GetWidgetFromName
-- + SetImageContent 是 2026-10-14 已实跑验证可用的链路。故背景挂件改回服务端生成 + 灌图。
--
-- 服务端 CreateActor 的 Actor 会同步到客户端渲染；SetWidget(Both, 服务端 broadcast) 挂 UMG；
-- 灌图走 WoWCustomUIImage(ServerOnly)。挂件位置用 GameState 已算好的盘面基底 origin/right（米），
-- 数学与客户端 ClientRenderer.bgTransform 一致。
local Config = require("EnvLua.Common.Tetris.TetrisConfig")

local TetrisBackgroundServer = {}

local STEP_M = ((Config.Render or {}).CellSize or 1.0) + ((Config.Render or {}).CellGap or 0.02)
local UMG_KEY = "51_UMGPreset_CustomAsset-3-408-b5541cbcd76165b496f8b42fcc560e8f677593530f5ab0f67ae9a6e696e16369"

local function atan2compat(y, x)
    local ok, v = pcall(function() return math.atan2(y, x) end)
    if ok and v then return v end
    ok, v = pcall(function() return math.atan(y, x) end)
    if ok and v then return v end
    return 0
end

local function resolveRef(key)
    if type(key) ~= "string" or type(AssetRef) ~= "table" then return nil end
    return AssetRef[key]
end

-- 由盘面基底 origin/right（米）反推挂件世界位置与 yaw，数学对齐客户端 ClientRenderer.bgTransform。
local function bgTransform(origin, right, boardIndex)
    local cfg = Config.BackgroundWidget
    if not (cfg and cfg.Enabled) or not origin or not right then return nil end
    local board = Config.Board or {}
    local w = ((board.Cols or 10) - 1) * STEP_M
    local h = ((board.Rows or 20) - 1) * STEP_M
    local rx, ry = right.X or 0, right.Y or 0
    local frameYaw = atan2compat(rx, -ry)
    local flipAxis = (type(Config.BoardFlipAxis180) == "boolean") and Config.BoardFlipAxis180 or false
    local posYaw = frameYaw - (flipAxis and math.pi or 0)
    local fx, fy = math.cos(posYaw), math.sin(posYaw)
    local cx = origin.X + rx * (w / 2)
    local cy = origin.Y + ry * (w / 2)
    local cz = origin.Z - h / 2
    local D = (type(cfg.DistanceBehindM) == "number") and cfg.DistanceBehindM or 4
    local sideW = (type(cfg.SideOffsetM) == "number") and cfg.SideOffsetM or 0
    local hgt = (type(cfg.HeightOffsetM) == "number") and cfg.HeightOffsetM or 0
    local pos = {
        X = cx + fx * D + rx * sideW,
        Y = cy + fy * D + ry * sideW,
        Z = cz + hgt,
    }
    local bias = 0
    if type(cfg.RotationBiasByIndex) == "table" then bias = cfg.RotationBiasByIndex[boardIndex] or 0 end
    local yawDeg = frameYaw * 180 / math.pi + bias
    local rotObj = nil
    pcall(function()
        if type(FRotator) == "table" and FRotator.MakeFromEuler then
            rotObj = FRotator.MakeFromEuler(Game:ConstructFVectorByLuaTable({ X = 0, Y = 0, Z = yawDeg }))
        end
    end)
    return pos, rotObj
end

-- 生成挂件 Actor（服务端 CreateActor → 同步到客户端）。成功返回 actor。
local function spawnActor(origin, right, boardIndex)
    local cfg = Config.BackgroundWidget
    local ref = resolveRef(cfg.PresetKey)
    if not ref then
        print("[BGS][Server] 资源未注册 AssetRef[" .. tostring(cfg.PresetKey) .. "]")
        return nil
    end
    local pos, rotObj = bgTransform(origin, right, boardIndex)
    if not pos then return nil end
    local sc = cfg.Scale or { X = 1, Y = 1, Z = 1 }
    local scaleVec = Game:ConstructFVectorByLuaTable({ X = sc.X or 1, Y = sc.Y or 1, Z = sc.Z or 1 })
    local ok, actor = pcall(function()
        return CreativeGameAPI.CreateActor(ref, Game:ConstructFVectorByLuaTable(pos), rotObj, scaleVec, nil)
    end)
    if ok and actor then
        pcall(function() if actor.SetActorEnableCollision then actor:SetActorEnableCollision(false) end end)
        pcall(function() if actor.SetActorHiddenInGame then actor:SetActorHiddenInGame(false) end end)
        print("[BGS][Server] 挂件已生成 index=" .. tostring(boardIndex) ..
            " pos=(" .. string.format("%.2f", pos.X) .. "," .. string.format("%.2f", pos.Y) .. "," ..
            string.format("%.2f", pos.Z) .. ")")
    else
        print("[BGS][Server][WARN] CreateActor 失败 index=" .. tostring(boardIndex) .. " err=" .. tostring(actor))
        return nil
    end
    return actor
end

-- 给挂件挂 UMG 并灌图（服务端链路）。返回 actor 供重试。
local function paintActor(actor, boardIndex, imgKey)
    if not actor then return nil end
    local wc = nil
    pcall(function() wc = actor:GetComponentByName("WidgetComponent") end)
    if not wc then pcall(function() wc = actor:GetComponentByClass("WidgetComponent") end) end
    if not wc then return actor end
    -- SetWidget 挂 UMG（服务端 broadcast 到客户端），只挂一次
    if not actor._bgUMGSet then
        local umgRef = resolveRef(UMG_KEY)
        if umgRef then
            local okSW = pcall(function() wc:SetWidget(umgRef) end)
            actor._bgUMGSet = okSW
            print("[BGS][Server] SetWidget index=" .. tostring(boardIndex) .. " ok=" .. tostring(okSW))
        end
    end
    -- 服务端按 pawn 取 uw（LuaArray 0 基），GetWidgetFromName → SetImageContent
    local cfg = Config.BackgroundWidget or {}
    local images = cfg.OpponentImages or {}
    local imgKeyResolved = images[imgKey] or images.Human
    local imgRef = resolveRef(imgKeyResolved)
    if not imgRef then return actor end
    local pawns = nil
    pcall(function() pawns = Game:GetAllPlayerPawns() end)
    if not pawns or type(pawns.Num) ~= "function" or pawns:Num() <= 0 then return actor end
    local uw = nil
    for i = 0, pawns:Num() - 1 do
        local pawn = pawns:Get(i)
        if pawn then
            pcall(function() uw = wc:GetUserWidgetObject(pawn) end)
            if not uw then pcall(function() uw = wc:GetWidget(pawn) end) end
            if uw then break end
        end
    end
    if not uw then return actor end
    -- 图片控件多候选定位：真实名（客户端诊断）→ 配置名 → 遍历
    local names = { "Creative_CustomImage_C_5400", cfg.ImageChildName, "Image", "image", "Background" }
    local img = nil
    local how = "?"
    if type(uw.GetWidgetFromName) == "function" then
        for _, nm in ipairs(names) do
            if nm and nm ~= "" then
                local okG, got = pcall(function() return uw:GetWidgetFromName(nm) end)
                if okG and got and type(got.SetImageContent) == "function" then img = got; how = "name=" .. tostring(nm); break end
            end
        end
    end
    if not img and type(uw.GetAllWidgets) == "function" then
        local okA, all = pcall(function() return uw:GetAllWidgets() end)
        if okA and all then
            local okN, n = pcall(function() return (type(all.Num) == "function") and all:Num() or #all end)
            if okN then
                for i = 0, (tonumber(n) or 0) - 1 do
                    local okC, c = pcall(function() return (type(all.Get) == "function") and all:Get(i) or all[i + 1] end)
                    if okC and c and type(c.SetImageContent) == "function" then img = c; how = "traverse[" .. tostring(i) .. "]"; break end
                end
            end
        end
    end
    if not img then return actor end
    local okSet = pcall(function() img:SetImageContent(imgRef) end)
    if okSet then
        print("[BGS][Server] 灌图成功 index=" .. tostring(boardIndex) .. " via=" .. how ..
            " key=" .. tostring(imgKey) .. " imgKey=" .. tostring(imgKeyResolved))
    end
    actor._bgPainted = actor._bgPainted or {}
    actor._bgPainted[imgKey] = true
    return actor
end

-- 幂等入口：host 传入 _boardGeom（含 o0/r0/o1/r1）与难度图键。每 seat 生成一个挂件并灌图。
-- 灌图在 SetWidget 后异步 UMG 可能延迟就绪，故首次失败时由 host 用重试计数再次调用。
function TetrisBackgroundServer.Ensure(host, geom, imgKey)
    local cfg = Config.BackgroundWidget
    if not (cfg and cfg.Enabled) or not geom then return end
    -- 背景挂件最终决定走服务端（官方确认客户端 3D UI 有 bug）；不再读 SpawnMode，
    -- 避免 Common 配置未同步时读到旧值 "Client" 导致服务端不生成。客户端生成链路已保留，后期官方修复后手动切换。
    if not host._bgActors then host._bgActors = {} end
    local seats = {
        { index = 1, origin = geom.o0, right = geom.r0 },
        { index = 2, origin = geom.o1, right = geom.r1 },
    }
    local pending = 0
    for _, s in ipairs(seats) do
        local a = host._bgActors[s.index]
        if not a then
            a = spawnActor(s.origin, s.right, s.index)
            if a then host._bgActors[s.index] = a end
        end
        if a then
            local painted = a._bgPainted and a._bgPainted[imgKey]
            if not painted then
                paintActor(a, s.index, imgKey)
                painted = a._bgPainted and a._bgPainted[imgKey]
                if not painted then pending = pending + 1 end
            end
        end
    end
    return pending
end

return TetrisBackgroundServer
