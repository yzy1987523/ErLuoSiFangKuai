-- ClientRenderer：把 Interfaces.RenderState 画成 3D 方块，不判定任何玩法。
--
-- 单位纪律（不可混用）：
--   * 入口 origin / right（BoardTransform，服务端下发）单位 = 米 m
--   * CreativeGameAPI.CreateActor 的 Location 单位 = 米 m
--   * WoWActorBase:K2_SetActorLocation 的 NewLocation 单位 = 厘米 cm（显式 ×100）
-- 坐标约定：grid[row][col]，row1=顶行、rowN=底行；origin = 盘面左上角，Z 向下递减。
--
-- 权威 API 来源：EnvLua/Core/LuaHint/{CreativeGameAPI,WoWActorBase,WoWStaticMeshComponentBase,GameAPI}.lua
-- 资源键来源：EnvLua/Common/TetrisConfig.lua Render 段 + EnvLua/Preset/AssetRef.lua（均已在编辑器注册）
local Config = require("EnvLua.Common.Tetris.TetrisConfig")

local ClientRenderer = {}
ClientRenderer.__index = ClientRenderer

local R = Config.Render or {}
local STEP_M = (R.CellSize or 1.0) + (R.CellGap or 0.02)
local BLOCK_PRESET_KEY = R.BlockActorPresetKey

-- AssetRef 是编辑器注入的全局表（见 Preset/AssetRef.lua），查询用 key 得到资源句柄。
local function resolveRef(key)
    if type(key) ~= "string" or type(AssetRef) ~= "table" then return nil end
    return AssetRef[key]
end

-- 取单元 Actor 上可用于换色的 StaticMeshComponent，并缓存（弱键，避免持有 Actor 引用）。
-- 引擎无运行时改材质 API，颜色只能靠 SetStaticMesh 换成预烘焙的彩色模型。
local function meshCompOf(self, actor)
    if not actor then return nil end
    local cached = self._compCache[actor]
    if cached ~= nil then return cached or nil end

    local comp = nil
    pcall(function()
        if actor.RootComponent and type(actor.RootComponent.SetStaticMesh) == "function" then
            comp = actor.RootComponent
        end
    end)
    if not comp then
        for _, cls in ipairs({ "StaticMeshComponent", "WoWStaticMeshComponentBase" }) do
            pcall(function()
                local c = actor:GetComponentByClass(cls)
                if c and type(c.SetStaticMesh) == "function" then comp = c end
            end)
            if comp then break end
        end
    end
    if not comp then
        for _, name in ipairs({ "StaticMesh", "StaticMeshComponent", "Mesh" }) do
            pcall(function()
                local c = actor:GetComponentByName(name)
                if c and type(c.SetStaticMesh) == "function" then comp = c end
            end)
            if comp then break end
        end
    end
    if not comp and type(actor.SetStaticMesh) == "function" then comp = actor end

    self._compCache[actor] = comp or false
    return comp
end

function ClientRenderer:new(origin, right)
    local o = setmetatable({}, self)
    -- 米制：P6 前用 Config.Render.BoardOrigin 占位，P6 接服务端真实下发值。
    o.originM = origin or R.BoardOrigin or { X = 0.0, Y = 0.0, Z = 10.0 }
    o.rightM = right or { X = 1.0, Y = 0.0, Z = 0.0 }
    o.stepM = STEP_M

    o._slots = {}                                  -- key -> {actor, locKey, color, ghost}
    o._pool = {}                                   -- 回收槽位（隐藏复用，避免频繁 Create/Destroy）
    o._compCache = setmetatable({}, { __mode = "k" })
    o._presetRef = resolveRef(BLOCK_PRESET_KEY)
    o._colorMesh = {}
    for t = 1, 8 do
        o._colorMesh[t] = resolveRef(R.ColorModelIDs and R.ColorModelIDs[t])
    end
    o._ghostScale = 0.55
    o._refWarned = false
    o._meshWarned = false
    return o
end

-- [P7] 运行时更新盘面基底（服务端按出生点下发的真实坐标）。
-- cellLocM/_place 每次按当前 originM/rightM 算 locKey，基底改变后下次 Update 自动重定位，无需重建 renderer。
function ClientRenderer:SetBasis(origin, right)
    if origin and origin.X ~= nil then self.originM = origin end
    if right and right.X ~= nil then self.rightM = right end
end

-- 格坐标 → 世界坐标（米）。right 是盘面横向单位向量，origin 为左上角。
function ClientRenderer:cellLocM(row, col)
    local offR = (col - 1) * self.stepM
    local offZ = -(row - 1) * self.stepM
    local r = self.rightM
    return {
        X = self.originM.X + (r.X or 0) * offR,
        Y = self.originM.Y + (r.Y or 0) * offR,
        Z = self.originM.Z + (r.Z or 0) * offR + offZ,
    }
