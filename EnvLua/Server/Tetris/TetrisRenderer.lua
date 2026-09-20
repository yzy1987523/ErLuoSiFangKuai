-- 渲染层：把数据层状态映射为 3D 方块的显隐。
-- 设计要点（与数据层解耦）：
--   1. 开局一次性创建 Cols x Rows 个方块，全部隐藏；
--   2. 之后不再移动任何方块，只在数据变化时切换显隐（脏检查，只改变化的格子）；
--   3. 颜色暂为单色（引擎无运行时改材质接口，多色需预着色模型）。
--
-- 创建方式在运行时自动探测：不同预设类型对应不同 API，且 Core/LuaHint 未必加载，
-- 因此首格试遍候选组合，选中后再批量创建其余格子。
local TetrisConfig = require("EnvLua.Server.Tetris.TetrisConfig")

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

-- 模块级：当前盘面偏航角(度)。ResolveOrigin 写入，makePieceRotator 读取，
-- 用于让方块绕“盘面法线(forward)”旋转，而非固定的世界 Y 轴。
local _boardYawDeg = 0

local TetrisRenderer = {}
TetrisRenderer.__index = TetrisRenderer

function TetrisRenderer:new(owner)
    local o = setmetatable({}, TetrisRenderer)
    o.owner = owner  -- WoWObject（GameMain 子类），用于 AddTimerOnce 调度消行延迟下落
    o.cells = {}    -- cells[row][col] = 实例/Actor 对象
    o.actors = {}   -- actors[row][col] = 底层 Actor（若可解析），用于可靠隐藏
    o.shown = {}    -- shown[row][col] = bool，当前显隐状态（脏检查用）
    o.border = {}   -- border[] = 边框格子对象（左/右/下三侧静态装饰，常驻可见）
    o.pieces = {}   -- pieces[type] = 见 BuildActivePiecesV1/V2，整体活动方块
    o.shownPieceType = nil  -- 当前显示中的活动方块类型（整体模式用）
    o.wholePieceV2 = nil    -- true=方案2(根+子组件)可用；false/nil=回退方案1(4 Actor)
    o.lastBoardSig = nil   -- 棋盘静态层签名，用于检测锁定/消行以触发全量同步
    o.built = false
    o.poolReady = false  -- 对象池 spawn 就绪后才摆静态方块（CreateActor 异步，过早设置会被丢弃/卡停车场）
    o.mode = nil    -- "instance" | "actor"
    o.ref = nil
    o.rot = nil
    o.previewing = false  -- 开局预览阶段：true 时暂停活动方块渲染、改摆 7 种展示
    o.createFailLogged = false
    o.visibleFailLogged = false
    o.frame = 0          -- 刷新次数，用于稳定期判定
    o.actorCount = 0     -- 已成功解析的底层 Actor 数
    -- 重构（对象池 + 独立 Actor + 消行 parent-shift）：
    o.pool = {}          -- 对象池：空闲方块 Actor 列表（预建 rows*cols 个，停在停车场）
    o.occ = {}           -- occ[row][col] = 占用该格的独立方块 Actor；nil=空（替代原 200 固定槽）
    o.shiftRoot = nil    -- 消行 parent-shift 临时根（EmptyActor），移完拆父
    o.pieceQueue = {}    -- 活动方块队列：预生成的方块实例（按类型），acquire/release 管理取还
    o.shownPiece = nil   -- 当前显示中的活动方块实例（队列语义，替代直接用 self.pieces[wantType]）
    o.piecesReady = false  -- 全部整体实例预热就绪（_everReady）后才渲染活动块，避免实例未建好导致方块错乱
    return o
end

-- ---------------- 锚点 ----------------

-- 获取本地玩家 pawn 的世界坐标，单位米。失败返回 nil。
-- K2_GetActorLocation 属 Class API，返回厘米，必须 /100 换算成米。
local function getLocalPawnLocationM()
    local ok, res = pcall(function()
        local arr = Game:GetAllPlayerPawns()
        if not arr or arr:Num() <= 0 then return nil end
        local pawn = arr:Get(0)
        if not pawn then return nil end
        local loc = pawn:K2_GetActorLocation()
        if not loc then return nil end
        local x, y, z = loc.X, loc.Y, loc.Z
        if x == nil or y == nil or z == nil then return nil end
        return { X = x / 100.0, Y = y / 100.0, Z = z / 100.0 }
    end)
    if ok then return res end
    return nil
end

function TetrisRenderer:ResolveOrigin(spawnPointKey)
    local r = TetrisConfig.Render
    local so = TetrisConfig.SceneObjects
    local step = r.CellSize + r.CellGap
    -- 盘面实际尺寸（与 cellLocation/PrintBounds 一致，必须用格间距 step 而非裸 CellSize）
    local w = (TetrisConfig.Board.Cols - 1) * step  -- 水平宽（顶行左→右间距）
    local h = (TetrisConfig.Board.Rows - 1) * step  -- 垂直高（顶行→底行间距）
    local lift = (type(TetrisConfig.BoardHeightOffsetM) == "number") and TetrisConfig.BoardHeightOffsetM or 1.3  -- 盘面底行离地间隙（米），整体悬空高度，可用 BoardHeightOffsetM 配置
    -- 用基准位置 spawnLoc(米) + 水平前方 (fx,fy) 落定盘面：
    --   盘面中心在基准前方 dist 米；右方向 right = forward × up = (fy,-fx,0)；
    --   左上角 origin = 中心 - 右半宽 + 上半高（row 向下为 -Z）；
    --   盘面朝向(绕世界Z的偏航)=atan2(fy,fx)+Y偏移，写入 self.rot 供整体方块/边框按盘面对齐。
    local function settle(spawnLoc, fx, fy, fsrc)
        local offDeg = (type(TetrisConfig.BoardYawOffsetDeg) == "number") and TetrisConfig.BoardYawOffsetDeg or 0
        -- 盘面“自身轴向”翻转 180°：仅翻转本地系（right / 法线 / 旋转轴），盘心落点位置不变（不绕出生装置公转）。
        -- 用法：玩家始终看到盘面“背面”导致左右/旋转全部镜像时，置 true 让盘面原地翻正看到正面。
        local flipAxis = (type(TetrisConfig.BoardFlipAxis180) == "boolean") and TetrisConfig.BoardFlipAxis180 or false
        local len = math.sqrt(fx * fx + fy * fy)
        if len < 1e-6 then fx, fy = 0, 1 end
        fx, fy = fx / len, fy / len
        -- 盘心落点朝向：只受 BoardYawOffsetDeg（绕出生装置公转微调）影响，不受自身轴向翻转影响。
        local posYaw = atan2compat(fy, fx) + offDeg * math.pi / 180
        -- 盘面本地系朝向：在落点朝向上再叠加“自身轴向翻转 180°”（绕盘心竖直轴原地转），使玩家看到正面。
        local frameYaw = posYaw + (flipAxis and math.pi or 0)
        local frx, fry = math.cos(frameYaw), math.sin(frameYaw)
        local right = { X = fry, Y = -frx, Z = 0 }
        local ffx, ffy = math.cos(posYaw), math.sin(posYaw)
        local dist = (type(TetrisConfig.BoardForwardDistM) == "number") and TetrisConfig.BoardForwardDistM or 8
        -- 左右偏移（沿盘面右向量 right，米，正=向玩家右手侧移；与 forward 垂直，不影响前后/朝向，且随翻转自动正方向）
        local side = (type(TetrisConfig.BoardSideOffsetM) == "number") and TetrisConfig.BoardSideOffsetM or 0
        local center = { X = spawnLoc.X + ffx * dist + right.X * side,
                         Y = spawnLoc.Y + ffy * dist + right.Y * side,
                         Z = spawnLoc.Z + lift + h / 2 }
        local origin = { X = center.X - right.X * (w / 2), Y = center.Y - right.Y * (w / 2), Z = center.Z + h / 2 }
        self.origin = origin
        self.boardCenter = center
        self.boardRight = right
        self.boardYaw = frameYaw * 180 / math.pi
        _boardYawDeg = self.boardYaw   -- 供 makePieceRotator 绕盘面法线旋转
        if type(FRotator) == "table" and FRotator.MakeFromEuler then
            self.rot = FRotator.MakeFromEuler(Game:ConstructFVectorByLuaTable({ X = 0, Y = 0, Z = self.boardYaw }))
        end
        print(string.format(
            "[Tetris] 锚点=%s loc=(%.2f,%.2f,%.2f) 前方(%.2f,%.2f) offDeg=%.1f 前方%.1fm center=(%.2f,%.2f,%.2f) yaw=%.1f",
            tostring(fsrc), spawnLoc.X, spawnLoc.Y, spawnLoc.Z, fx, fy, offDeg, dist, center.X, center.Y, center.Z, self.boardYaw))
        return origin
    end

    -- 优先基准：场景中的出生点装置 SpawnPointKey（位置 + 朝向）。
    -- 盘面生成在装置正面 BoardForwardDistM 米，盘面朝向 = 装置朝向 + Y角度偏移(BoardYawOffsetDeg)。
    -- 装置朝向用实例旋转偏航推导 forward；实测该装置 +Yaw 指向其“背面”，故基准 yaw 补 180°
    -- （否则盘面会落在装置背后），再叠加 BoardYawOffsetDeg 微调。
    -- 装置未注入/未就绪时回退玩家基准，待装置就绪后 SetupFixedCamera 会重新 ResolveOrigin 重摆。
    local key = spawnPointKey or self.spawnPointKey or (so and so.SpawnPointKey)
    if type(so) == "table" and key then
        if type(CreativeInstance) == "table" then
            local id = CreativeInstance[key]
            if id ~= nil and type(InstanceAPI) == "table" then
                local ok, loc2 = pcall(function() return InstanceAPI.GetInstanceLocation(id) end)
                if ok and loc2 and loc2.X then
                    -- GetInstanceLocation 为 Domain API，单位米（区别于 Class API 的 K2_GetActorLocation 用厘米）
                    -- 装置朝向：从实例旋转取偏航(地面装置 pitch≈0)推导 forward，基准 yaw +180° 修正装置正/背面。
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
                    self._spawnResolved = true
                    return settle({ X = loc2.X, Y = loc2.Y, Z = loc2.Z }, fx, fy, "出生点装置")
                end
            end
        end
        print("[Tetris][WARN] 出生点装置尚未注入，回退玩家基准（稍后重试重摆）")
    end

    -- 回退基准：本地玩家坐标 + 朝向（出生点装置不可用时的兜底，盘面随玩家朝向旋转面对玩家）。
    local okP, plist = pcall(function() return Game:GetAllPlayerPawns() end)
    local pawn = (okP and plist and plist.Num and plist:Num() > 0) and plist:Get(0) or nil
    if pawn then
        local locCM = pawn:K2_GetActorLocation()
        if locCM and locCM.X then
            local loc = { X = locCM.X / 100, Y = locCM.Y / 100, Z = locCM.Z / 100 }
            local ps = nil
            local okArr, arr = pcall(function() return Game:GetAllPlayerStates() end)
            if okArr and arr and arr.Num and arr:Num() > 0 then ps = arr:Get(0) end
            -- 取两种前方用于对比：相机视线（屏幕正前）与角色前向
            local fLookX, fLookY, fPawnX, fPawnY = 0, 1, 0, 1
            if ps then
                local okL, ld = pcall(function() return PlayerAPI.GetPlayerLookDirection(ps) end)
                if okL and ld and ld.X and ld.Y then
                    local len = math.sqrt(ld.X * ld.X + ld.Y * ld.Y)
                    if len > 1e-4 then fLookX, fLookY = ld.X / len, ld.Y / len end
                end
            end
            local okF, fwd = pcall(function() return pawn:GetActorForwardVector() end)
            if okF and fwd and fwd.X and fwd.Y then
                local len = math.sqrt(fwd.X * fwd.X + fwd.Y * fwd.Y)
                if len > 1e-4 then fPawnX, fPawnY = fwd.X / len, fwd.Y / len end
            end
            -- 屏幕正前 = 相机视线（最贴近“屏幕中心方向”，盘心落屏幕正中）；无视线则用角色前向
            local fx, fy, fsrc = fLookX, fLookY, "GetPlayerLookDirection"
            if fx == 0 and fy == 1 and (fPawnX ~= 0 or fPawnY ~= 1) then
                fx, fy, fsrc = fPawnX, fPawnY, "pawn:GetActorForwardVector"
            end
            return settle(loc, fx, fy, fsrc)
        end
    end

    print("[Tetris][ERROR] 无法生成盘面：出生点装置未注入且无本地玩家")
    return nil
end

-- 返回棋盘中心世界坐标（米）。供固定相机作为 ViewTarget。
function TetrisRenderer:GetBoardCenter()
    return self.boardCenter
end

function TetrisRenderer:PrintBounds()
    local r = TetrisConfig.Render
    local cols, rows = TetrisConfig.Board.Cols, TetrisConfig.Board.Rows
    local tl = self:cellLocation(1, 1)
    local br = self:cellLocation(rows, cols)
    local w = (cols - 1) * (r.CellSize + r.CellGap)
    local h = (rows - 1) * (r.CellSize + r.CellGap)
    print(string.format(
        "[Tetris] 盘面范围 X[%.2f ~ %.2f] Y=%.2f Z[%.2f ~ %.2f]  宽%.2fm 高%.2fm",
        tl.X, br.X, tl.Y, br.Z, tl.Z, w, h))
end

-- 纵向盘面：X 轴 = 列（左右），Z 轴 = 行（顶行 Z 最大，向下递减），Y = 深度固定。
function TetrisRenderer:cellLocation(row, col)
    local r = TetrisConfig.Render
    local step = r.CellSize + r.CellGap
    local o = self.origin or r.BoardOrigin
    -- 盘面右方向：玩家基准时为 forward×up（随朝向旋转），回退时为世界 +X（与原行为一致）
    local right = self.boardRight or { X = 1, Y = 0, Z = 0 }
    local dx = (col - 1) * step   -- 向右（沿盘面 right）
    local dz = (row - 1) * step   -- 向下（世界 -Z，盘面竖直）
    return {
        X = o.X + right.X * dx,
        Y = o.Y + right.Y * dx,
        Z = o.Z - dz,
    }
end

