-- 消行得分数字（3D Actor UI）：消行时在盘面右侧、被消行区域竖直居中显示 1 个 +XX，1.7s 后归还。
-- 多行只显示一个「本次消行总分」，文字由 doClear() 前后的 score 差值得到。
--
-- 对象池放在模块级 local：require 单例 → 对战双方两个 TetrisGame 共用同一份池。
-- 池初始预热 2 个；free 为空时【直接新建】（池满也新建，不设上限），符合「池满就创建新的」。
-- 摆到哪一盘由借用方 renderer 的 origin / boardCenter / boardRight / boardYaw 决定。
--
-- 单位：CreativeGameAPI.CreateActor 是 Domain API，Location 用米；
--       K2_TeleportTo 是 Class API，用厘米（下面 cmVec 显式换算）。
-- 资源：PresetKey 走 AssetRef["<Key>"] 句柄；须在 WOW Editor 注册 + update preset 后才可解析。
-- 防闪字：创建/回收时把 score 文本置空；显示前先写文本，写进所有玩家 UMG 后才取消隐藏。
local TetrisConfig = require("EnvLua.Server.Tetris.TetrisConfig")

local TetrisScorePopup = {}

local pool = {
    free = {},          -- 空闲条目（Actor 已隐藏）
    busy = {},          -- 借出中（重开时由 Reset 强制收回）
    built = 0,          -- 已创建 Actor 总数
    serial = 0,         -- 借用代际 token，防旧定时器误归还已复用的条目
    generation = 0,     -- Reset 代际，让上一局残留定时器自动失效
    refWarned = false,
    failWarned = false,
}

-- 前向声明：createEntry 在文件前半段就要清空文本，而写入函数定义在后面。
local writeText, clearText

local function cfg()
    return TetrisConfig.ScorePopup or {}
end

-- 米 -> 厘米向量（Class API 如 K2_TeleportTo 用厘米）
local function cmVec(loc)
    return Game:ConstructFVectorByLuaTable({ X = loc.X * 100, Y = loc.Y * 100, Z = loc.Z * 100 })
end

local function hideActor(actor)
    pcall(function()
        if actor.SetActorHiddenInGame then actor:SetActorHiddenInGame(true) end
    end)
end

local function showActor(actor)
    pcall(function()
        if actor.SetActorHiddenInGame then actor:SetActorHiddenInGame(false) end
    end)
end

-- 文本挂件旋转：按「每个盘面实例」的 boardYaw + 本模块自己的双盘偏航偏置，
-- 与 ClearRowFrameRot 同构但读 ScorePopup.RotationBiasByIndex，避免两套配置互相串用。
local function popupRot(renderer)
    if type(renderer) ~= "table" then return nil end
    local c = cfg()
    local bias = 0
    if type(c.RotationBiasByIndex) == "table" then
        bias = c.RotationBiasByIndex[renderer.boardIndex] or 0
    end
    local yaw = (renderer.boardYaw or 0) + bias
    if type(FRotator) == "table" and FRotator.MakeFromEuler then
        local ok, rot = pcall(function()
            return FRotator.MakeFromEuler(Game:ConstructFVectorByLuaTable({ X = 0, Y = 0, Z = yaw }))
        end)
        if ok and rot then return rot end
    end
    return renderer.rot
end

-- 右侧 + 多行上下居中的位置（米）。
-- 水平：盘心 + right*(半宽 + SideOffsetM)，再沿 boardForward 前置 DistanceFrontM。
-- 竖直：取被消行区域的中心行 (minRow+maxRow)/2，按与 cellLocation 一致的 o.Z - (row-1)*step 换算。
local function popupLoc(renderer, rows)
    local r = TetrisConfig.Render
    local c = cfg()
    local step = r.CellSize + r.CellGap
    local o = renderer.origin or r.BoardOrigin
    local right = renderer.boardRight or { X = 1, Y = 0, Z = 0 }
    local fwd = renderer.boardForward or { X = 0, Y = 1, Z = 0 }
    local center = renderer.boardCenter
    if not center then
        local w = (TetrisConfig.Board.Cols - 1) * step
        center = { X = o.X + right.X * (w / 2), Y = o.Y + right.Y * (w / 2), Z = o.Z }
    end
    local minRow, maxRow = nil, nil
    for _, row in ipairs(rows) do
        local n = tonumber(row)
        if n then
            if not minRow or n < minRow then minRow = n end
            if not maxRow or n > maxRow then maxRow = n end
        end
    end
    if not minRow then return nil end
    local midRow = (minRow + maxRow) / 2
    local halfW = (TetrisConfig.Board.Cols - 1) * step / 2
    local side = halfW + (type(c.SideOffsetM) == "number" and c.SideOffsetM or 0)
    local D = (type(c.DistanceFrontM) == "number") and c.DistanceFrontM or 0
    local hgt = (type(c.HeightOffsetM) == "number") and c.HeightOffsetM or 0
    return {
        X = center.X + right.X * side + fwd.X * D,
        Y = center.Y + right.Y * side + fwd.Y * D,
        Z = o.Z - (midRow - 1) * step + hgt,
    }
