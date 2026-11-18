-- 服务端批量生成场景 3D UI：BigFrame3D / BehindBoardWidget / BoardBackdrop3D(_small)。
-- 背景挂件(远景图)在 TetrisBackgroundServer 单独处理；本模块负责其余四类静态/半静态 3D UI。
-- 官方确认客户端 3D UI 显示有 bug 未修复，当前全部走服务端生成；每类配置读 SpawnMode（"Server" 生效）。
-- 后期官方修复后，把对应配置 SpawnMode 改 "Client"，本模块即跳过该类，客户端各自接管。
--
-- 算法逐字复刻自旧 TetrisRenderer（已实跑验证的位置/符号），改用 GameState 下发的盘面基底 g.oN/rN（米）。
-- 关键推导（flipAxis180=true，当前配置）：
--   center = o + r*(w/2)，center.Z = o.Z - h/2
--   frameYaw = atan2(r.X, -r.Y)；forward = (r.Y, -r.X, 0)（right 顺时针 90°）
--   yaw = degrees(frameYaw) + RotationBiasByIndex[index]
-- 单位：CreateActor 位置用米；scale 无量纲。
local Config = require("EnvLua.Common.Tetris.TetrisConfig")

local TetrisScene3DUIServer = {}

local STEP_M = ((Config.Render or {}).CellSize or 1.0) + ((Config.Render or {}).CellGap or 0.02)
local W_M = (((Config.Board or {}).Cols or 10) - 1) * STEP_M
local H_M = (((Config.Board or {}).Rows or 20) - 1) * STEP_M
local FLIP = (Config.BoardFlipAxis180 == true)

local function atan2compat(y, x)
    local ok, v = pcall(function() return math.atan2(y, x) end)
    if ok and v then return v end
    ok, v = pcall(function() return math.atan(y, x) end)
    if ok and v then return v end
    return 0
end

local function resolveRef(key)
    if type(key) ~= "string" then return nil end
    local r = nil
    pcall(function()
        if type(AssetRef) == "table" then r = AssetRef[key] end
        if not r and type(CreativeAsset) == "table" then r = CreativeAsset[key] end
    end)
    return r
end

local function yawRot(yawDeg)
    local rot = nil
    pcall(function()
        if type(FRotator) == "table" and FRotator.MakeFromEuler then
            rot = FRotator.MakeFromEuler(Game:ConstructFVectorByLuaTable({ X = 0, Y = 0, Z = yawDeg }))
        end
    end)
    return rot
end

local function scaleVecOf(sc)
    return Game:ConstructFVectorByLuaTable({ X = (sc and sc.X) or 1, Y = (sc and sc.Y) or 1, Z = (sc and sc.Z) or 1 })
end

local function createActor(ref, pos, rot, scaleVec)
    local ok, obj = pcall(function()
        return CreativeGameAPI.CreateActor(ref, Game:ConstructFVectorByLuaTable(pos), rot, scaleVec, nil)
    end)
    if ok then return obj end
    return nil
end

-- 由 origin(o)/right(r) 算盘面基底：center / forward / frameYawDeg。四类共用。
local function basisOf(o, r)
    local rx, ry = r.X or 0, r.Y or 0
    local cx = o.X + rx * (W_M / 2)
    local cy = o.Y + ry * (W_M / 2)
    local cz = o.Z - H_M / 2
    local frameYaw = atan2compat(rx, -ry)
    -- flipAxis180=true → forward=(ry,-rx)；false → forward=(-ry,rx)
    local fx, fy = (FLIP and ry or -ry), (FLIP and -rx or rx)
    return { X = cx, Y = cy, Z = cz }, { X = fx, Y = fy, Z = 0 }, frameYaw * 180 / math.pi
end

-- 按配置偏置算 yaw 旋转。
local function rotFor(cfg, boardIndex, frameYawDeg)
    local bias = 0
    if type(cfg.RotationBiasByIndex) == "table" then bias = cfg.RotationBiasByIndex[boardIndex] or 0 end
    return yawRot((frameYawDeg or 0) + bias)
end

