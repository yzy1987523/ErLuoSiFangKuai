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

-- 从单元 Actor 取出可用于换色的 StaticMeshComponent（或本身支持 SetStaticMesh 的封装 Actor）。
-- 与 PuyoRenderer 同策略：多策略探测并缓存结果（按 actor 弱引用），避免每帧重复探测。
-- 引擎无运行时改材质 API，故换色只能走 SetStaticMesh（已验证可用；不支持时 pcall 兜底保持单色）。
local function getMeshComp(self, actor)
    if not actor then return nil end
    if self._compCache == nil then self._compCache = setmetatable({}, { __mode = "k" }) end
    local cached = self._compCache[actor]
    if cached ~= nil then return cached or nil end   -- 缓存可能为 false（未找到）
    local comp
    -- 1) RootComponent 若为 StaticMeshComponent
    local ok, rc = pcall(function() return actor.RootComponent end)
    if ok and rc and type(rc.SetStaticMesh) == "function" then comp = rc end
    -- 2) 按类名取组件
    if not comp then
        for _, cls in ipairs({ "StaticMeshComponent", "WoWStaticMeshComponentBase", "WoWCustomStaticMeshComponentBase" }) do
            local ok2, c = pcall(function() return actor:GetComponentByClass(cls) end)
            if ok2 and c and type(c.SetStaticMesh) == "function" then comp = c; break end
        end
    end
    -- 3) 按组件名取
    if not comp then
        for _, nm in ipairs({ "StaticMesh", "StaticMeshComponent", "Mesh", "Cube" }) do
            local ok3, c = pcall(function() return actor:GetComponentByName(nm) end)
            if ok3 and c and type(c.SetStaticMesh) == "function" then comp = c; break end
        end
    end
    -- 4) 兜底：actor 自身直接转发了 SetStaticMesh（部分封装 Actor）
    if not comp and type(actor.SetStaticMesh) == "function" then comp = actor end
    self._compCache[actor] = comp or false
    if not comp and not self._meshApiWarned then
        self._meshApiWarned = true
        print("[Tetris][WARN] 无法取得 StaticMeshComponent，换色将失败（保持单色）")
    end
    return comp
end

-- 方块旋转绕“盘面法线(forward)”旋转（而非固定的世界 Y 轴）。
-- 注意：盘面偏航必须按「每个棋盘实例」取（self.boardYaw），绝不能写成模块级全局——
-- 否则多盘时后初始化的一方会覆盖前者的 yaw，导致另一盘的方块绕错轴旋转（表现为旋转/落地方向相反）。


local TetrisRenderer = {}
TetrisRenderer.__index = TetrisRenderer

function TetrisRenderer:new(owner, index)
    local o = setmetatable({}, TetrisRenderer)
    o.owner = owner  -- WoWObject（GameMain 子类），用于 AddTimerOnce 调度消行延迟下落
    o.boardIndex = (type(index) == "number") and index or 0  -- 盘面序号（供背向翻转判断）
    o.cells = {}    -- cells[row][col] = 实例/Actor 对象
    o.actors = {}   -- actors[row][col] = 底层 Actor（若可解析），用于可靠隐藏
    o.shown = {}    -- shown[row][col] = bool，当前显隐状态（脏检查用）
    o.border = {}   -- border[] = 边框格子对象（左/右/下三侧静态装饰，常驻可见）
    o._borderDisabled = false   -- 边框被配置关闭(BorderEnabled=false)时置 true，视为已完成
    o.pieces = {}   -- pieces[type] = 见 BuildActivePiecesV1/V2，整体活动方块
    o.shownPieceType = nil  -- 当前显示中的活动方块类型（整体模式用）
    o.wholePieceV2 = nil    -- true=方案2(根+子组件)可用；false/nil=回退方案1(4 Actor)
    o.lastBoardSig = nil   -- 棋盘静态层签名，用于检测锁定/消行以触发全量同步
    o.built = false
    o.poolReady = false  -- 对象池 spawn 就绪后才摆静态方块（CreateActor 异步，过早设置会被丢弃/卡停车场）
    o.mode = nil    -- "instance" | "actor"
    o.ref = nil
    o.rot = nil
    o.boardForward = nil  -- 装置→盘心方向（视线前向），背景墙定位用
    o._wallBuilt = false  -- 远景背景墙是否已生成
    o._wallActors = nil   -- 背景墙块对象列表（重建前清场）
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
        self.boardForward = { X = ffx, Y = ffy, Z = 0 }  -- 装置→盘心方向（视线前向）
        self.boardYaw = frameYaw * 180 / math.pi
        if type(FRotator) == "table" and FRotator.MakeFromEuler then
            self.rot = FRotator.MakeFromEuler(Game:ConstructFVectorByLuaTable({ X = 0, Y = 0, Z = self.boardYaw }))
        end
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
function TetrisRenderer:makePieceRotator(rot)
    local sign = TetrisConfig.Render.PieceSpinSign or 1
    local alpha = math.rad(self.boardYaw or 0)        -- 盘面偏航(弧度)，按实例取（双盘各自正确）
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
            return a.mode, a.ref, obj
        end
    end

    print("[Tetris][ERROR] 所有创建方案均失败，请确认预设已在编辑器注册")
    return nil, nil, nil
end

function TetrisRenderer:CreateOne(loc, scale, ref, rotOverride)
    local ok, obj = pcall(function()
        local rot = rotOverride or self.rot
        if self.mode == "instance" then
            return InstanceAPI.CreateInstance(ref, loc, rot, scale)
        else
            return CreativeGameAPI.CreateActor(ref, loc, rot, scale, nil)
        end
    end)
    if ok then return obj end
    if not self.createFailLogged then
        self.createFailLogged = true
        print("[Tetris][WARN] 创建失败: " .. tostring(obj))
    end
    return nil
end

