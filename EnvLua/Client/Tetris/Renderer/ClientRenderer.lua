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
-- 远景背景 WidgetComponent 要显示的 UMG（SetWidget Both；默认无 widget 时不显示）
local BG_UMG_KEY = "51_UMGPreset_CustomAsset-3-408-b5541cbcd76165b496f8b42fcc560e8f677593530f5ab0f67ae9a6e696e16369"

-- 远景背景挂件的难度图键（由 battle 在进入对局时注入：单人=Easy/Normal/Hard，双人=Human）
local BG_IMAGE_KEY = "Human"

-- 【客户端背景生成硬开关】官方确认客户端 3D UI 有 bug（GetUserWidgetObject/GetWidget 实测恒 nil，
-- 灌图失败），当前背景一律走服务端。此开关与配置解耦，避免配置未同步时双端重复生成。
-- 后期官方修复后改 true 启用客户端生成链路（下方完整代码已保留）。
local ENABLE_CLIENT_BG_SPAWN = false

-- AssetRef 是编辑器注入的全局表（见 Preset/AssetRef.lua），查询用 key 得到资源句柄。
local function resolveRef(key)
    if type(key) ~= "string" or type(AssetRef) ~= "table" then return nil end
    return AssetRef[key]
end

local function atan2compat(y, x)
    if type(math.atan2) == "function" then return math.atan2(y, x) end
    return math.atan(y, x)  -- Lua 5.3+ 双参形式
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
    o._bgWidget = nil          -- [BG] 远景背景 3D UI 挂件（本 renderer 对应盘面一个）
    o._bgBoardIndex = nil      -- 记录生成时的 boardIndex，供 SetBasis 变化后重定位
    return o
end

-- [P7] 运行时更新盘面基底（服务端按出生点下发的真实坐标）。
-- cellLocM/_place 每次按当前 originM/rightM 算 locKey，基底改变后下次 Update 自动重定位，无需重建 renderer。
function ClientRenderer:SetBasis(origin, right)
    if origin and origin.X ~= nil then self.originM = origin end
    if right and right.X ~= nil then self.rightM = right end
    -- 基底变化后重定位已生成的背景挂件（出生点装置晚注入导致基底更新时保持对齐）
    if self._bgWidget then pcall(function() self:_reanchorBackgroundWidget() end) end
end

-- [BG] 关闭 billboard：bFaceCamera 字段直接赋值常被代理吞掉或 SetWidget 异步加载覆盖，
-- 故立即设一次 + 打印前后值，并延迟由调用方再补一次。Space=0(World)、bFaceCamera=false。
function ClientRenderer:_applyBillboardOff(wc, tag)
    if not wc then return end
    local beforeFC, beforeSpace = "?", "?"
    pcall(function() if wc.bFaceCamera ~= nil then beforeFC = tostring(wc.bFaceCamera) end end)
    pcall(function() if wc.GetWidgetSpace then beforeSpace = tostring(wc:GetWidgetSpace()) end end)
    pcall(function() wc.bFaceCamera = false end)
    local afterFC = "?"
    pcall(function() if wc.bFaceCamera ~= nil then afterFC = tostring(wc.bFaceCamera) else afterFC = "nil(字段不可读)" end end)
    pcall(function() if wc.SetWidgetSpace then wc:SetWidgetSpace(0) end end)
    local afterSpace = "?"
    pcall(function() if wc.GetWidgetSpace then afterSpace = tostring(wc:GetWidgetSpace()) end end)
    print("[BG][Client] billboard关闭 " .. tostring(tag) ..
        " bFaceCamera: " .. beforeFC .. "→" .. afterFC ..
        " Space: " .. beforeSpace .. "→" .. afterSpace)
end