end

-- 新建池条目：ActorPreset(AssetRef) + CreativeGameAPI.CreateActor（Location 单位米）。
-- 新建时直接把 loc 交给 CreateActor，避免异步 spawn 后的首次 Teleport 被丢弃。
local function createEntry(loc, rot)
    local c = cfg()
    local key = c.PresetKey
    local ref = (type(AssetRef) == "table" and AssetRef[key])
        or (type(CreativeAsset) == "table" and CreativeAsset[key])
    if not ref then
        if not pool.refWarned then
            pool.refWarned = true
            print("[Tetris][ScorePopup][WARN] 资源键未注册(占位待替换): " .. tostring(key))
        end
        return nil
    end
    local sc = c.Scale or { X = 1, Y = 1, Z = 1 }
    local scaleVec = Game:ConstructFVectorByLuaTable({
        X = sc.X or 1, Y = sc.Y or 1, Z = sc.Z or 1,
    })
    local ok, obj = pcall(function()
        if type(CreativeGameAPI) == "table" and CreativeGameAPI.CreateActor then
            return CreativeGameAPI.CreateActor(ref, Game:ConstructFVectorByLuaTable(loc), rot, scaleVec, nil)
        end
        return nil
    end)
    if not ok or not obj then
        if not pool.failWarned then
            pool.failWarned = true
            print("[Tetris][ScorePopup][WARN] Actor 创建失败: " .. tostring(obj))
        end
        return nil
    end
    pool.built = pool.built + 1
    print(string.format("[Tetris][ScorePopup] 新建 Actor (累计 %d)", pool.built))
    local e = { actor = obj }
    -- 初始化：先隐藏，再把 score 文本置空，去掉编辑器里预置的默认文字。
    -- 异步 spawn 时这条清空可能未生效，显示前 place() 还会再写一次正确值。
    hideActor(obj)
    clearText(e)
    return e
end

-- 3D 挂件子文本写入：GetUserWidgetObject(pawn) 按玩家角色返回各自的 UMG 实例，
-- 必须遍历所有 pawn，否则第 2 名玩家看到的是编辑器默认文本。
-- 子控件无 InstanceUUID，不能用 CustomUIAPI.SetTextContent(uuid, ...)，须直接对控件对象写。
-- 返回是否对【所有】玩家的 UMG 都写入成功；未成功时调用方需继续补写。
writeText = function(e, text)
    local actor = e.actor
    local childName = cfg().ChildName or "score"
    local wc
    pcall(function()
        if type(actor.GetComponentByClass) == "function" then
            wc = actor:GetComponentByClass("WidgetComponent")
        end
    end)
    if not wc then
        pcall(function()
            for _, nm in ipairs({ "UI", "Widget", "WidgetComp", "WidgetComponent" }) do
                local okC, comp = pcall(function() return actor:GetComponentByName(nm) end)
                if okC and comp then wc = comp; break end
            end
        end)
    end
    if not wc then return false end
    local plist
    pcall(function() plist = Game:GetAllPlayerPawns() end)
    if not plist or type(plist.Num) ~= "function" then return false end
    local n = plist:Num()
    if n <= 0 then return false end
    -- 缓存按「已写入的文本 + pawn 数量」判定：内容变了必须重写。
    -- 只看 pawn 数会让初始化/回收写入的空文本短路掉本次的正确分数。
    if e.appliedText == text and e.textPawnN == n then return true end
    local written = 0
    for i = 0, n - 1 do
        local pawn = plist:Get(i)
        if pawn then
            local uw
            pcall(function() uw = wc:GetUserWidgetObject(pawn) end)
            if not uw then pcall(function() uw = wc:GetWidget(pawn) end) end
            if uw then
                local tw
                pcall(function() tw = uw:GetWidgetFromName(childName) end)
                if tw and type(tw.SetTextContent) == "function" then
                    pcall(function() tw:SetTextContent(text) end)
                    written = written + 1
                end
            end
        end
    end
    if written >= n then
        e.appliedText = text
        e.textPawnN = n
        return true
    end
    if not e.textWarned then
        e.textWarned = true
        print(string.format("[Tetris][ScorePopup][WARN] 文本控件 '%s' 未全部命中(%d/%d)，持续补写",
            tostring(childName), written, n))
    end
    return false
end

-- 初始化 / 回收时把 score 文本置空。
-- 清空未确认时清掉 appliedText，保证下次显示一定会重新写入正确分数。
clearText = function(e)
    if not writeText(e, "") then
        e.appliedText = nil
        e.textPawnN = nil
    end
end

-- 每帧补摆：CreateActor 异步，首次位置/显隐可能被静默丢弃（项目既有坑）。
-- 【防闪字】先把文本写进所有玩家的 UMG，再决定显隐：文本尚未写成功时保持隐藏，
-- 避免先露出编辑器默认值或上一次的 +XX；UMG 长时间不就绪时由 Show 置 textForced 强制显示。
-- K2_TeleportTo 的两个参数都不能为 nil，故 rot 为空时只切显隐。
local function place(e)
    local ok = writeText(e, e.text or "")
    if ok or e.textForced then
        showActor(e.actor)
    else
        hideActor(e.actor)
    end
    if e.loc and e.rot then
        pcall(function() e.actor:K2_TeleportTo(cmVec(e.loc), e.rot) end)
    end