-- ---------------- 远景背景墙 ----------------
-- 复用盘面基底：墙心 = 盘心 + 视线前向 * DistanceX；4 列沿 right、3 行沿 +Z；同向偏航、放大 ScaleN。
function TetrisRenderer:BuildBackgroundWall()
    local cfg = TetrisConfig.BackgroundWall
    if not (cfg and cfg.Enabled) then return end
    if not self.boardCenter or not self.boardForward or not self.boardRight
       or not self.rot or not self.mode then
        print("[Tetris][Wall][WARN] 盘面基底未就绪，暂缓背景墙")
        return
    end
    -- 重建前先清掉旧的（应对重新 ResolveOrigin 重摆）
    if self._wallActors then
        for _, a in ipairs(self._wallActors) do
            pcall(function() if a and a.K2_DestroyActor then a:K2_DestroyActor() end end)
        end
    end
    self._wallActors = {}
    local keys = cfg.BlockKeys or {}
    if #keys == 0 then
        print("[Tetris][Wall][WARN] BlockKeys 为空，跳过远景背景墙（请在 TetrisConfig.BackgroundWall.BlockKeys 填入模型资源键）")
        return
    end
    local N = (type(cfg.ScaleN) == "number") and cfg.ScaleN or 1
    local base = (type(cfg.BlockBaseSize) == "number") and cfg.BlockBaseSize or 1
    local gap = (type(cfg.BlockGap) == "number") and cfg.BlockGap or 0
    local pitch = base * N + gap
    local X = (type(cfg.DistanceX) == "number") and cfg.DistanceX or 40
    local cols = cfg.Cols or 4
    local rows = cfg.Rows or 3
    local wc = {
        X = self.boardCenter.X + self.boardForward.X * X,
        Y = self.boardCenter.Y + self.boardForward.Y * X,
        Z = self.boardCenter.Z,
    }
    local scaleVec = Game:ConstructFVectorByLuaTable({ X = N, Y = N, Z = N })
    local n = 0
    for c = 0, cols - 1 do
        for r = 0, rows - 1 do
            local offR = (c - (cols - 1) / 2) * pitch
            local offU = (r - (rows - 1) / 2) * pitch
            local pos = {
                X = wc.X + self.boardRight.X * offR,
                Y = wc.Y + self.boardRight.Y * offR,
                Z = wc.Z + offU,
            }
            local key = keys[((r * cols + c) % #keys) + 1]
            local ref = (type(AssetRef) == "table" and AssetRef[key])
                     or (type(CreativeAsset) == "table" and CreativeAsset[key])
            if ref then
                local ok, obj = pcall(function()
                    return self:CreateOne(Game:ConstructFVectorByLuaTable(pos), scaleVec, ref)
                end)
                if ok and obj then
                    self._wallActors[#self._wallActors + 1] = obj
                    n = n + 1
                end
            else
                print("[Tetris][Wall][WARN] 资源键无引用: " .. tostring(key))
            end
        end
    end
    print(string.format("[Tetris] 远景背景墙生成 %d/%d 块 (X=%.1f N=%.1f pitch=%.2f)",
        n, cols * rows, X, N, pitch))
end

-- ---------------- 盘面背后 3D UI 挂件（WidgetComponent Actor） ----------------
-- 在「盘面背后」各生成 1 个带 WidgetComponent 的 Actor（双盘各一，由各自 renderer 调用）。
-- 定位：挂件位置 = 盘心 + 视线前向(boardForward) * DistanceBehindM（与背景墙同源，即盘面背后）；
--       旋转：默认与盘面同向（3D UI 正面朝该盘玩家）；若本盘 index 在 FlipBoardIndices 中，
--       则绕竖直轴 +180°（背对玩家，给“对面盘”用，避免两边都朝向观察方）。
-- 幂等：已生成则跳过；重建（ReanchorBoard 重摆）时重定位到新基底。
function TetrisRenderer:BuildBehindBoardWidget()
    local cfg = TetrisConfig.BehindBoardWidget
    if not (cfg and cfg.Enabled) then return end
    if not self.boardCenter or not self.boardForward or not self.boardRight then
        if not self._widgetBaseLogged then
            self._widgetBaseLogged = true
            print(string.format("[Tetris][Widget][WARN] 盘面基底未就绪(首次): built=%s mode=%s hasCenter=%s hasFwd=%s hasRight=%s",
                tostring(self.built), tostring(self.mode),
                tostring(not not self.boardCenter), tostring(not not self.boardForward), tostring(not not self.boardRight)))
        end
        return
    end
    if self._behindWidgetActor then
        -- 已生成：交给 ReanchorBoard 重定位，这里不必重复创建
        return
    end
    local ref = (type(AssetRef) == "table" and AssetRef[cfg.PresetKey])
             or (type(CreativeAsset) == "table" and CreativeAsset[cfg.PresetKey])
    if not ref then
        if not self._widgetRefLogged then
            self._widgetRefLogged = true
            print(string.format("[Tetris][Widget][WARN] 资源键无引用(首次): %s | AssetRef表=%s CreativeAsset表=%s | 该键将在资源注册后由 Update 兜底生成",
                tostring(cfg.PresetKey), tostring(type(AssetRef) == "table"), tostring(type(CreativeAsset) == "table")))
        end
        return
    end
    local D = (type(cfg.DistanceBehindM) == "number") and cfg.DistanceBehindM or 4
    local side = (type(cfg.SideOffsetM) == "number") and cfg.SideOffsetM or 0
    local hgt = (type(cfg.HeightOffsetM) == "number") and cfg.HeightOffsetM or 0
    local pos = {
        X = self.boardCenter.X + self.boardForward.X * D + self.boardRight.X * side,
        Y = self.boardCenter.Y + self.boardForward.Y * D + self.boardRight.Y * side,
        Z = self.boardCenter.Z + self.boardForward.Z * D + hgt,   -- boardForward.Z 恒为 0
    }
    local scaleVec = Game:ConstructFVectorByLuaTable({
        X = (cfg.Scale and cfg.Scale.X) or 1,
        Y = (cfg.Scale and cfg.Scale.Y) or 1,
        Z = (cfg.Scale and cfg.Scale.Z) or 1,
    })
    local rot = self:BehindBoardWidgetRot()
    -- widget 是 ActorPreset（46_ActorPreset_*），强制走 CreateActor，不依赖 self.mode
    -- （Init 阶段占位 renderer 的 self.mode 尚未设置，但 ActorPreset 必用 CreateActor 创建）。
    local ok, obj = pcall(function()
        if type(CreativeGameAPI) == "table" and CreativeGameAPI.CreateActor then
            return CreativeGameAPI.CreateActor(ref, Game:ConstructFVectorByLuaTable(pos), rot, scaleVec, nil)
        end
        return self:CreateOne(Game:ConstructFVectorByLuaTable(pos), scaleVec, ref, rot)
    end)
    if ok and obj then
        self._behindWidgetActor = obj
        pcall(function() if obj.SetActorHiddenInGame then obj:SetActorHiddenInGame(false) end end)
        print(string.format("[Tetris][Widget] 盘面背后 3D UI 挂件已生成 (D=%.1f side=%.1f hgt=%.1f flip=%s)",
            D, side, hgt, tostring(self._behindWidgetFlipped)))
        -- AssetRef 晚注册导致挂件在 Update 阶段才生成时，补刷此前缓存的对方分数
        if self._pendingWidgetScore ~= nil then
            self:SetWidgetOpponentScore(self._pendingWidgetScore)
        end
    else
        print("[Tetris][Widget][WARN] 创建失败: " .. tostring(obj))
    end
end


-- 从挂件 Actor 实例上找到「对方分数」文本组件（运行时按候选名/类名获取，不依赖 UUID）。
-- 两个挂件各生成一个、组件就在各自 Actor 下，按实例获取天然互不干扰。首次找到后缓存到 _behindWidgetTextComp。
-- 找不到时打印 Actor 上全部组件（含名称），便于确认编辑器里文本组件的真实命名。
function TetrisRenderer:FindBehindWidgetTextComp()
    if self._behindWidgetTextComp then return self._behindWidgetTextComp end
    local actor = self._behindWidgetActor
    if not actor then return nil end
    local cfg = TetrisConfig.BehindBoardWidget or {}
    local childNames = cfg.OpponentScoreTextChildName or { "ui_enemyscore" }
    if type(childNames) == "string" then childNames = { childNames } end
    local firstName = childNames[1] or "ui_enemyscore"

    -- 0) 先尝试：文本控件是否直接作为同名组件挂在 Actor 上（少数情况）
    local direct
    pcall(function()
        local ok, c = pcall(function() return actor:GetComponentByName(firstName) end)
        if ok and c then direct = c end
    end)
    if direct then
        local duuid
        pcall(function()
            local ok1, u1 = pcall(function() return direct:GetWoWObjectID() end)
            local ok2, u2 = pcall(function() return direct:GetInstanceUUID() end)
            duuid = (ok1 and u1) or (ok2 and u2) or nil
        end)
        self._behindWidgetTextUUID = duuid and tostring(duuid) or nil
        self._behindWidgetTextComp = direct
        self._behindWidgetTextCompPath = "路径0:直接同名组件"
        print(string.format("[Tetris][LockDbg] 对手分控件命中[%s] %s uuid=%s",
            tostring(self._behindWidgetTextCompPath), tostring(firstName), tostring(self._behindWidgetTextUUID)))
        return direct
    end

    -- 1) 取 UI 组件（WoWWidgetComponent）
    local wc
    pcall(function()
        if type(actor.GetComponentByClass) == "function" then
            wc = actor:GetComponentByClass("WidgetComponent")
        end
    end)
    if not wc then
        pcall(function()
            for _, nm in ipairs({ "UI", "Widget", "WidgetComp", "WidgetComponent" }) do
                local ok, c = pcall(function() return actor:GetComponentByName(nm) end)
                if ok and c then wc = c; break end
            end
        end)
    end
    if not wc then
        print("[Tetris][Widget][WARN] 找不到 UI 组件(WidgetComponent)")
        return nil
    end

    -- 2) 取 PlayerCharacter 列表（GetUserWidgetObject 要求传入），逐个尝试拿到 WoWUserWidget
    local plist
    pcall(function()
        local okP, p = pcall(function() return Game:GetAllPlayerPawns() end)
        if okP and p then plist = p end
    end)
    if not plist or type(plist.Num) ~= "function" or plist:Num() <= 0 then
        return nil  -- 暂无玩家，下一帧重试
    end

    -- 3) 组件(WoWWidgetComponent) -> WoWUserWidget -> 文本控件(WoWCustomUIText) -> InstanceUUID
    local uw
    for i = 0, plist:Num() - 1 do
        local pawn = plist:Get(i)
        if pawn then
            pcall(function() uw = wc:GetUserWidgetObject(pawn) end)
            if not uw then pcall(function() uw = wc:GetWidget(pawn) end) end
            if uw then break end
        end
    end
    if not uw then
        print("[Tetris][Widget][WARN] wc:GetUserWidgetObject 所有玩家均返回空（组件可能尚未初始化，下一帧重试）")
        return nil
    end
    local tw
    for _, cn in ipairs(childNames) do
        pcall(function()
            local t = uw:GetWidgetFromName(cn)
            if t then tw = t end
        end)
        if tw then break end
    end
    if not tw then
        print(string.format("[Tetris][Widget][WARN] uw:GetWidgetFromName 未命中: %s", table.concat(childNames, ",")))
        return nil
    end
    local uuid
    pcall(function()
        local ok1, u1 = pcall(function() return tw:GetWoWObjectID() end)
        local ok2, u2 = pcall(function() return tw:GetInstanceUUID() end)
        uuid = (ok1 and u1) or (ok2 and u2) or nil
    end)
    self._behindWidgetTextUUID = uuid and tostring(uuid) or nil
    self._behindWidgetTextComp = tw
    self._behindWidgetTextCompPath = "路径2:UMG子控件(GetWidgetFromName)"
    print(string.format("[Tetris][LockDbg] 对手分控件命中[%s] %s uuid=%s",
        tostring(self._behindWidgetTextCompPath), tostring(firstName), tostring(self._behindWidgetTextUUID)))
    return tw
end



-- 把"对方分数"写到本挂件 Actor 上的文本组件。
-- 若挂件尚未生成（AssetRef 晚注册），先缓存分数，待 BuildBehindBoardWidget 生成后补刷。
function TetrisRenderer:SetWidgetOpponentScore(score)
    local cfg = TetrisConfig.BehindBoardWidget
    local dbg = (TetrisConfig and TetrisConfig.Debug and TetrisConfig.Debug.LockDbg)
    if not (cfg and cfg.Enabled) then
        if dbg then print("[Tetris][LockDbg] 对手分挂件被 BehindBoardWidget.Enabled 关闭，跳过写入") end
        return
    end
    score = (type(score) == "number") and score or 0
    self._pendingWidgetScore = score
    if not self._behindWidgetActor then
        if dbg then print(string.format("[Tetris][LockDbg] 对手分挂件 Actor 未生成，仅缓存 score=%s（待生成后补刷）", tostring(score))) end
        return
    end
    local comp = self:FindBehindWidgetTextComp()
    if not comp then
        if dbg then print(string.format("[Tetris][LockDbg] 对手分挂件找不到文本组件，score=%s 未显示（组件名/类名没匹配）", tostring(score))) end
        return
    end
    local txt = tostring(score)
    -- 本引擎文本控件按 InstanceUUID 寻址：优先用运行时 GetWoWObjectID 拿到的 UUID 走 CustomUIAPI（对所有玩家生效）
    local uuid = self._behindWidgetTextUUID
    if uuid and type(CustomUIAPI) == "table" and CustomUIAPI.SetAllPlayerTextContent then
        pcall(function() CustomUIAPI.SetAllPlayerTextContent(uuid, txt) end)
        -- if dbg then print(string.format("[Tetris][LockDbg] 对手分经 CustomUIAPI 写入 uuid=%s score=%s", tostring(uuid), txt)) end
    else
        -- 兜底：该文本控件是挂件 Widget 资源内部的子控件，无独立 CreativeInstance UUID，
        -- 直接对运行时拿到的控件对象 SetText/SetTextContent（世界空间挂件内容共享，对所有玩家生效）。
        if type(comp.SetTextContent) == "function" then
            pcall(function() comp:SetTextContent(txt) end)
        elseif type(comp.SetText) == "function" then
            pcall(function() comp:SetText(txt) end)
        end
        -- if dbg then print(string.format("[Tetris][LockDbg] 对手分经控件对象写入 board=%s score=%s 路径=%s",
        --     tostring(self.boardIndex), txt, tostring(self._behindWidgetTextCompPath))) end
    end
end

-- 计算背后 3D UI 挂件旋转：默认与盘面同向（正面朝该盘玩家）；
-- 若本盘 index 命中 FlipBoardIndices，则绕竖直轴 +180°（背对玩家）。
function TetrisRenderer:BehindBoardWidgetRot()
    local cfg = TetrisConfig.BehindBoardWidget
    -- 每个棋盘的额外偏置旋转（绕竖直/Yaw 轴，单位°）：按棋盘 index 区分，让挂件呈对称倾斜。
    -- 1号 +45°、2号 −45°；未列出的棋盘不额外偏置（0°）。
    local bias = 0
    if cfg and type(cfg.RotationBiasByIndex) == "table" then
        bias = cfg.RotationBiasByIndex[self.boardIndex] or 0
    end
    self._behindWidgetFlipped = (bias ~= 0)
    -- 始终基于盘面偏航 self.boardYaw 计算旋转：Build 阶段 self.rot 会被 makeZeroRotator() 覆盖（零/空），
    -- 但 boardYaw 在 settle 内设置且不被覆盖，故此处不依赖 self.rot，确保开局 Build 阶段也能拿到有效旋转。
    local yaw = (self.boardYaw or 0) + bias
    if type(FRotator) == "table" and FRotator.MakeFromEuler then
        return FRotator.MakeFromEuler(Game:ConstructFVectorByLuaTable({ X = 0, Y = 0, Z = yaw }))
    end
    return self.rot   -- FRotator 不可用时的回退（翻转/朝向可能失效，但至少能生成）
end