-- [BG] 由 origin/right 反推盘面几何，算远景背景挂件的位置与朝向。
-- 旧服务端 TetrisBackgroundWidget 读出生点装置(InstanceAPI, ServerOnly)，客户端改用已下发的盘面基底，
-- 数学等价：right=(fry,-frx) → frameYaw=atan2(right.X, -right.Y)；
-- forward=(cos(posYaw),sin(posYaw))，flipAxis180=true 时 posYaw=frameYaw-π → forward=-frame 方向。
-- 盘心 = origin + right*(w/2)，Z = origin.Z - h/2（origin 是左上角顶行，Z 向下递减）。
local function bgTransform(self, boardIndex)
    local cfg = Config.BackgroundWidget
    if not (cfg and cfg.Enabled) then return nil end
    local board = Config.Board or {}
    local w = ((board.Cols or 10) - 1) * STEP_M
    local h = ((board.Rows or 20) - 1) * STEP_M
    local o, r = self.originM, self.rightM
    local rx, ry = r.X or 0, r.Y or 0
    local frameYaw = atan2compat(rx, -ry)
    local flipAxis = (type(Config.BoardFlipAxis180) == "boolean") and Config.BoardFlipAxis180 or false
    local posYaw = frameYaw - (flipAxis and math.pi or 0)
    local fx, fy = math.cos(posYaw), math.sin(posYaw)
    -- 盘心
    local cx = o.X + rx * (w / 2)
    local cy = o.Y + ry * (w / 2)
    local cz = o.Z - h / 2
    -- 挂件偏移：D 沿 forward(视线前向)、sideW 沿 right、hgt 沿世界 +Z
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

-- 生成远景背景 3D UI 挂件（幂等：每 renderer 只建一个）。boardIndex 1/2 决定旋转偏置。
function ClientRenderer:EnsureBackgroundWidget(boardIndex)
    if not ENABLE_CLIENT_BG_SPAWN then return end  -- 背景一律走服务端（官方确认客户端 3D UI 有 bug）
    local cfg = Config.BackgroundWidget
    if not (cfg and cfg.Enabled) then return end
    if self._bgWidget then return end
    local ref = resolveRef(cfg.PresetKey)
    if not ref then
        if not self._bgRefWarned then
            self._bgRefWarned = true
            print("[BG][Client] 资源未注册 AssetRef[" .. tostring(cfg.PresetKey) .. "]")
        end
        return
    end
    local pos, rotObj = bgTransform(self, boardIndex)
    if not pos then return end
    local sc = cfg.Scale or { X = 1, Y = 1, Z = 1 }
    local scaleVec = Game:ConstructFVectorByLuaTable({
        X = sc.X or 1, Y = sc.Y or 1, Z = sc.Z or 1,
    })
    -- [生成方式] 对齐已验证能显示的方块：CreateActor 先建（位置传米、rot/scale 先不传），
    -- 再用 K2_SetActorLocation(cm)/K2_SetActorRotation/SetActorScale3D 显式设置 transform，
    -- 绕开 CreateActor 直传 transform 可能不生效的隐患。
    local ok, actor = pcall(function()
        return CreativeGameAPI.CreateActor(ref, Game:ConstructFVectorByLuaTable(pos), nil, nil, nil)
    end)
    if ok and actor then
        self._bgWidget = actor
        self._bgBoardIndex = boardIndex
        -- 显式 transform（单位：位置 cm，旋转 FRotator，缩放无量纲）——与方块 _place 同路
        pcall(function()
            actor:K2_SetActorLocation(Game:ConstructFVectorByLuaTable({
                X = pos.X * 100, Y = pos.Y * 100, Z = pos.Z * 100,
            }), false, nil, true)
        end)
        if rotObj then pcall(function() actor:K2_SetActorRotation(rotObj, false) end) end
        pcall(function() actor:SetActorScale3D(scaleVec) end)
        pcall(function() if actor.SetActorEnableCollision then actor:SetActorEnableCollision(false) end end)
        pcall(function() if actor.SetActorHiddenInGame then actor:SetActorHiddenInGame(false) end end)
        -- 【客户端生成完整链路 —— 保留供后期官方修复后启用】
        -- 当前官方确认客户端 3D UI 显示有 bug 未修复，SpawnMode="Server" 故此段不执行；
        -- 后期把 SpawnMode 改 "Client" 即走这里：SetWidget 挂 UMG + 关 billboard + 灌难度图。
        -- 注意：实跑发现客户端 wc:GetUserWidgetObject() 恒 nil（即便 SetWidget ok），
        -- 官方修复前无法灌图；修复后需复验此处 uw 获取，必要时试 GetUserWidgetObject(pawn)。
        local selfRef, actorRef, idxRef = self, actor, boardIndex
        local wc = nil
        pcall(function() wc = actorRef:GetComponentByName("WidgetComponent") end)
        if not wc then pcall(function() wc = actorRef:GetComponentByClass("WidgetComponent") end) end
        if wc then
            local umgRef = resolveRef(BG_UMG_KEY)
            if umgRef then
                local swOK = pcall(function() wc:SetWidget(umgRef) end)
                print("[BG][Client] SetWidget index=" .. tostring(idxRef) .. " ok=" .. tostring(swOK))
            end
            self:_applyBillboardOff(wc, "SetWidget后")
        else
            print("[BG][Client][WARN] 未找到 WidgetComponent index=" .. tostring(idxRef))
        end
        -- SetWidget 异步加载，官方建议等 1 秒后再 GetUserWidgetObject → 灌难度图
        pcall(function()
            actor:AddTimerOnce(1.0, function()
                selfRef:_tryPaintBackgroundWidget(actorRef, idxRef, 0)
            end)
        end)
        print("[BG][Client] 远景背景挂件已生成(Client模式) boardIndex=" .. tostring(boardIndex) ..
            " pos=(" .. string.format("%.2f", pos.X) .. "," .. string.format("%.2f", pos.Y) .. "," ..
            string.format("%.2f", pos.Z) .. ") yaw=" .. tostring(rotObj and rotObj.Yaw or "nil"))
        self:_diagBackground(pos, boardIndex)
    else
        print("[BG][Client][WARN] CreateActor 失败 boardIndex=" .. tostring(boardIndex) .. " err=" .. tostring(actor))
    end