end

local function release(e)
    if not e then return end
    e.token = nil
    for i = #pool.busy, 1, -1 do
        if pool.busy[i] == e then table.remove(pool.busy, i) end
    end
    hideActor(e.actor)
    -- 回收：清空本次分数，避免下次复用时先闪出上一次的 +XX
    e.textWarned = false
    clearText(e)
    e.text = nil
    e.textForced = false
    pool.free[#pool.free + 1] = e
end

local function acquire(loc, rot)
    local e = table.remove(pool.free)
    if not e then
        e = createEntry(loc, rot)   -- 池满也新建，不设上限
        if not e then return nil end
    end
    pool.serial = pool.serial + 1
    e.token = pool.serial
    pool.busy[#pool.busy + 1] = e
    return e
end

-- 开局预热：补齐到 PoolSize 个（默认 2），创建后立即隐藏。
-- 资源仍是占位时 createEntry 会静默跳过，等真实资源注册后自动生效。
function TetrisScorePopup.Prewarm(renderer)
    if not cfg().Enabled or type(renderer) ~= "table" then return end
    local target = (type(cfg().PoolSize) == "number") and cfg().PoolSize or 2
    local loc = renderer.hideLoc or popupLoc(renderer, { 1 }) or TetrisConfig.Render.BoardOrigin
    local rot = popupRot(renderer)
    while pool.built < target do
        local e = createEntry(loc, rot)
        if not e then break end
        hideActor(e.actor)
        pool.free[#pool.free + 1] = e
    end
end

-- 重开 / 回合结束：强制收回所有借出条目。
-- 模块级池跨局存活，而 owner 的定时器可能已被 Release 清掉，不回收会导致新局借不到 Actor。
function TetrisScorePopup.Reset()
    pool.generation = pool.generation + 1
    for i = #pool.busy, 1, -1 do
        local e = table.remove(pool.busy, i)
        if e then
            e.token = nil
            e.text = nil
            e.textForced = false
            hideActor(e.actor)
            pool.free[#pool.free + 1] = e
        end
    end
    -- 初始化：所有条目（含原本就空闲的）保持隐藏并把文本一律置空，杜绝跨局残留的旧分数。
    for _, e in ipairs(pool.free) do
        hideActor(e.actor)
        e.textWarned = false
        clearText(e)
    end
end

-- 消行时调用：rows = 被消除的行号列表（多行只弹一个总分，位置取行区间中心）
-- delta = 本次消行的得分增量（doClear 前后 board.score 差值）；owner 借宿 AddTimerOnce。
function TetrisScorePopup.Show(owner, renderer, rows, delta)
    local c = cfg()
    if not c.Enabled then return false end
    local gain = tonumber(delta) or 0
    if gain <= 0 then return false end
    if type(rows) ~= "table" or #rows == 0 then return false end
    if not owner or not renderer then return false end   -- owner 可能是引擎包装对象，不做类型判断
    if type(renderer) ~= "table" then return false end
    local loc = popupLoc(renderer, rows)
    if not loc then return false end
    local rot = popupRot(renderer)
    local value = math.floor(gain + 0.5)
    local okFmt, formatted = pcall(function()
        return string.format(c.Format or "+%d", value)
    end)
    local text = (okFmt and formatted) or ("+" .. tostring(value))

    local e = acquire(loc, rot)
    if not e then return false end
    e.loc, e.rot, e.text = loc, rot, text
    e.textForced = false
    e.textWarned = false
    -- 条目在创建 / 回收时已置空；这里先写正确分数再决定显隐，避免闪字
    place(e)

    local gen = pool.generation
    local token = e.token
    local interval = (type(c.TickInterval) == "number" and c.TickInterval > 0) and c.TickInterval or 0.05
    -- UMG 长时间不就绪时的兜底：强制显示，并继续在 tick 里补写正确分数
    local readyTimeout = (type(c.TextReadyTimeout) == "number") and c.TextReadyTimeout or 0.4
    owner:AddTimerOnce(readyTimeout, function()
        if gen ~= pool.generation or e.token ~= token then return end
        e.textForced = true
        place(e)
    end)
    -- CreateActor 异步 spawn + 各玩家 UMG 延迟就绪：显示窗口内持续补摆 / 补写
    local function tick()
        if gen ~= pool.generation or e.token ~= token then return end
        place(e)
        owner:AddTimerOnce(interval, tick)
    end
    owner:AddTimerOnce(interval, tick)
    owner:AddTimerOnce((type(c.Duration) == "number") and c.Duration or 1.7, function()
        if gen ~= pool.generation or e.token ~= token then return end
        release(e)
    end)
    return true
end

return TetrisScorePopup