-- 将背后 3D UI 挂件重定位到当前盘面基底（应对 ResolveOrigin 重新解析、基准变化）。
function TetrisRenderer:ReanchorBehindBoardWidget()
    local cfg = TetrisConfig.BehindBoardWidget
    if not (cfg and cfg.Enabled) then return end
    if not self._behindWidgetActor then return end
    if not self.boardCenter or not self.boardForward or not self.boardRight then return end
    local D = (type(cfg.DistanceBehindM) == "number") and cfg.DistanceBehindM or 4
    local side = (type(cfg.SideOffsetM) == "number") and cfg.SideOffsetM or 0
    local hgt = (type(cfg.HeightOffsetM) == "number") and cfg.HeightOffsetM or 0
    local pos = {
        X = self.boardCenter.X + self.boardForward.X * D + self.boardRight.X * side,
        Y = self.boardCenter.Y + self.boardForward.Y * D + self.boardRight.Y * side,
        Z = self.boardCenter.Z + self.boardForward.Z * D + hgt,
    }
    local rot = self:BehindBoardWidgetRot()
    pcall(function() self._behindWidgetActor:K2_TeleportTo(cmVec(pos), rot) end)
end

-- ============== 盘面前方 3D 大框（BigFrame3D）：与 BehindBoardWidget 相对，位于盘面前方（朝玩家一侧） ==============
-- 每个盘面（双盘各一）在「盘面前方」生成 1 个带 WidgetComponent 的 Actor，其 UMG 内含 Hold / Next 两个图片控件，
-- 替代双方原本的 2D Hold/Next 显示。定位 = 盘心 - 视线前向(boardForward) * DistanceFrontM（即盘面“朝玩家”一侧）。
function TetrisRenderer:BuildFrontBoardWidget()
    local cfg = TetrisConfig.BigFrame3D
    if not (cfg and cfg.Enabled) then return end
    if not self.boardCenter or not self.boardForward or not self.boardRight then
        if not self._frontWidgetBaseLogged then
            self._frontWidgetBaseLogged = true
            print(string.format("[Tetris][FrontWidget][WARN] 盘面基底未就绪(首次): built=%s hasCenter=%s hasFwd=%s hasRight=%s",
                tostring(self.built), tostring(not not self.boardCenter), tostring(not not self.boardForward), tostring(not not self.boardRight)))
        end
        return
    end
    if self._frontWidgetActor then return end   -- 已生成：交给 ReanchorFrontBoardWidget 重定位
    local ref = (type(AssetRef) == "table" and AssetRef[cfg.PresetKey])
             or (type(CreativeAsset) == "table" and CreativeAsset[cfg.PresetKey])
    if not ref then
        if not self._frontWidgetRefLogged then
            self._frontWidgetRefLogged = true
            print(string.format("[Tetris][FrontWidget][WARN] 资源键无引用(首次): %s | AssetRef表=%s CreativeAsset表=%s",
                tostring(cfg.PresetKey), tostring(type(AssetRef) == "table"), tostring(type(CreativeAsset) == "table")))
        end
        return
    end
    local D = (type(cfg.DistanceFrontM) == "number") and cfg.DistanceFrontM or 0.6
    local side = (type(cfg.SideOffsetM) == "number") and cfg.SideOffsetM or 0
    local hgt = (type(cfg.HeightOffsetM) == "number") and cfg.HeightOffsetM or 0
    -- 前方：沿 -boardForward（朝玩家一侧），与 BehindBoardWidget 的 +boardForward（背后）相反
    -- 前方：沿 +boardForward（与 BehindBoardWidget 同侧=朝玩家可见侧；-forward 会被盘体遮挡不可见，已实测验证）
    local pos = {
        X = self.boardCenter.X + self.boardForward.X * D + self.boardRight.X * side,
        Y = self.boardCenter.Y + self.boardForward.Y * D + self.boardRight.Y * side,
        Z = self.boardCenter.Z + self.boardForward.Z * D + hgt,
    }
    local scaleVec = Game:ConstructFVectorByLuaTable({
        X = (cfg.Scale and cfg.Scale.X) or 1,
        Y = (cfg.Scale and cfg.Scale.Y) or 1,
        Z = (cfg.Scale and cfg.Scale.Z) or 1,
    })
    local rot = self:FrontBoardWidgetRot()
    local ok, obj = pcall(function()
        if type(CreativeGameAPI) == "table" and CreativeGameAPI.CreateActor then
            return CreativeGameAPI.CreateActor(ref, Game:ConstructFVectorByLuaTable(pos), rot, scaleVec, nil)
        end
        return self:CreateOne(Game:ConstructFVectorByLuaTable(pos), scaleVec, ref, rot)
    end)
    if ok and obj then
        self._frontWidgetActor = obj
        pcall(function() if obj.SetActorHiddenInGame then obj:SetActorHiddenInGame(false) end end)
        print(string.format("[Tetris][FrontWidget] 盘面前方 3D 大框已生成 (D=%.1f side=%.1f hgt=%.1f)", D, side, hgt))
        -- AssetRef 晚注册导致大框在 Update 阶段才生成时，补刷此前缓存的 Hold/Next
        if self._pendingFrontHold ~= nil or self._pendingFrontNext ~= nil then
            self:SetFrontWidgetHoldNext(self._pendingFrontHold, self._pendingFrontNext)
        end
        -- 生成即隐藏 Hold/Next/backlight（running=false 时 Update 每帧也会隐藏；此处提前确保开局前不显示空框）
        self:SetFrontWidgetHoldNext(nil, nil)
        self:SetFrontBacklight(false)
    else
        print("[Tetris][FrontWidget][WARN] 创建失败: " .. tostring(obj))
    end
end

-- 计算盘面前方 3D 大框旋转：基于盘面偏航 self.boardYaw + RotationBiasByIndex[boardIndex]（与 BehindBoardWidgetRot 同构）
function TetrisRenderer:FrontBoardWidgetRot()
    local cfg = TetrisConfig.BigFrame3D
    local bias = 0
    if cfg and type(cfg.RotationBiasByIndex) == "table" then
        bias = cfg.RotationBiasByIndex[self.boardIndex] or 0
    end
    local yaw = (self.boardYaw or 0) + bias
    if type(FRotator) == "table" and FRotator.MakeFromEuler then
        return FRotator.MakeFromEuler(Game:ConstructFVectorByLuaTable({ X = 0, Y = 0, Z = yaw }))
    end
    return self.rot
end

-- 从盘面前方 3D 大框 Actor 上，按候选名列表找到某个图片子控件，返回其 InstanceUUID（全局）。
function TetrisRenderer:FindFrontWidgetImageChild(childNames)
    if type(childNames) == "string" then childNames = { childNames } end
    local actor = self._frontWidgetActor
    if not actor then return nil end
    local wc
    pcall(function()
        if type(actor.GetComponentByClass) == "function" then
            wc = actor:GetComponentByClass("WidgetComponent")
        end
    end)
    if not wc then
        pcall(function()
            for _, nm in ipairs({ "UI", "Widget", "WidgetComp", "WidgetComponent" }) do
                local okC, c = pcall(function() return actor:GetComponentByName(nm) end)
                if okC and c then wc = c; break end
            end
        end)
    end
    if not wc then
        print("[Tetris][FrontWidget][WARN] 找不到 UI 组件(WidgetComponent)")
        return nil
    end
    local plist
    pcall(function()
        local okP, p = pcall(function() return Game:GetAllPlayerPawns() end)
        if okP and p then plist = p end
    end)
    if not plist or type(plist.Num) ~= "function" or plist:Num() <= 0 then
        return nil  -- 暂无玩家，下一帧重试
    end
    local uw
    for i = 0, plist:Num() - 1 do
        local pawn = plist:Get(i)
        if pawn then
            pcall(function() uw = wc:GetUserWidgetObject(pawn) end)
            if not uw then pcall(function() uw = wc:GetWidget(pawn) end) end
            if uw then break end
        end
    end
    if not uw then
        print("[Tetris][FrontWidget][WARN] wc:GetUserWidgetObject 所有玩家均返回空（组件可能尚未初始化，下一帧重试）")
        return nil
    end
    -- 你的 UMG 结构是 ui → front → hold / next，所以先按名直接查（递归），失败再尝试经中间容器（如 front）二级查找
    local cname = (type(TetrisConfig.BigFrame3D) == "table") and TetrisConfig.BigFrame3D.FrontContainerName
    local function tryFind(name)
        local t
        pcall(function() t = uw:GetWidgetFromName(name) end)
        if not t and cname then
            local c
            pcall(function() c = uw:GetWidgetFromName(cname) end)
            if c then pcall(function() t = c:GetWidgetFromName(name) end) end
        end
        return t
    end
    local tw
    for _, cn in ipairs(childNames) do
        local t = tryFind(cn)
        if t then tw = t; break end
    end
    if not tw then
        print(string.format("[Tetris][FrontWidget][WARN] uw:GetWidgetFromName 未命中: %s", table.concat(childNames, ",")))
        return nil
    end
    print(string.format("[Tetris][FrontWidget] 定位成功 childNames=%s", table.concat(childNames, ",")))
    -- 返回图片控件对象（WoWCustomUIImage）：世界空间 WidgetComponent 的图片子控件必须用对象方法
    -- SetImageContent / SetImageColor / SetVisible 操作（CustomUIAPI.SetImageWidget* 仅适用于 2D HUD 命名实例，对这类控件无效）。
    return tw
end

-- 把 Hold / Next 图片写入盘面前方 3D 大框的图片控件（替代 2D Hold/Next）。
-- 若大框未生成或图片子控件未定位，则缓存类型，待生成/定位后补刷。
-- 道具图片（IsItemType，即 PieceImages[9/10/11]）颜色设为白色；普通方块按 PieceTint 染色。
function TetrisRenderer:SetFrontWidgetHoldNext(holdType, nextType)
    local cfg = TetrisConfig.BigFrame3D
    if not (cfg and cfg.Enabled) then return end
    -- 缓存最新类型（即使大框/控件尚未就绪）
    self._pendingFrontHold = holdType
    self._pendingFrontNext = nextType
    if not self._frontWidgetActor then return end
    if not self._frontHoldWidget then
        self._frontHoldWidget = self:FindFrontWidgetImageChild(cfg.HoldImageChildName or { "hold" })
    end
    if not self._frontNextWidget then
        self._frontNextWidget = self:FindFrontWidgetImageChild(cfg.NextImageChildName or { "next" })
    end
    local imgs = TetrisConfig.PieceImages
    local tints = TetrisConfig.PieceTint
    local function resolveImg(t)
        local key = (t and imgs) and imgs[t] or nil
        if not key then return nil end
        return (type(AssetRef) == "table" and AssetRef[key]) or key
    end
    local function isItem(t)
        return type(TetrisConfig.IsItemType) == "function" and TetrisConfig.IsItemType(t)
    end
    -- 直接操作图片控件对象（WoWCustomUIImage）：SetImageContent / SetImageColor / SetVisible。
    -- 无内容时 SetVisible(false) 隐藏（初始/未持有/队列未就绪均不显示空框）；有内容时显示并注入贴图+染色。
    -- 贴图/染色仅在类型变化时才刷新（变更检测），避免每帧重载贴图导致闪烁。
    local function setImg(widget, t, lastKey)
        if not widget then return end
        local imgID = resolveImg(t)
        local visible = (imgID ~= nil)
        pcall(function() widget:SetVisible(visible) end)
        if not visible then
            self[lastKey] = nil
            return
        end
        if self[lastKey] == t then return end   -- 类型未变，跳过贴图重载
        self[lastKey] = t
        local colorVec
        if isItem(t) then
            colorVec = Game:ConstructFVectorByLuaTable({ X = 1, Y = 1, Z = 1 })   -- 道具：白色
        else
            local c = (t and tints) and tints[t]
            if c then colorVec = Game:ConstructFVectorByLuaTable({ X = c.X, Y = c.Y, Z = c.Z }) end
        end
        pcall(function() widget:SetImageContent(imgID) end)
        if colorVec then pcall(function() widget:SetImageColor(colorVec) end) end
    end
    setImg(self._frontHoldWidget, holdType, "_frontHoldLastType")
    setImg(self._frontNextWidget, nextType, "_frontNextLastType")
