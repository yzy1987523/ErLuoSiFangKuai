-- 俄罗斯方块数据层：纯逻辑，不依赖任何引擎 API。
-- 渲染层只读取本模块的状态（getCell / getActivePiece），不参与计算。
-- 约定：grid[row][col]，row 1 = 顶行，row Rows = 底行；col 1 = 最左列。
local TetrisConfig = require("EnvLua.Server.Tetris.TetrisConfig")

local TetrisBoard = {}
TetrisBoard.__index = TetrisBoard

local pieceType = TetrisConfig.PieceType

-- ---------------- 工具：矩阵旋转 ----------------
-- 顺时针 90°：newM[i][j] = oldM[N + 1 - j][i]
local function rotateMatrixCW(m)
    local n = #m
    local out = {}
    for i = 1, n do
        out[i] = {}
        for j = 1, n do
            out[i][j] = m[n + 1 - j][i]
        end
    end
    return out
end

-- 预生成每种方块的 4 个旋转态
local function buildRotationStates(shape)
    local states = { shape }
    local cur = shape
    for _ = 1, 3 do
        cur = rotateMatrixCW(cur)
        states[#states + 1] = cur
    end
    return states
end

local rotationStates = {}
for id, def in pairs(TetrisConfig.Pieces) do
    rotationStates[id] = buildRotationStates(def.shape)
end

-- ---------------- 构造 / 重置 ----------------
function TetrisBoard:new()
    local o = setmetatable({}, self)
    o:reset()
    return o
end

function TetrisBoard:reset()
    local cfg = TetrisConfig.Board
    self.cols = cfg.Cols
    self.rows = cfg.Rows

    -- grid[row][col] = 0 空，或方块类型 ID（1..7，同时代表颜色）
    self.grid = {}
    for r = 1, self.rows do
        self.grid[r] = {}
        for c = 1, self.cols do
            self.grid[r][c] = 0
        end
    end

    self.bag = {}                 -- 7-bag 随机袋
    self.active = nil             -- 当前下落方块 { type, rot, x, y }
    self.holdType = nil           -- Hold 暂存方块类型
    self.canHold = true           -- 每次落地前只能用一次 Hold
    self.nextQueue = {}           -- 预览队列
    self:fillQueue()

    self.score = 0
    self.lines = 0
    self.level = 1
    self.combo = -1               -- -1 表示上一次未消除，用于 combo 计数
    self.isGameOver = false
    self.pendingGarbage = 0       -- 待注入的垃圾行数（对战用）
    self.outgoingGarbage = 0      -- 本次 lock 应发给对手的垃圾行数（对战用，外层消费）
    self.spawnSeq = 0             -- 生成计数，供外层检测"是否产出了新方块"
    self.lastSpawned = nil
    -- 渲染层消费用的瞬时标记（消行 parent-shift 用）
    self.pendingClearedRows = nil     -- 本次 lockPiece 被消除的行号列表
    self.pendingGarbageMoved = nil    -- 本次是否发生过垃圾行上移（会导致普通位移公式失效）
    self.clearing = false              -- 消行动画期间置 true：挂起出块与重力，等动画结束后 finishClear()

    self:applyInitialLayout()
    self:spawn()
    return self
end

-- ---------------- 初始预填版面 ----------------
-- 从 TetrisConfig.InitialLayout 读取，写入 grid[row][col]。
-- 时机：reset 末尾、spawn 之前；初始满行是否立即消除由 Game 层控制（AutoClearOnStart）。
function TetrisBoard:applyInitialLayout()
    local cfg = TetrisConfig.InitialLayout
    if not cfg or not cfg.Enabled then return end

    local function writeLine(r, line)
        line = line or ""
        for c = 1, math.min(self.cols, #line) do
            local ch = line:sub(c, c)
            if ch ~= "." and ch ~= " " then
                local v = tonumber(ch)
                if v and v >= 1 and v <= 8 then
                    self.grid[r][c] = v
                end
            end
        end
    end

    if cfg.Rows then
        for r = 1, math.min(self.rows, #cfg.Rows) do
            writeLine(r, cfg.Rows[r])
        end
    end
    if cfg.ByRow then
        for r, line in pairs(cfg.ByRow) do
            if r >= 1 and r <= self.rows then
                writeLine(r, line)
            end
        end
    end
end

-- ---------------- 随机袋（7-bag） ----------------
function TetrisBoard:refillBag()
    self.bag = {}
    for i = 1, 7 do
        self.bag[i] = i
    end
    -- Fisher-Yates 洗牌
    for i = #self.bag, 2, -1 do
        local j = math.random(1, i)
        self.bag[i], self.bag[j] = self.bag[j], self.bag[i]
    end
end

function TetrisBoard:nextPieceType()
    if #self.bag == 0 then
        self:refillBag()
    end
    return table.remove(self.bag, 1)
end

function TetrisBoard:fillQueue()
    while #self.nextQueue < 3 do
        self.nextQueue[#self.nextQueue + 1] = self:nextPieceType()
    end
end

-- ---------------- 方块生成 ----------------
function TetrisBoard:spawn(typeOverride)
    local t = typeOverride
    if not t then
        t = table.remove(self.nextQueue, 1)
        self:fillQueue()
    end

    local size = #TetrisConfig.Pieces[t].shape
    -- 水平居中：列偏移 = floor((cols - size) / 2) + 1
    local x = math.floor((self.cols - size) / 2) + 1
    local y = 1  -- 顶行对齐，矩阵内的空行使方块视觉上略靠下

    self.active = { type = t, rot = 1, x = x, y = y }
    self.canHold = true

    -- 生成快照：外层据此判断是否产出了新方块（用于调试上屏）
    self.spawnSeq = (self.spawnSeq or 0) + 1
    self.lastSpawned = { type = t, rot = 1, x = x, y = y, seq = self.spawnSeq }

    -- 生成即无法放置 => 顶到天，游戏结束
    if not self:canPlace(self.active, x, y, 1) then
        self.isGameOver = true
    end
    return not self.isGameOver
end

-- ---------------- 碰撞检测 ----------------
-- 判断方块以 (x, y, rot) 放置时是否合法（不越界、不与已固定格子重叠）
function TetrisBoard:canPlace(piece, x, y, rot)
    local m = rotationStates[piece.type][rot]
    local n = #m
    for r = 1, n do
        for c = 1, n do
            if m[r][c] == 1 then
                local gr = y + r - 1
                local gc = x + c - 1
                if gc < 1 or gc > self.cols then return false end
                if gr > self.rows then return false end
                if gr >= 1 then
                    if self.grid[gr][gc] ~= 0 then return false end
                end
                -- gr < 1 表示还在盘面上方，允许
            end
        end
    end
    return true
end

-- ---------------- 操作 ----------------
function TetrisBoard:move(dx)
    if self.isGameOver or not self.active then return false end
    local p = self.active
    if self:canPlace(p, p.x + dx, p.y, p.rot) then
        p.x = p.x + dx
        return true
    end
    return false
end

-- 取 SRS 踢墙偏移表（数据层与渲染层共享 TetrisConfig.Rotation）。
-- 返回形如 { {x,y}, ... } 的列表，y 向上为正（棋盘向下为正，应用时 newY = y - ky）。
function TetrisBoard:getKicks(type, fromRot, toRot)
    local f = (fromRot - 1) % 4
    local t = (toRot - 1) % 4
    local R = TetrisConfig.Rotation
    if type == TetrisConfig.PieceType.I then
        return (R.I[f] and R.I[f][t]) or { { 0, 0 } }
    elseif type == TetrisConfig.PieceType.O then
        return { { 0, 0 } }   -- O 旋转不变形，仅原地（枢轴即 4×4 框中心）
    else
        return (R.JLSTZ[f] and R.JLSTZ[f][t]) or { { 0, 0 } }
    end
end

-- 旋转：dir = 1 顺时针，-1 逆时针；带 SRS 踢墙（依次尝试偏移表，含纵向）。
function TetrisBoard:rotate(dir)
    if self.isGameOver or not self.active then return false end
    local p = self.active
    local n = #rotationStates[p.type]
    local from = p.rot
    local to = ((p.rot - 1 + dir) % n) + 1
    if to == p.rot then return false end

    local kicks = self:getKicks(p.type, from, to)
    for _, k in ipairs(kicks) do
        -- SRS 偏移 (kx, ky)，ky 向上为正；棋盘 y 向下为正 → newY = p.y - ky
        if self:canPlace(p, p.x + k[1], p.y - k[2], to) then
            p.x = p.x + k[1]
            p.y = p.y - k[2]
            p.rot = to
            return true
        end
    end
    return false
end

-- 软降一格：成功返回 true，触底返回 false
function TetrisBoard:softDrop()
    if self.isGameOver or not self.active then return false end
    local p = self.active
    if self:canPlace(p, p.x, p.y + 1, p.rot) then
        p.y = p.y + 1
        self.score = self.score + TetrisConfig.Score.SoftDropPerCell
        return true
    end
    return false
end

-- 硬降：直接落到底并锁定
function TetrisBoard:hardDrop()
    if self.isGameOver or not self.active then return false end
    local p = self.active
    local dist = 0
    while self:canPlace(p, p.x, p.y + 1, p.rot) do
        p.y = p.y + 1
        dist = dist + 1
    end
    self.score = self.score + dist * TetrisConfig.Score.HardDropPerCell
    self:lockPiece()
    return true
end

-- Hold：与暂存方块交换，每个方块落地前仅一次
function TetrisBoard:hold()
    if self.isGameOver or not self.active or not self.canHold then return false end
    local cur = self.active.type
    local swap = self.holdType
    self.holdType = cur

    if swap then
        -- 用暂存方块替换当前，位置重置到顶部
        local size = #TetrisConfig.Pieces[swap].shape
        self.active = {
            type = swap,
            rot = 1,
            x = math.floor((self.cols - size) / 2) + 1,
            y = 1,
        }
        if not self:canPlace(self.active, self.active.x, self.active.y, 1) then
            self.isGameOver = true
        end
    else
        -- 首次使用：暂存当前，直接取下一个
        self:spawn()
    end
    -- 必须放在最后：spawn() 内部会把 canHold 重置为 true
    self.canHold = false
    return true
end

-- ---------------- 锁定与消行 ----------------
function TetrisBoard:lockPiece()
    if not self.active then return end
    local p = self.active
    local m = rotationStates[p.type][p.rot]
    local n = #m

    local lockedCells = {}
    for r = 1, n do
        for c = 1, n do
            if m[r][c] == 1 then
                local gr = p.y + r - 1
                local gc = p.x + c - 1
                if gr >= 1 and gr <= self.rows and gc >= 1 and gc <= self.cols then
                    self.grid[gr][gc] = p.type
                    lockedCells[#lockedCells + 1] = { row = gr, col = gc }
                end
            end
        end
    end
    -- 记录本次锁定方块的原始格位置（消行前的行号），供渲染层在消行重排前先提交为静态块，
    -- 使其能像普通旧块一样参与 delta 计算与延迟下落。
    self.pendingLockedCells = (#lockedCells > 0) and lockedCells or nil
    self.active = nil

    local cleared = self:clearLines()
    self:applyGarbage()
    if cleared > 0 then
        -- 消行：动画(渲染层 ClearDelay 秒)未结束前不出块。active 保持 nil、clearing 置位，
        -- 由 Game 层在动画结束后调用 finishClear() 重新出块，避免新块在消除未完成时就出现/下落。
        self.clearing = true
    else
        self:spawn()
    end
    return cleared
end

-- 消除满行，返回消除行数。
-- countScore：默认 true（正常锁定消除，计分/连击/升级）；false 用于开局初始消除，仅清网格、不污染分数。
function TetrisBoard:clearLines(countScore)
    local cleared = 0
    local writeRow = self.rows

    local clearedRows = {}
    for r = self.rows, 1, -1 do
        local full = true
        for c = 1, self.cols do
            if self.grid[r][c] == 0 then
                full = false
                break
            end
        end
        if full then
            cleared = cleared + 1
            clearedRows[#clearedRows + 1] = r
        else
            if writeRow ~= r then
                -- 把当前行下移到 writeRow
                for c = 1, self.cols do
                    self.grid[writeRow][c] = self.grid[r][c]
                end
            end
            writeRow = writeRow - 1
        end
    end
    -- 记录本次被消除的行，供渲染层做 parent-shift（方块整体下落动画）
    self.pendingClearedRows = (#clearedRows > 0) and clearedRows or nil
    -- 顶部剩余行清空
    for r = writeRow, 1, -1 do
        for c = 1, self.cols do
            self.grid[r][c] = 0
        end
    end

    if cleared > 0 then
        if countScore ~= false then
            local base = TetrisConfig.Score.LineClear[cleared] or 0
            self.score = self.score + base * self.level
            self.combo = self.combo + 1
            if self.combo > 0 then
                self.score = self.score + TetrisConfig.Score.ComboBonus * self.combo * self.level
            end
            self.lines = self.lines + cleared
            local newLevel = math.min(
                math.floor(self.lines / TetrisConfig.Timing.LinesPerLevel) + 1,
                TetrisConfig.Timing.MaxLevel
            )
            if newLevel > self.level then self.level = newLevel end
        end
    else
        if countScore ~= false then
            self.combo = -1
        end
    end
    -- 对战：把本次消除应发给对手的垃圾行数记下来，供外层（TetrisGame/TetrisMatch）消费
    if cleared > 0 and countScore ~= false then
        self.outgoingGarbage = (TetrisConfig.Versus and TetrisConfig.Versus.GarbageTable and TetrisConfig.Versus.GarbageTable[cleared]) or 0
    else
        self.outgoingGarbage = 0
    end
    return cleared
end

-- 渲染层消费：取走本次被消除的行号（取后清空，避免重复处理）
function TetrisBoard:consumeClearedRows()
    local r = self.pendingClearedRows
    self.pendingClearedRows = nil
    return r
end

-- 渲染层消费：取走本次锁定方块的原始格位置（取后清空，避免重复提交）
function TetrisBoard:consumeLockedCells()
    local c = self.pendingLockedCells
    self.pendingLockedCells = nil
    return c
end

-- 渲染层消费：本次是否发生过垃圾行上移（取后清空）
function TetrisBoard:consumedGarbageMoved()
    local g = self.pendingGarbageMoved
    self.pendingGarbageMoved = nil
    return g
end

-- ---------------- 垃圾行（对战） ----------------
function TetrisBoard:addGarbage(count)
    if not count or count <= 0 then return end
    local cap = TetrisConfig.Versus and TetrisConfig.Versus.MaxPending
    if cap and self.pendingGarbage + count > cap then
        count = cap - self.pendingGarbage
    end
    if count < 0 then count = 0 end
    self.pendingGarbage = self.pendingGarbage + count
end

-- 对战：取走本次应发给对手的垃圾行数（取后清零，避免重复发送）
function TetrisBoard:consumeOutgoingGarbage()
    local g = self.outgoingGarbage or 0
    self.outgoingGarbage = 0
    return g
end

-- 从底部注入垃圾行：整行填充，随机留一个缺口
function TetrisBoard:applyGarbage()
    local count = self.pendingGarbage
    if count <= 0 then return 0 end
    self.pendingGarbage = 0
    self.pendingGarbageMoved = true   -- 垃圾行上移会改变方块位置，渲染层应退化为逐格重排

    for _ = 1, count do
        -- 整体上移一行，顶行被挤出（若顶行非空则游戏结束）
        for r = 1, self.rows - 1 do
            for c = 1, self.cols do
                self.grid[r][c] = self.grid[r + 1][c]
            end
        end
        local gap = math.random(1, self.cols)
        for c = 1, self.cols do
            self.grid[self.rows][c] = (c == gap) and 0 or 8  -- 8 = 垃圾块颜色
        end
    end

    -- 上移导致方块越顶即结束
    for c = 1, self.cols do
        if self.grid[1][c] ~= 0 then
            self.isGameOver = true
            break
        end
    end
    return count
end

-- ---------------- 重力 tick ----------------
-- 每个重力周期调用一次：能下落则下落一格，否则锁定
function TetrisBoard:tick()
    if self.isGameOver then return false end
    if self.clearing then return false end  -- 消行动画期间暂停重力与出块，等 finishClear()
    if not self.active then
        self:spawn()
        return false
    end
    local p = self.active
    if self:canPlace(p, p.x, p.y + 1, p.rot) then
        p.y = p.y + 1
        return true
    end
    self:lockPiece()
    return false
end

-- 消行动画结束后由 Game 层调用：解除挂起并出下一个方块（见 lockPiece 的 clearing 逻辑）。
function TetrisBoard:finishClear()
    if not self.clearing then return false end
    self.clearing = false
    self:spawn()
    return true
end

-- ---------------- 供渲染层读取 ----------------
-- 返回 grid[row][col]：0 空，1..7 方块颜色，8 垃圾块
function TetrisBoard:getCell(row, col)
    if row < 1 or row > self.rows or col < 1 or col > self.cols then return 0 end
    return self.grid[row][col]
end

-- 当前下落方块整体状态 {type, rot, x, y}（或 nil），供渲染层整体方块使用
function TetrisBoard:getActive()
    return self.active
end

-- 当前下落方块占用的格子列表 {{row, col, colorType}, ...}，供渲染层叠加显示
function TetrisBoard:getActiveCells()
    local out = {}
    if not self.active then return out end
    local p = self.active
    local m = rotationStates[p.type][p.rot]
    local n = #m
    for r = 1, n do
        for c = 1, n do
            if m[r][c] == 1 then
                local gr = p.y + r - 1
                local gc = p.x + c - 1
                if gr >= 1 and gr <= self.rows and gc >= 1 and gc <= self.cols then
                    out[#out + 1] = { row = gr, col = gc, colorType = p.type }
                end
            end
        end
    end
    return out
end

-- 幽灵块（硬降落点预览）
function TetrisBoard:getGhostCells()
    local out = {}
    if not self.active then return out end
    local p = self.active
    local ghostY = p.y
    while self:canPlace(p, p.x, ghostY + 1, p.rot) do
        ghostY = ghostY + 1
    end
    local m = rotationStates[p.type][p.rot]
    local n = #m
    for r = 1, n do
        for c = 1, n do
            if m[r][c] == 1 then
                local gr = ghostY + r - 1
                local gc = p.x + c - 1
                if gr >= 1 and gr <= self.rows and gc >= 1 and gc <= self.cols then
                    out[#out + 1] = { row = gr, col = gc, colorType = p.type }
                end
            end
        end
    end
    return out
end

function TetrisBoard:getGravityInterval()
    local t = TetrisConfig.Timing.GravityIntervalByLevel
    return t[math.min(self.level, #t)]
end

function TetrisBoard:isOver()
    return self.isGameOver
end

function TetrisBoard:getNextQueue()
    return self.nextQueue
end

function TetrisBoard:getHoldType()
    return self.holdType
end

-- 调试用：把盘面打印成字符串
function TetrisBoard:dump()
    local s = ""
    for r = 1, self.rows do
        for c = 1, self.cols do
            s = s .. (self.grid[r][c] == 0 and "." or tostring(self.grid[r][c]))
        end
        s = s .. "\n"
    end
    return s
end

return TetrisBoard
