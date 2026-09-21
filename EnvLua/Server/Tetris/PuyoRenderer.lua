-- Puyo 渲染层：把 PuyoBoard 状态映射为 3D 方块显隐。
-- 设计要点（精简自 TetrisRenderer，只覆盖 Puyo 需要的部分）：
--   * 几何：复用 Tetris 的 ResolveOrigin / cellLocation（盘面按各自出生点 yaw 摆正，修复过的双盘旋转 bug）。
--   * 全部用「独立单元 Actor」（BlockActorPresetKey，ForceActorMode 已验证客户端可复制），
--     每帧按各自格世界坐标 K2_TeleportTo 定位 —— 刻意不用「根+AddComponent 子组件」，
--     因为本引擎不复制运行时 AddComponent 子组件的 transform（客户端会全叠原点，见 TetrisRenderer 注释）。
--   * 颜色：引擎无运行时改材质 API，故提供 4 色方块模型，取格时 actor:SetStaticMesh(颜色模型) 换色
--     （SetStaticMesh 已验证可用；Actor 不支持时 pcall 兜底保持单色，不影响定位）。
--   * 池3（落定多色单元）：cells[row][col] = 单元 Actor。
--   * 池4（活动对子）：2 个独立单元 Actor（c1/c2 各一），按对子两格坐标分别传送。
--   * 预览 / 幽灵：同样各 2 个独立单元 Actor。
local TetrisConfig = require("EnvLua.Server.Tetris.TetrisConfig")

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
-- 黑盒引擎下组件获取方式未知，故多策略探测并缓存结果（按 actor 弱引用），避免每帧重复探测。
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
        print("[Puyo][WARN] 无法取得 StaticMeshComponent，换色将失败（保持单色）")
    end
    return comp
end

local PuyoRenderer = {}
PuyoRenderer.__index = PuyoRenderer

function PuyoRenderer:new(owner)
    local o = setmetatable({}, PuyoRenderer)
    o.owner = owner
    local pb = TetrisConfig.Puyo.Board
    o.cols = pb.Cols
    o.rows = pb.Rows
    o.cells = {}        -- cells[row][col] = 单元 Actor
    o.shown = {}        -- shown[row][col] = color(>0) 当前显隐（脏检查）
    o.activeActors = nil  -- { a1, a2 } 活动对子
    o.previewActors = nil -- { a1, a2 }
    o.ghostActors = nil   -- { a1, a2 }
    o.built = false
    o._spawnResolved = false
    o.origin = nil
    o.boardRight = { X = 1, Y = 0, Z = 0 }
    o.boardCenter = nil
    o.boardYaw = 0
    o.rot = nil
    o.mesh = {}         -- mesh[color] = meshRef（换色用）
    o.refTop = nil      -- 单元 Actor 预设 ref
    o.hideLoc = { X = 0, Y = 0, Z = -500 }  -- 停车场（米，远低于地面）
    return o
end