-- 通用「挂件类」生成（BehindBoardWidget / BigFrame3D / BoardBackdrop3D / _small）。
-- signFwd: 沿 forward 的符号方向（+1 / -1）；配置 D 直接乘该符号。
local function spawnWidget(host, cacheKey, cfg, o, r, boardIndex, signFwd)
    if not (cfg and cfg.Enabled) then return 0 end
    if cfg.SpawnMode ~= "Server" then return 0 end
    if host._scene3d and host._scene3d[cacheKey] then return 0 end
    local ref = resolveRef(cfg.PresetKey)
    if not ref then
        print("[S3D][WARN] 资源未注册 " .. tostring(cacheKey) .. " key=" .. tostring(cfg.PresetKey))
        return 0
    end
    local center, forward, frameYawDeg = basisOf(o, r)
    local D = (type(cfg.DistanceBehindM) == "number" and cfg.DistanceBehindM)
        or (type(cfg.DistanceFrontM) == "number" and cfg.DistanceFrontM) or 0
    local side = cfg.SideOffsetM or 0
    local hgt = cfg.HeightOffsetM or 0
    local pos = {
        X = center.X + forward.X * D * signFwd + r.X * side,
        Y = center.Y + forward.Y * D * signFwd + r.Y * side,
        Z = center.Z + hgt,
    }
    local rot = rotFor(cfg, boardIndex, frameYawDeg)
    local obj = createActor(ref, pos, rot, scaleVecOf(cfg.Scale))
    if not obj then
        print("[S3D][WARN] 创建失败 " .. tostring(cacheKey) .. " index=" .. tostring(boardIndex))
        return 0
    end
    pcall(function() if obj.SetActorHiddenInGame then obj:SetActorHiddenInGame(false) end end)
    pcall(function() if obj.SetActorEnableCollision then obj:SetActorEnableCollision(false) end end)
    host._scene3d = host._scene3d or {}
    host._scene3d[cacheKey] = obj
    print("[S3D] 已生成 " .. tostring(cacheKey) .. " index=" .. tostring(boardIndex) ..
        " pos=(" .. string.format("%.2f", pos.X) .. "," .. string.format("%.2f", pos.Y) .. "," ..
        string.format("%.2f", pos.Z) .. ")")
    return 1
end

