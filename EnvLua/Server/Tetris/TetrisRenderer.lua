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
    o.built = false
    o.mode = nil    -- "instance" | "actor"
    o.ref = nil
    o.rot = nil
    o.createFailLogged = false
    o.visibleFailLogged = false
    o.frame = 0          -- 刷新次数，用于稳定期判定
    o.actorCount = 0     -- 已成功解析的底层 Actor 数
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

-- 显隐：优先用底层 Actor 的 SetActorHiddenInGame（最可靠）；
-- 取不到 Actor 时退回实例层的 ToggleInstanceVisible。
function TetrisRenderer:ApplyVisible(row, col, visible)
    -- InvertVisible：个别实例的显隐语义与文档相反时的翻转开关
    local vs = visible
    if TetrisConfig.Render.InvertVisible then vs = not vs end

    local actor = self:EnsureActor(row, col)
    if actor then
        local pok, perr = pcall(function() actor:SetActorHiddenInGame(not vs) end)
        if not pok and not self.visibleFailLogged then
            self.visibleFailLogged = true
            print("[Tetris][WARN] Actor 隐藏失败: " .. tostring(perr))
        end
        return
    end

    local obj = self.cells[row] and self.cells[row][col]
    if not obj then return end
    local ok, err = pcall(function()
        if self.mode == "instance" then
            InstanceAPI.ToggleInstanceVisible(obj, vs)
            -- 兜底：部分实例类型对 ToggleInstanceVisible 无响应，改用缩放为 0 隐藏。
            -- 缩放按"我们的意图"走，不受语义翻转影响。
            if TetrisConfig.Render.UseScaleToHide then
                local s = visible and TetrisConfig.Render.BlockScale or 0.0
                InstanceAPI.SetInstanceScale(obj, Game:ConstructFVectorByLuaTable({ X = s, Y = s, Z = s }))
            end
        else
            obj:SetActorHiddenInGame(not vs)
        end
    end)
    if not ok and not self.visibleFailLogged then
        self.visibleFailLogged = true
        print("[Tetris][WARN] 显隐设置失败: " .. tostring(err))
    end
end

-- ---------------- 创建全部格子并隐藏 ----------------
function TetrisRenderer:Build()
    if self.built then return true end

    local cols = TetrisConfig.Board.Cols
    local rows = TetrisConfig.Board.Rows
    local s = TetrisConfig.Render.BlockScale
    self.origin = self:ResolveOrigin()
    self.rot = makeZeroRotator()

    local scale = Game:ConstructFVectorByLuaTable({ X = s, Y = s, Z = s })
    local keyTop = TetrisConfig.Render.BlockAssetRefKey
    local keyBottom = TetrisConfig.Render.BlockAssetRefKeyBottom
    local candTop = collectRefCandidates(keyTop)
    local candBottom = collectRefCandidates(keyBottom)
    print(string.format("[Tetris] 资源引用候选: 上区=%d 下区=%d", #candTop, #candBottom))

    local loc0 = Game:ConstructFVectorByLuaTable(self:cellLocation(1, 1))
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

    for row = 1, rows do
        self.cells[row] = {}
        self.actors[row] = {}
        self.shown[row] = {}
        for col = 1, cols do
            self.cells[row][col] = nil
            self.actors[row][col] = nil
            self.shown[row][col] = nil   -- nil = 尚未同步，确保首帧必定下发一次隐藏
        end
    end

    -- 注意：此处【不】下发任何显隐指令。实例刚创建时底层对象尚未生成，
    -- 此时的隐藏请求会被静默丢弃，改由 Update 在稳定期内反复下发。
    self.cells[1][1] = firstObj

    local okCount = 1   -- 首格已在探测阶段创建成功
    local splitRow = math.ceil(rows / 2)   -- 顶半区用上区资源，底半区用下区资源
    for row = 1, rows do
        for col = 1, cols do
            if not (row == 1 and col == 1) then
                local loc = Game:ConstructFVectorByLuaTable(self:cellLocation(row, col))
                local ref = (row <= splitRow) and self.refTop or self.refBottom
                local obj = self:CreateOne(loc, scale, ref)
                if obj then
                    self.cells[row][col] = obj
                    okCount = okCount + 1
                end
            end
        end
    end

    self.built = true
    print("[Tetris] 方块格子创建完成: " .. okCount .. "/" .. (rows * cols)
          .. "  模式=" .. tostring(self.mode)
          .. "（显隐交由稳定期刷新处理）")
    if TetrisConfig.Debug.PrintBoardBounds then
        self:PrintBounds()
    end
    return okCount > 0
end

-- 调试：逐行统计 已创建 / 当前显示 / 期望显示 的格子数。
-- 用于区分两类问题：
--   1) created < 10（整行缺格）-> 创建阶段就失败了（资源/距离/数量上限），与显隐无关；
--   2) created=10 但 shown=0 而 want>0 -> 生成了却被错误隐藏。
function TetrisRenderer:DumpCells(want)
    local rows = TetrisConfig.Board.Rows
    local cols = TetrisConfig.Board.Cols
    print("[Tetris][DUMP] 逐行格子状态  created / shown / want")
    for r = 1, rows do
        local created, shown, w = 0, 0, 0
        for c = 1, cols do
            if self.cells[r] and self.cells[r][c] then created = created + 1 end
            if self.shown[r] and self.shown[r][c] then shown = shown + 1 end
            if want and want[r] and want[r][c] then w = w + 1 end
        end
        print(string.format("  row %2d: created=%2d shown=%2d want=%2d%s",
            r, created, shown, w,
            created < cols and "  <-- 本行有格子未创建!" or ""))
    end
    print(string.format("[Tetris][DUMP] 模式=%s 解析Actor=%d/%d 已建=%s frame=%d",
        tostring(self.mode), self.actorCount, rows * cols, tostring(self.built), self.frame))