end

-- 设置盘面前方 3D 大框上的「攻势高亮」(backlight) 显隐。
-- 该图片在 ui 下与 front 同级、默认隐藏；visible=true 显示（点击攻势技能 SK06 时），false 隐藏（攻击结算后）。
function TetrisRenderer:SetFrontBacklight(visible)
    local cfg = TetrisConfig.BigFrame3D
    if not (cfg and cfg.Enabled) then return end
    if not self._frontWidgetActor then return end
    if not self._frontBacklightWidget then
        self._frontBacklightWidget = self:FindFrontWidgetImageChild(cfg.BacklightChildName or { "backlight", "Backlight" })
    end
    if not self._frontBacklightWidget then return end
    local v = (visible == true)
    if self._frontBacklightShown == v then return end   -- 状态未变则跳过
    self._frontBacklightShown = v
    pcall(function() self._frontBacklightWidget:SetVisible(v) end)
end

-- 将盘面前方 3D 大框重定位到当前盘面基底（应对 ResolveOrigin 重新解析、基准变化）。
function TetrisRenderer:ReanchorFrontBoardWidget()
    local cfg = TetrisConfig.BigFrame3D
    if not (cfg and cfg.Enabled) then return end
    if not self._frontWidgetActor then return end
    if not self.boardCenter or not self.boardForward or not self.boardRight then return end
    local D = (type(cfg.DistanceFrontM) == "number") and cfg.DistanceFrontM or 0.6
    local side = (type(cfg.SideOffsetM) == "number") and cfg.SideOffsetM or 0
    local hgt = (type(cfg.HeightOffsetM) == "number") and cfg.HeightOffsetM or 0
    local pos = {
        X = self.boardCenter.X + self.boardForward.X * D + self.boardRight.X * side,
        Y = self.boardCenter.Y + self.boardForward.Y * D + self.boardRight.Y * side,
        Z = self.boardCenter.Z + self.boardForward.Z * D + hgt,
    }
    local rot = self:FrontBoardWidgetRot()
    -- 与 ReanchorBehindBoardWidget 保持一致：pos 是米，必须用 cmVec(×100) 转厘米，否则会被当成米当厘米放到盘心内部而不可见
    pcall(function() self._frontWidgetActor:K2_TeleportTo(cmVec(pos), rot) end)
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
        -- 道具 3D UI 回收：方块归还池时，摘除其附加的 UI 子级（附加到子级方式 + 回收时移除）
        local reg = self._itemUIByBlock
        local e = reg and reg[a]
        if e then
            pcall(function() e.actor:K2_DetachFromActor(1, 1, 1) end)
            pcall(function() if e.actor.SetActorHiddenInGame then e.actor:SetActorHiddenInGame(true) end end)
            e.attachedTo = nil
            e.appliedFor = nil
            e.imgComp = nil
            e.hidden = true
            reg[a] = nil
            local pool = self._itemWidgetPool or {}
            self._itemWidgetPool = pool
            pool[#pool + 1] = e
        end
        if self._occUsed then self._occUsed[a] = nil end
        pcall(function() a:K2_TeleportTo(cmVec(self.hideLoc), self.rot) end)
        self.pool[#self.pool + 1] = a
    end
end

-- 为静态格提供一个方块 Actor（数据驱动）：读格子 {color,item}；若该格是道具(item~=nil)且当前正有
-- 掉落道具块 self._itemBlockActor，则复用它（落锁不回收替换，直接登记进 occ，保留其附加的 3D UI 子级）；
-- 否则从对象池取。复用后把 self._itemBlockActor 置空，UpdateItemBlock 不再回收它；
-- 后续消除由 ReleaseActor（occ 回收）统一回收（含摘除 UI 子级）。
function TetrisRenderer:ProvideStaticBlock(board, row, col)
    local cell = board and board:getCell(row, col)   -- {color,item} 或 nil
    if not cell then return nil end
    if cell.item and self._itemBlockActor then
        local a = self._itemBlockActor
        self._itemBlockActor = nil
        self._itemBlockHidden = true
        self:placeActor(a, row, col)
        self:PaintCell(a, cell.color)
        return a
    end
    local a = self:AcquireActor()
    if a then
        self:placeActor(a, row, col)
        self:PaintCell(a, cell.color)
    end
    return a
end

-- 把独立方块 Actor 放到 (row,col) 的世界坐标（静态摆放，不依赖附着）。
function TetrisRenderer:placeActor(a, row, col)
    if not a then return end
    pcall(function() a:K2_TeleportTo(cmVec(self:cellLocation(row, col)), self.rot) end)
end

-- ---------------- 方块换色（按类型/垃圾） ----------------
-- 解析 8 种彩色模型引用（1..7 = 方块颜色，8 = 垃圾灰），缓存到 self.colorMesh。
-- 任一未注册（AssetRef 解析为 nil）→ 该类型回退默认单色（不换色）。幂等，仅解析一次。
function TetrisRenderer:PrepareColorRefs()
    if self._colorRefsReady then return end
    self._colorRefsReady = true
    self.colorMesh = {}
    local ids = TetrisConfig.Render.ColorModelIDs
    if type(ids) == "table" then
        for t = 1, 8 do
            local key = ids[t]
            local ref = (type(AssetRef) == "table" and key) and AssetRef[key] or nil
            self.colorMesh[t] = ref
            -- if key and not ref and TetrisConfig.Debug then
            --     print(string.format("[Tetris][Color][WARN] ColorModelIDs[%d] 资源未注册 AssetRef[\"%s\"]，回退单色",
            --         t, tostring(key)))
            -- end
        end
    end
    -- 道具方块本体：灰色立方（与类型无关，复用垃圾块灰模 key）
    local ibk = TetrisConfig.Item and TetrisConfig.Item.BlockModelKey
    self.itemBlockRef = (type(ibk) == "string" and type(AssetRef) == "table" and AssetRef[ibk]) or nil
    if TetrisConfig.Debug then
        local n = 0
        for t = 1, 8 do if self.colorMesh[t] then n = n + 1 end end
        -- print(string.format("[Tetris][Color] 彩色模型解析完成: %d/8（其余回退单色）", n))
    end
end

-- 把单元方块 Actor 换成指定颜色的模型（color: 1..7 方块色 / 8 垃圾与道具灰）。
-- 未解析到对应模型 → 不换色，保持默认单色。失败 pcall 兜底。
function TetrisRenderer:PaintCell(a, color)
    if not a or not color or color < 1 then return end
    if color > 8 then color = 8 end   -- 容错：道具类别号(9..11)等一律按灰，避免越界
    if not self.colorMesh then self:PrepareColorRefs() end
    local ref = self.colorMesh and self.colorMesh[color]
    if not ref then return end  -- 回退单色
    local comp = getMeshComp(self, a)
    if comp then
        pcall(function() comp:SetStaticMesh(ref) end)
    end
end

-- 在指定格位置播放消行特效。Domain API 坐标用米，cellLocation 返回值即米，直接构造 FVector 传入。
-- 资源走 AssetRef（需 VSCode 插件注册并 update preset）；失败静默，不影响消行主流程。
-- 在指定“行”的消行位置播放特效。位置只依赖行号：
--   · 水平取盘面中心（优先 boardCenter，已含 right 投影，与盘面朝向一致；回退 origin + right*(w/2)），
--     不再依赖列——消行特效本就该横跨整行居中，列方向偏移在旋转盘面下正是之前偏位的根因。
--   · 竖直按行：与 cellLocation 的 Z = o.Z - (row-1)*step 一致（行方向永远是世界 -Z，不受盘面 yaw 影响，故行很准）。
-- 资源走 AssetRef（需 VSCode 插件注册并 update preset）；失败静默，不影响消行主流程。
-- 爆破竖版特效：道具爆破消除一整列，在该列底部由下往上播放竖版光束。
-- 位置：水平取该列 cellLocation(col) 的 X/Y，竖直锚定在列底部(bot.Z)由下往上发射；
-- 朝向：SetSceneEffectRotation 立为竖版（Pitch/Roll 旋转）+ yaw 叠 boardYaw 正对玩家。
-- 爆破竖版光束：缩放完全由配置 BlastEffectScale 控制（X=水平宽度, Y=竖直长度, Z=深度厚度，均为绝对倍数），代码不按列高换算。
function TetrisRenderer:PlayBlastEffectAt(col, bottomRow, topRow)
    if not SceneEffectAPI or not SceneEffectAPI.CreateSceneEffect then return end
    local cl = TetrisConfig.Clear or {}
    local key = cl.BlastEffectPresetKey or cl.EffectPresetKey or "13_EffectPreset_100032"
    local ref = AssetRef and AssetRef[key]
    if not ref then
        if TetrisConfig.Debug then
            print(string.format("[Tetris][Blast][WARN] 特效资源未注册 AssetRef[%s]，跳过", tostring(key)))
        end
        return
    end
    local bot = self:cellLocation(bottomRow, col)        -- 该列底部(盘底)世界坐标
    -- 竖直锚定在「列底部」(bot.Z)，由下往上发射（光束长=整列高，Pitch=-90 指 +Z 向上）；
    -- 水平取该列(bot.X/Y，同列所有行一致)。
    local off = cl.BlastEffectOffset or { X = 0, Y = 0, Z = 0 }
    local pos = { X = bot.X + (off.X or 0), Y = bot.Y + (off.Y or 0), Z = bot.Z + (off.Z or 0) }
    local dur = cl.EffectDuration or 0.5
    local ok, id = pcall(function()
        return SceneEffectAPI.CreateSceneEffect(ref, Game:ConstructFVectorByLuaTable(pos), dur)
    end)
    if not ok or not id or id == 0 then
        if TetrisConfig.Debug then
            print(string.format("[Tetris][Blast][WARN] 特效创建失败 col=%d id=%s", col, tostring(id)))
        end
        return
    end
    -- 立为竖版：额外旋转(Pitch=90 等) + yaw 叠 boardYaw 正对玩家
    local erot = cl.BlastEffectRot or { X = 90, Y = 0, Z = 0 }
    pcall(function()
        if type(FRotator) == "table" and FRotator.MakeFromEuler then
            local rot = FRotator.MakeFromEuler(Game:ConstructFVectorByLuaTable({
                X = erot.X or 0, Y = erot.Y or 0, Z = (self.boardYaw or 0) + (erot.Z or 0) }))
            SceneEffectAPI.SetSceneEffectRotation(id, rot)
        end
    end)
    -- 缩放：完全由配置 BlastEffectScale 控制（X=水平宽度, Y=竖直长度, Z=深度厚度，均为绝对倍数，1.0=原始大小）。
    -- 不再在代码里按列高换算或加下限，方便边调边改。
    local sc = cl.BlastEffectScale or { X = 1.0, Y = 1.5, Z = 1.0 }
    pcall(function()
        SceneEffectAPI.SetSceneEffectScale(id, Game:ConstructFVectorByLuaTable({ X = sc.X or 1.0, Y = sc.Y or 1.0, Z = sc.Z or 1.0 }))
    end)
end

function TetrisRenderer:PlayClearEffectAt(row)
    if not SceneEffectAPI or not SceneEffectAPI.CreateSceneEffect then return end
    local key = (TetrisConfig.Clear and TetrisConfig.Clear.EffectPresetKey) or "13_EffectPreset_100032"
    local ref = AssetRef and AssetRef[key]
    if not ref then
        if TetrisConfig.Debug then
            print(string.format("[Tetris][Clear][WARN] 特效资源未注册 AssetRef[%s]，跳过", tostring(key)))
        end
        return
    end
    local r = TetrisConfig.Render
    local step = r.CellSize + r.CellGap
    local o = self.origin or r.BoardOrigin
    local right = self.boardRight or { X = 1, Y = 0, Z = 0 }
    -- 盘面水平中心：优先 boardCenter（ResolveOrigin 已算好，含 right 投影）；否则由 origin 推。
    local center = self.boardCenter
    if not center then
        local w = (TetrisConfig.Board.Cols - 1) * step
        center = { X = o.X + right.X * (w / 2), Y = o.Y + right.Y * (w / 2), Z = o.Z }
    end
    -- 竖直按行（与世界 -Z 同向，与 cellLocation 完全一致）；水平直接取盘面中心，不乘列。
    local loc = { X = center.X, Y = center.Y, Z = o.Z - (row - 1) * step }
    -- 水平偏移：沿盘面本地左侧（-right）。LeftOffsetM>0 即向左，两块盘朝向不同也各自向左、保持一致。
    local off = (TetrisConfig.Clear and TetrisConfig.Clear.EffectPositionOffset) or { X = 0.0, Y = 0.0, Z = 0.0 }
    
    local along = (off.X or 0) * right.X + (off.Y or 0) * right.Y
    -- 竖直仅用 off.Z 作上下微调（沿世界 -Z，与行方向一致），X/Y 不再参与水平。
    local pos = { X = loc.X + right.X * along, Y = loc.Y + right.Y * along, Z = loc.Z + (off.Z or 0) }
    local dur = (TetrisConfig.Clear and TetrisConfig.Clear.EffectDuration) or 1.0
    local ok, id = pcall(function()
        return SceneEffectAPI.CreateSceneEffect(
            ref,
            Game:ConstructFVectorByLuaTable(pos),
            dur)
    end)
    if not ok or not id or id == 0 then
        if TetrisConfig.Debug then
            print(string.format("[Tetris][Clear][WARN] 特效创建失败 row=%d id=%s", row, tostring(id)))
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
        print(string.format("[Tetris][Clear] 特效 row=%d id=%s scale=(%.2f,%.2f,%.2f)",
            row, tostring(id), scale.X, scale.Y, scale.Z))
    end
end

-- 位移道具特效：位移块消除→整行右移时，在位移块所在行播放横向特效。
-- 位置：竖直按位移块所在行（数据层行号，不找方块）；水平居中盘面（与消行特效一致）。
-- 朝向：基准为盘面法线（yaw=boardYaw 正对玩家）叠加配置偏转 ShiftEffectRot（默认 0）。
function TetrisRenderer:PlayShiftEffectAt(row)
    if not SceneEffectAPI or not SceneEffectAPI.CreateSceneEffect then return end
    local cl = TetrisConfig.Clear or {}
    local key = cl.ShiftEffectPresetKey or "13_EffectPreset_100043"
    local ref = AssetRef and AssetRef[key]
    if not ref then
        if TetrisConfig.Debug then
            print(string.format("[Tetris][Shift][WARN] 特效资源未注册 AssetRef[%s]，跳过", tostring(key)))
        end
        return
    end
    local r = TetrisConfig.Render
    local step = r.CellSize + r.CellGap
    local o = self.origin or r.BoardOrigin
    local right = self.boardRight or { X = 1, Y = 0, Z = 0 }
    -- 水平居中盘面（与消行特效一致）
    local center = self.boardCenter
    if not center then
        local w = (TetrisConfig.Board.Cols - 1) * step
        center = { X = o.X + right.X * (w / 2), Y = o.Y + right.Y * (w / 2), Z = o.Z }
    end
    -- 竖直按行（与世界 -Z 同向，与 cellLocation 完全一致）；水平直接取盘面中心，不乘列。
    local loc = { X = center.X, Y = center.Y, Z = o.Z - (row - 1) * step }
    local off = cl.ShiftEffectOffset or { X = 0.0, Y = 0.0, Z = 0.0 }
    local along = (off.X or 0) * right.X + (off.Y or 0) * right.Y
    local pos = { X = loc.X + right.X * along, Y = loc.Y + right.Y * along, Z = loc.Z + (off.Z or 0) }
    local dur = cl.EffectDuration or 0.5
    local ok, id = pcall(function()
        return SceneEffectAPI.CreateSceneEffect(ref, Game:ConstructFVectorByLuaTable(pos), dur)
    end)
    if not ok or not id or id == 0 then
        if TetrisConfig.Debug then
            print(string.format("[Tetris][Shift][WARN] 特效创建失败 row=%d id=%s", row, tostring(id)))
        end
        return
    end
    -- 缩放
    local scale = cl.ShiftEffectScale or { X = 1.0, Y = 1.0, Z = 1.0 }
    pcall(function()
        SceneEffectAPI.SetSceneEffectScale(id, Game:ConstructFVectorByLuaTable({ X = scale.X, Y = scale.Y, Z = scale.Z }))
    end)
    -- 朝向：基准盘面法线(yaw=boardYaw 正对玩家) + 配置偏转（默认 0）
    local erot = cl.ShiftEffectRot or { X = 0, Y = 0, Z = 0 }
    pcall(function()
        if type(FRotator) == "table" and FRotator.MakeFromEuler then
            local rot = FRotator.MakeFromEuler(Game:ConstructFVectorByLuaTable({
                X = erot.X or 0, Y = erot.Y or 0, Z = (self.boardYaw or 0) + (erot.Z or 0) }))
            SceneEffectAPI.SetSceneEffectRotation(id, rot)
        end
    end)
    if TetrisConfig.Debug then
        print(string.format("[Tetris][Shift] 特效 row=%d id=%s rot=(%.1f,%.1f,%.1f)",
            row, tostring(id), erot.X or 0, erot.Y or 0, (self.boardYaw or 0) + (erot.Z or 0)))
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

-- ---------------- 活动方块优先构建（含 3 次 × 1s 兜底） ----------------
-- 先确保 7 个活动方块（整体模式）生成完整，再让上层延迟构建“其他方块”（静态池 / 消行根）。
-- 流程：生成 → 延迟 1s → 校验（7/7 是否都在）→ 不完整则重置重建，最多 3 次；3 次后无论是否完整都继续，避免死等。
-- 玩家盘与对方盘各自持有一个 renderer 实例，故“对方的 7 个”会由对方 renderer 同步执行同一流程，无需额外协调。
-- ---------------- 分阶段构建（由 TetrisMatch 统一编排，跨玩家盘+对方盘汇总数量） ----------------
-- 步骤：1) 生成 4*7*2 个方块(子块) → 2) 轮询确认数量足够后“设置”14 个整体方块(根+附着)，最多 3 次
--       → 3) 生成方框(边框) → 4) 确认方框好后，每隔 0.25s 生成 1 个静态方块直到池目标(400)。