end

function ClientRenderer:_acquire()
    local slot = table.remove(self._pool)
    if not slot then
        if not self._presetRef then
            if not self._refWarned then
                self._refWarned = true
                print("[Tetris][Renderer][WARN] 方块预设未注册 AssetRef[" .. tostring(BLOCK_PRESET_KEY) .. "]，跳过渲染")
            end
            return nil
        end
        local ok, actor = pcall(function()
            return CreativeGameAPI.CreateActor(
                self._presetRef,
                Game:ConstructFVectorByLuaTable({ X = 0, Y = 0, Z = 0 }),
                nil, nil, nil
            )
        end)
        if not ok or not actor then return nil end
        pcall(function() actor:SetActorEnableCollision(false) end)
        slot = { actor = actor }
    end
    pcall(function() slot.actor:SetActorHiddenInGame(false) end)
    slot.locKey = nil
    slot.color = nil
    slot.ghost = nil
    return slot
end

function ClientRenderer:_release(key)
    local slot = self._slots[key]
    if not slot then return end
    self._slots[key] = nil
    pcall(function() slot.actor:SetActorHiddenInGame(true) end)
    self._pool[#self._pool + 1] = slot
end

function ClientRenderer:_setColor(actor, color)
    local ref = self._colorMesh[color]
    if not ref then
        if not self._meshWarned then
            self._meshWarned = true
            print("[Tetris][Renderer][WARN] 彩色模型 AssetRef 未注册，保持预设单色")
        end
        return
    end
    local comp = meshCompOf(self, actor)
    if comp then pcall(function() comp:SetStaticMesh(ref) end) end
end

function ClientRenderer:_place(key, row, col, color, ghost)
    local slot = self._slots[key]
    if not slot then
        slot = self:_acquire()
        if not slot then return end
        self._slots[key] = slot
    end

    local locM = self:cellLocM(row, col)
    local locKey = string.format("%.3f_%.3f_%.3f", locM.X, locM.Y, locM.Z)
    if slot.locKey ~= locKey then
        -- 米 → 厘米：Domain/配置用米，K2_SetActorLocation 用厘米。
        -- 四参必须传齐（SweepHitResult 是隐藏输出参数），第三参 nil 占位。
        local cm = Game:ConstructFVectorByLuaTable({
            X = locM.X * 100.0, Y = locM.Y * 100.0, Z = locM.Z * 100.0,
        })
        pcall(function() slot.actor:K2_SetActorLocation(cm, false, nil, true) end)
        slot.locKey = locKey
    end

    if slot.color ~= color then
        self:_setColor(slot.actor, color)
        slot.color = color
    end
    if slot.ghost ~= ghost then
        local s = ghost and self._ghostScale or 1.0
        pcall(function()
            slot.actor:SetActorScale3D(Game:ConstructFVectorByLuaTable({ X = s, Y = s, Z = s }))
        end)
        slot.ghost = ghost
    end
end

-- 道具块（item 9..12）本体统一用灰色 8 号模型，颜色与道具解耦。
local function colorOf(cellOrType)
    local t = cellOrType
    if type(t) == "table" then
        if t.item ~= nil then return 8 end
        t = t.color
    end
    if type(t) == "number" and Config.IsItemType and Config.IsItemType(t) then return 8 end
    return t or 1
end

--- 按 RenderState 刷新全部方块（差异更新：位置/颜色/缩放未变则不改）。
---@param state table @Interfaces.RenderState
function ClientRenderer:Update(state)
    if type(state) ~= "table" then return end
    local wanted = {}

    for row, line in pairs(state.grid or {}) do
        for col, cell in pairs(line) do
            if cell then
                wanted["g_" .. row .. "_" .. col] = {
                    row = row, col = col, color = colorOf(cell), ghost = false,
                }
            end
        end
    end

    local active = state.active
    if active and type(active.cells) == "table" then
        for i, c in ipairs(active.cells) do
            wanted["a_" .. i] = { row = c.row, col = c.col, color = colorOf(c.colorType), ghost = false }
        end
    end

    for i, c in ipairs(state.ghost or {}) do
        wanted["h_" .. i] = { row = c.row, col = c.col, color = colorOf(c.colorType), ghost = true }
    end

    for key in pairs(self._slots) do
        if not wanted[key] then self:_release(key) end
    end
    for key, w in pairs(wanted) do
        self:_place(key, w.row, w.col, w.color, w.ghost)
    end
end

-- 盘面变换：P6 前用占位值；P6 后由服务端下发 BoardTransform（米）。
function ClientRenderer:ApplyTransform(transform)
    if type(transform) ~= "table" then return end
    if transform.ox then
        self.originM = { X = transform.ox, Y = transform.oy or 0, Z = transform.oz or 0 }
        for key in pairs(self._slots) do self._slots[key].locKey = nil end
    end
end

-- ===================== 消行 3D 框（客户端本地表现） =====================
-- SceneEffectAPI 全类 ServerOnly（Core/LuaHint/SceneEffectAPI.lua 已确认），客户端不能播场景粒子特效。
-- 改用客户端已验证可用的 CreativeGameAPI.CreateActor（P4 双盘方块即用此 API）造「带 WidgetComponent 的长条框 Actor」，
-- 资源 = Config.ClearRowWidget.PresetKey（46_ActorPreset_2125630218，带整行 UMG 图片，已注册 AssetRef）。
-- 显隐时机由 ClientGame._startClearSequence（Show）→ _finishClearSequence（Hide）控制，覆盖整个消行特效窗口。
local CLEAR_WIDGET = Config.ClearRowWidget or {}

function ClientRenderer:_acquireClearFrame(idx)
    self._clearActors = self._clearActors or {}
    local actor = self._clearActors[idx]
    if actor then return actor end
    local ref = resolveRef(CLEAR_WIDGET.PresetKey)
    if not ref then
        if not self._clearRefWarned then
            self._clearRefWarned = true
            print("[Tetris][Renderer][WARN] 消行框预设未注册 AssetRef[" .. tostring(CLEAR_WIDGET.PresetKey) .. "]")
        end
        return nil
    end
    local ok, a = pcall(function()
        return CreativeGameAPI.CreateActor(
            ref, Game:ConstructFVectorByLuaTable({ X = 0, Y = 0, Z = 0 }), nil, nil, nil
        )
    end)
    if not ok or not a then
        print("[Tetris][Renderer][WARN] 消行框 CreateActor 失败: " .. tostring(a))
        return nil
    end
    pcall(function() a:SetActorEnableCollision(false) end)
    self._clearActors[idx] = a
    return a
end

-- 把消行框摆到指定 (row, col) 的中心并显形。row/col 为棋盘格坐标（1 基），cellLocM 内部换算为米。
function ClientRenderer:_placeClearFrame(idx, row, col)
    local actor = self:_acquireClearFrame(idx)
    if not actor then return end
    local locM = self:cellLocM(row, col)
    -- 米 → 厘米：K2_SetActorLocation 第 3 参是隐藏 FHitResult& 输出，必须传 nil 占位、四参传齐。
    local cm = Game:ConstructFVectorByLuaTable({
        X = locM.X * 100.0, Y = locM.Y * 100.0, Z = locM.Z * 100.0,
    })
    pcall(function() actor:K2_SetActorLocation(cm, false, nil, true) end)
    local sc = CLEAR_WIDGET.Scale or { X = 1, Y = 1, Z = 1 }
    pcall(function() actor:SetActorScale3D(Game:ConstructFVectorByLuaTable(sc)) end)
    pcall(function() actor:SetActorHiddenInGame(false) end)
end

function ClientRenderer:ShowClearFrame(rows)
    if CLEAR_WIDGET.Enabled == false then return end
    if type(rows) ~= "table" or #rows == 0 then return end
    local cols = (Config.Board and Config.Board.Cols) or 10
    local colCenter = cols / 2   -- 长条框覆盖整行，落在行中心即可
    for i, row in ipairs(rows) do
        self:_placeClearFrame(i, row, colCenter)
    end
    print("[Tetris][Renderer] ShowClearFrame 显示 " .. tostring(#rows) .. " 个消行框")
end

-- 爆破竖列：客户端无竖版 SceneEffect，退化为在该列中部显示一个框作可见提示（col 为爆破列号）。
function ClientRenderer:ShowBlastColumn(col)
    if CLEAR_WIDGET.Enabled == false then return end
    local rows = (Config.Board and Config.Board.Rows) or 20
    self:_placeClearFrame(1, math.floor(rows / 2), col or 1)
    print("[Tetris][Renderer] ShowBlastColumn 列=" .. tostring(col))
end

function ClientRenderer:HideClearFrame()
    for _, actor in ipairs(self._clearActors or {}) do
        pcall(function() actor:SetActorHiddenInGame(true) end)
    end
end

function ClientRenderer:ShowStoneFalling(stones) end

--- 销毁全部 Actor（对局结束/切场景时调用）。
function ClientRenderer:Release()
    for key, slot in pairs(self._slots) do
        pcall(function() CreativeGameAPI.DestroyActor(slot.actor) end)
        self._slots[key] = nil
    end
    for _, slot in ipairs(self._pool) do
        pcall(function() CreativeGameAPI.DestroyActor(slot.actor) end)
    end
    for _, actor in ipairs(self._clearActors or {}) do
        pcall(function() CreativeGameAPI.DestroyActor(actor) end)
    end
    self._clearActors = nil
    self._pool = {}
    self._compCache = nil
end

return ClientRenderer