-- ---------------- 构建零旋转 FRotator ----------------
local function makeZeroRotator()
    local ok, rot = pcall(function()
        if type(FRotator) == "table" and FRotator.MakeFromEuler then
            return FRotator.MakeFromEuler(Game:ConstructFVectorByLuaTable({ X = 0, Y = 0, Z = 0 }))
        end
        return nil
    end)
    if ok and rot then return rot end
    return nil
end

-- 构造整体方块根 Actor 的旋转：绕“盘面法线(forward)”旋转 (rot-1)*90°，
-- 与数据层 rotateOffset 等价（yaw=90° 时退化成原 Pitch 逻辑，已验证一致）。
-- 关键点：盘面法线 = forward = (cos yaw, sin yaw, 0)，随出生点装置朝向变化，并非恒为世界 Y。
-- 旧实现固定绕世界 Y(Pitch)，在非 yaw=90° 朝向下会让方块翻出盘面（视为“旋转有问题”）。
-- UE MakeFromEuler(X,Y,Z) = (Roll绕X, Pitch绕Y, Yaw绕Z)，旋转矩阵 = Rz(Yaw)*Ry(Pitch)*Rx(Roll)。
-- 把“绕水平轴 n=(cosα,sinα,0) 旋转 θ”解析分解为 UE 欧拉角(pitch,yaw,roll)：
--   sin(pitch) = sinθ·sinα
--   yawE       = atan2((1-cosθ)·cosα·sinα,  cosθ + (1-cosθ)·cos²α)
--   roll       = atan2(sinθ·cosα, cosθ)
-- （yaw=0 → Roll(θ) 绕世界 X；yaw=90° → Pitch(θ) 绕世界 Y，均与旧行为/rotateOffset 一致）
local function makePieceRotator(rot)
    local sign = TetrisConfig.Render.PieceSpinSign or 1
    local alpha = math.rad(_boardYawDeg or 0)         -- 盘面偏航(弧度)
    local th = math.rad(-(rot - 1) * 90 * sign)       -- 旋转角(弧度，符号对齐 rotateOffset)
    local ca, sa = math.cos(alpha), math.sin(alpha)
    local ct, st = math.cos(th), math.sin(th)
    -- 解析分解（与 UE ZYX 欧拉矩阵匹配；yaw=0 / yaw=90° 两特例已手算验证）
    local pitch = math.asin(st * sa)
    local yawE = atan2compat((1 - ct) * ca * sa, ct + (1 - ct) * ca * ca)
    local roll = atan2compat(st * ca, ct)
    local ok, r = pcall(function()
        if type(FRotator) == "table" and FRotator.MakeFromEuler then
            return FRotator.MakeFromEuler(Game:ConstructFVectorByLuaTable({
                X = math.deg(roll), Y = math.deg(pitch), Z = math.deg(yawE) }))
        end
        return nil
    end)
    if ok and r then return r end
    return makeZeroRotator()
end

-- 绕 Y 轴（盘面法向/深度轴）的俯仰旋转：tetromino 在 X-Z 竖直面内旋转即用 Pitch。
local function makePitchRotator(deg)
    local ok, rot = pcall(function()
        if type(FRotator) == "table" and FRotator.MakeFromEuler then
            return FRotator.MakeFromEuler(Game:ConstructFVectorByLuaTable({ X = 0, Y = deg, Z = 0 }))
        end
        return nil
    end)
    if ok and rot then return rot end
    return nil
end

-- 米 -> 厘米向量（Class API 如 K2_TeleportTo 用厘米）
local function cmVec(loc)
    return Game:ConstructFVectorByLuaTable({ X = loc.X * 100, Y = loc.Y * 100, Z = loc.Z * 100 })
end

