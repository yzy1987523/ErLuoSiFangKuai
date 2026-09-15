-- 渲染层：把数据层状态映射为 3D 方块的显隐。
-- 设计要点（与数据层解耦）：
--   1. 开局一次性创建 Cols x Rows 个方块，全部隐藏；
--   2. 之后不再移动任何方块，只在数据变化时切换显隐（脏检查，只改变化的格子）；
--   3. 颜色暂为单色（引擎无运行时改材质接口，多色需预着色模型）。
--
-- 创建方式在运行时自动探测：不同预设类型对应不同 API，且 Core/LuaHint 未必加载，
-- 因此首格试遍候选组合，选中后再批量创建其余格子。
local TetrisConfig = require("EnvLua.Server.Tetris.TetrisConfig")

local TetrisRenderer = {}
TetrisRenderer.__index = TetrisRenderer

function TetrisRenderer:new()
    local o = setmetatable({}, TetrisRenderer)
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

function TetrisRenderer:ResolveOrigin()
    local r = TetrisConfig.Render
    local base = r.BoardOrigin
    local src = "BoardOrigin"

    if r.AnchorToPlayer then
        local p = getLocalPawnLocationM()
        if p then
            base = {
                X = p.X + r.AnchorOffset.X,
                Y = p.Y + r.AnchorOffset.Y,
                Z = p.Z + r.AnchorOffset.Z,
            }
            src = "玩家锚点"
        else
            print("[Tetris][WARN] 未取到玩家 pawn，锚定失败，回退使用 BoardOrigin")
        end
    end

    print(string.format("[Tetris] 盘面锚点来源=%s 左上角=(%.2f, %.2f, %.2f)",
        src, base.X, base.Y, base.Z))
    return base
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
    return {
        X = o.X + (col - 1) * step,
        Y = o.Y,
        Z = o.Z - (row - 1) * step,
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
    if a then return a end
    local s = TetrisConfig.Render.BlockScale
    local scale = Game:ConstructFVectorByLuaTable({ X = s, Y = s, Z = s })
    return self:CreateOne(Game:ConstructFVectorByLuaTable(self.hideLoc), scale, self.refTop)
end

-- 归还方块 Actor 到对象池（停回停车场，保持可见但脱离盘面）。
function TetrisRenderer:ReleaseActor(a)
    if a then
        pcall(function() a:K2_TeleportTo(cmVec(self.hideLoc), self.rot) end)
        self.pool[#self.pool + 1] = a
    end
end

-- 把独立方块 Actor 放到 (row,col) 的世界坐标（静态摆放，不依赖附着）。
function TetrisRenderer:placeActor(a, row, col)
    if not a then return end
    pcall(function() a:K2_TeleportTo(cmVec(self:cellLocation(row, col)), self.rot) end)
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
    return {
        X = o.X + (active.x + pc - 2) * step,
        Y = o.Y,
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
        self:BuildActivePiecesV3()
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

-- 方案3：每类 1 个隐形根 Actor + 4 个方块子 Actor 附着在根上。
-- 子 Actor 是真实 Actor，附着关系会被复制；根一动，4 子随根原子跟随（统一运动 + 1/4 流量）。
-- 相对偏移在构建时按其 rot=1 形状烘焙（KeepWorld 附着 → 子相对根 = 偏移量），旋转通过对根设 Pitch 实现。
function TetrisRenderer:BuildActivePiecesV3()
    local rootRef = (type(AssetRef) == "table") and AssetRef[TetrisConfig.Render.PieceRootPresetKey] or nil
    local childRef = (type(AssetRef) == "table") and AssetRef[TetrisConfig.Render.PieceChildPresetKey] or nil
    if not rootRef or not childRef then
        print("[Tetris][WARN] 整体方块(方案3)资源未就绪(root/child 预设需在编辑器注册并执行 update preset)，回退方案1")
        self:BuildActivePiecesV1()
        return
    end
    local step = TetrisConfig.Render.CellSize + TetrisConfig.Render.CellGap
    local s = TetrisConfig.Render.BlockScale
    local scale = Game:ConstructFVectorByLuaTable({ X = s, Y = s, Z = s })
    local park = self.hideLoc
    local rot0 = self.rot
    local built = 0

    for t = 1, 7 do
        local shape = TetrisConfig.Pieces[t] and TetrisConfig.Pieces[t].shape
        if not shape then
            print("[Tetris][WARN] 整体方块(方案3)类型 " .. t .. " 无 shape，跳过")
        else
            local pr, pc = self:piecePivot(t)
            -- rot=1 形状相对「旋转轴心」的局部偏移（米）
            local offs = {}
            for r = 1, #shape do
                for c = 1, #shape do
                    if shape[r][c] == 1 then
                        offs[#offs + 1] = { dx = (c - pc) * step, dz = -((r - pr) * step) }
                    end
                end
            end
            -- 隐形根 Actor 停在停车场（矩阵中心 = 旋转枢轴）
            local root = CreativeGameAPI.CreateActor(rootRef, Game:ConstructFVectorByLuaTable(park), rot0, scale, nil)
            if not root then
                print("[Tetris][WARN] 整体方块(方案3)根 Actor 创建失败，回退方案1")
                self:BuildActivePiecesV1()
                return
            end
            pcall(function() root:SetActorHiddenInGame(false) end)  -- EmptyActor 无网格→渲染仍隐形；不传播隐藏给子 Actor
            local children = {}
            local okAll = true
            for _, o in ipairs(offs) do
                -- 子 Actor 先建在「根世界位置 + 偏移」处（暂不附着）
                local cw = Game:ConstructFVectorByLuaTable({ X = park.X + o.dx, Y = park.Y, Z = park.Z + o.dz })
                local child = CreativeGameAPI.CreateActor(childRef, cw, rot0, scale, nil)
                if not child then okAll = false break end
                children[#children + 1] = child
            end
            if not okAll then
                print("[Tetris][WARN] 整体方块(方案3)子 Actor 创建失败，回退方案1")
                self:BuildActivePiecesV1()
                return
            end
            -- attached 留待首次放置时再做：根 Actor 是异步 spawn 的，构建后立即附着对前几个类型会静默失败
            -- （子 Actor 变孤儿、不跟随根 → 表现为「部分方块不整体运动」）。放置时根已 spawn 完，附着必成功。
            self.pieces[t] = { root = root, children = children, offsets = offs, attached = false, type = t }
            built = built + 1
        end
    end
    self.wholePieceAttach = (built > 0)
    print("[Tetris] 整体活动方块(方案3 附着子Actor)已构建: " .. built .. "/7（根+4子Actor，移动只传根→原子跟随）")
end

-- 方案3：只传送根 Actor（平移单变换，保留 V3 的 1/4 流量优势）；
-- 旋转/换型时把子 Actor 相对偏移烘焙成与数据层 rotateMatrixCW「完全一致」的方向（rotateOffset）。
-- 关键修复：根保持零旋转，不再用引擎 Pitch（MakeFromEuler 的 Y 分量是 Yaw/绕 Z 轴，与盘面绕 Y 轴旋转
-- 不是同一轴，且旋转方向约定与数据层矩阵 CW 不一致），否则旋转后子块世界坐标 ≠ cellLocation(数据格)，
-- 落地瞬间整块跳位。
-- 判定整体方块是否“完整”：所有子 Actor 已正确跟随根
-- （世界位置 ≈ 根位置 + 旋转后的相对偏移，容差 5cm）。
-- 用于在下落前确认方块已完整，避免“根已就位、子块还停在停车场”的半成品帧。
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
            local exX = rl.X + dx * 100
            local exZ = rl.Z + dz * 100
            if math.abs(cl.X - exX) > 5 or math.abs(cl.Z - exZ) > 5 then
                ok = false return
            end
        end
    end)
    return ok
end

-- 无条件幂等重试：把整体方块的 4 个子 Actor 附着到根，并烘焙当前 rot 的相对偏移。
-- 每帧调用都安全：K2_AttachToActor 幂等；根未 spawn 时附着静默失败，下一帧再来，直到成功。
-- 重烘焙消除“先传送根再附着导致相对偏移错乱（子块永久停在停车场）”的隐患。
function TetrisRenderer:EnsureWholePieceAttached(p, active)
    if not p or not p.root or not p.children then return end
    local rot = active and active.rot or 1
    for i, child in ipairs(p.children) do
        pcall(function() child:K2_AttachToActor(p.root, "", 1, 1, 1, false) end)
        local o = p.offsets[i]
        if o then
            local dx, dz = self:rotateOffset(o.dx, o.dz, rot)
            pcall(function()
                child:K2_SetActorRelativeLocation(
                    Game:ConstructFVectorByLuaTable({ X = dx * 100, Y = 0, Z = dz * 100 }))
            end)
        end
    end
end

-- 预热（下落前生成好 1 个方块）：在活动方块下落期间，把“下一个方块”的根 Actor spawn 完成、
-- 4 个子 Actor 附着并烘焙到 rot=1 偏移，使其真正成为活动方块时已是完整整体，消除首次出现的半成品帧。
-- 无条件幂等：根未 spawn / 子块未跟随时静默失败，每帧重试，直至就绪；期间整体隐藏在停车场外。
function TetrisRenderer:PrewarmPiece(type)
    if not self.wholePieceAttach or not type then return end
    local p = self.pieces[type]
    if not p or not p.root then return end
    self:EnsureWholePieceAttached(p, { rot = 1 })
    pcall(function() p.root:K2_TeleportTo(cmVec(self.hideLoc), self.rot) end)
    pcall(function() p.root:SetActorHiddenInGame(true) end)
    for _, child in ipairs(p.children or {}) do
        pcall(function() child:SetActorHiddenInGame(true) end)
    end
end

-- 预热下一个方块（读取数据层预览队列的首个类型）
function TetrisRenderer:PrewarmNext(board)
    if self.previewing then return end  -- 预览期由 LayoutShowcasePieces 统一附着，勿抢回停车场
    if not self.wholePieceAttach or not TetrisConfig.Render.UseWholePiece then return end
    local nq = board and board:getNextQueue()
    if not nq or not nq[1] then return end
    -- 关键：若下一个方块与当前活动方块同型（7-bag 边界处可能相邻同型），
    -- 其根与活动方块是同一套，预热会把它传送到停车场并隐藏，导致活动方块消失。故跳过。
    local act = board:getActive()
    if act and act.type == nq[1] then return end
    self:PrewarmPiece(nq[1])
end

function TetrisRenderer:placeWholePieceV3(p, active)
    if not p or not p.root then return end
    local center = self:pieceCenterWorld(active)

    -- 无条件幂等重试：每帧重新附着 + 重烘焙相对偏移（确保相对偏移永远正确，与根位置无关）。
    self:EnsureWholePieceAttached(p, active)

    -- 先把根定位到 spawn（若已附着，子块随根到 spawn；若未附着，上面重烘焙已把子块直接放到 spawn+偏移）。
    pcall(function() p.root:K2_TeleportTo(cmVec(center), self.rot) end)

    -- 就绪判定：子块世界位置 ≈ 根 + 偏移 → 已完整跟随。
    -- 未就绪（根尚未 spawn / 子块未跟随）：整体隐藏，玩家看不到半成品，下一帧继续。
    if not self:isWholePieceReady(p, active) then
        pcall(function() p.root:SetActorHiddenInGame(true) end)
        for _, child in ipairs(p.children or {}) do
            pcall(function() child:SetActorHiddenInGame(true) end)
        end
        return
    end

    -- 就绪：显示整体方块
    pcall(function() p.root:SetActorHiddenInGame(false) end)
    for _, child in ipairs(p.children or {}) do
        pcall(function() child:SetActorHiddenInGame(false) end)
    end
    p.lastRot = active.rot
    p.lastType = active.type

    -- 诊断（逐类型，每局每种仅一次）：确认子 Actor 跟随根、旋转正确（服务端视角）
    if TetrisConfig.Debug and not (self._v3DiagDone and self._v3DiagDone[p.type]) then
        self._v3DiagDone = self._v3DiagDone or {}
        self._v3DiagDone[p.type] = true
        pcall(function()
            local c1 = p.children[1]
            local wl = c1 and c1:K2_GetActorLocation()
            if wl then
                local dx, dz = self:rotateOffset(p.offsets[1].dx, p.offsets[1].dz, active.rot)
                print(string.format(
                    "[Tetris][V3] type=%d 子#1 实world=(%.0f,%.0f,%.0f) 期望≈(%.0f,?,%.0f) rot=%d",
                    p.type, wl.X, wl.Y, wl.Z, (center.X + dx) * 100, (center.Z + dz) * 100, active.rot))
            end
        end)
    end
end

-- 方案3：根 Actor 归位（子 Actor 随根回停车场）
function TetrisRenderer:parkWholePieceV3(p)
    if not p or not p.root then return end
    pcall(function() p.root:K2_TeleportTo(cmVec(self.hideLoc), self.rot) end)
end

-- 方案1：用统一变换把 4 个子 Actor 定位到当前位置
function TetrisRenderer:placePieceChildren(p, active)
    if not p or not p.cells then return end
    local center = self:pieceCenterWorld(active)
    for i, off in ipairs(p.offsets) do
        local dx, dz = self:rotateOffset(off.dx, off.dz, active.rot)
        local wloc = { X = center.X + dx, Y = center.Y, Z = center.Z + dz }
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
    if self.previewing then return end  -- 预览阶段由 ShowcasePieces 接管，不渲染活动方块
    if not TetrisConfig.Render.UseWholePiece or next(self.pieces) == nil then return end
    local active = board:getActive()
    local wantType = active and active.type or nil

    if self.wholePieceAttach then
        if wantType == self.shownPieceType then
            if active then
                local p = self.pieces[wantType]
                if p then self:placeWholePieceV3(p, active) end
            end
            return
        end
        if self.shownPieceType and self.pieces[self.shownPieceType] then
            self:parkWholePieceV3(self.pieces[self.shownPieceType])
        end
        if wantType and self.pieces[wantType] then
            self:placeWholePieceV3(self.pieces[wantType], active)
        end
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
    if not self.wholePieceAttach or next(self.pieces) == nil then return end
    self.previewing = true
    self.shownPieceType = nil
    self._showcaseDiagDone = false
    -- 立即尝试一次；若 7 个模板的根 Actor 尚未 spawn（CreateActor 异步），附着会失败，
    -- 由 Update 在预览期每帧调用 LayoutShowcasePieces 重试，直至全部附着成功。
    self:LayoutShowcasePieces()
    print(string.format("[Tetris] 开局预览：7 种方块已摆在面前，%.0f 秒后开始下落", seconds or 10))
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
    local midX = o.X + (TetrisConfig.Board.Cols - 1) * step / 2  -- 盘面横向中心
    local zShow = o.Z + step * 2               -- 盘面上方两行处（Z 越大越高）
    for t = 1, 7 do
        local p = self.pieces[t]
        if p and p.root then
            -- 每帧无条件重试附着（AttachToActor 幂等；根未 spawn 时静默失败，下帧再来）
            for i, child in ipairs(p.children or {}) do
                pcall(function() child:K2_AttachToActor(p.root, "", 1, 1, 1, false) end)
                local o2 = p.offsets[i]
                if o2 then
                    local relLoc = Game:ConstructFVectorByLuaTable({ X = o2.dx * 100, Y = 0, Z = o2.dz * 100 })
                    pcall(function() child:K2_SetActorRelativeLocation(relLoc) end)
                end
            end
            local cx = midX + (t - 4) * gap     -- t=1..7 → 居中对称展开
            pcall(function() p.root:K2_TeleportTo(cmVec({ X = cx, Y = o.Y, Z = zShow }), self.rot) end)
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
    self.shownPieceType = nil
    print("[Tetris] 预览结束")
end

-- ---------------- 创建全部格子并隐藏 ----------------
function TetrisRenderer:Build()
    if self.built then return true end

    local cols = TetrisConfig.Board.Cols
    local rows = TetrisConfig.Board.Rows
    local s = TetrisConfig.Render.BlockScale
    self.origin = self:ResolveOrigin()
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
    if not self.origin then
        print("[Tetris][WARN] 边框生成失败：盘面原点未初始化")
        return
    end
    local cols, rows = TetrisConfig.Board.Cols, TetrisConfig.Board.Rows
    local r = TetrisConfig.Render
    local step = r.CellSize + r.CellGap
    local s = r.BlockScale
    local scale = Game:ConstructFVectorByLuaTable({ X = s, Y = s, Z = s })
    local ref = (type(AssetRef) == "table") and AssetRef[TetrisConfig.Render.BorderAssetRefKey] or nil
    if not ref then
        print("[Tetris][WARN] 边框资源 AssetRef[\"" .. tostring(TetrisConfig.Render.BorderAssetRefKey) .. "\"] 为空，跳过边框生成")
        return
    end

    local o = self.origin

    -- 创建单个边框格子：优先 Actor 模式（与场景方块一致、无实例池上限），失败回退动态实例
    local function makeBorder(x, z)
        local loc = Game:ConstructFVectorByLuaTable({ X = x, Y = o.Y, Z = z })
        local ok, obj = pcall(function()
            return CreativeGameAPI.CreateActor(ref, loc, self.rot, scale, nil)
        end)
        if ok and obj then
            pcall(function() obj:SetActorHiddenInGame(false) end)
            self.border[#self.border + 1] = obj
            return
        end
        local ok2, obj2 = pcall(function()
            return InstanceAPI.CreateInstance(ref, loc, self.rot, scale)
        end)
        if ok2 and obj2 then
            pcall(function()
                if InstanceAPI.ToggleInstanceVisible then InstanceAPI.ToggleInstanceVisible(obj2, true) end
            end)
            self.border[#self.border + 1] = obj2
        else
            print("[Tetris][WARN] 边框格子创建失败 @(" .. tostring(x) .. "," .. tostring(z) .. ")")
        end
    end

    -- 左、右两侧：每行一块
    for row = 1, rows do
        local z = o.Z - (row - 1) * step
        makeBorder(o.X + (0 - 1) * step, z)          -- 左（虚拟列 0）
        makeBorder(o.X + (cols + 1 - 1) * step, z)   -- 右（虚拟列 Cols+1）
    end
    -- 下侧：每列一块（虚拟行 Rows+1）
    for col = 1, cols do
        local x = o.X + (col - 1) * step
        makeBorder(x, o.Z - (rows + 1 - 1) * step)
    end

    print("[Tetris] 边框格子创建完成: " .. #self.border .. "/" .. (rows + rows + cols)
          .. "（左/右/下三侧，常驻可见）")
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

-- 消行重排：数据层权威。利用 board:consumeClearedRows() 给出的被消行，
-- 把「会下落的方块」按下移行数 delta 分组，挂到 parent-shift 根整体下移，移完拆父还原为独立 Actor；
-- 被消行的方块归还对象池；本次锁定的新增格从池取 Actor 静态摆放。
function TetrisRenderer:ReconcileClear(board, clearedRows)
    local rows = TetrisConfig.Board.Rows
    local cols = TetrisConfig.Board.Cols
    local step = TetrisConfig.Render.CellSize + TetrisConfig.Render.CellGap

    -- 1) 快照旧占用表；被消行的方块直接归还池
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
    end

    -- 2) 计算每个最终格的来源旧行：newRow = oldRow + delta(oldRow)，delta = 该格上方被消行数。
    --    delta>0 的方块走 parent-shift；delta==0（未动）保留原位；无对应旧 Actor 的=本次锁定的新增格。
    local groups = {}        -- groups[delta] = { {a, nr, c}, ... }
    local newlyLocked = {}   -- { {r, c} }
    for r = 1, rows do
        for c = 1, cols do
            if board:getCell(r, c) ~= 0 then
                local delta = 0
                for cr, _ in pairs(clearedSet) do
                    if cr < r then delta = delta + 1 end
                end
                local oldRow = r - delta
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

    -- 3) parent-shift：每个 delta 组挂到临时根整体下移，再拆父还原独立 Actor
    if self.shiftRoot then
        for delta, list in pairs(groups) do
            -- 根先归位到停车场，确保子 Actor 以 KeepWorld 挂上时相对偏移正确
            pcall(function() self.shiftRoot:K2_TeleportTo(cmVec(self.hideLoc), self.rot) end)
            for _, it in ipairs(list) do
                pcall(function() it.a:K2_AttachToActor(self.shiftRoot, "", 1, 1, 1, false) end)
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

    -- 4) 本次锁定的新增格：从池取 Actor 静态摆放
    for _, nl in ipairs(newlyLocked) do
        local a = self:AcquireActor()
        if a then
            self:placeActor(a, nl.r, nl.c)
            self.occ[nl.r][nl.c] = a
        end
    end

    if TetrisConfig.Debug then
        print(string.format(
            "[Tetris][Clear] 消%d行 parent-shift 完成（动态组=%d 新增格=%d 池余=%d）",
            #clearedRows, (function() local n=0 for _ in pairs(groups) do n=n+1 end return n end)(),
            #newlyLocked, #self.pool))
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

    local rows = TetrisConfig.Board.Rows
    local cols = TetrisConfig.Board.Cols

    -- 静态层：仅在盘面数据变化（锁定/消行）时重排；且仅在对象池就绪后
    if self.poolReady then
        local sig = self:boardSignature(board)
        if sig ~= self.lastBoardSig then
            local cleared = board:consumeClearedRows()
            local garbageMoved = board:consumedGarbageMoved()
            if cleared and #cleared > 0 and not garbageMoved and TetrisConfig.Render.UseParentShiftOnClear then
                self:ReconcileClear(board, cleared)
            else
                self:ReconcileBoard(board)
            end
            self.lastBoardSig = sig
        end
    end

    -- 活动方块整体层（位移/旋转只传根）
    self:RenderActivePiece(board)

    -- 下落前预热下一个方块（根 spawn + 子块附着 + 烘焙偏移），使其成为活动方块时已是完整整体，
    -- 消除“新方块首次出现、根还没生成完、子块还没跟随”的缺格半成品帧。每帧无条件幂等重试。
    self:PrewarmNext(board)

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
end

return TetrisRenderer