-- ---------------- 几何（复用 Tetris 的盘面定位逻辑，仅盘面尺寸取 Puyo） ----------------
function PuyoRenderer:ResolveOrigin(spawnPointKey)
    local r = TetrisConfig.Render
    local so = TetrisConfig.SceneObjects
    local step = r.CellSize + r.CellGap
    local w = (self.cols - 1) * step
    local h = (self.rows - 1) * step
    local lift = (type(TetrisConfig.BoardHeightOffsetM) == "number") and TetrisConfig.BoardHeightOffsetM or 1.3

    local function settle(spawnLoc, fx, fy, fsrc)
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
        local side = (type(TetrisConfig.BoardSideOffsetM) == "number") and TetrisConfig.BoardSideOffsetM or 0
        local center = { X = spawnLoc.X + ffx * dist + right.X * side,
                         Y = spawnLoc.Y + ffy * dist + right.Y * side,
                         Z = spawnLoc.Z + lift + h / 2 }
        local origin = { X = center.X - right.X * (w / 2), Y = center.Y - right.Y * (w / 2), Z = center.Z + h / 2 }
        self.origin = origin
        self.boardCenter = center
        self.boardRight = right
        self.boardYaw = frameYaw * 180 / math.pi
        if type(FRotator) == "table" and FRotator.MakeFromEuler then
            self.rot = FRotator.MakeFromEuler(Game:ConstructFVectorByLuaTable({ X = 0, Y = 0, Z = self.boardYaw }))
        end
        return origin
    end

    local key = spawnPointKey or self.spawnPointKey or (so and so.SpawnPointKey)
    if type(so) == "table" and key then
        if type(CreativeInstance) == "table" then
            local id = CreativeInstance[key]
            if id ~= nil and type(InstanceAPI) == "table" then
                local ok, loc2 = pcall(function() return InstanceAPI.GetInstanceLocation(id) end)
                if ok and loc2 and loc2.X then
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
        print("[Puyo][WARN] 出生点装置尚未注入，回退玩家基准（稍后重试重摆）")
    end

    local okP, plist = pcall(function() return Game:GetAllPlayerPawns() end)
    local pawn = (okP and plist and plist.Num and plist:Num() > 0) and plist:Get(0) or nil
    if pawn then
        local locCM = pawn:K2_GetActorLocation()
        if locCM and locCM.X then
            local loc = { X = locCM.X / 100, Y = locCM.Y / 100, Z = locCM.Z / 100 }
            local fLookX, fLookY = 0, 1
            local okArr, arr = pcall(function() return Game:GetAllPlayerStates() end)
            local ps = (okArr and arr and arr.Num and arr:Num() > 0) and arr:Get(0) or nil
            if ps then
                local okL, ld = pcall(function() return PlayerAPI.GetPlayerLookDirection(ps) end)
                if okL and ld and ld.X and ld.Y then
                    local len = math.sqrt(ld.X * ld.X + ld.Y * ld.Y)
                    if len > 1e-4 then fLookX, fLookY = ld.X / len, ld.Y / len end
                end
            end
            return settle(loc, fLookX, fLookY, "pawn")
        end
    end
    print("[Puyo][ERROR] 无法生成盘面：出生点装置未注入且无本地玩家")
    return nil
end

function PuyoRenderer:GetBoardCenter()
    return self.boardCenter
end

-- 网格格 → 世界坐标（米）。right 沿盘面右向量，Z 向下递减。
function PuyoRenderer:cellLocation(row, col)
    local r = TetrisConfig.Render
    local step = r.CellSize + r.CellGap
    local o = self.origin or r.BoardOrigin
    local right = self.boardRight or { X = 1, Y = 0, Z = 0 }
    local dx = (col - 1) * step
    local dz = (row - 1) * step
    return { X = o.X + right.X * dx, Y = o.Y + right.Y * dx, Z = o.Z - dz }
end

local function cmVec(loc)
    return Game:ConstructFVectorByLuaTable({ X = loc.X * 100, Y = loc.Y * 100, Z = loc.Z * 100 })
end

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

-- ---------------- 资源 / 创建 ----------------
function PuyoRenderer:PrepareRefs()
    self.refTop = (type(AssetRef) == "table") and AssetRef[TetrisConfig.Render.BlockActorPresetKey] or nil
    if not self.refTop and type(AssetRef) == "table" then
        self.refTop = AssetRef[TetrisConfig.Render.BlockAssetRefKey] or nil
    end
    self.mesh = {}
    local pb = TetrisConfig.Puyo
    for c = 1, pb.Colors do
        local key = pb.BlockMesh and pb.BlockMesh[c]
        local ref = (type(AssetRef) == "table" and key) and AssetRef[key] or nil
        if not ref then
            print("[Puyo][WARN] BlockMesh[" .. tostring(c) .. "] AssetRef[\""
                .. tostring(key) .. "\"] 未解析，回退单色模型")
            ref = (type(AssetRef) == "table") and AssetRef[TetrisConfig.Render.PieceMeshAssetKey] or nil
        end
        self.mesh[c] = ref
    end
end

function PuyoRenderer:SetMesh(actor, color)
    local ref = self.mesh[color]
    if not actor then return end
    if not ref then
        -- 资源未解析（AssetRef 缺失 / 未 update preset）：保持单色，仅首次提示
        if not self._meshWarn then self._meshWarn = {} end
        if not self._meshWarn[color] then
            self._meshWarn[color] = true
            print("[Puyo][WARN] 颜色 " .. tostring(color)
                .. " 的模型未解析（AssetRef 缺失？未执行 update preset），保持单色")
        end
        return
    end
    local comp = getMeshComp(self, actor)
    if comp then
        pcall(function() comp:SetStaticMesh(ref) end)
    end
end