end

-- [BG][诊断] 回读 actor 真实位置 + 相机位置/朝向，判断挂件是在视野外还是渲染问题。
-- 只在生成后打印一次，避免刷屏。相机 API 是 ClientOnly，这里本就是客户端。
function ClientRenderer:_diagBackground(pos, boardIndex)
    local actor = self._bgWidget
    -- 1) actor 回读真实位置（确认 CreateActor 真把 actor 放到了 pos）
    local aloc = nil
    pcall(function()
        if actor and actor.K2_GetActorLocation then
            local l = actor:K2_GetActorLocation()
            if l then aloc = { X = l.X or 0, Y = l.Y or 0, Z = l.Z or 0 } end
        end
    end)
    -- 2) hidden 状态
    local hidden = "?"
    pcall(function()
        if actor and actor.bHidden ~= nil then hidden = tostring(actor.bHidden) end
    end)
    -- 3) 相机位置 / 朝向
    local clip, crot = nil, nil
    pcall(function() if type(CameraAPI) == "table" and CameraAPI.GetCameraLocation then clip = CameraAPI.GetCameraLocation() end end)
    pcall(function() if type(CameraAPI) == "table" and CameraAPI.GetCameraRotation then crot = CameraAPI.GetCameraRotation() end end)

    local function fmt(v) return v and ("(" .. string.format("%.1f", v.X or 0) .. "," ..
        string.format("%.1f", v.Y or 0) .. "," .. string.format("%.1f", v.Z or 0) .. ")") or "nil" end
    print("[BG][Diag] index=" .. tostring(boardIndex) ..
        " actorLoc=" .. fmt(aloc) .. " 期望pos=" .. fmt(pos) .. " hidden=" .. hidden ..
        " camLoc=" .. fmt(clip) .. " camRot=" .. (crot and
            ("P" .. string.format("%.0f", crot.Pitch or 0) .. " Y" .. string.format("%.0f", crot.Yaw or 0)) or "nil"))

    -- 4) 距离 + 前向点积（>0 表示在相机前方）
    local function distDot(pt)
        if not pt or not clip then return nil end
        local dx, dy, dz = pt.X - (clip.X or 0), pt.Y - (clip.Y or 0), pt.Z - (clip.Z or 0)
        local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
        local dot = 0
        if crot then
            local p, y = math.rad(crot.Pitch or 0), math.rad(crot.Yaw or 0)
            local fx, fy, fz = math.cos(p) * math.cos(y), math.cos(p) * math.sin(y), math.sin(p)
            dot = dx * fx + dy * fy + dz * fz
        end
        return dist, dot
    end
    local function report(tag, pt)
        local dist, dot = distDot(pt)
        if dist then
            print("[BG][Diag] index=" .. tostring(boardIndex) .. " " .. tag ..
                " 距相机=" .. string.format("%.1f", dist) .. "m 前向点积=" .. string.format("%.1f", dot) ..
                (dot > 0 and " (相机前方)" or " (相机后方/侧面)"))
        end
    end
    report("挂件", aloc)
    -- 盘心参考点（已知方块在此渲染，能看见）——对照判断挂件是否偏出视野
    local board = Config.Board or {}
    local w = ((board.Cols or 10) - 1) * STEP_M
    local h = ((board.Rows or 20) - 1) * STEP_M
    local o, r = self.originM, self.rightM
    local center = {
        X = o.X + (r.X or 0) * (w / 2),
        Y = o.Y + (r.Y or 0) * (w / 2),
        Z = o.Z - h / 2,
    }
    report("盘心(可见参照)", center)