-- ============ BigFrame3D 灌 Hold/Next 图（服务端） ============
-- 旧 TetrisRenderer:SetFrontWidgetHoldNext 的服务端移植版。数据在客户端（玩法在客户端跑），
-- 由 GameState 的 P7_ReportBigFrame RPC 收到后调用本函数。按 pawn 定位 UMG 子控件，注入 PieceImages + PieceTint。
local function findFrontWidgetImageChild(host, actor, childNames)
    if type(childNames) == "string" then childNames = { childNames } end
    local wc = nil
    pcall(function() wc = actor:GetComponentByClass("WidgetComponent") end)
    if not wc then
        pcall(function()
            for _, nm in ipairs({ "UI", "Widget", "WidgetComp", "WidgetComponent" }) do
                local okC, c = pcall(function() return actor:GetComponentByName(nm) end)
                if okC and c then wc = c; break end
            end
        end)
    end
    if not wc then return nil end
    local plist = nil
    pcall(function() plist = Game:GetAllPlayerPawns() end)
    if not plist or type(plist.Num) ~= "function" or plist:Num() <= 0 then return nil end
    local cfg = Config.BigFrame3D or {}
    local cname = cfg.FrontContainerName
    local cacheKey = table.concat(childNames, "|") .. "|" .. tostring(cname)
    host._frontChildCache = host._frontChildCache or {}
    local bucket = host._frontChildCache[cacheKey]
    local n = plist:Num()
    if not bucket or bucket.n ~= n then bucket = { n = n }; host._frontChildCache[cacheKey] = bucket end
    local function tryFind(uw, name)
        local t = nil
        pcall(function() t = uw:GetWidgetFromName(name) end)
        if not t and cname then
            local c = nil
            pcall(function() c = uw:GetWidgetFromName(cname) end)
            if c then pcall(function() t = c:GetWidgetFromName(name) end) end
        end
        return t
    end
    local found = {}
    for i = 0, n - 1 do
        local tw = bucket[i]
        if tw == nil then
            local pawn = plist:Get(i)
            if pawn then
                local uw = nil
                pcall(function() uw = wc:GetUserWidgetObject(pawn) end)
                if not uw then pcall(function() uw = wc:GetWidget(pawn) end) end
                if uw then
                    for _, cn in ipairs(childNames) do
                        local t = tryFind(uw, cn)
                        if t then tw = t; break end
                    end
                end
            end
            if tw then bucket[i] = tw end
        end
        if tw then found[#found + 1] = { idx = i, widget = tw } end
    end
    return found
end

-- holdType/nextType: 方块类型 1..7/道具 9..11/nil；backlight: 攻势高亮显隐；boardIndex: 1/2（哪个盘的大框）。
function TetrisScene3DUIServer.SetBigFrameHoldNext(host, boardIndex, holdType, nextType, backlight)
    local cfg = Config.BigFrame3D
    if not (cfg and cfg.Enabled) then return end
    host._scene3d = host._scene3d or {}
    local actor = host._scene3d["bigframe_" .. tostring(boardIndex)]
    if not actor then
        -- 限频打印：大框 actor 尚未生成时提示（几何就绪 Ensure 会生成，之后上报再灌）
        host._bfNoActorWarn = host._bfNoActorWarn or {}
        if not host._bfNoActorWarn[boardIndex] then
            host._bfNoActorWarn[boardIndex] = true
            print("[BigFrame3D][Server] 灌图跳过：bigframe_" .. tostring(boardIndex) ..
                " actor 未生成 hold=" .. tostring(holdType) .. " next=" .. tostring(nextType))
        end
        return
    end
    print("[BigFrame3D][Server] 灌图 bigframe_" .. tostring(boardIndex) ..
        " hold=" .. tostring(holdType) .. " next=" .. tostring(nextType) ..
        " backlight=" .. tostring(backlight))

    local imgs, tints = Config.PieceImages, Config.PieceTint
    local function resolveImg(t)
        local key = (t and imgs) and imgs[t] or nil
        if not key then return nil end
        return resolveRef(key)
    end
    local function isItem(t)
        return type(Config.IsItemType) == "function" and Config.IsItemType(t)
    end
    local function setImg(childNames, t, lastByIndex)
        local items = findFrontWidgetImageChild(host, actor, childNames)
        if not items or #items == 0 then
            -- 控件还没加载好（3D 挂件 UMG 异步加载，参考背景挂件需十几次重试）：返回 false 触发上层重试
            print("[BigFrame3D][Server] 控件未就绪 bigframe_" .. tostring(boardIndex) ..
                " child=" .. tostring(type(childNames) == "table" and childNames[1] or childNames))
            return false
        end
        local imgID = resolveImg(t)
        local visible = (imgID ~= nil)
        local colorVec = nil
        if visible then
            if isItem(t) then
                colorVec = Game:ConstructFVectorByLuaTable({ X = 1, Y = 1, Z = 1 })
            else
                local c = (t and tints) and tints[t]
                if c then colorVec = Game:ConstructFVectorByLuaTable({ X = c.X, Y = c.Y, Z = c.Z }) end
            end
        end
        for _, it in ipairs(items) do
            local widget = it.widget
            pcall(function() widget:SetVisible(visible) end)
            if not visible then
                lastByIndex[it.idx] = nil
            elseif lastByIndex[it.idx] ~= t then
                lastByIndex[it.idx] = t
                pcall(function() widget:SetImageContent(imgID) end)
                if colorVec then pcall(function() widget:SetImageColor(colorVec) end) end
            end
        end
        return true
    end

    host._bfHoldLast = host._bfHoldLast or {}
    host._bfNextLast = host._bfNextLast or {}
    host._bfHoldLast[boardIndex] = host._bfHoldLast[boardIndex] or {}
    host._bfNextLast[boardIndex] = host._bfNextLast[boardIndex] or {}
    local okHold = setImg(cfg.HoldImageChildName or { "hold" }, holdType, host._bfHoldLast[boardIndex])
    local okNext = setImg(cfg.NextImageChildName or { "next" }, nextType, host._bfNextLast[boardIndex])

    -- 控件未就绪（UMG 异步加载）时安排重试：记住本盘最新值，0.3s×12 重灌；
    -- 每次客户端新上报会覆盖为更新值，重试用「上报值快照」避免灌旧图。
    if not (okHold and okNext) then
        host._bfRetry = host._bfRetry or {}
        local prev = host._bfRetry[boardIndex]
        host._bfRetry[boardIndex] = { holdType, nextType, backlight, tries = prev and prev.tries or 0 }
        TetrisScene3DUIServer._scheduleRetry(host, boardIndex)
    elseif host._bfRetry then
        host._bfRetry[boardIndex] = nil   -- 灌图成功，清掉重试项（下次变化重新计时）
    end

    -- backlight 显隐（攻势高亮，ui 下与 front 同级）
    local blItems = findFrontWidgetImageChild(host, actor, cfg.BacklightChildName or { "backlight" })
    if blItems then
        local v = (backlight == true)
        host._bfBacklightShown = host._bfBacklightShown or {}
        host._bfBacklightShown[boardIndex] = host._bfBacklightShown[boardIndex] or {}
        local shown = host._bfBacklightShown[boardIndex]
        for _, it in ipairs(blItems) do
            if shown[it.idx] ~= v then
                shown[it.idx] = v
                pcall(function() it.widget:SetVisible(v) end)
            end
        end
    end
end

-- [BigFrame3D] 控件未就绪时的延迟重试：读 _bfRetry[boardIndex] 最新值重灌，最多 12 次（3.6s）。
-- 控件一旦就绪，SetBigFrameHoldNext 里 okHold/okNext 都为 true，不再安排下一次重试，自然收敛。
function TetrisScene3DUIServer._scheduleRetry(host, boardIndex)
    local bucket = host._bfRetry and host._bfRetry[boardIndex]
    if not bucket then return end
    if (bucket.tries or 0) >= 12 then
        print("[BigFrame3D][Server] 重试耗尽 bigframe_" .. tostring(boardIndex) .. "（控件始终未就绪）")
        return
    end
    bucket.tries = (bucket.tries or 0) + 1
    host:AddTimerOnce(0.3, function()
        local cur = host._bfRetry and host._bfRetry[boardIndex]
        if not cur then return end
        TetrisScene3DUIServer.SetBigFrameHoldNext(host, boardIndex, cur[1], cur[2], cur[3])
    end)
end

-- 幂等入口：host 传 _boardGeom（o0/r0/o1/r1）。每个座位各生成一套。
-- 按子代理核实的「实际符号折算表」调用 spawnWidget：
--   BehindBoardWidget: cfg D=+0.51, 代码 +forward*D        → signFwd=+1
--   BigFrame3D:        cfg D=-0.5, 代码 +forward*D         → signFwd=+1
--   BoardBackdrop3D:   cfg D=-0.5, 代码 -forward*D         → signFwd=-1
--   BoardBackdrop3D_small: cfg D=+0.51, 代码 -forward*D    → signFwd=-1
function TetrisScene3DUIServer.Ensure(host, geom)
    if not geom then return end
    local seats = {
        { index = 1, o = geom.o0, r = geom.r0 },
        { index = 2, o = geom.o1, r = geom.r1 },
    }
    for _, s in ipairs(seats) do
        if s.o and s.r then
            spawnWidget(host, "behind_" .. s.index, Config.BehindBoardWidget, s.o, s.r, s.index, 1)
            spawnWidget(host, "bigframe_" .. s.index, Config.BigFrame3D, s.o, s.r, s.index, 1)
            spawnWidget(host, "backdrop_" .. s.index, Config.BoardBackdrop3D, s.o, s.r, s.index, -1)
            spawnWidget(host, "backdropSmall_" .. s.index, Config.BoardBackdrop3D_small, s.o, s.r, s.index, -1)
        end
    end
end

return TetrisScene3DUIServer