end

-- ---------------- 刷新 ----------------
-- 全量下发：不依赖脏检查。每帧对每个格子调用一次，
-- 直接把数据层的期望显隐状态时时刻刻落到渲染层。
-- 好处：1) 自愈"实例初始未就绪导致首帧隐藏失败"的问题；
--      2) 掉落过程中格子显隐严格跟随数据层，不会因陈旧的 shown 状态而错位。
function TetrisRenderer:SetCell(row, col, visible)
    local obj = self.cells[row] and self.cells[row][col]
    if not obj then return end
    self:ApplyVisible(row, col, visible)
    self.shown[row][col] = visible
end

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

-- 按数据层刷新整块盘面：已固定格子 + 当前下落方块
function TetrisRenderer:Update(board)
    if not self.built then return end
    self.frame = self.frame + 1

    local rows = TetrisConfig.Board.Rows
    local cols = TetrisConfig.Board.Cols

    local want = {}
    for r = 1, rows do
        want[r] = {}
        for c = 1, cols do
            want[r][c] = (board:getCell(r, c) ~= 0)
        end
    end

    local active = board:getActiveCells()
    for _, cell in ipairs(active) do
        want[cell.row][cell.col] = true
    end

    -- 每帧全量下发，不依赖脏检查（详见 SetCell 注释）
    for r = 1, rows do
        for c = 1, cols do
            self:SetCell(r, c, want[r][c])
        end
    end

    -- 解析窗口结束后汇报底层 Actor 解析情况
    if self.frame == TetrisConfig.Render.ActorResolveFrames + 1 then
        print("[Tetris] Actor解析完成, 底层Actor解析=" .. tostring(self.actorCount)
              .. "/" .. (rows * cols))
    end

    if TetrisConfig.Debug.PrintGrid then
        self:PrintGrid(want)
    end
    if TetrisConfig.Debug.DumpCellStatus
        and (self.frame % 30 == 0 or self.frame == TetrisConfig.Render.ActorResolveFrames + 1) then
        self:DumpCells(want)
    end
end

function TetrisRenderer:Clear()
    if not self.built then return end
    for r = 1, TetrisConfig.Board.Rows do
        for c = 1, TetrisConfig.Board.Cols do
            self:SetCell(r, c, false)
        end
    end
end

return TetrisRenderer