end

function ClientRenderer:_reanchorBackgroundWidget()
    if not self._bgWidget then return end
    local pos, rotObj = bgTransform(self, self._bgBoardIndex or 1)
    if not pos then return end
    -- K2_SetActorLocation 单位 cm（÷ 见文件头单位纪律：CreateActor 用 m，K2 用 cm）
    local cm = Game:ConstructFVectorByLuaTable({
        X = pos.X * 100, Y = pos.Y * 100, Z = pos.Z * 100,
    })
    if rotObj then pcall(function() self._bgWidget:K2_SetActorRotation(rotObj, false) end) end
    pcall(function() self._bgWidget:K2_SetActorLocation(cm, false, nil, true) end)
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

-- ===================== 远景背景挂件灌图（客户端自包含） =====================
-- 设难度图键（battle 进入对局时调用：单人 Easy/Normal/Hard，双人 Human）。模块级，两个 renderer 共用。
function ClientRenderer.SetBackgroundImageKey(key)
    if type(key) == "string" and key ~= "" then BG_IMAGE_KEY = key end
end

-- 从 uw 里按「真实控件名 → 配置名 → 遍历带 SetImageContent 的子控件」定位图片控件。
local function findWidgetImage(uw)
    if not uw then return nil, "uw=nil" end
    local cfg = Config.BackgroundWidget or {}
    local names = { "Creative_CustomImage_C_5400", cfg.ImageChildName, "Image", "image", "Background" }
    if type(uw.GetWidgetFromName) == "function" then
        for _, nm in ipairs(names) do
            if nm and nm ~= "" then
                local ok, img = pcall(function() return uw:GetWidgetFromName(nm) end)
                if ok and img and type(img.SetImageContent) == "function" then
                    return img, "name=" .. tostring(nm)
                end
            end
        end
    end
    if type(uw.GetAllWidgets) == "function" then
        local ok, all = pcall(function() return uw:GetAllWidgets() end)
        if ok and all then
            local okN, n = pcall(function()
                return (type(all.Num) == "function") and all:Num() or #all
            end)
            if okN then
                for i = 0, (tonumber(n) or 0) - 1 do
                    local okC, c = pcall(function()
                        return (type(all.Get) == "function") and all:Get(i) or all[i + 1]
                    end)
                    if okC and c and type(c.SetImageContent) == "function" then
                        return c, "traverse[" .. tostring(i) .. "]"
                    end
                end
            end
        end
    end
    return nil, "not-found"
end