-- ---------------- 资源引用候选 ----------------
local function collectRefCandidates(key)
    local list = {}
    local function add(name, val)
        if val ~= nil then list[#list + 1] = { name = name, val = val } end
    end
    if type(AssetRef) == "table" then add("AssetRef", AssetRef[key]) end
    if type(CreativeAsset) == "table" then add("CreativeAsset", CreativeAsset[key]) end
    add("原始Key", key)
    return list
end

-- 从候选里挑出用于实际创建的 ref（优先 AssetRef，与探测首选项一致）
local function pickRef(candidates)
    for _, c in ipairs(candidates) do
        if c.name == "AssetRef" then return c.val end
    end
    if #candidates > 0 then return candidates[1].val end
    return nil
end

-- ---------------- 创建方式探测 ----------------
-- 返回 mode（"instance" / "actor"）、实际使用的 ref、首个对象
function TetrisRenderer:ProbeCreator(candidates, loc, scale)
    local attempts = {}

    for _, c in ipairs(candidates) do
        -- 方案 A：InstanceAPI.CreateInstance（CreativeAsset 类型的对应接口）
        attempts[#attempts + 1] = {
            label = "InstanceAPI.CreateInstance ref=" .. c.name .. " rot=FRotator",
            mode = "instance", ref = c.val, rot = self.rot,
        }
        attempts[#attempts + 1] = {
            label = "InstanceAPI.CreateInstance ref=" .. c.name .. " rot=nil",
            mode = "instance", ref = c.val, rot = nil,
        }
        -- 方案 B：CreativeGameAPI.CreateActor
        attempts[#attempts + 1] = {
            label = "CreativeGameAPI.CreateActor ref=" .. c.name,
            mode = "actor", ref = c.val, rot = nil,
        }
    end

    for _, a in ipairs(attempts) do
        local ok, obj = pcall(function()
            if a.mode == "instance" then
                return InstanceAPI.CreateInstance(a.ref, loc, a.rot, scale)
            else
                return CreativeGameAPI.CreateActor(a.ref, loc, a.rot, scale, nil)
            end
        end)
        if ok and obj then
            print("[Tetris] 创建方式探测成功 -> " .. a.label)
            return a.mode, a.ref, obj
        end
    end

    print("[Tetris][ERROR] 所有创建方案均失败，请确认预设已在编辑器注册")
    return nil, nil, nil
end

function TetrisRenderer:CreateOne(loc, scale, ref)
    local ok, obj = pcall(function()
        if self.mode == "instance" then
            return InstanceAPI.CreateInstance(ref, loc, self.rot, scale)
        else
            return CreativeGameAPI.CreateActor(ref, loc, self.rot, scale, nil)
        end
    end)
    if ok then return obj end
    if not self.createFailLogged then
        self.createFailLogged = true
        print("[Tetris][WARN] 创建失败: " .. tostring(obj))
    end
    return nil
end

-- 尝试取出实例背后的 Actor。动态实例可能是纯组件，取不到时返回 nil。
function TetrisRenderer:ResolveActor(obj)
    if not obj or self.mode ~= "instance" then return nil end
    local ok, actor = pcall(function() return InstanceAPI.GetActorByLogicInstance(obj) end)
    if ok and actor then return actor end
    return nil
end

-- 惰性解析：实例刚创建时底层 Actor 尚未生成，过早查询必然拿不到，
-- 因此在稳定期内持续重试，一旦成功即缓存；超过 ActorResolveFrames 则放弃。
function TetrisRenderer:EnsureActor(row, col)
    if self.mode ~= "instance" then return nil end
    local cached = self.actors[row] and self.actors[row][col]
    if cached then return cached end
    if self.frame > TetrisConfig.Render.ActorResolveFrames then return nil end

    local obj = self.cells[row] and self.cells[row][col]
    if not obj then return nil end
    local actor = self:ResolveActor(obj)
    if actor then
        self.actors[row][col] = actor
        self.actorCount = self.actorCount + 1
    end
    return actor
end

-- ---------------- 对象池 / 独立方块 Actor 操作 ----------------
-- 从对象池取出一个空闲方块 Actor；池耗尽（理论不会）时兜底新建一个。
function TetrisRenderer:AcquireActor()
    local a = table.remove(self.pool)
    if a then
        -- 重复占用检测：若 a 仍在占用集合，说明之前没 Release 就被再次取出 → occ 双重占用 → 一格漏显示。
        if self._occUsed and self._occUsed[a] then
            self._dupN = (self._dupN or 0) + 1
            if self._dupN % 120 == 1 then
            end
        end
        self._occUsed = self._occUsed or {}
        self._occUsed[a] = true
        return a
    end
    local s = TetrisConfig.Render.BlockScale
    local scale = Game:ConstructFVectorByLuaTable({ X = s, Y = s, Z = s })
    local na = self:CreateOne(Game:ConstructFVectorByLuaTable(self.hideLoc), scale, self.refTop)
    if na then
        self._occUsed = self._occUsed or {}
        self._occUsed[na] = true
    else
        self._noActorN = (self._noActorN or 0) + 1
        if self._noActorN % 120 == 1 then
        end
    end
    return na
end

-- 归还方块 Actor 到对象池（停回停车场，保持可见但脱离盘面）。
function TetrisRenderer:ReleaseActor(a)
    if a then
        if self._occUsed then self._occUsed[a] = nil end
        pcall(function() a:K2_TeleportTo(cmVec(self.hideLoc), self.rot) end)
        self.pool[#self.pool + 1] = a
    end
end

-- 把独立方块 Actor 放到 (row,col) 的世界坐标（静态摆放，不依赖附着）。
function TetrisRenderer:placeActor(a, row, col)
    if not a then return end
    pcall(function() a:K2_TeleportTo(cmVec(self:cellLocation(row, col)), self.rot) end)
end

-- 在指定格位置播放消行特效。Domain API 坐标用米，cellLocation 返回值即米，直接构造 FVector 传入。
-- 资源走 AssetRef（需 VSCode 插件注册并 update preset）；失败静默，不影响消行主流程。
function TetrisRenderer:PlayClearEffectAt(row, col)
    if not SceneEffectAPI or not SceneEffectAPI.CreateSceneEffect then return end
    local key = (TetrisConfig.Clear and TetrisConfig.Clear.EffectPresetKey) or "13_EffectPreset_100032"
    local ref = AssetRef and AssetRef[key]
    if not ref then
        if TetrisConfig.Debug then
            print(string.format("[Tetris][Clear][WARN] 特效资源未注册 AssetRef[%s]，跳过", tostring(key)))
        end
        return
    end
    local loc = self:cellLocation(row, col)
    -- 在格中心点基础上叠加配置偏移（单位：米，与 cellLocation 同坐标系）。
    local off = (TetrisConfig.Clear and TetrisConfig.Clear.EffectPositionOffset) or { X = 0.0, Y = 0.0, Z = 0.0 }
    local pos = { X = loc.X + (off.X or 0), Y = loc.Y + (off.Y or 0), Z = loc.Z + (off.Z or 0) }
    local dur = (TetrisConfig.Clear and TetrisConfig.Clear.EffectDuration) or 1.0
    local ok, id = pcall(function()
        return SceneEffectAPI.CreateSceneEffect(
            ref,
            Game:ConstructFVectorByLuaTable(pos),
            dur)
    end)
    if not ok or not id or id == 0 then
        if TetrisConfig.Debug then
            print(string.format("[Tetris][Clear][WARN] 特效创建失败 row=%d col=%d id=%s", row, col, tostring(id)))
        end
        return
    end
    -- 创建后调整尺寸：CreateSceneEffect 无缩放参数，需用 SetSceneEffectScale。
    -- 缩放为 FVector，各分量默认 1.0 = 原始大小。
    local scale = (TetrisConfig.Clear and TetrisConfig.Clear.EffectScale) or { X = 1.0, Y = 1.0, Z = 1.0 }
    pcall(function()
        SceneEffectAPI.SetSceneEffectScale(id,
            Game:ConstructFVectorByLuaTable({ X = scale.X, Y = scale.Y, Z = scale.Z }))
    end)
    if TetrisConfig.Debug then
        print(string.format("[Tetris][Clear] 特效 row=%d col=%d id=%s scale=(%.2f,%.2f,%.2f)",
            row, col, tostring(id), scale.X, scale.Y, scale.Z))
    end
end

-- ---------------- 整体活动方块（7 种 tetromino） ----------------
-- 设计：每种方块 = 4 个独立子方块 Actor，由「同一变换」驱动，保证刚体一致（整体移动）。
-- 不依赖 K2_AttachToActor 的父级传播（黑盒引擎下挂载经常不跟随，导致方块错位/不统一），
-- 而是每帧用 pieceCenterWorld + 旋转后的偏移，直接把 4 个子方块传送到正确位置——一次计算、整体落地。
-- 落地时：4 子方块送回停车场，棋盘单元方块接管显示（落地的方块设置为单元方块）。
-- 消行时：被清行的单元方块归位消失。

-- 旋转轴心（框内坐标）：与数据层 SRS 枢轴统一。
-- 4×4 框（I/O）中心 = (2.5, 2.5)；3×3 框（其余 5 种）中心格 = (2, 2)。
function TetrisRenderer:piecePivot(type)
    local pv = TetrisConfig.Rotation.Pivot[type]
    if pv then return pv.r, pv.c end
    local n = #TetrisConfig.Pieces[type].shape
    return (n + 1) / 2, (n + 1) / 2
end

-- 当前活动方块世界中心（旋转轴心映射到盘面坐标）
function TetrisRenderer:pieceCenterWorld(active)
    local step = TetrisConfig.Render.CellSize + TetrisConfig.Render.CellGap
    local pr, pc = self:piecePivot(active.type)
    local o = self.origin
    -- 列方向必须沿盘面 right（随盘面朝向旋转）；直接用世界 X 会在盘面非世界轴时错位
    local right = self.boardRight or { X = 1, Y = 0, Z = 0 }
    local dx = (active.x + pc - 2) * step
    return {
        X = o.X + right.X * dx,
        Y = o.Y + right.Y * dx,
        Z = o.Z - (active.y + pr - 2) * step,
    }
end

-- 绕 Y 轴旋转一个 (dx,dz) 偏移（与数据层顺时针旋转一致）
function TetrisRenderer:rotateOffset(dx, dz, rot)
    local sign = TetrisConfig.Render.PieceSpinSign
    local ang = math.rad((rot - 1) * 90 * sign)
    local cs, sn = math.cos(ang), math.sin(ang)
    -- 左手系绕 Y：X' = X*cos + Z*sin ; Z' = -X*sin + Z*cos
    return dx * cs + dz * sn, -dx * sn + dz * cs
end

-- ---------------- 整体活动方块 ----------------
-- 提供两套实现，由 BuildActivePieces 按资源可用性自动选择：
--   方案1（V1）：每类 4 个独立 Actor，由同一变换各自传送（旧逻辑，作为回退）。
--   方案2（V2）：每类 1 个隐形根 Actor + 4 个 StaticMeshComponent 子组件；
--               移动/下落只传送根一次 → 4 子组件随根原子跟随（零错位、1/4 流量）。
-- 两者都用 pieceCenterWorld / rotateOffset 算出相对矩阵中心的偏移，旋转枢轴一致。

-- 资源是否足以启用方案2（根 Actor 预设 + 组件预设都必须在 AssetRef 中）
function TetrisRenderer:CanUseWholePieceV2()
    if not self.origin then return false end
    local ar = (type(AssetRef) == "table") and AssetRef[TetrisConfig.Render.PieceRootPresetKey] or nil
    local cr = (type(AssetRef) == "table") and AssetRef[TetrisConfig.Render.PieceComponentPresetKey] or nil
    return ar and cr
end

-- 资源是否足以启用方案3（根 Actor 预设 + 子 Actor 预设都必须在 AssetRef 中）
function TetrisRenderer:CanUseWholePieceAttach()
    if not self.origin then return false end
    local rr = (type(AssetRef) == "table") and AssetRef[TetrisConfig.Render.PieceRootPresetKey] or nil
    local cr = (type(AssetRef) == "table") and AssetRef[TetrisConfig.Render.PieceChildPresetKey] or nil
    return rr and cr
end

-- 调度：优先方案3（附着子Actor）→ 方案2（组件，已证不可用）→ 方案1（4 Actor）
function TetrisRenderer:BuildActivePieces()
    if not TetrisConfig.Render.UseWholePiece then return end
    self.wholePieceV2 = false
    self.wholePieceAttach = false
    if TetrisConfig.Render.UseWholePieceAttach and self:CanUseWholePieceAttach() then
        self:BuildWholePiecePool()
    elseif TetrisConfig.Render.UseWholePieceV2 and self:CanUseWholePieceV2() then
        self:BuildActivePiecesV2()
    else
        self:BuildActivePiecesV1()
    end
end

-- 方案1：每类 4 个独立子 Actor（回退用）
function TetrisRenderer:BuildActivePiecesV1()
    if not self.origin then
        print("[Tetris][WARN] 整体方块(方案1)生成失败：盘面原点未初始化")
        return
    end
    local ref = (type(AssetRef) == "table") and AssetRef[TetrisConfig.Render.BlockActorPresetKey] or nil
    if not ref then
        print("[Tetris][WARN] 整体方块资源 AssetRef[\"" .. TetrisConfig.Render.BlockActorPresetKey
              .. "\"] 为空，回退逐格模式")
        return
    end
    local step = TetrisConfig.Render.CellSize + TetrisConfig.Render.CellGap
    local s = TetrisConfig.Render.BlockScale
    local scale = Game:ConstructFVectorByLuaTable({ X = s, Y = s, Z = s })
    local park = self.hideLoc

    for t = 1, 7 do
        local shape = TetrisConfig.Pieces[t] and TetrisConfig.Pieces[t].shape
        if not shape then
            print("[Tetris][WARN] 整体方块类型 " .. t .. " 无 shape，跳过")
        else
            local pr, pc = self:piecePivot(t)
            -- 收集 4 格相对旋转轴心的局部偏移（X=+列, Z=-行；轴心与数据层 SRS 枢轴一致）
            local offs = {}
            for r = 1, #shape do
                for c = 1, #shape do
                    if shape[r][c] == 1 then
                        offs[#offs + 1] = { dx = (c - pc) * step, dz = -((r - pr) * step) }
                    end
                end
            end
            -- 4 个子方块 Actor，初始停在停车场（远离盘面），运行时由统一变换驱动
            local kids = {}
            for _, o in ipairs(offs) do
                local wloc = Game:ConstructFVectorByLuaTable({ X = park.X + o.dx, Y = park.Y, Z = park.Z + o.dz })
                local child = CreativeGameAPI.CreateActor(ref, wloc, self.rot, scale, nil)
                if child then kids[#kids + 1] = child end
            end
            self.pieces[t] = { cells = kids, offsets = offs }
        end
    end
    local cnt = 0
    for _ in pairs(self.pieces) do cnt = cnt + 1 end
    self.wholePieceV2 = false
    print("[Tetris] 整体活动方块(方案1)已构建: " .. cnt .. "/7（4 子 Actor 由同一变换驱动）")
end

-- 方案2：每类 1 个隐形根 Actor + 4 个 StaticMeshComponent 子组件
function TetrisRenderer:BuildActivePiecesV2()
    local rootRef = (type(AssetRef) == "table") and AssetRef[TetrisConfig.Render.PieceRootPresetKey] or nil
    local compRef = (type(AssetRef) == "table") and AssetRef[TetrisConfig.Render.PieceComponentPresetKey] or nil
    local meshRef = (type(AssetRef) == "table") and AssetRef[TetrisConfig.Render.PieceMeshAssetKey] or nil
    if not rootRef or not compRef then
        print("[Tetris][WARN] 整体方块(方案2)资源未就绪(root/component 预设需在编辑器注册并执行 update preset)，回退方案1")
        self:BuildActivePiecesV1()
        return
    end
    local step = TetrisConfig.Render.CellSize + TetrisConfig.Render.CellGap
    local s = TetrisConfig.Render.BlockScale
    local scale = Game:ConstructFVectorByLuaTable({ X = s, Y = s, Z = s })
    local park = self.hideLoc
    local built = 0

    for t = 1, 7 do
        local shape = TetrisConfig.Pieces[t] and TetrisConfig.Pieces[t].shape
        if not shape then
            print("[Tetris][WARN] 整体方块(方案2)类型 " .. t .. " 无 shape，跳过")
        else
            local pr, pc = self:piecePivot(t)
            -- 4 格相对「旋转轴心」的局部偏移（米）；旋转绕此中心，与数据层 SRS 枢轴一致
            local offs = {}
            for r = 1, #shape do
                for c = 1, #shape do
                    if shape[r][c] == 1 then
                        offs[#offs + 1] = { dx = (c - pc) * step, dz = -((r - pr) * step) }
                    end
                end
            end
            -- 隐形根 Actor（EmptyActor）停在停车场，作为整体锚点（矩阵中心）
            local root = CreativeGameAPI.CreateActor(rootRef, Game:ConstructFVectorByLuaTable(park), self.rot, scale, nil)
            if not root then
                print("[Tetris][WARN] 整体方块(方案2)根 Actor 创建失败，回退方案1")
                self:BuildActivePiecesV1()
                return
            end
            local comps = {}
            local okAll = true
            for _, o in ipairs(offs) do
                local comp = CreativeGameAPI.AddComponent(root, compRef, "cell", nil, nil, nil)
                if not comp then
                    okAll = false
                    break
                end
                -- 关键修复：组件必须设为 Movable，否则运行时改相对位置被引擎忽略，
                -- 4 个子组件全堆在根原点（0,0,0）重叠成一个立方体 → 「只掉 1 格、落地才变完整」。
                pcall(function() comp:SetMobility(2) end)
                if meshRef then
                    pcall(function() comp:SetStaticMesh(meshRef) end)
                end
                -- 相对根的本地偏移（厘米，Class API）：Y 固定 0（与盘面同深）
                local relLoc = Game:ConstructFVectorByLuaTable({ X = o.dx * 100, Y = 0, Z = o.dz * 100 })
                pcall(function() comp:K2_SetRelativeLocation(relLoc, false, nil, true) end)
                -- 诊断：确认相对位置/机动性是否真的生效（黑盒引擎下组件 API 行为未知）
                pcall(function()
                    if TetrisConfig.Debug then
                        local rl = comp.RelativeLocation
                        print(string.format(
                            "[Tetris][V2] 子组件#%d 目标rel=(%.0f,%.0f,%.0f) 实际rel=(%.0f,%.0f,%.0f) Mobility=%s",
                            #comps + 1, o.dx * 100, 0, o.dz * 100,
                            rl and rl.X or -9999, rl and rl.Y or -9999, rl and rl.Z or -9999,
                            tostring(comp.Mobility)))
                    end
                end)
                comps[#comps + 1] = comp
            end
            if not okAll then
                print("[Tetris][WARN] 整体方块(方案2)子组件创建失败，回退方案1")
                self:BuildActivePiecesV1()
                return
            end
            self.pieces[t] = { root = root, comps = comps, offsets = offs, lastRot = nil, lastType = nil }
            built = built + 1
        end
    end
    self.wholePieceV2 = (built > 0)
    print("[Tetris] 整体活动方块(方案2)已构建: " .. built .. "/7（根+子组件，移动只传根→原子跟随）")
end

-- 统一活动方块池（方案3：每类 1 个隐形根 Actor + 4 个方块子 Actor 附着在根上）：
-- 仅预建 7 个活动整体实例（每型 1 份），供下落/旋转/移动使用；分帧构建避免一次性 105 个 Actor 卡顿。
-- 顺序写入 self.piecePool（= self.pieces[t]），由 PrimeAllPieces 预热附着后就绪。
-- 下一预览 / Hold 暂存改为「按需生成的静态方块」（见 UpdateNextPreview / UpdateHoldPreview），仅展示、不预建，
-- 故初始化只有 7 个整体方块；子 Actor 是真实 Actor，根一动 4 子随根原子跟随（统一运动 + 1/4 流量）。
function TetrisRenderer:BuildWholePiecePool()
    local rootRef = (type(AssetRef) == "table") and AssetRef[TetrisConfig.Render.PieceRootPresetKey] or nil
    local childRef = (type(AssetRef) == "table") and AssetRef[TetrisConfig.Render.PieceChildPresetKey] or nil
    if not rootRef or not childRef then
        print("[Tetris][WARN] 统一方块池(每型3份)资源未就绪(root/child 预设需在编辑器注册并执行 update preset)，回退方案1")
        self:BuildActivePiecesV1()
        return
    end
    if self._poolBuild then return end  -- 已在分帧构建中
    local step = TetrisConfig.Render.CellSize + TetrisConfig.Render.CellGap
    local s = TetrisConfig.Render.BlockScale
    local scale = Game:ConstructFVectorByLuaTable({ X = s, Y = s, Z = s })
    local park = self.hideLoc
    local rot0 = self.rot
    local right = self.boardRight or { X = 1, Y = 0, Z = 0 }
    self.pieces = {}
    self.piecePool = {}

    -- 预生成清单：每型 3 份（活动/下一/Hold），共 21 个整体实例。
    -- 改为分帧构建（每帧若干份，见 ProcessPoolBuild），避免一次性同步 CreateActor 105 次造成初始化冻结。
    local list = {}
    for t = 1, 7 do
        local shape = TetrisConfig.Pieces[t] and TetrisConfig.Pieces[t].shape
        if not shape then
            print("[Tetris][WARN] 统一方块池类型 " .. t .. " 无 shape，跳过")
        else
            local pr, pc = self:piecePivot(t)
            local offs = {}
            for r = 1, #shape do
                for c = 1, #shape do
                    if shape[r][c] == 1 then
                        offs[#offs + 1] = { dx = (c - pc) * step, dz = -((r - pr) * step) }
                    end
                end
            end
            list[#list + 1] = { t = t, copy = 1, offs = offs }
        end
    end
    self.wholePieceAttach = (#list > 0)
    self._poolBuild = {
        list = list, idx = 1, built = 0, perFrame = 2,
        step = step, scale = scale, park = park, rot0 = rot0, right = right,
        rootRef = rootRef, childRef = childRef,
    }
    print("[Tetris] 统一方块池开始分帧构建: 计划 " .. #list .. "/21（每型3份=活动+下一+暂存），每帧约 " .. 2 .. " 份")
    self:ProcessPoolBuild()  -- 立即建首批，其余由 Update 逐帧补齐
end

-- 分帧构建：每帧最多建 self._poolBuild.perFrame 个整体实例，消除一次性同步 CreateActor 的卡顿。
-- 根 Actor 异步 spawn，子块附着推迟到 PrimeAllPieces / 展示期每帧重试（与旧逻辑一致）。
function TetrisRenderer:ProcessPoolBuild()
    local pb = self._poolBuild
    if not pb then return end
    local rootRef, childRef, park, rot0, right, scale = pb.rootRef, pb.childRef, pb.park, pb.rot0, pb.right, pb.scale
    local done = 0
    while pb.idx <= #pb.list and done < pb.perFrame do
        local item = pb.list[pb.idx]
        pb.idx = pb.idx + 1
        local t, copy, offs = item.t, item.copy, item.offs
        -- 隐形根 Actor 停在停车场（矩阵中心 = 旋转枢轴）
        local root = CreativeGameAPI.CreateActor(rootRef, Game:ConstructFVectorByLuaTable(park), rot0, scale, nil)
        if not root then
            print("[Tetris][WARN] 统一方块池根 Actor 创建失败，回退方案1")
            self._poolBuild = nil
            self:BuildActivePiecesV1()
            return
        end
        pcall(function() root:SetActorHiddenInGame(false) end)  -- EmptyActor 无网格→渲染仍隐形；不传播隐藏给子 Actor
        local children = {}
        local okAll = true
        for _, o in ipairs(offs) do
            -- 子 Actor 先建在「根世界位置 + 偏移」处（暂不附着）
            local cw = Game:ConstructFVectorByLuaTable({ X = park.X + right.X * o.dx, Y = park.Y + right.Y * o.dx, Z = park.Z + o.dz })
            local child = CreativeGameAPI.CreateActor(childRef, cw, rot0, scale, nil)
            if not child then okAll = false break end
            children[#children + 1] = child
        end
        if not okAll then
            print("[Tetris][WARN] 统一方块池子 Actor 创建失败，回退方案1")
            self._poolBuild = nil
            self:BuildActivePiecesV1()
            return
        end
        -- attached 留待首次放置/展示时再做：根 Actor 是异步 spawn 的，构建后立即附着会静默失败
        -- （子 Actor 变孤儿、不跟随根 → 表现为「部分方块不整体运动」）。
        local inst = { root = root, children = children, offsets = offs, attached = false, type = t }
        pb.built = pb.built + 1
        self.piecePool[pb.built] = inst
        self.pieces[t] = inst
        done = done + 1
    end
    if pb.idx > #pb.list then
        local total = pb.built
        self._poolBuild = nil
        self:fillPieceQueue()  -- 把预建实例(活动 7 份)入队，供 acquire/release 管理取还
        print("[Tetris] 统一方块池已构建: " .. total .. "/7（每型1份=活动；下一/Hold 改由静态方块按需生成）")
    end
end

-- 下一个方块预览 / Hold 暂存不再预建整体实例，改为游戏进行中按需在对应位置生成静态方块
-- （见 UpdateNextPreview / UpdateHoldPreview 与 BuildPreviewBlocks），故 BuildWholePiecePool 只管 7 个活动方块。

-- 方案3：只传送根 Actor（平移单变换，保留 V3 的 1/4 流量优势）；
-- 旋转由根 Actor 绕盘面垂直轴（世界 Y / UE Pitch = MakeFromEuler 的 X 分量）旋转 (rot-1)*90° 实现，
-- 子块作为根的子 Actor 随父旋转，保持整体刚体一致（旋转不再烘焙到子块相对偏移）。
-- 旋转方向由 makePieceRotator 用 PieceSpinSign 对齐数据层 rotateMatrixCW（与 rotateOffset 矩阵等价）。
-- 判定整体方块是否"完整"：所有子 Actor 已正确跟随根
-- （世界位置 ≈ 根位置 + 旋转后的相对偏移，容差 5cm）。
-- 用于在下落前确认方块已完整，避免"根已就位、子块还停在停车场"的半成品帧。
function TetrisRenderer:isWholePieceReady(p, active)
    if not p or not p.root or not p.children or #p.children == 0 then return false end
    local ok = true
    pcall(function()
        local rl = p.root:K2_GetActorLocation()
        if not rl then ok = false return end
        for i, child in ipairs(p.children) do
            local cl = child:K2_GetActorLocation()
            local o = p.offsets[i]
            if not cl or not o then ok = false return end
            local dx, dz = self:rotateOffset(o.dx, o.dz, active.rot)
            local right = self.boardRight or { X = 1, Y = 0, Z = 0 }
            local exX = rl.X + right.X * dx * 100
            local exY = rl.Y + right.Y * dx * 100
            local exZ = rl.Z + dz * 100
            if math.abs(cl.X - exX) > 5 or math.abs(cl.Y - exY) > 5 or math.abs(cl.Z - exZ) > 5 then
                ok = false return
            end
        end
    end)
    return ok
end

-- 安全附着：pcall 捕获防每帧抛错中断重试循环（保持 V3 稳健），失败每帧 Log.Error 暴露真实错误（不吞错）。
-- 根未 spawn 时 K2_AttachToActor 若静默失败则不抛错、下一帧重试；若抛错也被 pcall 兜住，仅报警不中断。
function TetrisRenderer:attachChildToRoot(child, root)
    if not child or not root then return false end
    local ok, err = pcall(function() child:K2_AttachToActor(root, "", 1, 1, 1, false) end)
    if not ok then
        Log.Error("[Tetris][Attach] K2_AttachToActor 失败: " .. tostring(err))
        return false
    end
    self._attachOkN = (self._attachOkN or 0) + 1
    if self._attachOkN % 60 == 1 then  -- 限频，避免每帧幂等成功刷屏
        local ok2, cl = pcall(function() return child:K2_GetActorLocation() end)
        if ok2 and cl then
            Log.Info(string.format("[Tetris][Attach] 成功 child=%s loc=(%.0f,%.0f,%.0f)",
                tostring(child), cl.X, cl.Y, cl.Z))
        else
            Log.Info("[Tetris][Attach] 成功 child=" .. tostring(child))
        end
    end
    return true
end

-- ---------------- 活动方块队列（轻量封装） ----------------
-- 预生成的方块实例按类型入队；活动方块生成时 acquire 一个，锁定后 release 归还。
-- 内部实例仍为 7 种预建(wholePieceAttach)；队列仅管理「取/还」，行为不变。
function TetrisRenderer:fillPieceQueue()
    self.pieceQueue = {}
    for t = 1, 7 do
        local p = self.pieces[t]
        if p then
            p.type = t
            p.inUse = false
            table.insert(self.pieceQueue, p)
        end
    end
end

-- 从队列取一个指定类型的方块实例（标记占用）。队列空/无同型时回退直接取预建实例。
-- 取出的实例只在此标记占用；子块附着仅在 PrimeAllPieces 初始化时设置一次，piecesReady 闸门保证此处已就绪，
-- placeWholePieceV3 只移动/旋转根，子块靠 UE 附着关系随根跟随，无需重附。
function TetrisRenderer:acquirePiece(type)
    if not type then return nil end
    for i, p in ipairs(self.pieceQueue) do
        if p.type == type and not p.inUse then
            table.remove(self.pieceQueue, i)
            p.inUse = true
            return p
        end
    end
    print(string.format("[Tetris][WARN] acquire 队列无空闲 type=%d 回退 self.pieces（仍属7预建池,非新生成）", type))
    local p = self.pieces[type]
    if p then p.inUse = true end
    return p
end

-- 归还方块实例到队列（先归位停车场），供后续活动方块复用。
function TetrisRenderer:releasePiece(p)
    if not p then return end
    p.inUse = false
    self:parkWholePieceV3(p)
    table.insert(self.pieceQueue, p)
end

-- 无条件幂等重试：把整体方块的 4 个子 Actor 附着到根，并烘焙当前 rot 的相对偏移。
-- 每帧调用都安全：K2_AttachToActor 幂等；根未 spawn 时附着静默失败，下一帧再来，直到成功。
-- 重烘焙消除"先传送根再附着导致相对偏移错乱（子块永久停在停车场）"的隐患。
function TetrisRenderer:EnsureWholePieceAttached(p, active)
    if not p or not p.root or not p.children then return end
    for i, child in ipairs(p.children) do
        -- 每帧幂等重附：纠正因异步 spawn / 释放复用 / 任何原因变孤儿、停在停车场的子块。
        -- 否则 _everReady 冻结后不再重附 → 该子块永远不跟随根 → 表现为「漏显示单元」。
        self:attachChildToRoot(child, p.root)
        -- 每帧均重设子块相对偏移（rot=1 原始值）：常量无抖动，但可纠正任何原因（复用/旋转/detach）
        -- 变孤儿、停在停车场(hideLoc)的子块，立即归位到根，避免「漏显示/不显示」（取消隐藏后仍停在视线外）。
        local o = p.offsets[i]
        if o then
            -- 子块相对根偏移必须沿盘面 right（随 boardRight 旋转）；用世界 X 轴固定偏移会在盘面
            -- 非世界轴(即 pawn 基准真实朝向)时错位，且无法跟随 ResolveOrigin 后续更新（时序问题）
            local right = self.boardRight or { X = 1, Y = 0, Z = 0 }
            pcall(function()
                child:K2_SetActorRelativeLocation(
                    Game:ConstructFVectorByLuaTable({ X = right.X * o.dx * 100, Y = right.Y * o.dx * 100, Z = o.dz * 100 }))
        end)
        end
    end
end

-- 预热（下落前生成好 1 个方块）：在活动方块下落期间，把"下一个方块"的根 Actor spawn 完成、
-- 4 个子 Actor 附着并烘焙到 rot=1 偏移，使其真正成为活动方块时已是完整整体，消除首次出现的半成品帧。
-- 无条件幂等：根未 spawn / 子块未跟随时静默失败，每帧重试，直至就绪；期间整体隐藏在停车场外。
function TetrisRenderer:PrewarmPiece(type)
    if not self.wholePieceAttach or not type then return end
    local p = self.pieces[type]
    if not p or not p.root or p._everReady then return end
    -- 每帧幂等重试附着 + 摆 rot=1 原始偏移（仅未就绪时设置一次）。
    -- 不隐藏、不 teleport：可见性完全由 RenderActivePiece 控制，避免预热与显示路径互相抢实例。
    self:EnsureWholePieceAttached(p, { rot = 1 })
    -- 预热完成判据：子块已随根就位（attach 成功 + 相对偏移正确）→ 冻结 _everReady，
    -- 之后旋转/移动只转根、不再触碰任何子块坐标。
    if self:isWholePieceReady(p, { rot = 1 }) then
        p._everReady = true
    end
end

-- 启动前预热闸门：逐帧把所有 7 种整体实例附着并就绪（_everReady）。
-- 全部就绪后才允许渲染活动方块，避免「实例未建好 / 子块未跟随」导致的方块错乱、半成品帧。
-- 非整体模式（回退 V1）或已就绪则直接放行。
function TetrisRenderer:PrimeAllPieces()
    if self.piecesReady then return end
    if not self.wholePieceAttach then
        self.piecesReady = true
        return
    end
    local allOk = true
    for t = 1, 7 do
        local p = self.pieces[t]
        if not p or not p.root then allOk = false break end
        self:PrewarmPiece(t)
        if not p._everReady then allOk = false end
    end
    if allOk then
        self.piecesReady = true
        print("[Tetris] 全部整体方块预热就绪 7/7，开始渲染活动块")
    end
end

function TetrisRenderer:placeWholePieceV3(p, active)
    if not p or not p.root then return end
    local center = self:pieceCenterWorld(active)

    -- 子块附着仅在 PrimeAllPieces 初始化时设置一次（piecesReady 闸门保证此处已就绪）；
    -- 之后只移动/旋转根，子块靠 UE 附着关系随根整体刚体跟随，无需每帧重附防御。
    -- 先把根定位到 spawn 并绕盘面垂直轴旋转到当前 rot（子块随根旋转，保持整体刚体一致）。
    pcall(function() p.root:K2_TeleportTo(cmVec(center), makePieceRotator(active.rot)) end)

    -- 旋转构造验证探针（一次性）：打印根旋转分量(P/Y/R) 与子块相对根实际偏移 vs 期望偏移，
    -- 确认根旋转方向/轴是否对齐 rotateOffset。打印的是数值不是类型，可直接判断方向。
    if active.rot > 1 and not (self._rotVerifyRot and self._rotVerifyRot[active.rot]) then
        self._rotVerifyRot = self._rotVerifyRot or {}
        self._rotVerifyRot[active.rot] = true
        pcall(function()
            local function dumpRot(r)
                if not r then return "nil" end
                local g = function(k) local ok, v = pcall(function() return r[k] end) return ok and tostring(v) or "?" end
                return string.format("P=%s Y=%s R=%s", g("Pitch"), g("Yaw"), g("Roll"))
            end
            local function getRot(actor)
                local ok, v = pcall(function() return actor:K2_GetActorRotation() end)
                return ok and v or nil
            end
            local rl = p.root:K2_GetActorLocation()
            local c1 = p.children[1]
            local cl = c1 and c1:K2_GetActorLocation()
            local o = p.offsets[1]
            local dx, dz = self:rotateOffset(o.dx, o.dz, active.rot)
            local cR = makePieceRotator(active.rot)

        end)
    end

    -- 就绪判定：子块世界位置 ≈ 根 + 偏移 → 已完整跟随。
    -- 未就绪（根尚未 spawn / 子块未跟随）：整体隐藏，玩家看不到半成品，下一帧继续。
    if not self:isWholePieceReady(p, active) then
        -- 半成品/漏单元诊断：判定失败（整块将隐藏）。打印 4 子块各自偏差，定位哪块孤儿(d 大)或缺失(nil)。
        self._v3FailN = (self._v3FailN or 0) + 1
        if self._v3FailN % 120 == 1 then
            pcall(function()
                local rl = p.root:K2_GetActorLocation()
                local parts = {}
                for i, child in ipairs(p.children or {}) do
                    if not child then
                        parts[#parts + 1] = string.format("#%d nil", i)
                    else
                        local cl = child:K2_GetActorLocation()
                        local o = p.offsets[i]
                        if rl and cl and o then
                            local dx, dz = self:rotateOffset(o.dx, o.dz, active.rot)
                            local d = math.sqrt((cl.X - (rl.X + dx * 100)) ^ 2 + (cl.Z - (rl.Z + dz * 100)) ^ 2)
                            parts[#parts + 1] = string.format("#%d d=%.0f", i, d)
                        else
                            parts[#parts + 1] = string.format("#%d ?", i)
                        end
                    end
                end
            end)
        end
        -- 诊断：旋转态(rot>1)判定失败时，打印首个子块实际 vs 期望偏差，确认根旋转方向/轴是否对齐 rotateOffset。
        -- 偏差≈0 → 隐藏另有原因；偏差大且 X/Z 同号反号 → 符号反；某轴异常大 → 轴分量(X 非 Pitch)错。
        if active.rot > 1 and not (self._v3RotDiagDone and self._v3RotDiagDone[p.type]) then
            self._v3RotDiagDone = self._v3RotDiagDone or {}
            self._v3RotDiagDone[p.type] = true
            pcall(function()
                local c1 = p.children[1]
                local rl = p.root:K2_GetActorLocation()
                local cl = c1 and c1:K2_GetActorLocation()
                if rl and cl then
                    local dx, dz = self:rotateOffset(p.offsets[1].dx, p.offsets[1].dz, active.rot)

                end
            end)
        end
        -- 位置偏差不再隐藏整块（piecesReady 闸门已保证附着就绪，子块随根跟随，不存在孤儿）；
        -- 隐藏整块反而造成「下落方块未显示」的假象。放行到下方统一显示（实例缺失时 pcall 兜底，不崩）。
    end

    -- 就绪：整体方块（靠移动根到盘面显示，不调用显隐；子块跟随根）。
    -- 活动整体始终为可见状态，靠 hideLoc 视线外/盘面位置控制是否入画。

    -- 可见性诊断（限频）：定位"显示不出的块"到底是「仍隐藏」还是「子块孤儿停在视线外(hideLoc)」。
    -- rootHid=true → 唤醒/取消隐藏失败（隐藏态）；某 child d 很大 → 该子块未跟随根（视线外孤儿，attach 未生效）。
    self._visDiagN = (self._visDiagN or 0) + 1
    if self._visDiagN % 120 == 1 then
        pcall(function()
            local rh = p.root:GetActorHiddenInGame()
            local rl = p.root:K2_GetActorLocation()
            local parts = {}
            for i, child in ipairs(p.children or {}) do
                local ch = child:GetActorHiddenInGame()
                local cl = child:K2_GetActorLocation()
                local d = (rl and cl) and math.sqrt((cl.X - rl.X) ^ 2 + (cl.Z - rl.Z) ^ 2) or -1
                parts[#parts + 1] = string.format("#%d hid=%s d=%.0f", i, tostring(ch), d)
            end
        end)
    end

    p._everReady = true  -- 整体已随根正确就绪：冻结子块偏移，旋转/移动纯靠根 Actor 带动（不再每帧重设）
    p.lastRot = active.rot
    p.lastType = active.type

    -- 结构体检（每型一次，无条件打印）：确认 children 数量=offsets、无重复引用。
    -- 若 children<4 或存在 #i=#j 重复 → 即「漏显示单元」的结构性根因（构建/复用裁减或引用共享）。
    if not (self._structDone and self._structDone[p.type]) then
        self._structDone = self._structDone or {}
        self._structDone[p.type] = true

    end

    -- 漏单元诊断：显示已发生，逐子块体检；仅发现异常（孤儿/缺失/无效）才打印，正常无噪音。
    -- 去掉「每型一次」限制：漏单元多为偶发（复用/旋转后才出现），须每次都查才能抓到。
    pcall(function()
        local rl = p.root:K2_GetActorLocation()
        local bad = {}
        for i, child in ipairs(p.children or {}) do
            if not child then
                bad[#bad + 1] = string.format("#%d nil", i)
            else
                local cl = child:K2_GetActorLocation()
                local o = p.offsets[i]
                if rl and cl and o then
                    local dx, dz = self:rotateOffset(o.dx, o.dz, active.rot)
                    local dist = math.sqrt((cl.X - (rl.X + dx * 100)) ^ 2 + (cl.Z - (rl.Z + dz * 100)) ^ 2)
                    if dist > 50 then bad[#bad + 1] = string.format("#%d d=%.0f", i, dist) end
                else
                    bad[#bad + 1] = string.format("#%d 无效", i)
                end
            end
        end
        if #bad > 0 then
            self._leakN = (self._leakN or 0) + 1
            if self._leakN % 120 == 1 then
            end
        end
    end)

    -- 诊断（逐类型，每局每种仅一次）：确认子 Actor 跟随根、旋转正确（服务端视角）
    if TetrisConfig.Debug and not (self._v3DiagDone and self._v3DiagDone[p.type]) then
        self._v3DiagDone = self._v3DiagDone or {}
        self._v3DiagDone[p.type] = true
        pcall(function()
            local c1 = p.children[1]
            local wl = c1 and c1:K2_GetActorLocation()
            if wl then
                local dx, dz = self:rotateOffset(p.offsets[1].dx, p.offsets[1].dz, active.rot)

            end
        end)
    end
end

-- 调试用：停车场移到视线内，并按 type 横向分散 7 个块，便于肉眼区分、观察回收块是否隐藏/缺子块。
-- 仅移动根；子块随根一起到可见位。正常下落不受影响（活动块由 place 摆到盘面）。
function TetrisRenderer:parkWholePieceV3(p)
    if not p or not p.root then return end
    local r = TetrisConfig.Render
    local step = r.CellSize + r.CellGap
    local gap = step * 4                        -- 每种间隔 4 格，避免重叠
    local o = self.origin or r.BoardOrigin
    local midX = o.X + (TetrisConfig.Board.Cols - 1) * step / 2
    local zShow = o.Z + step * 50                -- 盘面上方 8 行（视线内，非 hideLoc 暗处）
    local x = midX + (p.type - 4) * gap
    pcall(function() p.root:K2_TeleportTo(cmVec({ X = x, Y = o.Y, Z = zShow }), self.rot) end)
end

-- 方案1：用统一变换把 4 个子 Actor 定位到当前位置
function TetrisRenderer:placePieceChildren(p, active)
    if not p or not p.cells then return end
    local center = self:pieceCenterWorld(active)
    local right = self.boardRight or { X = 1, Y = 0, Z = 0 }
    for i, off in ipairs(p.offsets) do
        local dx, dz = self:rotateOffset(off.dx, off.dz, active.rot)
        -- dx 为盘面右方向偏移（沿 right）；dz 为世界 Z 方向偏移
        local wloc = { X = center.X + right.X * dx, Y = center.Y + right.Y * dx, Z = center.Z + dz }
        local cell = p.cells[i]
        if cell then
            pcall(function() cell:K2_TeleportTo(cmVec(wloc), self.rot) end)
        end
    end
end

-- 方案1：把 4 个子 Actor 送回停车场
function TetrisRenderer:parkPieceChildren(p)
    if not p or not p.cells then return end
    for i, off in ipairs(p.offsets) do
        local wloc = { X = self.hideLoc.X + off.dx, Y = self.hideLoc.Y, Z = self.hideLoc.Z + off.dz }
        local cell = p.cells[i]
        if cell then
            pcall(function() cell:K2_TeleportTo(cmVec(wloc), self.rot) end)
        end
    end
end

-- 方案2：只传送根 Actor；4 子组件随根原子跟随。
-- 相对偏移仅在旋转/换型时更新（低频）；平移时不碰子组件 → 完全原子、零错位、最小流量。
function TetrisRenderer:placeWholePieceV2(p, active)
    if not p or not p.root then return end
    local center = self:pieceCenterWorld(active)
    pcall(function() p.root:K2_TeleportTo(cmVec(center), self.rot) end)

    if p.lastRot ~= active.rot or p.lastType ~= active.type then
        for i, off in ipairs(p.offsets) do
            local comp = p.comps[i]
            if comp then
                local dx, dz = self:rotateOffset(off.dx, off.dz, active.rot)
                pcall(function()
                    comp:K2_SetRelativeLocation(
                        Game:ConstructFVectorByLuaTable({ X = dx * 100, Y = 0, Z = dz * 100 }),
                        false, nil, true)
                end)
            end
        end
        p.lastRot = active.rot
        p.lastType = active.type
    end
end

-- 方案2：根 Actor 归位（子组件随根回停车场）
function TetrisRenderer:parkWholePieceV2(p)
    if not p or not p.root then return end
    pcall(function() p.root:K2_TeleportTo(cmVec(self.hideLoc), self.rot) end)
end

-- 显示/归位活动方块整体；按 wholePieceAttach / wholePieceV2 选择方案3 / 方案2 / 方案1。
function TetrisRenderer:RenderActivePiece(board)
    if not self.piecesReady then return end  -- 7 种整体实例未全部附着就绪（PrimeAllPieces），不渲染活动块，避免错乱/半成品
    if self.previewing then return end  -- 预览阶段由 ShowcasePieces 接管，不渲染活动方块
    if not TetrisConfig.Render.UseWholePiece or next(self.pieces) == nil then return end
    local active = board:getActive()
    local wantType = active and active.type or nil

    if self.wholePieceAttach then
        if wantType == self.shownPieceType then
            if active and self.shownPiece then
                self:placeWholePieceV3(self.shownPiece, active)
            end
            return
        end
        -- 类型变化：回收旧的、从队列取新的
        if self.shownPiece then self:releasePiece(self.shownPiece) end
        local p = nil
        if wantType then p = self:acquirePiece(wantType) end
        if p then
            self:placeWholePieceV3(p, active)
            -- 下落调试：仅在新方块开始下落（acquire 取新实例）时打印一次，所有子块实际坐标 vs 预期坐标。
            if TetrisConfig.Debug and TetrisConfig.Debug.DropDbg then
                pcall(function()
                    local rl = p.root:K2_GetActorLocation()
                    local lines = {}
                    for i, child in ipairs(p.children or {}) do
                        local cl = child:K2_GetActorLocation()
                        local o = p.offsets[i]
                        local dx, dz = self:rotateOffset(o.dx, o.dz, active.rot)
                        local ex, ez = (rl.X + dx * 100), (rl.Z + dz * 100)
                        local dev = (cl and rl and o) and math.sqrt((cl.X - ex) ^ 2 + (cl.Z - ez) ^ 2) or -1
                        lines[#lines + 1] = string.format("#%d act=(%.0f,%.0f,%.0f) exp=(%.0f,%.0f,%.0f) dev=%.0f",
                            i, cl.X, cl.Y, cl.Z, ex, rl.Y, ez, dev)
                    end
                end)
            end
        end
        self.shownPiece = p
        self.shownPieceType = wantType
        return
    end

    if self.wholePieceV2 then
        if wantType == self.shownPieceType then
            if active then
                local p = self.pieces[wantType]
                if p then self:placeWholePieceV2(p, active) end
            end
            return
        end
        if self.shownPieceType and self.pieces[self.shownPieceType] then
            self:parkWholePieceV2(self.pieces[self.shownPieceType])
        end
        if wantType and self.pieces[wantType] then
            self:placeWholePieceV2(self.pieces[wantType], active)
        end
        self.shownPieceType = wantType
        return
    end

    if wantType == self.shownPieceType then
        if active then
            local p = self.pieces[wantType]
            if p then self:placePieceChildren(p, active) end
        end
        return
    end
    if self.shownPieceType and self.pieces[self.shownPieceType] then
        self:parkPieceChildren(self.pieces[self.shownPieceType])
    end
    if wantType and self.pieces[wantType] then
        self:placePieceChildren(self.pieces[wantType], active)
    end
    self.shownPieceType = wantType
end

-- ---------------- 开局预览 ----------------
-- 把 7 种方块（整体模式模板）摆在盘面前方正上方一排，供肉眼核对形状。
-- 仅整体模式(wholePieceAttach)有效；其余模式直接回调（无预览）。
function TetrisRenderer:ShowcasePieces(seconds)
    -- 版本标记：确认新代码是否真的加载进运行实例。重启后若看不到本行，说明仍在跑旧实例。
    -- pcall 捕获测试：确认 pcall 能否捕获报错；并验证 Log 是否真未定义（之前 DiagRot 用 Log.Info 被吞的元凶）
    do
        local ok1, r1 = pcall(function() return 1 + 1 end)
        local ok2, err2 = pcall(function() return Log.Info("若看到此说明 Log 可用") end)
    end
    if not self.wholePieceAttach or next(self.pieces) == nil then return end
    self.previewing = true
    self.shownPieceType = nil
    self._showcaseDiagDone = false
    self._previewForceRot = false               -- 半程演示旋转由 Game 在 PreviewSeconds*0.5 调用 PreviewRotateDemo() 置位
    self._previewRotDone = false
    self._previewSeconds = seconds or 5
    self._previewStartFrame = self.frame or 0    -- 预览起始帧（兜底：若 Game flag/os 均不可见，按帧数在预览中期旋转）
    -- 记录预览起始时钟（os.clock 若被环境禁用则置 nil，回退依赖 Game 的 PreviewRotateDemo 路径）
    local ok, clk = pcall(function() return os.clock() end)
    self._previewStartClock = ok and clk or nil
    -- 立即尝试一次；若 7 个模板的根 Actor 尚未 spawn（CreateActor 异步），附着会失败，
    -- 由 Update 在预览期每帧调用 LayoutShowcasePieces 重试，直至全部附着成功。
    self:LayoutShowcasePieces()
    print(string.format("[Tetris] 开局预览：7 个活动方块(每型1份)已摆在盘面上方，%.0f 秒后开始下落", seconds or 10))
end

-- 预览半程触发：让 7 个展示方块整体旋转 90° 一次（与下落同源 makePieceRotator + rotateOffset），供肉眼核对旋转跟随。
function TetrisRenderer:PreviewRotateDemo()
    if not self.previewing then return end
    self._previewForceRot = true
    -- 预览期 Game 不每帧驱动 renderer:Update，LayoutShowcasePieces 仅被 ShowcasePieces 立即调过一次（rot=1）；
    -- 故此处必须主动重摆一次，把 _previewForceRot→midRot=2 的旋转 teleport 到根，否则旋转永不应用。
    self:LayoutShowcasePieces()
end

-- 摆出/刷新 7 种预览方块。幂等、且对异步 spawn 安全：
-- 根未 spawn 时附着会失败 → 不置 attached，下一帧由 Update 再来一次，直到根就绪。
-- 注意：本函数每帧调用（预览期），但根/子已附着后只做廉价的位置传送，无副作用。
function TetrisRenderer:LayoutShowcasePieces()
    if not self.wholePieceAttach or next(self.pieces) == nil then return end
    local r = TetrisConfig.Render
    local step = r.CellSize + r.CellGap
    local gap = step * 5                       -- 每种方块间隔 5 格，避免相邻重叠
    local o = self.origin or r.BoardOrigin
    local right = self.boardRight or { X = 1, Y = 0, Z = 0 }
    local midX = o.X + (TetrisConfig.Board.Cols - 1) * step / 2  -- 盘面横向中心
    local zShow = o.Z + step * 5              -- 盘面上方两行处（Z 越大越高）
    if not self._diagLayoutSelfDone then
        self._diagLayoutSelfDone = true
    end
    -- 21 个预览方块不做旋转（按需求屏蔽），统一以 rot=1 原样展示，便于核对生成。
    local midRot = 1
    -- 统一方块池：21 个(每型3份)在盘面最上方排成 3 行 × 7 列（列=类型，行=第几份），供核对生成是否正确
    local pool = self.piecePool or {}
    for k, p in ipairs(pool) do
        if p and p.root then
            -- 每帧无条件重试附着（AttachToActor 幂等；根未 spawn 时静默失败，下帧再来）
            for i, child in ipairs(p.children or {}) do
                self:attachChildToRoot(child, p.root)
                local o2 = p.offsets[i]
                if o2 then
                    -- 子块相对偏移始终保持 rot=1 原始值；旋转完全由根 Actor 带动
                    -- （与下落 placeWholePieceV3 一致：只转根、子块跟随，避免重复旋转导致子块飞散）
                    local right = self.boardRight or { X = 1, Y = 0, Z = 0 }
                    -- 子块相对根偏移必须沿盘面 right（随 boardRight 旋转）；用世界 X 轴固定偏移会在盘面
                    -- 非世界轴(即 pawn 基准真实朝向)时错位，且无法跟随 ResolveOrigin 后续更新（时序问题）
                    local relLoc = Game:ConstructFVectorByLuaTable({ X = right.X * o2.dx * 100, Y = right.Y * o2.dx * 100, Z = o2.dz * 100 })
                    pcall(function() child:K2_SetActorRelativeLocation(relLoc) end)
                end
            end
            local col = (k - 1) % 7               -- 0..6：列 = 类型
            local row = math.floor((k - 1) / 7)   -- 0,1,2：行 = 第几份（活动/下一/Hold）
            local along = (col - 3) * gap         -- 沿 right 居中展开 7 列
            local x = o.X + right.X * along
            local y = o.Y + right.Y * along
            local z = zShow + row * gap           -- 3 行向上堆叠于盘面上方
            -- 根带旋转量传送：与下落 placeWholePieceV3 同源（makePieceRotator），确保预览旋转=下落旋转。
            pcall(function() p.root:K2_TeleportTo(cmVec({ X = x, Y = y, Z = z }), makePieceRotator(midRot)) end)
        end
    end
    -- 诊断（预览开始后等待足够帧数让附着完成，仅打印一次）：
    -- 逐子块输出「实际相对位置 vs 期望偏移」，定位哪一个子块错位
    if TetrisConfig.Debug and not self._showcaseDiagDone then
        self._showcaseDiagFrame = (self._showcaseDiagFrame or 0) + 1
        if self._showcaseDiagFrame >= 30 then   -- ~0.5 秒后执行，确保异步 spawn 已完成
            self._showcaseDiagDone = true
            for t = 1, 7 do
                local p = self.pieces[t]
                if p and p.root then
                    pcall(function()
                        local rloc = p.root:K2_GetActorLocation()
                        for i, o in ipairs(p.offsets) do
                            local c = p.children[i]
                            local wl = c and c:K2_GetActorLocation()
                            if rloc and wl then
                                local exX, exZ = o.dx * 100, o.dz * 100
                                local acX, acZ = wl.X - rloc.X, wl.Z - rloc.Z
                                local ok = math.abs(acX - exX) < 2 and math.abs(acZ - exZ) < 2
                                print(string.format(
                                    "[Tetris][Preview] type=%d 子#%d 期望相对=(%.0f,%.0f) 实际相对=(%.0f,%.0f) %s",
                                    t, i, exX, exZ, acX, acZ, ok and "OK" or "MISS!!"))
                            end
                        end
                    end)
                end
            end
        end
    end
end

-- 结束预览：收起全部 7 种模板到停车场，恢复正常活动方块渲染。
function TetrisRenderer:EndShowcase()
    if not self.previewing then return end
    self.previewing = false
    for t = 1, 7 do
        local p = self.pieces[t]
        if p then self:parkWholePieceV3(p) end
    end
    self.shownPiece = nil
    self.shownPieceType = nil
    print("[Tetris] 预览结束")
end

-- 下一个 / Hold 预览均采用「按需生成的静态方块」：仅在对应位置创建若干独立方块 Actor 作展示，
-- 不参与下落/旋转，类型变化时才重建，锚点变化时仅传送跟随。无需预建整体实例，初始化只保留 7 个活动方块。

-- 预览静态方块采用与盘面一致的「对象池复用」：归还即传送到隐藏停车场(hideLoc)，
-- 而非销毁——本文件不存在可靠的 DestroyActor，误用会导致旧方块残留世界、新方块进入时不回收。
function TetrisRenderer:AcquirePreviewBlock()
    self.previewBlockPool = self.previewBlockPool or {}
    local b = table.remove(self.previewBlockPool)
    if b then return b end
    local s = TetrisConfig.Render.BlockScale
    local scale = Game:ConstructFVectorByLuaTable({ X = s, Y = s, Z = s })
    return self:CreateOne(Game:ConstructFVectorByLuaTable(self.hideLoc), scale, self.refTop)
end

function TetrisRenderer:ReleasePreviewBlock(b)
    if not b then return end
    pcall(function() b:K2_TeleportTo(cmVec(self.hideLoc), self.rot) end)
    self.previewBlockPool = self.previewBlockPool or {}
    self.previewBlockPool[#self.previewBlockPool + 1] = b
end

-- 在 anchor 处为某型方块生成静态展示方块（按 shape 逐格放置，沿盘面 right 展开）。返回 actor 数组。
function TetrisRenderer:BuildPreviewBlocks(type, anchor)
    local shape = TetrisConfig.Pieces[type] and TetrisConfig.Pieces[type].shape
    if not shape then return nil end
    local r = TetrisConfig.Render
    local step = r.CellSize + r.CellGap
    local pr, pc = self:piecePivot(type)
    local right = self.boardRight or { X = 1, Y = 0, Z = 0 }
    local blocks = {}
    for rr = 1, #shape do
        for cc = 1, #shape do
            if shape[rr][cc] == 1 then
                local dx = (cc - pc) * step
                local dz = -((rr - pr) * step)
                local b = self:AcquirePreviewBlock()
                if b then
                    pcall(function() b:K2_TeleportTo(cmVec({ X = anchor.X + right.X * dx, Y = anchor.Y + right.Y * dx, Z = anchor.Z + dz }), self.rot) end)
                    blocks[#blocks + 1] = b
                end
            end
        end
    end
    return blocks
end

-- 把已生成的展示方块按新 anchor 重新排列（锚点/基准变化时跟随）。
function TetrisRenderer:PositionPreviewBlocks(blocks, type, anchor)
    if not blocks then return end
    local shape = TetrisConfig.Pieces[type] and TetrisConfig.Pieces[type].shape
    if not shape then return end
    local r = TetrisConfig.Render
    local step = r.CellSize + r.CellGap
    local pr, pc = self:piecePivot(type)
    local right = self.boardRight or { X = 1, Y = 0, Z = 0 }
    local i = 0
    for rr = 1, #shape do
        for cc = 1, #shape do
            if shape[rr][cc] == 1 then
                i = i + 1
                local b = blocks[i]
                if b then
                    local dx = (cc - pc) * step
                    local dz = -((rr - pr) * step)
                    pcall(function() b:K2_TeleportTo(cmVec({ X = anchor.X + right.X * dx, Y = anchor.Y + right.Y * dx, Z = anchor.Z + dz }), self.rot) end)
                end
            end
        end
    end
end

-- 回收展示方块数组：归还到预览对象池（传送到隐藏停车场），供下次复用。
function TetrisRenderer:ClearPreviewBlocks(blocks)
    if not blocks then return end
    for _, b in ipairs(blocks) do
        self:ReleasePreviewBlock(b)
    end
end

-- 下一个方块预览：游戏进行中在盘面指定侧显示 nextQueue[1]；用静态方块按需生成，仅展示。
function TetrisRenderer:UpdateNextPreview(board)
    if not TetrisConfig.Render.EnableNextPreview then return end
    if not board then return end
    -- 开局展示阶段不显示下一个方块
    if self.previewing then
        self:ClearPreviewBlocks(self.nextPreviewBlocks)
        self.nextPreviewBlocks = nil
        self.nextPreviewCurType = nil
        return
    end
    if not self.origin then return end
    local r = TetrisConfig.Render
    local step = r.CellSize + r.CellGap
    local o = self.origin
    local right = self.boardRight or { X = 1, Y = 0, Z = 0 }
    local cols = TetrisConfig.Board.Cols
    local rows = TetrisConfig.Board.Rows
    local side = (r.NextPreviewSide == "right") and 1 or -1  -- 1=盘面右侧, -1=盘面左侧
    local gapCells = (r.NextPreviewLeftCells and r.NextPreviewLeftCells > 0) and r.NextPreviewLeftCells or (cols + 3)
    local off = r.NextPreviewOffset or {}
    local sideTotal = gapCells + (off.right or 0)
    local anchor = {
        X = o.X + side * right.X * step * sideTotal,
        Y = o.Y + side * right.Y * step * sideTotal,
        Z = o.Z - step * (rows / 2) + step * (off.z or 0),
    }
    local nextTypes = board:getNextQueue()
    local showT = nextTypes and nextTypes[1]
    if not showT then
        self:ClearPreviewBlocks(self.nextPreviewBlocks)
        self.nextPreviewBlocks = nil
        self.nextPreviewCurType = nil
        return
    end
    -- 类型变化才重建静态方块；否则仅跟随锚点传送
    if self.nextPreviewCurType ~= showT or not self.nextPreviewBlocks then
        self:ClearPreviewBlocks(self.nextPreviewBlocks)
        self.nextPreviewBlocks = self:BuildPreviewBlocks(showT, anchor)
        self.nextPreviewCurType = showT
    else
        self:PositionPreviewBlocks(self.nextPreviewBlocks, showT, anchor)
    end
end

-- Hold 暂存预览：游戏进行中在盘面左侧显示 board.holdType；用静态方块按需生成，仅展示。
function TetrisRenderer:UpdateHoldPreview(board)
    if not TetrisConfig.Render.EnableHoldPreview then return end
    if not board then return end
    -- 开局展示阶段不显示 Hold
    if self.previewing then
        self:ClearPreviewBlocks(self.holdPreviewBlocks)
        self.holdPreviewBlocks = nil
        self.holdPreviewCurType = nil
        return
    end
    if not self.origin then return end
    local r = TetrisConfig.Render
    local step = r.CellSize + r.CellGap
    local o = self.origin
    local right = self.boardRight or { X = 1, Y = 0, Z = 0 }
    local cols = TetrisConfig.Board.Cols
    local rows = TetrisConfig.Board.Rows
    local side = (r.HoldPreviewSide == "right") and 1 or -1  -- 1=盘面右侧, -1=盘面左侧
    local gapCells = (r.HoldPreviewGapCells and r.HoldPreviewGapCells > 0) and r.HoldPreviewGapCells or (cols + 3)
    local off = r.HoldPreviewOffset or {}
    local sideTotal = gapCells + (off.right or 0)
    local anchor = {
        X = o.X + side * right.X * step * sideTotal,
        Y = o.Y + side * right.Y * step * sideTotal,
        Z = o.Z - step * (rows / 2) + step * (off.z or 0),
    }
    local holdT = board:getHoldType()
    if not holdT then
        self:ClearPreviewBlocks(self.holdPreviewBlocks)
        self.holdPreviewBlocks = nil
        self.holdPreviewCurType = nil
        return
    end
    -- 类型变化才重建静态方块；否则仅跟随锚点传送
    if self.holdPreviewCurType ~= holdT or not self.holdPreviewBlocks then
        self:ClearPreviewBlocks(self.holdPreviewBlocks)
        self.holdPreviewBlocks = self:BuildPreviewBlocks(holdT, anchor)
        self.holdPreviewCurType = holdT
    else
        self:PositionPreviewBlocks(self.holdPreviewBlocks, holdT, anchor)
    end
end

-- ---------------- 创建全部格子并隐藏 ----------------
function TetrisRenderer:Build(spawnPointKey)
    if self.built then return true end

    local cols = TetrisConfig.Board.Cols
    local rows = TetrisConfig.Board.Rows
    local s = TetrisConfig.Render.BlockScale
    self.origin = self:ResolveOrigin(spawnPointKey)
    self.spawnPointKey = spawnPointKey
    self.rot = makeZeroRotator()
    -- 隐藏停车场：隐藏的格子传送到此处（远离盘面、不入画，但保持可见状态，靠位置而非显隐控制）
    self.hideLoc = { X = self.origin.X, Y = self.origin.Y, Z = self.origin.Z - 200 }

    local scale = Game:ConstructFVectorByLuaTable({ X = s, Y = s, Z = s })
    local keyTop = TetrisConfig.Render.BlockAssetRefKey
    local keyBottom = TetrisConfig.Render.BlockAssetRefKeyBottom
    local candTop = collectRefCandidates(keyTop)
    local candBottom = collectRefCandidates(keyBottom)
    print(string.format("[Tetris] 资源引用候选: 上区=%d 下区=%d", #candTop, #candBottom))

    local loc0 = Game:ConstructFVectorByLuaTable(self.hideLoc)
    local mode, refTop, firstObj

    if TetrisConfig.Render.ForceActorMode then
        -- 强制使用 CreateActor（真实 Actor），绕过动态实例 ≈100 的池上限。
        -- 动态实例池上限会导致底行创建失败；Actor 模式实测可生成 200+ 个对象。
        -- CreateActor 需要 ActorPreset 类型的引用（前缀 46_ActorPreset_*），不能用 CreativeAsset 键。
        local actorKey = TetrisConfig.Render.BlockActorPresetKey
        local ref = (type(AssetRef) == "table") and AssetRef[actorKey] or nil
        if not ref then
            print("[Tetris][ERROR] Actor 预设引用为空，请确认 AssetRef[\"" .. tostring(actorKey)
                  .. "\"] 已注册并执行 update preset")
            return false
        end
        mode = "actor"
        refTop = ref
        self.refBottom = ref   -- Actor 模式无实例上限，单预设即可覆盖全盘
        local ok, obj = pcall(function()
            return CreativeGameAPI.CreateActor(ref, loc0, self.rot, scale, nil)
        end)
        if ok and obj then
            firstObj = obj
        else
            print("[Tetris][ERROR] 强制 Actor 模式首格创建失败: " .. tostring(obj))
            return false
        end
        print("[Tetris] 强制 Actor 模式（CreateActor，绕过动态实例池上限）")
    else
        -- 探测创建方式：用上区首格探一次即可（上下两区同为动态实例，mode 通用）
        mode, refTop, firstObj = self:ProbeCreator(candTop, loc0, scale)
        if not mode then return false end
        self.refBottom = pickRef(candBottom)
        if not self.refBottom then
            print("[Tetris][ERROR] 下区资源引用为空，请确认 AssetRef[\"" .. tostring(keyBottom)
                  .. "\"] 已注册并执行 update preset")
        end
    end
    self.mode = mode
    self.refTop = refTop

    -- 对象池：预建 rows*cols 个方块 Actor 停在停车场，运行时「取出/归还」，不再有 200 固定槽。
    self.occ = {}
    for row = 1, rows do
        self.occ[row] = {}
        for col = 1, cols do
            self.occ[row][col] = nil
        end
    end
    self.pool = {}
    -- 探测阶段已建好 firstObj，直接入池；再补足到 rows*cols 个。
    if firstObj then self.pool[#self.pool + 1] = firstObj end
    local ref = self.refTop
    for _ = 1, (rows * cols) - (firstObj and 1 or 0) do
        local obj = self:CreateOne(Game:ConstructFVectorByLuaTable(self.hideLoc), scale, ref)
        if obj then self.pool[#self.pool + 1] = obj end
    end

    -- 消行 parent-shift 用的临时根（EmptyActor）：把要下移的方块挂上去整体位移，移完拆父还原为独立 Actor。
    local rootRef = (type(AssetRef) == "table") and AssetRef[TetrisConfig.Render.PieceRootPresetKey] or nil
    if rootRef then
        self.shiftRoot = CreativeGameAPI.CreateActor(rootRef, Game:ConstructFVectorByLuaTable(self.hideLoc), self.rot, scale, nil)
    else
        print("[Tetris][WARN] 缺 PieceRootPresetKey，消行 parent-shift 不可用，回退逐格传送")
    end

    self.built = true
    print("[Tetris] 对象池创建完成: " .. #self.pool .. "/" .. (rows * cols)
          .. "  模式=" .. tostring(self.mode) .. "（静态方块=独立Actor，消行=parent-shift）")
    if TetrisConfig.Debug.PrintBoardBounds then
        self:PrintBounds()
    end
    self:BuildBorder()
    self:BuildActivePieces()
    return #self.pool > 0
end

-- ---------------- 生成盘面外边框 ----------------
-- 用 AssetRef[BorderAssetRefKey]（44_CreativeAsset_3400003，与方块同模型）在盘面的
-- 左（虚拟列 0）、右（虚拟列 Cols+1）、下（虚拟行 Rows+1）三侧各生成一排 1 格厚的外边框，
-- 常驻可见（不参与方块显隐）。顶部开放，供方块下落进入。
-- 三侧集合互不重叠，共 Rows + Rows + Cols 块。
function TetrisRenderer:BuildBorder()
    -- 幂等：已成功创建则跳过（Update 会在失败时逐帧重试本函数）
    if self.border and #self.border > 0 then return end
    self.borderSpecs = {}
    self.border = {}
    if not self.origin then
        print("[Tetris][WARN] 边框生成失败：盘面原点未初始化")
        return
    end
    -- 动态实例创建依赖 InstanceAPI；未注入时延后重试（不打印错误刷屏）
    if type(InstanceAPI) ~= "table" then
        print("[Tetris][WARN] InstanceAPI 未注入，边框延后重试")
        return
    end
    local cols, rows = TetrisConfig.Board.Cols, TetrisConfig.Board.Rows
    local r = TetrisConfig.Render
    local step = r.CellSize + r.CellGap
    local s = r.BlockScale
    local scale = Game:ConstructFVectorByLuaTable({ X = s, Y = s, Z = s })
    -- 外框用动态实例（InstanceAPI.CreateInstance，需 CreativeAsset 预设键）。
    -- 引用候选：AssetRef -> CreativeAsset -> 原始Key，逐一试（与 ProbeCreator 同策略）。
    local cands = collectRefCandidates(TetrisConfig.Render.BorderAssetRefKey)
    if #cands == 0 then
        print("[Tetris][WARN] 边框资源 \"" .. tostring(TetrisConfig.Render.BorderAssetRefKey) .. "\" 无可用引用，跳过边框生成")
        return
    end

    local o = self.origin
    -- 盘面右方向（随朝向旋转）：边框列偏移必须沿 right，否则盘面非世界轴时错位
    local right = self.boardRight or { X = 1, Y = 0, Z = 0 }
    local comboFailed = false

    -- 一次性探测：找出真正能创建实例的 (API, ref, rot) 组合（不同引擎/构建可用性不同）。
    -- 逐组合尝试并打印结果，命中后缓存复用（探针创建的实例直接用作首个边框格，不浪费）。
    local function resolveCombo(probeLoc)
        if self._borderCombo then return self._borderCombo end
        if comboFailed then return nil end
        local log = {}
        for _, api in ipairs({ "CreateInstance", "CreateGroupInstance" }) do
            local fn = InstanceAPI[api]
            if type(fn) == "function" then
                for _, c in ipairs(cands) do
                    local rots = { self.rot, nil }   -- 下标遍历，确保 nil 也被试到
                    for ri = 1, 2 do
                        local rot = rots[ri]
                        local ok, obj = pcall(function() return fn(c.val, probeLoc, rot, scale) end)
                        log[#log + 1] = string.format("%s/%s/%s->%s",
                            api, c.name, ri == 1 and "rot" or "nil", tostring(obj))
                        if ok and obj then
                            if not self._borderProbeLogged then
                                self._borderProbeLogged = true
                                print("[Tetris][BorderProbe] 命中 -> " .. log[#log]
                                      .. " ; 全部: " .. table.concat(log, " | "))
                            end
                            self._borderCombo = { api = api, ref = c.val, rot = rot, refName = c.name }
                            self._borderProbeObj = obj   -- 探针实例复用为首个边框格
                            return self._borderCombo
                        end
                    end
                end
            else
                log[#log + 1] = api .. "=未实现"
            end
        end
        comboFailed = true
        if not self._borderProbeLogged then
            self._borderProbeLogged = true
            print("[Tetris][BorderProbe] 全部失败: " .. table.concat(log, " | "))
        end
        return nil
    end

    -- 创建单个边框格子（实例化）：dx=沿盘面右方向偏移（米，可为负）；dz=向下偏移（米，世界 -Z）
    local function makeBorder(dx, dz)
        local loc = Game:ConstructFVectorByLuaTable({
            X = o.X + right.X * dx,
            Y = o.Y + right.Y * dx,
            Z = o.Z - dz,
        })
        local combo = resolveCombo(loc)
        if not combo then return end
        local obj
        if self._borderProbeObj then
            obj = self._borderProbeObj           -- 复用作第一个格子
            self._borderProbeObj = nil
        else
            local ok, o2 = pcall(function() return InstanceAPI[combo.api](combo.ref, loc, combo.rot, scale) end)
            obj = ok and o2 or nil
        end
        if obj then
            pcall(function()
                if InstanceAPI.ToggleInstanceVisible then InstanceAPI.ToggleInstanceVisible(obj, true) end
            end)
            self.border[#self.border + 1] = obj
            self.borderSpecs[#self.borderSpecs + 1] = { dx = dx, dz = dz }
        else
            print("[Tetris][WARN] 边框格子创建失败 @(dx=" .. tostring(dx) .. ",dz=" .. tostring(dz) .. ")")
        end
    end

    -- 左、右两侧：每行一块
    for row = 1, rows do
        local dz = (row - 1) * step
        makeBorder((0 - 1) * step, dz)          -- 左（虚拟列 0）
        makeBorder((cols + 1 - 1) * step, dz)   -- 右（虚拟列 Cols+1）
    end
    -- 下侧：每列一块（虚拟行 Rows+1）
    for col = 1, cols do
        makeBorder((col - 1) * step, (rows + 1 - 1) * step)
    end

    print("[Tetris] 边框格子创建完成: " .. #self.border .. "/" .. (rows + rows + cols)
          .. "（左/右/下三侧，常驻可见，实例化）")
end

-- 边框随 boardRight 重定位：Build 时 boardRight 可能尚未确定（出生点装置未注入，走回退默认），
-- 出生点装置注入后 SetupFixedCamera 会重新 ResolveOrigin 更新 boardRight，并调本函数用最新
-- boardRight/origin 重摆所有边框格，使其与 InitialLayout 静态格子保持同一基准（修复时序错位）。
function TetrisRenderer:ReanchorBorder()
    if not self.border or not self.borderSpecs then return end
    local right = self.boardRight or { X = 1, Y = 0, Z = 0 }
    local o = self.origin
    if not o then return end
    -- self.rot 可能为 nil（makeZeroRotator 失败）：K2_TeleportTo 的 DestRotation 不能为 nil，否则静默失败。
    local rot = self.rot or makeZeroRotator()
    for i, a in ipairs(self.border) do
        local s = self.borderSpecs[i]
        if a and s then
            local loc = Game:ConstructFVectorByLuaTable({ X = o.X + right.X * s.dx, Y = o.Y + right.Y * s.dx, Z = o.Z - s.dz })
            if type(a) == "number" then
                -- 动态实例（CreateInstance 返回实例句柄）：必须用 InstanceAPI 移动，不能 K2_TeleportTo
                pcall(function() InstanceAPI.SetInstanceLocation(a, loc) end)
                if rot then pcall(function() InstanceAPI.SetInstanceRotation(a, rot) end) end
            else
                pcall(function() a:K2_TeleportTo(loc, rot) end)
            end
        end
    end
    -- 一次性诊断：确认边框确实被重摆、摆到了哪（排查“外框看不到”）。
    if not self._borderAnchorLogged and #self.border > 0 and self.borderSpecs[1] then
        self._borderAnchorLogged = true
        local s1 = self.borderSpecs[1]
        print(string.format(
            "[Tetris] 边框重摆: n=%d 首格=(%.2f,%.2f,%.2f) origin=(%.2f,%.2f,%.2f) right=(%.2f,%.2f)",
            #self.border, o.X + right.X * s1.dx, o.Y + right.Y * s1.dx, o.Z - s1.dz, o.X, o.Y, o.Z, right.X, right.Y))
    end
end

-- 静态层随 boardRight 重摆：Build 时盘面前景基准（出生点装置/玩家）可能尚未就绪，
-- 已落定静态格在那时的旧 boardRight 下被 placeActor 烘焙好位置；之后 Update 的签名脏检查
-- 只重排“变化”的格子、不重新传送“已存在”的格子，导致静态格停留在旧基准。
-- 出生点装置注入后 SetupFixedCamera 重新 ResolveOrigin 更新 boardRight，此处用最新
-- origin/boardRight 把全部已落定格子重传一次，使其与边框、下落块保持同一基准（修复时序错位）。
function TetrisRenderer:ReanchorBoard()
    if not self.occ then return end
    local rows = TetrisConfig.Board.Rows
    local cols = TetrisConfig.Board.Cols
    for r = 1, rows do
        if self.occ[r] then
            for c = 1, cols do
                local a = self.occ[r][c]
                if a then
                    self:placeActor(a, r, c)  -- cellLocation 读实时 origin/boardRight
                end
            end
        end
    end
end

-- 调试：逐行统计 已创建 / 当前显示 / 期望显示 的格子数。
-- 用于区分两类问题：
--   1) created < 10（整行缺格）-> 创建阶段就失败了（资源/距离/数量上限），与显隐无关；
--   2) created=10 但 shown=0 而 want>0 -> 生成了却被错误隐藏。
function TetrisRenderer:DumpCells(want)
    local rows = TetrisConfig.Board.Rows
    local cols = TetrisConfig.Board.Cols
    print("[Tetris][DUMP] 逐行格子状态  occ(占用Actor) / want")
    for r = 1, rows do
        local occN, w = 0, 0
        for c = 1, cols do
            if self.occ[r] and self.occ[r][c] then occN = occN + 1 end
            if want and want[r] and want[r][c] then w = w + 1 end
        end
        print(string.format("  row %2d: occ=%2d want=%2d%s",
            r, occN, w,
            occN ~= w and "  <-- 占用与期望不一致!" or ""))
    end
    print(string.format("[Tetris][DUMP] 模式=%s 池余=%d/%d 已建=%s frame=%d",
        tostring(self.mode), #(self.pool or {}), rows * cols, tostring(self.built), self.frame))
end

-- ---------------- 刷新 ----------------
-- SetCell（逐格显隐）已被对象池模型取代：静态方块是「独立 Actor + occ 占用表」，
-- 锁定/消行时由 ReconcileBoard / ReconcileClear 直接取还池并摆放，不再逐格下发显隐。

-- 把期望显隐矩阵打印成字符画，便于和屏幕实际画面对照
function TetrisRenderer:PrintGrid(want)
    local rows = TetrisConfig.Board.Rows
    local cols = TetrisConfig.Board.Cols
    print("[Tetris] 期望显隐（# 应显示 / . 应隐藏），第1行=盘面顶部")
    for r = 1, rows do
        local line = ""
        for c = 1, cols do
            line = line .. (want[r][c] and "#" or ".")
        end
        print("  " .. string.format("%2d|", r) .. line)
    end
end

-- 棋盘静态层签名：仅统计已落定（grid!=0）的格子坐标和，用于检测锁定/消行引起的变化。
-- 返回相同值表示静态层无变化，可完全跳过棋盘刷新（零流量）。
function TetrisRenderer:boardSignature(board)
    local rows = TetrisConfig.Board.Rows
    local cols = TetrisConfig.Board.Cols
    local s = 0
    for r = 1, rows do
        for c = 1, cols do
            if board:getCell(r, c) ~= 0 then
                s = s + r * 73856093 + c * 19349663
            end
        end
    end
    return s
end

-- 朴素重排：与数据层逐格 diff，缺失的从对象池取 Actor 摆放，多余的归还池。
-- 用于「普通锁定（无消行）」与「垃圾行上移」等无需 grouped 位移的场景。
function TetrisRenderer:ReconcileBoard(board)
    local rows = TetrisConfig.Board.Rows
    local cols = TetrisConfig.Board.Cols
    for r = 1, rows do
        for c = 1, cols do
            local filled = board:getCell(r, c) ~= 0
            local a = self.occ[r] and self.occ[r][c]
            if filled and not a then
                local na = self:AcquireActor()
                if na then
                    self:placeActor(na, r, c)
                    self.occ[r][c] = na
                end
            elseif not filled and a then
                self:ReleaseActor(a)
                self.occ[r][c] = nil
            end
        end
    end
end

-- 消行重排（两阶段）：
--   阶段A（立即/本帧）：被消行的方块直接归还对象池（立即消失）；本帧锁定的新增格立即摆放；
--                 其余需要下落的块按下移行数 delta 分组，延迟 ClearDelay 秒后再整体下移（阶段B）。
--   阶段B（延迟）：用现存 parent-shift 方式把下移块整体下移填补空缺，移完拆父还原独立 Actor。
-- 这样视觉上：被消行先瞬间清空 → 停顿 ClearDelay 秒 → 上方方块再整块落下（而非原版一次性同步完成）。
function TetrisRenderer:ReconcileClear(board, clearedRows)
    if TetrisConfig.Debug then
        print(string.format("[Tetris][DBG] ReconcileClear 进入: 行数=%d _clearFallPending=%s -> %s",
            #(clearedRows or {}), tostring(self._clearFallPending ~= nil),
            self._clearFallPending and "先同步flush上一次下落(立即)" or "无pending"))
    end
    -- 若上一次消行的下落尚未执行（0.5s 窗口内又发生锁定），先同步 flush 上一次，
    -- 保证 occ 与数据层一致，避免叠加错位。
    if self._clearFallPending then self:ReconcileClearFall() end

    local rows = TetrisConfig.Board.Rows
    local cols = TetrisConfig.Board.Cols
    local delay = (TetrisConfig.Clear and TetrisConfig.Clear.ClearDelay) or 0.5

    -- 1) 快照旧占用表；被消行的方块直接归还池（立即消失，不等延迟）
    local oldOcc = self.occ
    self.occ = {}
    for r = 1, rows do
        self.occ[r] = {}
        for c = 1, cols do self.occ[r][c] = nil end
    end
    local clearedSet = {}
    for _, cr in ipairs(clearedRows) do clearedSet[cr] = true end
    for _, cr in ipairs(clearedRows) do
        for c = 1, cols do
            local a = oldOcc[cr] and oldOcc[cr][c]
            if a then self:ReleaseActor(a) end
        end
        self:PlayClearEffectAt(cr, 9)   -- 在待消除格位置播放特效
    end

    -- 2) 计算每个最终格的来源旧行：clearLines 从底向上紧凑堆叠保留行，被消行上方的行整体下落填补。
    --    映射：从底往上数保留行，第 m 个保留行落到新行号 rows-m+1（m = rows-r+1），oldRow = kept[m]。
    --    delta = r - oldRow；delta>0 的方块走 parent-shift；delta==0（未动）保留原位；无对应旧 Actor 的=本次锁定的新增格。
    local groups = {}        -- groups[delta] = { {a, nr, c}, ... }
    local newlyLocked = {}   -- { {r, c} }
    local kept = {}          -- kept[m] = 原行号（从底往上第 m 个保留行）
    for oldR = rows, 1, -1 do
        if not clearedSet[oldR] then kept[#kept + 1] = oldR end
    end
    for r = 1, rows do
        for c = 1, cols do
            if board:getCell(r, c) ~= 0 then
                local m = rows - r + 1
                local oldRow = kept[m]
                local delta = r - oldRow
                local a = oldOcc[oldRow] and oldOcc[oldRow][c]
                if a then
                    if delta > 0 then
                        groups[delta] = groups[delta] or {}
                        groups[delta][#groups[delta] + 1] = { a = a, nr = r, c = c }
                    else
                        self.occ[r][c] = a   -- 静止方块：保持原位置
                    end
                else
                    newlyLocked[#newlyLocked + 1] = { r = r, c = c }
                end
            end
        end
    end

    -- 3) 本帧锁定的新增格：立即从池取 Actor 静态摆放（与下落解耦，无需等延迟）
    for _, nl in ipairs(newlyLocked) do
        local a = self:AcquireActor()
        if a then
            self:placeActor(a, nl.r, nl.c)
            self.occ[nl.r][nl.c] = a
        end
    end

    -- 4) 需要下落的块：延迟 ClearDelay 秒后整体下移（现存 parent-shift 方式，见 ReconcileClearFall）
    local groupCount = 0
    for _ in pairs(groups) do groupCount = groupCount + 1 end
    if groupCount > 0 then
        self._clearFallPending = { groups = groups }
        if TetrisConfig.Debug then
            print(string.format("[Tetris][DBG] 阶段B调度: groupCount=%d ownerHasTimer=%s delay=%.2f -> %s",
                groupCount, tostring(self.owner and self.owner.AddTimerOnce ~= nil), delay,
                (self.owner and self.owner.AddTimerOnce) and "定时器延迟" or "SYNC同步兜底"))
        end
        if self.owner and self.owner.AddTimerOnce then
            self.owner:AddTimerOnce(delay, function()
                if self and self.ReconcileClearFall then self:ReconcileClearFall() end
            end)
        else
            self:ReconcileClearFall()   -- 无定时器能力：同步兜底，行为回退到原版
        end
    end

    if TetrisConfig.Debug then
        print(string.format(
            "[Tetris][Clear] 阶段A 回收消%d行（新增格=%d 待下落组=%d 池余=%d 延迟=%.2fs）",
            #clearedRows, #newlyLocked, groupCount, #self.pool, delay))
    end
end

-- 阶段B：执行之前记录的 parent-shift 下落（被消行上方的块整体下移填补空缺）。
-- 在 ClearDelay 秒后由定时器触发；若期间又发生锁定，ReconcileClear 开头会先同步 flush 本函数。
function TetrisRenderer:ReconcileClearFall()
    local pending = self._clearFallPending
    self._clearFallPending = nil
    if TetrisConfig.Debug then
        print(string.format("[Tetris][DBG] 阶段B触发: ReconcileClearFall 执行 pending=%s", tostring(pending ~= nil)))
    end
    if not pending then return end
    local groups = pending.groups
    local step = TetrisConfig.Render.CellSize + TetrisConfig.Render.CellGap

    if self.shiftRoot then
        for delta, list in pairs(groups) do
            -- 根先归位到停车场，确保子 Actor 以 KeepWorld 挂上时相对偏移正确
            pcall(function() self.shiftRoot:K2_TeleportTo(cmVec(self.hideLoc), self.rot) end)
            for _, it in ipairs(list) do
                self:attachChildToRoot(it.a, self.shiftRoot)
            end
            -- 移动根：下移 delta*step（Z 减小）
            pcall(function()
                self.shiftRoot:K2_TeleportTo(
                    cmVec({ X = self.hideLoc.X, Y = self.hideLoc.Y, Z = self.hideLoc.Z - delta * step }),
                    self.rot)
            end)
            -- 拆父还原（KeepWorld），写回占用表
            for _, it in ipairs(list) do
                local okDet = pcall(function() it.a:K2_DetachFromActor(1, 1, 1) end)
                if not okDet then
                    self:placeActor(it.a, it.nr, it.c)   -- 兜底：直接设到最终格
                end
                self.occ[it.nr][it.c] = it.a
            end
            -- 根归位（已拆父的子 Actor 不受影响）
            pcall(function() self.shiftRoot:K2_TeleportTo(cmVec(self.hideLoc), self.rot) end)
        end
    else
        -- 无 shiftRoot：退化为逐格传送
        for _, list in pairs(groups) do
            for _, it in ipairs(list) do
                self:placeActor(it.a, it.nr, it.c)
                self.occ[it.nr][it.c] = it.a
            end
        end
    end

    if TetrisConfig.Debug then
        local n = 0
        for _ in pairs(groups) do n = n + 1 end
        print(string.format("[Tetris][Clear] 阶段B 下落完成（动态组=%d 池余=%d）", n, #self.pool))
    end
end

-- 按数据层刷新：
--   1) 棋盘静态层（已落定方块）只在签名变化时全量同步（锁定/消行），平时零流量；
--   2) 活动方块走整体模式，只传送根 Actor（1 次/帧），不再逐格下发。
function TetrisRenderer:Update(board)
    if not self.built then return end
    self.frame = self.frame + 1

    -- 预览阶段：每帧重试摆出 7 种方块（覆盖根 Actor 异步 spawn 未就绪、首帧附着失败的情形）
    if self.previewing then
        self:LayoutShowcasePieces()
    end

    -- 对象池 spawn 就绪判定：CreateActor 是异步的，约 1~2 帧才真正生成；
    -- 首个实质落定发生在重力锁定之后（远大于此窗口），故用保守帧数门槛即可。
    -- 未就绪前绝不摆静态方块，否则 K2_TeleportTo 被静默丢弃 → 方块卡在停车场。
    if not self.poolReady and self.frame >= (TetrisConfig.Render.PoolReadyFrames or 2) then
        self.poolReady = true
    end

    -- 分帧补齐 21 个整体实例（BuildWholePiecePool 起的异步构建），未完成前逐帧建少量，避免初始化卡顿。
    if self._poolBuild then self:ProcessPoolBuild() end

    -- 启动前预热：逐帧把所有 7 种整体实例附着并就绪；全部 _everReady 后才允许渲染活动块。
    -- CreateActor 异步、首帧附着可能失败，故每帧幂等重试，直到实例真正建好（通常几帧内完成）。
    self:PrimeAllPieces()

    -- 边框延迟创建：Build 时 InstanceAPI 可能未注入或实例创建暂时失败，重试直到成功（上限若干帧）。
    -- 每 5 帧才真正尝试一次（探测开销较大）；成功后强制重摆若干帧，确保对齐当前基准。
    if (not self.border or #self.border == 0) and (self._borderRetry or 0) < 30 then
        self._borderRetry = (self._borderRetry or 0) + 1
        if ((self._borderRetry - 1) % 5) == 0 then
            self:BuildBorder()
        end
        if self.border and #self.border > 0 then
            self._basisAnchorFrames = 40
        end
    end

    -- 基准一致性自愈：ResolveOrigin 可能在 Build 之后才拿到出生点装置（origin/boardRight 变化），
    -- 而边框/静态格的 Actor 由异步 CreateActor 生成——单次 teleport 若早于 spawn 会被静默丢弃，
    -- 导致边框停留在旧基准（朝向翻转后会跑出视野，表现为“外框看不到”）。故检测到基准变化后，
    -- 在随后若干帧内逐帧幂等重摆边框与已落定静态格，覆盖异步 spawn 窗口并始终对齐当前基准。
    if self.origin and self.boardRight then
        local basisSig = string.format("%.3f,%.3f,%.3f|%.3f,%.3f,%.3f",
            self.origin.X, self.origin.Y, self.origin.Z,
            self.boardRight.X, self.boardRight.Y, self.boardRight.Z)
        if basisSig ~= self._basisSig then
            self._basisSig = basisSig
            self._basisAnchorFrames = 40   -- 覆盖异步 spawn 所需帧数
        end
        if (self._basisAnchorFrames or 0) > 0 then
            self._basisAnchorFrames = self._basisAnchorFrames - 1
            self:ReanchorBorder()
            self:ReanchorBoard()
        end
    end

    local rows = TetrisConfig.Board.Rows
    local cols = TetrisConfig.Board.Cols

    -- 提交刚锁定的方块为静态块（按锁定前行号摆位）：必须在消行重排之前完成，
    -- 使其进入 occ 成为“旧块”；若位于被消行上方，ReconcileClear 的 delta 计算会把它归入
    -- groups 参与延迟下落。活动块整体 actor 由随后的 RenderActivePiece 回收（先放置后回收，无闪烁）。
    if self.poolReady then
        local locked = board:consumeLockedCells()
        if locked then
            for _, lc in ipairs(locked) do
                local a = self.occ[lc.row] and self.occ[lc.row][lc.col]
                if not a then
                    a = self:AcquireActor()
                    if a then
                        self:placeActor(a, lc.row, lc.col)
                        self.occ[lc.row] = self.occ[lc.row] or {}
                        self.occ[lc.row][lc.col] = a
                    end
                end
            end
        end
    end

    -- 静态层：仅在盘面数据变化（锁定/消行）时重排；且仅在对象池就绪后
    if self.poolReady then
        local sig = self:boardSignature(board)
        if sig ~= self.lastBoardSig then
            local cleared = board:consumeClearedRows()
            local garbageMoved = board:consumedGarbageMoved()
            if TetrisConfig.Debug then
                print(string.format(
                    "[Tetris][DBG] Update重排: sig变化 cleared=%s garbageMoved=%s 等待下落中=%s UseParentShift=%s -> %s",
                    tostring(cleared and #cleared or 0), tostring(garbageMoved),
                    tostring(self._clearFallPending ~= nil), tostring(TetrisConfig.Render.UseParentShiftOnClear),
                    (cleared and #cleared > 0 and not garbageMoved and TetrisConfig.Render.UseParentShiftOnClear) and "ReconcileClear" or "ReconcileBoard"))
            end
            if cleared and #cleared > 0 and not garbageMoved and TetrisConfig.Render.UseParentShiftOnClear then
                self:ReconcileClear(board, cleared)
            else
                self:ReconcileBoard(board)
            end
            self.lastBoardSig = sig
        else
            if TetrisConfig.Debug and self._clearFallPending then
                print(string.format("[Tetris][DBG] Update: 处于0.5s等待窗口，本次 sig 未变(active piece 未动) pendingFall=%s",
                    tostring(self._clearFallPending ~= nil)))
            end
        end
    end

    -- 活动方块整体层（位移/旋转只传根）
    self:RenderActivePiece(board)

    -- 下一个方块预览（盘面右侧）
    self:UpdateNextPreview(board)

    -- Hold 暂存方块预览（盘面左侧）
    self:UpdateHoldPreview(board)

    if TetrisConfig.Debug.PrintGrid then
        local want = {}
        for r = 1, rows do
            want[r] = {}
            for c = 1, cols do
                want[r][c] = (board:getCell(r, c) ~= 0)
            end
        end
        self:PrintGrid(want)
    end
    if TetrisConfig.Debug.DumpCellStatus and (self.frame % 30 == 0) then
        local want = {}
        for r = 1, rows do
            want[r] = {}
            for c = 1, cols do
                want[r][c] = (board:getCell(r, c) ~= 0)
            end
        end
        self:DumpCells(want)
    end
end

function TetrisRenderer:Clear()
    if not self.built then return end
    -- 棋盘静态层：所有占用 Actor 归还对象池
    if self.occ then
        for r = 1, TetrisConfig.Board.Rows do
            if self.occ[r] then
                for c = 1, TetrisConfig.Board.Cols do
                    local a = self.occ[r][c]
                    if a then self:ReleaseActor(a) end
                    self.occ[r][c] = nil
                end
            end
        end
    end
    -- 活动方块整体层归位
    if self.shownPieceType and self.pieces[self.shownPieceType] then
        local p = self.pieces[self.shownPieceType]
        if self.wholePieceAttach then
            self:parkWholePieceV3(p)
        elseif self.wholePieceV2 then
            self:parkWholePieceV2(p)
        else
            self:parkPieceChildren(p)
        end
    end
    self.shownPieceType = nil
    self.lastBoardSig = nil
    self._clearFallPending = nil   -- 取消残留的消行延迟下落（定时器触发时不再执行）
end

return TetrisRenderer