-- 生成 4×7 = 28 个子方块（暂未附着根），存于 self._pieceChildren[t]。幂等，仅生成一次。
function TetrisRenderer:GenPieceChildren()
    if self._childrenBuilt then return end
    self._childrenBuilt = true
    local r = TetrisConfig.Render
    local step = r.CellSize + r.CellGap
    local s = r.BlockScale
    local scale = Game:ConstructFVectorByLuaTable({ X = s, Y = s, Z = s })
    local park = self.hideLoc
    local right = self.boardRight or { X = 1, Y = 0, Z = 0 }
    local childRef = (type(AssetRef) == "table") and AssetRef[r.PieceChildPresetKey] or nil
    if not childRef then
        print("[Tetris][WARN] 缺 PieceChildPresetKey，活动块回退方案1")
        self._useV1 = true
        return
    end
    self._pieceChildren = {}
    self._pieceChildrenOffsets = {}
    for t = 1, 7 do
        local shape = TetrisConfig.Pieces[t] and TetrisConfig.Pieces[t].shape
        if shape then
            local pr, pc = self:piecePivot(t)
            local offs = {}
            for rr = 1, #shape do
                for cc = 1, #shape do
                    if shape[rr][cc] == 1 then
                        offs[#offs + 1] = { dx = (cc - pc) * step, dz = -((rr - pr) * step) }
                    end
                end
            end
            local kids = {}
            for _, o in ipairs(offs) do
                local cw = Game:ConstructFVectorByLuaTable({ X = park.X + right.X * o.dx, Y = park.Y + right.Y * o.dx, Z = park.Z + o.dz })
                local child = CreativeGameAPI.CreateActor(childRef, cw, self.rot, scale, nil)
                if child then
                    self:PaintCell(child, t)  -- 按类型换彩色模型（未解析则回退单色）
                    kids[#kids + 1] = child
                end
            end
            self._pieceChildren[t] = kids
            self._pieceChildrenOffsets[t] = offs
        end
    end
end

-- 本盘已生成的子方块总数（供 match 汇总轮询）。
function TetrisRenderer:PieceChildCount()
    local n = 0
    if self._pieceChildren then
        for t = 1, 7 do if self._pieceChildren[t] then n = n + #self._pieceChildren[t] end end
    end
    return n
end

-- 设置本盘 7 个整体方块：为每型创建隐形根并把 4 个子块挂上去（构建 self.pieces[t]）。
-- 每次调用重置重建（供“设置 3 次”重试）；缺 root 预设时回退方案1。
function TetrisRenderer:SetupPieceRoots()
    if self._useV1 then
        self:BuildActivePiecesV1()
        return
    end
    self.pieces = {}
    self.piecePool = {}
    local r = TetrisConfig.Render
    local s = r.BlockScale
    local scale = Game:ConstructFVectorByLuaTable({ X = s, Y = s, Z = s })
    local rootRef = (type(AssetRef) == "table") and AssetRef[r.PieceRootPresetKey] or nil
    if not rootRef then
        print("[Tetris][WARN] 缺 PieceRootPresetKey，活动块回退方案1")
        self:BuildActivePiecesV1()
        return
    end
    self.wholePieceAttach = true
    for t = 1, 7 do
        local children = (self._pieceChildren and self._pieceChildren[t]) or {}
        if #children == 4 then
            local root = CreativeGameAPI.CreateActor(rootRef, Game:ConstructFVectorByLuaTable(self.hideLoc), self.rot, scale, nil)
            if root then
                pcall(function() root:SetActorHiddenInGame(false) end)
                self.pieces[t] = { root = root, children = children, offsets = self._pieceChildrenOffsets[t], attached = false, type = t }
                self.piecePool[#self.piecePool + 1] = self.pieces[t]
            end
        end
    end
    self:fillPieceQueue()
end

-- 本盘 7 个活动方块是否设置完整（每型 root + 4 children 都在）。
function TetrisRenderer:ActivePiecesComplete()
    if self._useV1 then return true end
    for t = 1, 7 do
        local p = self.pieces[t]
        if not p or not p.root or not p.children or #p.children ~= 4 then return false end
    end
    return true
end

-- 生成方框（边框）：转发到幂等的 BuildBorder。
function TetrisRenderer:GenBorder()
    self:BuildBorder()
end

-- 本盘边框是否生成好。
function TetrisRenderer:BorderDone()
    if self._borderDisabled then return true end   -- 边框被配置关闭：视为已完成，避免构建状态机走 25 次 0.2s 超时
    return (self.border and #self.border > 0)
end

-- 生成一个静态方块入池（由 match 每 0.25s 调一次），直到达到本盘目标（rows*cols）。
function TetrisRenderer:GenStaticOne()
    local target = TetrisConfig.Board.Cols * TetrisConfig.Board.Rows
    if #self.pool >= target then return end
    local s = TetrisConfig.Render.BlockScale
    local scale = Game:ConstructFVectorByLuaTable({ X = s, Y = s, Z = s })
    local ref = self.refTop
    local obj = self:CreateOne(Game:ConstructFVectorByLuaTable(self.hideLoc), scale, ref)
    if obj then self.pool[#self.pool + 1] = obj end
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
                if child then
                    self:PaintCell(child, t)  -- 按类型换彩色模型（未解析则回退单色）
                    kids[#kids + 1] = child
                end
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
-- 下一 / Hold 预览已改用 2D 图片展示（见 TetrisGame:UpdateHoldNextUI），不再生成 3D 静态方块，
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
            self:PaintCell(child, t)  -- 按类型换彩色模型（未解析则回退单色）
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

-- 下一 / Hold 预览已改用 2D 图片展示，不再预建/生成 3D 静态方块，故 BuildWholePiecePool 只管 7 个活动方块。

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
            -- 取出即重附：打破 _everReady 冻结，保证被停放(teleport 到停车场)过的实例
            -- 子块重新挂回根并归位，避免“复用/换出(hold)时缺子块（孤儿停在停车场）”。
            self:EnsureWholePieceAttached(p, { rot = 1 })
            print(string.format("[Tetris][Pool] 取出 acquire type=%d（取出后空闲 %d）", type, #self.pieceQueue))
            return p
        end
    end
    print(string.format("[Tetris][WARN] acquire 队列无空闲 type=%d 回退 self.pieces（仍属7预建池,非新生成）", type))
    local p = self.pieces[type]
    if p then p.inUse = true end
    if p then self:EnsureWholePieceAttached(p, { rot = 1 }) end  -- 回退路径同样保证子块重新挂回根
    return p
end

-- 归还方块实例到队列（先归位停车场），供后续活动方块复用。
function TetrisRenderer:releasePiece(p)
    if not p then return end
    p.inUse = false
    self:parkWholePieceV3(p)
    table.insert(self.pieceQueue, p)
    print(string.format("[Tetris][Pool] 放回 release type=%d（归还后空闲 %d）", p.type, #self.pieceQueue))
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
    if self._useV1 then  -- 方案1 回退：不经整体附着，直接放行
        self.piecesReady = true
        return
    end
    if not self.wholePieceAttach then
        return  -- 整体模式尚未设置好（处于构建阶段），等 SetupPieceRoots 后再预热，不提前放行
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
    pcall(function() p.root:K2_TeleportTo(cmVec(center), self:makePieceRotator(active.rot)) end)

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
            local cR = self:makePieceRotator(active.rot)

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
-- 整体模式(V3)停车：把单个方块停回「预览区/停车场」（盘面上方可见区）。
-- 停车场即开局预览区(Showcase)：7 个方块并排始终可见，仅「当前活动方块」临时离场下落、锁定后归位。
-- 位置与 LayoutShowcasePieces 同源：用 Showcase 配置 + boardRight 计算，保证与预览排布完全对齐。
function TetrisRenderer:parkWholePieceV3(p)
    if not p or not p.root then return end
    local r = TetrisConfig.Render
    local sc = r.Showcase or {}
    local step = r.CellSize + r.CellGap
    local gap = step * (sc.GapCells or 5)          -- 与 LayoutShowcasePieces 一致
    local height = step * (sc.HeightCells or 13)
    local nf = sc.NormalOffsetM or 0
    local o = self.origin or r.BoardOrigin
    local right = self.boardRight or { X = 1, Y = 0, Z = 0 }
    local nrm = { X = -right.Y, Y = right.X, Z = 0 }   -- 显示法线 = right 逆时针转 90°
    local zShow = o.Z + height
    local t = p.type or 1
    local along = (t - 1 - 3) * gap                 -- 沿 right 居中展开，与预览同一列
    local x = o.X + right.X * along + nrm.X * nf
    local y = o.Y + right.Y * along + nrm.Y * nf
    pcall(function() p.root:K2_TeleportTo(cmVec({ X = x, Y = y, Z = zShow }), self.rot) end)
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
    if not self.wholePieceAttach then return end
    self.previewing = true
    self.shownPieceType = nil
    self._previewSeconds = seconds or (TetrisConfig.Render.PreviewSeconds or 1)
    -- 立即摆一次；若 7 个方块的根/子 Actor 尚未 spawn（CreateActor 异步），由 Update 在预览期每帧重试。
    self:LayoutShowcasePieces()
    print(string.format("[Tetris] 开局预览：7 种方块已摆在盘面上方，%.0f 秒后开始下落", self._previewSeconds))
end

-- 把本盘 7 种方块(每型1份，self.pieces)并排摆到盘面上方做开局预览。
-- 幂等、对异步 spawn 安全：根未 spawn 时传送会失败，下一帧由 Update 重试。
-- 子块相对偏移已在开局前 PrimeAllPieces / PrewarmPiece 烘焙好(rot=1)，此处只需传送根，子块随根跟随。
function TetrisRenderer:LayoutShowcasePieces()
    if not self.wholePieceAttach or next(self.pieces) == nil then return end
    local r = TetrisConfig.Render
    local sc = r.Showcase or {}
    local step = r.CellSize + r.CellGap
    local gap = step * (sc.GapCells or 5)          -- 相邻方块间隔（格）
    local height = step * (sc.HeightCells or 13)   -- 盘面上方抬高（格）
    local nf = sc.NormalOffsetM or 0               -- 沿显示法线偏移（米）

    local o = self.origin or r.BoardOrigin
    local right = self.boardRight or { X = 1, Y = 0, Z = 0 }
    -- 显示法线 = right 逆时针转 90° = (-right.Y, right.X)，水平且垂直于 right，已含 BoardFlipAxis180 翻转。
    -- 不可用 boardForward（基于 posYaw，不含翻转，翻转开启时指向盘面内侧）。
    local nrm = { X = -right.Y, Y = right.X, Z = 0 }
    local zShow = o.Z + height

    for t = 1, 7 do
        local p = self.pieces[t]
        if p and p.root then
            -- 子块相对偏移沿 boardRight 烘焙到 rot=1（与下落 placeWholePieceV3 同源：只转根、子块跟随）。
            -- 幂等：根未 spawn 时静默失败，下帧再来；确保即便预热未完成，展示期也能正确挂接并显示。
            for i, child in ipairs(p.children or {}) do
                self:attachChildToRoot(child, p.root)
                local o2 = p.offsets[i]
                if o2 then
                    local rel = Game:ConstructFVectorByLuaTable({ X = right.X * o2.dx * 100, Y = right.Y * o2.dx * 100, Z = o2.dz * 100 })
                    pcall(function() child:K2_SetActorRelativeLocation(rel) end)
                end
            end
            -- 沿盘面 right 居中展开 7 列（t=1..7 → col=0..6，居中以第 4 个为中点）
            local along = (t - 1 - 3) * gap
            local x = o.X + right.X * along + nrm.X * nf
            local y = o.Y + right.Y * along + nrm.Y * nf
            pcall(function() p.root:K2_TeleportTo(cmVec({ X = x, Y = y, Z = zShow }), self.rot) end)
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

    -- 解析 8 种彩色模型引用（供落定方块 / 活动方块换色），缺失则回退单色。
    self:PrepareColorRefs()

    -- 对象池占位（occ 必须先建好，供运行时“取出/归还”落定使用）
    self.occ = {}
    for row = 1, rows do
        self.occ[row] = {}
        for col = 1, cols do
            self.occ[row][col] = nil
        end
    end
    -- 静态方块对象池：先放入探测阶段建的 firstObj，后续由 match 分阶段每 0.25s 补足到 rows*cols。
    self._firstObj = firstObj  -- 探测阶段建的示例 Actor，留作静态池首格复用（避免空建泄漏）
    self.pool = self._firstObj and { self._firstObj } or {}

    -- 消行 parent-shift 用的临时根（EmptyActor）：把要下移的方块挂上去整体位移，移完拆父还原为独立 Actor。
    local rootRef = (type(AssetRef) == "table") and AssetRef[TetrisConfig.Render.PieceRootPresetKey] or nil
    if rootRef then
        self.shiftRoot = CreativeGameAPI.CreateActor(rootRef, Game:ConstructFVectorByLuaTable(self.hideLoc), self.rot, scale, nil)
    end

    self.built = true
    -- 盘面背后 3D UI 挂件：在 Build 阶段（开局构建）即按 SpawnPointKey 解析出的盘面基底直接生成，
    -- 不再等到对象池就绪（Update/poolReady），双盘各在自己的 Build 里生成一个。
    self:BuildBehindBoardWidget()
    if TetrisConfig.Debug.PrintBoardBounds then
        self:PrintBounds()
    end
    -- 注意：方块的实际生成（4*7*2 子块 → 设置 14 个整体 → 方框 → 静态池）由 TetrisMatch:BuildGames
    -- 统一分阶段编排（跨玩家盘+对方盘汇总数量）；Build 只做上述 setup（原点/引用/occ/首格），不在此生成方块。
    return self.mode ~= nil
end

-- ---------------- 生成盘面外边框 ----------------
-- 用 AssetRef[BorderAssetRefKey]（44_CreativeAsset_3400003，与方块同模型）在盘面的
-- 左（虚拟列 0）、右（虚拟列 Cols+1）、下（虚拟行 Rows+1）三侧各生成一排 1 格厚的外边框，
-- 常驻可见（不参与方块显隐）。顶部开放，供方块下落进入。
-- 三侧集合互不重叠，共 Rows + Rows + Cols 块。
function TetrisRenderer:BuildBorder()
    -- 开关关闭：完全不生成外边框（立方体方框），置空并跳过（Update 重试时也不会再创建）
    if TetrisConfig.Render and TetrisConfig.Render.BorderEnabled == false then
        self.border = {}
        self.borderSpecs = {}
        self._borderDisabled = true   -- 边框被配置关闭：标记"故意为空"，供 BorderDone() 视为已完成
        return
    end
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
                            self._borderProbeLogged = true
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
    -- 背后 3D UI 挂件随盘面基底重定位（出生点装置晚注入后基准变化）
    self:ReanchorBehindBoardWidget()
    self:ReanchorFrontBoardWidget()
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

-- 棋盘静态层签名：仅统计已落定（占位）的格子坐标和，用于检测锁定/消行引起的变化。
-- 返回相同值表示静态层无变化，可完全跳过棋盘刷新（零流量）。
function TetrisRenderer:boardSignature(board)
    local rows = TetrisConfig.Board.Rows
    local cols = TetrisConfig.Board.Cols
    local s = 0
    for r = 1, rows do
        for c = 1, cols do
            if board:getCell(r, c) ~= nil then
                s = s + r * 73856093 + c * 19349663
            end
        end
    end
    return s
end

-- 数据驱动刷新：与数据层逐格 diff（读每格 {color,item}），缺失取 Actor 摆放、多余归还池。
-- 下落锁定 / 消除过程 / 消除后 / 垃圾上移 全部走此路：渲染层只把数据层渲染成对应颜色块 + 道具 3D 图。
function TetrisRenderer:ReconcileBoard(board)
    local rows = TetrisConfig.Board.Rows
    local cols = TetrisConfig.Board.Cols
    for r = 1, rows do
        for c = 1, cols do
            local cell = board:getCell(r, c)   -- {color,item} 或 nil(空)
            local a = self.occ[r] and self.occ[r][c]
            if cell and not a then
                local na = self:ProvideStaticBlock(board, r, c)
                if na then
                    self.occ[r][c] = na
                end
            elseif not cell and a then
                self:ReleaseActor(a)      -- 消除/挖空/移位后此格已空 → 回收（含摘除道具 3D UI 子级）
                self.occ[r][c] = nil
            else
                -- 已有块：按当前格颜色重绘（垃圾上升/位移后该格内容可能已变，避免沿用旧色）
                self:PaintCell(a, cell and cell.color or 0)
            end
        end
    end
end

-- 消行已由「两阶段 parent-shift」改为「全数据驱动刷新」：数据层消行(clearLines)改完 grid 后，
-- 渲染层统一走 ReconcileBoard 逐格 diff（释放消除格、补放/重绘/位移幸存格），消除瞬间由 Update
-- 调 PlayClearEffectAt 播特效。原 ReconcileClear/ReconcileClearFall（delta/group/parent-shift 下落动画）
-- 已删除——它们无法跟踪道具爆破打洞、位移右移等单元格/列级改动，是不同步根源。



-- 按数据层刷新：
--   1) 棋盘静态层（已落定方块）只在签名变化时全量同步（锁定/消行），平时零流量；
--   2) 活动方块走整体模式，只传送根 Actor（1 次/帧），不再逐格下发。
-- ---------------- 道具方块：灰色 1×1 方块本体 + 按类型的 3D 浮空图 ----------------
-- 设计：道具作为「单一类别」——方块本体永远是同一个灰色 1×1（与类型无关、可无限扩充），
--       只有头顶的 3D 图按类型区分（PieceImages[type]，新增类型只加一行配置）。
--   1) 方块本体：复用静态方块对象池（AcquireActor/placeActor/PaintCell），外观灰色；
--      活动(掉落)道具用 self._itemBlockActor（从池取一个、按帧摆到活动格），落地后归还池、改由网格 occ 渲染。
--   2) 3D 图：UI Actor 池（_itemWidgetPool）覆盖「所有道具格」（活动格 + 网格内道具格），
--      定位在格子上方针向玩家、按类型换图；落地道具因此也自带 3D 图。
-- 实现要点：cellLocation 返回米；K2_TeleportTo 要厘米(cmVec())+旋转；CreateActor 必须带位置/旋转/缩放。

-- 方块本体：活动(掉落)道具显示为灰色 1×1 块（复用静态方块池）。
function TetrisRenderer:UpdateItemBlock(board)
    local cfg = TetrisConfig.Item
    if not cfg then return end
    if not board or not self.origin then return end
    local active = board:getActive()
    local isItem = active and TetrisConfig.IsItemType(active.type)
    if isItem then
        if not self._itemBlockActor then
            local a = self:AcquireActor()
            if a then self._itemBlockActor = a; self._itemBlockHidden = true end
        end
        if self._itemBlockActor then
            self:placeActor(self._itemBlockActor, active.y, active.x)
            self:PaintCell(self._itemBlockActor, active.type)  -- 道具→灰色
            if self._itemBlockHidden then
                pcall(function() self._itemBlockActor:SetActorHiddenInGame(false) end)
                self._itemBlockHidden = false
            end
        end
    elseif self._itemBlockActor then
        self:ReleaseActor(self._itemBlockActor)  -- 归还池，落地后由网格 occ 接手灰块
        self._itemBlockActor = nil
        self._itemBlockHidden = true
    end
end

-- 3D 浮空图：UI Actor 池，覆盖「所有道具格」（活动格 + 网格内道具格）。
function TetrisRenderer:UpdateItemWidgets(board)
    local dbg = TetrisConfig.Item and TetrisConfig.Item.Debug
    local cfg = TetrisConfig.Item and TetrisConfig.Item.Widget3D
    if dbg and not self._dbgItemCfgLogged then
        self._dbgItemCfgLogged = true
        local ref = (type(CreativeAsset) == "table" and cfg and CreativeAsset[cfg.PresetKey])
                 or (type(AssetRef) == "table" and cfg and AssetRef[cfg.PresetKey])
        print(string.format("[Tetris][DBG 3D] Enabled=%s PresetKey=%s refResolved=%s LiftM=%s FrontOffsetM=%s",
            tostring(cfg and cfg.Enabled), tostring(cfg and cfg.PresetKey), tostring(ref ~= nil), tostring(cfg and cfg.LiftM), tostring(cfg and cfg.FrontOffsetM)))
    end
    if not (cfg and cfg.Enabled) then return end
    if not board or not self.origin then return end
    -- 1) 收集所有道具格及其方块 Actor：活动格→self._itemBlockActor；落地格→self.occ[r][c]（二者不重叠）
    local cells = {}
    local active = board:getActive()
    if active and TetrisConfig.IsItemType(active.type) and self._itemBlockActor then
        local loc = self:cellLocation(active.y, active.x)
        if loc then cells[#cells + 1] = { block = self._itemBlockActor, loc = loc, type = active.type } end
    end
    for r = 1, (board.rows or 0) do
        for c = 1, (board.cols or 0) do
            local v = board:getCell(r, c)
            if TetrisConfig.IsItemType(v) then
                local b = self.occ and self.occ[r] and self.occ[r][c]
                if b then
                    local loc = self:cellLocation(r, c)
                    if loc then cells[#cells + 1] = { block = b, loc = loc, type = v.item } end
                end
            end
        end
    end
    -- 2) 逐个把 3D UI 附加到对应方块（附加到子级；回收时由 ReleaseActor 摘除）
    for i = 1, #cells do
        self:AttachItemUIToBlock(cells[i].block, cells[i].loc, cells[i].type)
    end
    -- 注：本帧不在 cells 的 UI 必随其方块被 ReleaseActor 回收而摘除（见 ReleaseActor）
end

-- 道具浮空图标旋转：与已验证的「背后 3D 挂件」一致，基于盘面偏航 self.boardYaw 让 Widget 平面正面对玩家，
-- 避免用 self.rot（Build 阶段被 makeZeroRotator() 覆盖为 0，会使 Widget 背对/侧对相机而“看不见”）。
function TetrisRenderer:ItemWidgetRot()
    local yaw = self.boardYaw or 0
    if type(FRotator) == "table" and FRotator.MakeFromEuler then
        return FRotator.MakeFromEuler(Game:ConstructFVectorByLuaTable({ X = 0, Y = 0, Z = yaw }))
    end
    return self.rot or makeZeroRotator()
end

-- 取一个空闲的 UI 池条目（已 detach + 隐藏）；池空则新建一个（停停车场、隐藏）。
-- 返回条目 {actor,imgComp,appliedFor,hidden,attachedTo} 或 nil（资源缺失）。
function TetrisRenderer:EnsureFreeItemUI()
    local cfg = TetrisConfig.Item and TetrisConfig.Item.Widget3D
    if not (cfg and cfg.Enabled) then return nil end
    local pool = self._itemWidgetPool or {}
    self._itemWidgetPool = pool
    local e = table.remove(pool)  -- 取一个空闲（已 detach + 隐藏）条目
    if e and e.actor then return e end
    local ref = (type(CreativeAsset) == "table" and CreativeAsset[cfg.PresetKey])
             or (type(AssetRef) == "table" and AssetRef[cfg.PresetKey])
    if not ref then
        if not self._itemWidgetRefLogged then
            self._itemWidgetRefLogged = true
            print(string.format("[Tetris][ItemWidget][WARN] 资源键无引用: %s（请确认已在编辑器注册该 ActorPreset）", tostring(cfg.PresetKey)))
        end
        return nil
    end
    local pos = cmVec(self.hideLoc)
    local rot = self:ItemWidgetRot()
    local scale = Game:ConstructFVectorByLuaTable({ X = 1, Y = 1, Z = 1 })
    local ok, obj = pcall(function()
        if type(CreativeGameAPI) == "table" and CreativeGameAPI.CreateActor then
            return CreativeGameAPI.CreateActor(ref, pos, rot, scale, nil)
        end
        return self:CreateOne(pos, scale, ref, rot)
    end)
    if ok and obj then
        pcall(function() if obj.SetActorHiddenInGame then obj:SetActorHiddenInGame(true) end end)
        e = { actor = obj, imgComp = nil, appliedFor = nil, hidden = true, attachedTo = nil }
    else
        print("[Tetris][ItemWidget][WARN] 创建失败: " .. tostring(obj))
    end
    return e
end

-- 把 3D UI 附加为「方块 block 的子级」（K2_AttachToActor），并每帧传送到方块正前方（朝玩家）。
-- 仅做幂等附件一次；定位/朝向/换图每帧刷新（项目经验：挂载跟随不可靠，故每帧传送兜底）。
-- 回收：方块被 ReleaseActor 时自动 K2_DetachFromActor 摘除（见 ReleaseActor）。
function TetrisRenderer:AttachItemUIToBlock(block, loc, pieceType)
    local cfg = TetrisConfig.Item and TetrisConfig.Item.Widget3D
    local dbg = TetrisConfig.Item and TetrisConfig.Item.Debug
    if not (cfg and block) then return end
    self._itemUIByBlock = self._itemUIByBlock or {}
    local e = self._itemUIByBlock[block]
    if not e then
        e = self:EnsureFreeItemUI()
        if not e then return end
        pcall(function() e.actor:K2_AttachToActor(block, "", 1, 1, 1, false) end)  -- 附加到子级（幂等）
        e.attachedTo = block
        self._itemUIByBlock[block] = e
    end
    -- 定位：方块「正前方（朝玩家）」+ 垂直偏移（基于 cellLocation，与方块同基准）
    local fwd = self.boardForward
    local front = (cfg.FrontOffsetM ~= nil) and cfg.FrontOffsetM or 1.0
    local lift = (cfg.LiftM ~= nil) and cfg.LiftM or 0.0
    local tx = (loc.X or 0)
    local ty = (loc.Y or 0)
    local tz = (loc.Z or 0)
    if fwd then
        tx = tx - (fwd.X or 0) * front
        ty = ty - (fwd.Y or 0) * front
    end
    tz = tz + lift
    local rot = self:ItemWidgetRot()
    pcall(function() e.actor:K2_TeleportTo(cmVec({ X = tx, Y = ty, Z = tz }), rot) end)
    self:SetItemWidgetImageFor(e, pieceType)
    if e.hidden then
        pcall(function() e.actor:SetActorHiddenInGame(false) end)
        e.hidden = false
    end
end

-- 按《3D-UI 组件使用指南》verified 链路，给某个 UI 池条目换图。
-- 控件对象级 imgComp:SetImageContent(AssetRef 句柄)，无 UUID/ps；取组件在 pawn 就绪前每帧重试、命中后缓存。
-- 注意：参数名用 pieceType，避免遮蔽全局 type() 函数。
function TetrisRenderer:SetItemWidgetImageFor(e, pieceType)
    local cfg = TetrisConfig.Item and TetrisConfig.Item.Widget3D
    local dbg = TetrisConfig.Item and TetrisConfig.Item.Debug
    local a = e and e.actor
    if not (cfg and a) then return end
    local key = TetrisConfig.PieceImages and TetrisConfig.PieceImages[pieceType]
    local imgID = (type(AssetRef) == "table" and key) and AssetRef[key] or nil
    if dbg and not e._dbgImgLogged then
        e._dbgImgLogged = true
        print(string.format("[Tetris][DBG 3D] image(idx=%s) pieceType=%s key=%s imgID=%s",
            tostring(e.idx), tostring(pieceType), tostring(key), tostring(imgID)))
    end
    if not imgID then return end
    if not e.imgComp and cfg.ImageChildName then
        local wc
        pcall(function()
            if type(a.GetComponentByClass) == "function" then
                wc = a:GetComponentByClass("WidgetComponent")
            end
        end)
        if not wc then
            for _, nm in ipairs({ "UI", "Widget", "WidgetComp", "WidgetComponent" }) do
                local ok2, c = pcall(function() return a:GetComponentByName(nm) end)
                if ok2 and c then wc = c; break end
            end
        end
        if dbg and not e._dbgWC then e._dbgWC = true
            print(string.format("[Tetris][DBG 3D] pool WidgetComponent(idx=%s)=%s", tostring(e.idx), tostring(wc ~= nil))) end
        if wc then
            local plist
            pcall(function() plist = Game:GetAllPlayerPawns() end)
            if plist and type(plist.Num) == "function" and plist:Num() > 0 then
                local uw
                for j = 0, plist:Num() - 1 do
                    local pawn = plist:Get(j)
                    if pawn then
                        pcall(function() uw = wc:GetUserWidgetObject(pawn) end)
                        if not uw then pcall(function() uw = wc:GetWidget(pawn) end) end
                        if uw then break end
                    end
                end
                if dbg then print(string.format("[Tetris][DBG 3D] UserWidget(idx=%s)=%s", tostring(e.idx), tostring(uw ~= nil))) end
                if uw and cfg.ImageChildName then
                    pcall(function() e.imgComp = uw:GetWidgetFromName(cfg.ImageChildName) end)
                    if dbg and not e._dbgIC then e._dbgIC = true
                        print(string.format("[Tetris][DBG 3D] pool imgComp(idx=%s, %s)=%s", tostring(e.idx), tostring(cfg.ImageChildName), tostring(e.imgComp ~= nil))) end
                end
            elseif dbg then
                print("[Tetris][DBG 3D] GetAllPlayerPawns 为空（首帧？）下一帧重试")
            end
        end
    end
    -- 换图：imgComp:SetImageContent(AssetRef 句柄)。控件就绪且本类型尚未应用时才设置。
    if e.imgComp and e.appliedFor ~= pieceType then
        local ok = pcall(function() e.imgComp:SetImageContent(imgID) end)
        if ok then e.appliedFor = pieceType end
        if dbg and not e._dbgSetLogged then e._dbgSetLogged = true
            print(string.format("[Tetris][DBG 3D] pool SetImageContent(idx=%s) ok=%s type=%s", tostring(e.idx), tostring(ok), tostring(pieceType))) end
    end
end

-- 取本地玩家 PlayerState（CustomUI 个性化需要；渲染层无 GetPlayerState，从 Game:GetAllPlayerStates 取首个并缓存）
function TetrisRenderer:GetLocalPlayerState()
    if self._localPS then return self._localPS end
    local ok, arr = pcall(function() return Game:GetAllPlayerStates() end)
    if ok and arr and arr.Num and arr:Num() > 0 then
        self._localPS = arr:Get(0)
    end
    return self._localPS
end

function TetrisRenderer:Update(board, running)
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
    -- 对象池就绪后一次性生成远景背景墙（此时 self.mode/rot/basis 均已稳定，避免异步丢块）
    if self.poolReady and not self._wallBuilt then
        self._wallBuilt = true
        self:BuildBackgroundWall()
    end
    -- 兜底生成盘面背后 3D UI 挂件：Build 阶段（开局第一帧）若 AssetRef 尚未注册该 ActorPreset 会失败，
    -- 这里 poolReady 后再次尝试；函数内有 _behindWidgetActor 幂等保护，已生成则跳过，不会重复创建。
    self:BuildBehindBoardWidget()
    -- 兜底生成盘面前方 3D 大框（BigFrame3D）：同样幂等，AssetRef 晚注册时在此重试。
    self:BuildFrontBoardWidget()

    -- 盘面前方 3D 大框 Hold/Next/backlight：每帧按 running 显隐（初始/暂停/结束隐藏，方块下落时显示）。
    -- 直接操作图片控件对象（SetImageContent/SetImageColor/SetVisible），与背后盘面一致；不依赖 ps，AI 盘也在此路径刷新。
    if self._frontWidgetActor and TetrisConfig.BigFrame3D and TetrisConfig.BigFrame3D.Enabled then
        if running == true then
            local ht = board:getHoldType()
            local nq = board:getNextQueue()
            local nt = (nq and nq[1]) or nil
            self:SetFrontWidgetHoldNext(ht, nt)
            self:SetFrontBacklight(board.attackBonusNext and board.attackBonusNext > 0)
        else
            self:SetFrontWidgetHoldNext(nil, nil)   -- 隐藏 Hold/Next
            self:SetFrontBacklight(false)           -- 隐藏攻势高亮
        end
    end

    -- 分帧补齐 21 个整体实例（BuildWholePiecePool 起的异步构建），未完成前逐帧建少量，避免初始化卡顿。
    if self._poolBuild then self:ProcessPoolBuild() end

    -- 启动前预热：逐帧把所有 7 种整体实例附着并就绪；全部 _everReady 后才允许渲染活动块。
    -- CreateActor 异步、首帧附着可能失败，故每帧幂等重试，直到实例真正建好（通常几帧内完成）。
    self:PrimeAllPieces()

    -- 边框延迟创建：Build 时 InstanceAPI 可能未注入或实例创建暂时失败，重试直到成功（上限若干帧）。
    -- 每 5 帧才真正尝试一次（探测开销较大）；成功后强制重摆若干帧，确保对齐当前基准。
    if (not self.border or #self.border == 0) and (self._borderRetry or 0) < 30 and not self._borderDisabled then
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

    -- 静态层：数据驱动刷新。仅在盘面数据变化（锁定/消除/垃圾，boardSignature 变化）时全量 diff。
    -- 三阶段（board.stage）：fall(下落) / clearing(消除过程) / settle(消除后)——消除过程与消除后均由数据层驱动渲染。
    -- 消除瞬间（clearing→settle，数据层已改完 grid）按消除行播消行特效；下落块由下方 RenderActivePiece 单独渲染。
    if self.poolReady then
        local sig = self:boardSignature(board)
        if sig ~= self.lastBoardSig then
            local cleared = board:consumeClearedRows()
            if cleared and #cleared > 0 then
                for _, cr in ipairs(cleared) do self:PlayClearEffectAt(cr) end
            end
            -- 爆破竖版特效：在该列最下方块处由下往上播放竖版光束
            local blastFx = board:consumeBlastFx()
            if blastFx then
                for _, bf in ipairs(blastFx) do self:PlayBlastEffectAt(bf.col, bf.bottom, bf.top) end
            end
            -- 位移特效：在位移块所在行播放横向特效（数据层行号，不依赖方块）
            local shiftFx = board:consumeShiftFx()
            if shiftFx then
                for _, srow in ipairs(shiftFx) do self:PlayShiftEffectAt(srow) end
            end
            if TetrisConfig.Debug then
                print(string.format("[Tetris][DBG] Update刷新: sig变化 stage=%s 消行=%d -> ReconcileBoard(数据驱动)",
                    tostring(board:getStage()), cleared and #cleared or 0))
            end
            self:ReconcileBoard(board)   -- 全数据驱动：释放消除格、补放/重绘/位移幸存格
            self.lastBoardSig = sig
        end
    end

    -- 活动方块整体层（位移/旋转只传根）
    self:RenderActivePiece(board)

    -- 道具方块：灰色 1×1 方块本体（活动掉落块，复用静态方块池）+ 头顶 3D 浮空图（池，覆盖活动格与落地格）
    self:UpdateItemBlock(board)
    self:UpdateItemWidgets(board)

    -- 下一/Hold 预览已改用 2D 图片展示（见 TetrisGame:UpdateHoldNextUI），此处不再生成 3D 静态方块。

    if TetrisConfig.Debug.PrintGrid then
        local want = {}
        for r = 1, rows do
            want[r] = {}
            for c = 1, cols do
                want[r][c] = (board:getCell(r, c) ~= nil)
            end
        end
        self:PrintGrid(want)
    end
    if TetrisConfig.Debug.DumpCellStatus and (self.frame % 30 == 0) then
        local want = {}
        for r = 1, rows do
            want[r] = {}
            for c = 1, cols do
                want[r][c] = (board:getCell(r, c) ~= nil)
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
    -- 活动道具方块（不在 occ 内）：归还并摘除其附加的 3D UI 子级
    if self._itemBlockActor then
        self:ReleaseActor(self._itemBlockActor)
        self._itemBlockActor = nil
        self._itemBlockHidden = true
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