-- 轮询灌图：SetWidget 异步加载 UMG，uw 就绪后定位图片控件并写入难度图。
function ClientRenderer:_tryPaintBackgroundWidget(actor, idx, tries)
    if not actor then return end
    local wc = nil
    pcall(function() wc = actor:GetComponentByName("WidgetComponent") end)
    if not wc then pcall(function() wc = actor:GetComponentByClass("WidgetComponent") end) end
    if not wc then
        if tries < 12 then
            pcall(function() actor:AddTimerOnce(1.0, function() self:_tryPaintBackgroundWidget(actor, idx, tries + 1) end) end)
        end
        return
    end
    -- 每次补关 billboard（SetWidget/UMG 加载可能重置朝向状态）
    self:_applyBillboardOff(wc, "灌图try" .. tostring(tries))

    -- 【官方最新建议】SetWidget 是异步流程，等 1 秒后再取；原来用 GetUserWidgetObject 是对的。
    -- 优先 GetUserWidgetObject，GetWidget 仅作兜底。
    local uw = nil
    local uwVia = "GetUserWidgetObject"
    pcall(function() uw = wc:GetUserWidgetObject() end)
    if not uw then
        pcall(function() uw = wc:GetWidget() end)
        if uw then uwVia = "GetWidget" end
    end
    if not uw then
        print("[BG][Paint] index=" .. tostring(idx) .. " try=" .. tostring(tries) ..
            " uw=nil (GetUserWidgetObject/GetWidget 均空)，等待 UMG 加载")
        if tries < 12 then
            pcall(function() actor:AddTimerOnce(1.0, function() self:_tryPaintBackgroundWidget(actor, idx, tries + 1) end) end)
        end
        return
    end
    -- 诊断：确认拿到的是 WoWClientUserWidget，且带 GetWidgetFromName
    local uwGFN, uwGAW = "?", "?"
    pcall(function() uwGFN = tostring(type(uw.GetWidgetFromName)) end)
    pcall(function() uwGAW = tostring(type(uw.GetAllWidgets)) end)
    print("[BG][Paint] 取到uw index=" .. tostring(idx) .. " try=" .. tostring(tries) ..
        " via=" .. uwVia ..
        " uwType=" .. type(uw) .. " GetWidgetFromName=" .. uwGFN .. " GetAllWidgets=" .. uwGAW)

    local img, how = findWidgetImage(uw)
    if not img then
        local hasGFN, hasGAW = "?", "?"
        pcall(function() hasGFN = tostring(type(uw.GetWidgetFromName)) end)
        pcall(function() hasGAW = tostring(type(uw.GetAllWidgets)) end)
        print("[BG][Paint] index=" .. tostring(idx) .. " try=" .. tostring(tries) ..
            " 图片控件未找到 reason=" .. tostring(how) ..
            " uw.GetWidgetFromName=" .. hasGFN .. " uw.GetAllWidgets=" .. hasGAW)
        if tries < 12 then
            pcall(function() actor:AddTimerOnce(1.0, function() self:_tryPaintBackgroundWidget(actor, idx, tries + 1) end) end)
        end
        return
    end

    local cfg = Config.BackgroundWidget or {}
    local images = cfg.OpponentImages or {}
    local imgKey = images[BG_IMAGE_KEY] or images.Human
    local imgRef = resolveRef(imgKey)
    local okSet = pcall(function() img:SetImageContent(imgRef) end)
    pcall(function() if wc.RequestRedraw then wc:RequestRedraw() end end)
    print("[BG][Paint] 灌图成功 index=" .. tostring(idx) .. " try=" .. tostring(tries) ..
        " via=" .. tostring(how) .. " key=" .. tostring(BG_IMAGE_KEY) ..
        " imgKey=" .. tostring(imgKey) .. " ref=" .. tostring(imgRef) .. " ok=" .. tostring(okSet))
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
    if self._bgWidget then
        pcall(function() CreativeGameAPI.DestroyActor(self._bgWidget) end)
        self._bgWidget = nil
    end
    self._clearActors = nil
    self._pool = {}
    self._compCache = nil
end

return ClientRenderer
