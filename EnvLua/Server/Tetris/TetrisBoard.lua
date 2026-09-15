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

-- 预生成每种方块的 4 个旋转态（SRS）。
-- JLSTZ 走朴素 3x3 矩阵旋转（等价于 SRS）；I 用配置里的显式 4 态（朴素旋转会使其在踢墙表中错位）。
local function buildRotationStates(id, def)
    local srs = TetrisConfig.SRSRotationStates and TetrisConfig.SRSRotationStates[id]
    if srs then return srs end
    local states = { def.shape }
    local cur = def.shape
    for _ = 1, 3 do
        cur = rotateMatrixCW(cur)
        states[#states + 1] = cur
    end
    return states
end

local rotationStates = {}
for id, def in pairs(TetrisConfig.Pieces) do
    rotationStates[id] = buildRotationStates(id, def)
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
    self.spawnSeq = 0             -- 生成计数，供外层检测"是否产出了新方块"
    self.lastSpawned = nil
    self.lastWasRotation = false  -- 最近一次有效操作是否为旋转（T-Spin 判定用）
    self.lastKickIndex = nil      -- 旋转成功命中的踢墙偏移序号（1 起；>=4 触发 mini->full 升级）
    self.lastTSpin = "none"       -- 最近一次锁定产生的 T-Spin 结果："none"|"mini"|"full"

    self:spawn()
    return self
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
    -- 新方块入场：清除上一块的旋转/T-Spin 标记
    self.lastWasRotation = false
    self.lastKickIndex = nil
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

-- ---------------- T-Spin 判定（3 角规则） ----------------
-- 3x3 包围盒四角（1-indexed 盒内行列）按 rot 划分“前角/后角”。
-- rot：1=出生(尖朝上) 2=R(尖朝右) 3=2(尖朝下) 4=L(尖朝左)
local TSPIN_CORNERS = {
    [1] = { front = { {1,1}, {1,3} }, back = { {3,1}, {3,3} } },
    [2] = { front = { {1,3}, {3,3} }, back = { {1,1}, {3,1} } },
    [3] = { front = { {3,1}, {3,3} }, back = { {1,1}, {1,3} } },
    [4] = { front = { {1,1}, {3,1} }, back = { {1,3}, {3,3} } },
}

-- 网格坐标 (gx,gy) 是否被占据：左右墙/地板(越界)算占据；天花板(顶部之上)算空；盘内看 grid。
local function cornerOccupied(self, gx, gy)
    if gx < 1 or gx > self.cols or gy > self.rows then return true end
    if gy < 1 then return false end
    return self.grid[gy][gx] ~= 0
end

-- 返回 "none" | "mini" | "full"
function TetrisBoard:detectTSpin(p, wasRotation, kickIndex)
    if p.type ~= pieceType.T or not wasRotation then return "none" end
    local corners = { {1,1}, {1,3}, {3,1}, {3,3} }
    local filled = 0
    for _, cc in ipairs(corners) do
        if cornerOccupied(self, p.x + cc[2] - 1, p.y + cc[1] - 1) then
            filled = filled + 1
        end
    end
    if filled < 3 then return "none" end
    local c = TSPIN_CORNERS[p.rot]
    local frontFilled = cornerOccupied(self, p.x + c.front[1][2] - 1, p.y + c.front[1][1] - 1)
                     and cornerOccupied(self, p.x + c.front[2][2] - 1, p.y + c.front[2][1] - 1)
    if frontFilled then return "full" end
    -- mini：若命中第 4/5 个踢墙偏移（TST/fin 踢），按标准规则升级为 full
    if kickIndex and kickIndex >= 4 then return "full" end
    return "mini"
end

-- ---------------- 操作 ----------------
function TetrisBoard:move(dx)
    if self.isGameOver or not self.active then return false end
    local p = self.active
    if self:canPlace(p, p.x + dx, p.y, p.rot) then
        p.x = p.x + dx
        self.lastWasRotation = false   -- 平移会取消 T-Spin 资格
        return true
    end
    return false
end

-- 旋转：dir = 1 顺时针，-1 逆时针；使用 SRS 标准踢墙表（按方块分组：I 专属，其余用 JLSTZ 表）。
-- 成功时记录 lastWasRotation / lastKickIndex，供 lockPiece 里的 T-Spin 判定使用。
function TetrisBoard:rotate(dir)
    if self.isGameOver or not self.active then return false end
    local p = self.active
    local n = #rotationStates[p.type]
    local newRot = ((p.rot - 1 + dir) % n) + 1
    if newRot == p.rot then return false end

    local group = (p.type == pieceType.I) and TetrisConfig.SRSKicks.I or TetrisConfig.SRSKicks.JLSTZ
    local kicks = (group[p.rot] and group[p.rot][newRot]) or { {0, 0} }
    for i, k in ipairs(kicks) do
        local nx = p.x + k[1]
        local ny = p.y + k[2]
        if self:canPlace(p, nx, ny, newRot) then
            p.x = nx
            p.y = ny
            p.rot = newRot
            self.lastWasRotation = true
            self.lastKickIndex = i
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
        self.lastWasRotation = false   -- 下落会取消 T-Spin 资格
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
    self.lastWasRotation = false
    self.lastKickIndex = nil
    return true
end

-- ---------------- 锁定与消行 ----------------
function TetrisBoard:lockPiece()
    if not self.active then return end
    local p = self.active
    -- 落定瞬间判定 T-Spin（在写入 grid 之前，依据当前占用情况）
    local tspin = self:detectTSpin(p, self.lastWasRotation, self.lastKickIndex)

    local m = rotationStates[p.type][p.rot]
    local n = #m

    for r = 1, n do
        for c = 1, n do
            if m[r][c] == 1 then
                local gr = p.y + r - 1
                local gc = p.x + c - 1
                if gr >= 1 and gr <= self.rows and gc >= 1 and gc <= self.cols then
                    self.grid[gr][gc] = p.type
                end
            end
        end
    end
    self.active = nil

    local cleared = self:clearLines(tspin)
    self.lastTSpin = (tspin ~= "none") and tspin or "none"
    self:applyGarbage()
    self:spawn()
    return cleared
end

-- 消除满行，返回消除行数。tspin 为 "none"/"mini"/"full"：T-Spin 时计分用 T-Spin 表而非普通消行表。
function TetrisBoard:clearLines(tspin)
    local cleared = 0
    local writeRow = self.rows

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
    -- 顶部剩余行清空
    for r = writeRow, 1, -1 do
        for c = 1, self.cols do
            self.grid[r][c] = 0
        end
    end

    if cleared > 0 then
        -- T-Spin 与普通消行二选一计分：T-Spin 分值已内含消行收益，避免重复累加
        local base
        if tspin and tspin ~= "none" then
            if tspin == "full" then
                base = TetrisConfig.Score.TSpin.Full[cleared] or 0
            else
                base = TetrisConfig.Score.TSpin.Mini[cleared] or 0
            end
        else
            base = TetrisConfig.Score.LineClear[cleared] or 0
        end
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
    else
        self.combo = -1
    end
    return cleared
end

-- ---------------- 垃圾行（对战） ----------------
function TetrisBoard:addGarbage(count)
    self.pendingGarbage = self.pendingGarbage + count
end

-- 从底部注入垃圾行：整行填充，随机留一个缺口
function TetrisBoard:applyGarbage()
    local count = self.pendingGarbage
    if count <= 0 then return 0 end
    self.pendingGarbage = 0

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

-- ---------------- 供渲染层读取 ----------------
-- 返回 grid[row][col]：0 空，1..7 方块颜色，8 垃圾块
function TetrisBoard:getCell(row, col)
    if row < 1 or row > self.rows or col < 1 or col > self.cols then return 0 end
    return self.grid[row][col]
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