function PuyoRenderer:CreateCell()
    if not self.refTop then return nil end
    local s = TetrisConfig.Puyo.BlockScale or TetrisConfig.Render.BlockScale or 1.0
    local scale = Game:ConstructFVectorByLuaTable({ X = s, Y = s, Z = s })
    local a = CreativeGameAPI.CreateActor(self.refTop, cmVec(self.hideLoc), self.rot or makeZeroRotator(), scale, nil)
    return a
end

function PuyoRenderer:MoveActor(a, worldLoc)
    if a then pcall(function() a:K2_TeleportTo(cmVec(worldLoc), self.rot) end) end
end

function PuyoRenderer:HideActor(a)
    if a then pcall(function() a:K2_TeleportTo(cmVec(self.hideLoc), self.rot) end) end
end

-- 在指定格位置播放消除特效。坐标用米，cellLocation 返回值即米，直接构造 FVector 传入。
-- 资源走 AssetRef（需 VSCode 插件注册并 update preset）；失败静默，不影响消除主流程。
function PuyoRenderer:PlayClearEffectAt(row, col)
    if not SceneEffectAPI or not SceneEffectAPI.CreateSceneEffect then return end
    local pb = TetrisConfig.Puyo
    local key = (pb and pb.ClearEffectKey) or "13_EffectPreset_100021"
    local ref = AssetRef and AssetRef[key]
    if not ref then
        if TetrisConfig.Debug then
            print(string.format("[Puyo][Clear][WARN] 特效资源未注册 AssetRef[%s]，跳过", tostring(key)))
        end
        return
    end
    local loc = self:cellLocation(row, col)
    local off = (pb and pb.ClearEffectOffset) or { X = 0.0, Y = 0.0, Z = 0.0 }
    local pos = { X = loc.X + (off.X or 0), Y = loc.Y + (off.Y or 0), Z = loc.Z + (off.Z or 0) }
    local dur = (pb and pb.ClearEffectDuration) or 0.5
    local ok, id = pcall(function()
        return SceneEffectAPI.CreateSceneEffect(ref, Game:ConstructFVectorByLuaTable(pos), dur)
    end)
    if not ok or not id or id == 0 then
        if TetrisConfig.Debug then
            print(string.format("[Puyo][Clear][WARN] 特效创建失败 row=%d col=%d id=%s", row, col, tostring(id)))
        end
        return
    end
    local scale = (pb and pb.ClearEffectScale) or { X = 1.0, Y = 1.0, Z = 1.0 }
    pcall(function()
        SceneEffectAPI.SetSceneEffectScale(id, Game:ConstructFVectorByLuaTable({ X = scale.X, Y = scale.Y, Z = scale.Z }))
    end)
    if TetrisConfig.Debug then
        print(string.format("[Puyo][Clear] 特效 row=%d col=%d id=%s", row, col, tostring(id)))
    end
end

-- 活动对子 c2 相对枢轴(c1)的格偏移（用于算出 c2 的 grid 坐标）
local function pairCellOffset(rot)
    if rot == 1 then return { dc = 0, dr = -1 } end  -- 上
    if rot == 2 then return { dc = 1, dr = 0 } end   -- 右
    if rot == 3 then return { dc = 0, dr = 1 } end   -- 下
    return { dc = -1, dr = 0 }                        -- 左 (rot=4)
end

-- 把一对（c1,c2,枢轴x,y,rot）摆到 2 个 Actor（各自传送到自己的格坐标）
function PuyoRenderer:PlacePair(actors, c1, c2, x, y, rot)
    if not actors then return end
    local off = pairCellOffset(rot)
    local r1, c1c = y, x
    local r2, c2c = y + off.dr, x + off.dc
    self:SetMesh(actors[1], c1)
    self:SetMesh(actors[2], c2)
    self:MoveActor(actors[1], self:cellLocation(r1, c1c))
    if r2 >= 1 and r2 <= self.rows and c2c >= 1 and c2c <= self.cols then
        self:MoveActor(actors[2], self:cellLocation(r2, c2c))
    else
        self:HideActor(actors[2])  -- c2 临时在盘面外（极少数，如顶部旋转）：藏起
    end
end

-- ---------------- 构建 ----------------
function PuyoRenderer:Build(spawnPointKey)
    self:ResolveOrigin(spawnPointKey)
    self:PrepareRefs()
    if not self.refTop then
        print("[Puyo][ERROR] 单元方块预设未注册（BlockActorPresetKey），无法构建")
        return false
    end

    -- 池3：落定单元网格
    for r = 1, self.rows do
        self.cells[r] = {}
        self.shown[r] = {}
        for c = 1, self.cols do
            local a = self:CreateCell()
            if a then self:HideActor(a) end
            self.cells[r][c] = a
            self.shown[r][c] = 0
        end
    end

    -- 池4 + 预览 + 幽灵：各 2 个 Actor
    self.activeActors = { self:CreateCell(), self:CreateCell() }
    self.previewActors = { self:CreateCell(), self:CreateCell() }
    self.ghostActors = { self:CreateCell(), self:CreateCell() }
    self:HideActor(self.activeActors[1]); self:HideActor(self.activeActors[2])
    self:HideActor(self.previewActors[1]); self:HideActor(self.previewActors[2])
    self:HideActor(self.ghostActors[1]); self:HideActor(self.ghostActors[2])

    -- 外框（左/右/下三侧静态装饰）：与方块同模型，用动态实例生成；
    -- InstanceAPI 可能晚注入，BuildBorder 内部幂等，Update 里会重试直到成功。
    self:BuildBorder()

    -- 预览位置：盘面右侧外移若干格、顶部
    local step = TetrisConfig.Render.CellSize + TetrisConfig.Render.CellGap
    local right = self.boardRight or { X = 1, Y = 0, Z = 0 }
    local sideCells = (TetrisConfig.Puyo.PreviewSideCells or (self.cols + 3))
    self.previewBase = {
        X = (self.boardCenter and self.boardCenter.X or 0) + right.X * ((self.cols / 2 + sideCells) * step),
        Y = (self.boardCenter and self.boardCenter.Y or 0) + right.Y * ((self.cols / 2 + sideCells) * step),
        Z = (self.boardCenter and self.boardCenter.Z or 0) + (self.rows / 2) * step,
    }

    self.built = true
    return true
end

-- ---------------- 刷新（数据层读取） ----------------
function PuyoRenderer:Update(board)
    if not self.built then return end
    -- 外框重试：InstanceAPI 晚注入或首帧创建失败时在后续帧补齐
    if (not self.border or #self.border == 0) and type(InstanceAPI) == "table" then
        self:BuildBorder()
    end
    local step = TetrisConfig.Render.CellSize + TetrisConfig.Render.CellGap

    -- 池3：落定单元
    for r = 1, self.rows do
        for c = 1, self.cols do
            local color = board:getCell(r, c)
            local a = self.cells[r] and self.cells[r][c]
            if a and color ~= self.shown[r][c] then
                if color > 0 then
                    self:SetMesh(a, color)
                    self:MoveActor(a, self:cellLocation(r, c))
                else
                    self:HideActor(a)
                end
                self.shown[r][c] = color
            elseif a and color > 0 then
                -- 颜色未变但位置可能因重力/消行改变 → 每帧重摆（盘面仅 72 格，开销小）
                self:MoveActor(a, self:cellLocation(r, c))
            end
        end
    end

    -- 池4：活动对子
    local ap = board:getActivePair()
    if ap then
        self:PlacePair(self.activeActors, ap.c1, ap.c2, ap.x, ap.y, ap.rot)
    else
        self:HideActor(self.activeActors[1]); self:HideActor(self.activeActors[2])
    end

    -- 幽灵对子（落点预览）
    if TetrisConfig.Puyo.ShowGhost ~= false then
        local gp = board:getGhostPair()
        if gp and ap then
            self:PlacePair(self.ghostActors, gp.c1, gp.c2, gp.x, gp.y, gp.rot)
        else
            self:HideActor(self.ghostActors[1]); self:HideActor(self.ghostActors[2])
        end
    end

    -- 预览对子（下一对）：固定在盘面右侧，c1 在预览基位、c2 在其上方
    local nx = board:getNextPair()
    if nx and self.previewBase then
        self:SetMesh(self.previewActors[1], nx.c1)
        self:SetMesh(self.previewActors[2], nx.c2)
        self:MoveActor(self.previewActors[1], self.previewBase)
        self:MoveActor(self.previewActors[2], { X = self.previewBase.X, Y = self.previewBase.Y, Z = self.previewBase.Z + step })
    else
        self:HideActor(self.previewActors[1]); self:HideActor(self.previewActors[2])
    end
end

-- ---------------- 收尾 / 兼容 ----------------
function PuyoRenderer:Clear()
    if not self.built then return end
    for r = 1, self.rows do
        for c = 1, self.cols do
            local a = self.cells[r] and self.cells[r][c]
            if a then self:HideActor(a) end
            self.shown[r][c] = 0
        end
    end
    self:HideActor(self.activeActors[1]); self:HideActor(self.activeActors[2])
    self:HideActor(self.previewActors[1]); self:HideActor(self.previewActors[2])
    self:HideActor(self.ghostActors[1]); self:HideActor(self.ghostActors[2])
end

-- ---------------- 外框（左/右/下三侧静态装饰，常驻可见） ----------------
-- 复用 Tetris 的 BorderAssetRefKey（44_CreativeAsset，与方块同模型），用 InstanceAPI.CreateInstance
-- 在盘面左(虚拟列0)/右(虚拟列Cols+1)/下(虚拟行Rows+1)各生成一排 1 格厚外框。顶部开放供方块落入。
-- 几何与 cellLocation 同源：沿 boardRight 偏移、向下 -Z 递减，确保盘面非世界轴时也不错位。
function PuyoRenderer:BuildBorder()
    if self.border and #self.border > 0 then return end
    if not self.origin then return end
    if type(InstanceAPI) ~= "table" then return end
    local r = TetrisConfig.Render
    local step = r.CellSize + r.CellGap
    local s = r.BlockScale or 1.0
    local scale = Game:ConstructFVectorByLuaTable({ X = s, Y = s, Z = s })
    local ref = (type(AssetRef) == "table") and AssetRef[TetrisConfig.Render.BorderAssetRefKey] or nil
    if not ref then
        print("[Puyo][WARN] 边框资源 BorderAssetRefKey 未解析，跳过外框")
        return
    end
    local right = self.boardRight or { X = 1, Y = 0, Z = 0 }
    local o = self.origin
    self.border = {}
    self.borderSpecs = {}
    local function make(dx, dz)
        local loc = Game:ConstructFVectorByLuaTable({
            X = o.X + right.X * dx, Y = o.Y + right.Y * dx, Z = o.Z - dz,
        })
        local ok, obj = pcall(function() return InstanceAPI.CreateInstance(ref, loc, self.rot, scale) end)
        if ok and obj then
            pcall(function() if InstanceAPI.ToggleInstanceVisible then InstanceAPI.ToggleInstanceVisible(obj, true) end end)
            self.border[#self.border + 1] = obj
            self.borderSpecs[#self.borderSpecs + 1] = { dx = dx, dz = dz }
        end
    end
    for row = 1, self.rows do
        local dz = (row - 1) * step
        make((0 - 1) * step, dz)              -- 左
        make((self.cols + 1 - 1) * step, dz)  -- 右
    end
    for col = 1, self.cols do
        make((col - 1) * step, (self.rows + 1 - 1) * step)  -- 下
    end
    print("[Puyo] 边框创建完成: " .. #self.border .. "/" .. (self.rows + self.rows + self.cols)
        .. "（左/右/下三侧，常驻可见）")
end

-- 外框随 boardRight/origin 重定位（出生点装置晚注入、基准变化后调用）。
function PuyoRenderer:ReanchorBorder()
    if not self.border or not self.borderSpecs or not self.origin then return end
    local right = self.boardRight or { X = 1, Y = 0, Z = 0 }
    local o = self.origin
    local rot = self.rot or makeZeroRotator()
    for i, a in ipairs(self.border) do
        local sp = self.borderSpecs[i]
        if a and sp then
            local loc = Game:ConstructFVectorByLuaTable({
                X = o.X + right.X * sp.dx, Y = o.Y + right.Y * sp.dx, Z = o.Z - sp.dz,
            })
            if type(a) == "number" then
                -- 动态实例句柄：用 InstanceAPI 移动，不能 K2_TeleportTo
                pcall(function() InstanceAPI.SetInstanceLocation(a, loc) end)
                if rot then pcall(function()
                    if InstanceAPI.SetInstanceRotation then InstanceAPI.SetInstanceRotation(a, rot) end
                end) end
            else
                pcall(function() a:K2_TeleportTo(loc, rot) end)
            end
        end
    end
end

-- Puyo 盘面静态格由独立单元 Actor 持有，重摆由 Update 每帧负责，无需额外处理。
function PuyoRenderer:ReanchorBoard() end

return PuyoRenderer
