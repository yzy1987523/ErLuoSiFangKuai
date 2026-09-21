-- 噗哟噗哟（四消）数据层：纯逻辑，不依赖任何引擎 API。
-- 渲染层只读取本模块状态（getCell / getActivePair / getNextPair / getGhostPair），不参与计算。
--
-- 盘面约定：grid[row][col]，row 1 = 顶行，row Rows = 底行；col 1 = 最左列。
-- 单元格值：0 空，1..Colors 颜色。
--
-- 活动对子 {c1, c2, x, y, rot}：以 c1 为枢轴位于 (x, y)，c2 相对枢轴：
--   rot=1 上 (x, y-1) | rot=2 右 (x+1, y) | rot=3 下 (x, y+1) | rot=4 左 (x-1, y)
local TetrisConfig = require("EnvLua.Server.Tetris.TetrisConfig")

local PuyoBoard = {}
PuyoBoard.__index = PuyoBoard

-- ---------------- 工具 ----------------
-- rot → 伙伴相对枢轴偏移 {dx, dy}（dy 向下为正）
local function partnerOffset(rot)
    if rot == 1 then return { 0, -1 } end   -- 上
    if rot == 2 then return { 1, 0 } end    -- 右
    if rot == 3 then return { 0, 1 } end    -- 下
    return { -1, 0 }                        -- 左 (rot=4)
end

-- 计算对子占用的两格 {row, col, color}
local function pairCells(p)
    local off = partnerOffset(p.rot)
    return {
        { row = p.y,     col = p.x,     color = p.c1 },
        { row = p.y + off[2], col = p.x + off[1], color = p.c2 },
    }
end

local function randColor(cfg)
    return math.random(1, cfg.Colors)
end

-- ---------------- 构造 / 重置 ----------------
function PuyoBoard:new()
    local o = setmetatable({}, self)
    o:reset()
    return o
end

function PuyoBoard:reset()
    local cfg = TetrisConfig.Puyo
    self.cols = cfg.Board.Cols
    self.rows = cfg.Board.Rows
    self.colors = cfg.Colors

    self.grid = {}
    for r = 1, self.rows do
        self.grid[r] = {}
        for c = 1, self.cols do
            self.grid[r][c] = 0
        end
    end

    self.nextQueue = {}       -- 后续对子队列（每项 {c1, c2}）
    self:fillQueue()

    self.active = nil         -- 当前下落对子 {c1, c2, x, y, rot}
    self.isGameOver = false
    self.score = 0
    self.chain = 0            -- 上一次锁定触发的连锁层数
    self.spawnSeq = 0
    self.lastSpawned = nil

    -- 渲染层消费用的瞬时标记
    self.pendingCleared = nil       -- 本次锁定被消除的格列表 {{row,col},...}
    self.pendingChain = 0           -- 本次连锁层数
    self.lockPaused = false         -- 落地停顿（暂未用动画，预留）
    self.clearing = false           -- 消除挂起（预留）

    self:spawn()
    return self
end

-- ---------------- 队列 ----------------
function PuyoBoard:nextPair()
    if #self.nextQueue == 0 then self:fillQueue() end
    return table.remove(self.nextQueue, 1)
end

function PuyoBoard:fillQueue()
    while #self.nextQueue < 2 do
        local cfg = TetrisConfig.Puyo
        self.nextQueue[#self.nextQueue + 1] = { c1 = randColor(cfg), c2 = randColor(cfg) }
    end
end

-- ---------------- 方块生成 ----------------
function PuyoBoard:spawn()
    local cfg = TetrisConfig.Puyo
    local pr = self:nextPair()
    local x = 3   -- 6 列居中（索引 1..6，枢轴落第 3 列）
    local y = 2
    local rot = 1

    self.active = { c1 = pr.c1, c2 = pr.c2, x = x, y = y, rot = rot }
    self.spawnSeq = (self.spawnSeq or 0) + 1
    self.lastSpawned = { c1 = pr.c1, c2 = pr.c2, x = x, y = y, rot = rot, seq = self.spawnSeq }

    -- 生成即无法放置 → 顶到天，游戏结束
    if not self:canPlacePair(self.active, x, y, rot) then
        self.isGameOver = true
    end
    self:fillQueue()
    return not self.isGameOver
end

-- ---------------- 碰撞检测 ----------------
function PuyoBoard:canPlacePair(p, x, y, rot)
    local off = partnerOffset(rot)
    local cells = {
        { row = y,     col = x, },
        { row = y + off[2], col = x + off[1] },
    }
    for _, cc in ipairs(cells) do
        local r, c = cc.row, cc.col
        if c < 1 or c > self.cols then return false end
        if r < 1 or r > self.rows then return false end
        if self.grid[r][c] ~= 0 then return false end
    end
    return true
end

-- ---------------- 操作 ----------------
function PuyoBoard:move(dx)
    if self.isGameOver or not self.active then return false end
    local p = self.active
    if self:canPlacePair(p, p.x + dx, p.y, p.rot) then
        p.x = p.x + dx
        return true
    end
    return false
end

-- 旋转：dir = 1 顺时针，-1 逆时针；简单踢墙（原地 → 左 → 右 → 上）
function PuyoBoard:rotate(dir)
    if self.isGameOver or not self.active then return false end
    local p = self.active
    local n = 4
    local to = ((p.rot - 1 + dir) % n) + 1   -- 保持 1..4：rot=1,dir=1 → 2；rot=4,dir=1 → 1
    if to == p.rot then return false end

    local kicks = { { 0, 0 }, { -1, 0 }, { 1, 0 }, { 0, -1 } }
    for _, k in ipairs(kicks) do
        if self:canPlacePair(p, p.x + k[1], p.y + k[2], to) then
            p.x = p.x + k[1]
            p.y = p.y + k[2]
            p.rot = to
            return true
        end
    end
    return false
end

-- 软降一格：成功返回 true，触底返回 false
function PuyoBoard:softDrop()
    if self.isGameOver or not self.active then return false end
    local p = self.active
    if self:canPlacePair(p, p.x, p.y + 1, p.rot) then
        p.y = p.y + 1
        return true
    end
    return false
end

-- 硬降：直接落到底并锁定
function PuyoBoard:hardDrop()
    if self.isGameOver or not self.active then return false end
    local p = self.active
    while self:canPlacePair(p, p.x, p.y + 1, p.rot) do
        p.y = p.y + 1
    end
    self:lockPair()
    return true
end

-- ---------------- 锁定与连锁消除 ----------------
function PuyoBoard:lockPair()
    if not self.active then return end
    local p = self.active
    local cells = pairCells(p)
    for _, cc in ipairs(cells) do
        if cc.row >= 1 and cc.row <= self.rows and cc.col >= 1 and cc.col <= self.cols then
            self.grid[cc.row][cc.col] = cc.color
        end
    end
    self.active = nil

    -- 连锁消除
    self:resolve()
    if not self.isGameOver then
        self:spawn()
    end
end

-- 4-连通同色组检测：返回所有 size >= 4 的组（每组为 { {row,col}, ... }）
local function findGroups(self)
    local visited = {}
    for r = 1, self.rows do visited[r] = {} end
    local groups = {}
    local function bfs(sr, sc, color)
        local stack = { { sr, sc } }
        visited[sr][sc] = true
        local comp = {}
        while #stack > 0 do
            local cur = table.remove(stack)
            local r, c = cur[1], cur[2]
            comp[#comp + 1] = { row = r, col = c }
            local neigh = { { r - 1, c }, { r + 1, c }, { r, c - 1 }, { r, c + 1 } }
            for _, nb in ipairs(neigh) do
                local nr, nc = nb[1], nb[2]
                if nr >= 1 and nr <= self.rows and nc >= 1 and nc <= self.cols then
                    if not visited[nr][nc] and self.grid[nr][nc] == color then
                        visited[nr][nc] = true
                        stack[#stack + 1] = { nr, nc }
                    end
                end
            end
        end
        return comp
    end

    for r = 1, self.rows do
        for c = 1, self.cols do
            if not visited[r][c] and self.grid[r][c] ~= 0 then
                local comp = bfs(r, c, self.grid[r][c])
                if #comp >= 4 then
                    groups[#groups + 1] = comp
                end
            end
        end
    end
    return groups
end

-- 逐列竖直下落填补空隙（噗哟：每个块独立下落，不做整体保持）
local function applyGravityColumn(self, c)
    local write = self.rows
    for r = self.rows, 1, -1 do
        if self.grid[r][c] ~= 0 then
            if write ~= r then
                self.grid[write][c] = self.grid[r][c]
                self.grid[r][c] = 0
            end
            write = write - 1
        end
    end
end

-- 连锁消除：循环 找组→消除→下落，直到无消除；累计 chain
function PuyoBoard:resolve()
    local totalCleared = {}
    local chain = 0
    while true do
        local groups = findGroups(self)
        if #groups == 0 then break end
        chain = chain + 1
        for _, g in ipairs(groups) do
            for _, cell in ipairs(g) do
                totalCleared[#totalCleared + 1] = { row = cell.row, col = cell.col }
                self.grid[cell.row][cell.col] = 0
            end
        end
        for c = 1, self.cols do
            applyGravityColumn(self, c)
        end
    end
    self.pendingCleared = (#totalCleared > 0) and totalCleared or nil
    self.pendingChain = chain
    self.chain = chain
    if chain > 0 then
        local bonus = TetrisConfig.Puyo.ChainBonus or {}
        local add = bonus[math.min(chain, #bonus)] or 0
        self.score = self.score + add
    end
end

-- ---------------- 重力 tick ----------------
function PuyoBoard:tick()
    if self.isGameOver then return false end
    if not self.active then
        self:spawn()
        return false
    end
    local p = self.active
    if self:canPlacePair(p, p.x, p.y + 1, p.rot) then
        p.y = p.y + 1
        return true
    end
    self:lockPair()
    return false
end

-- ---------------- 供渲染层读取 ----------------
function PuyoBoard:getCell(row, col)
    if row < 1 or row > self.rows or col < 1 or col > self.cols then return 0 end
    return self.grid[row][col]
end

-- 当前下落对子原始状态 {c1, c2, x, y, rot}（或 nil）
function PuyoBoard:getActivePair()
    return self.active
end

-- 当前对子占用的两格 {row, col, color}
function PuyoBoard:getActivePairCells()
    if not self.active then return {} end
    return pairCells(self.active)
end

-- 下一个对子颜色 {c1, c2}（预览）
function PuyoBoard:getNextPair()
    return self.nextQueue[1]
end

-- 幽灵（硬降落点）对子位置：沿当前 x 找到最终 y，保持 rot
function PuyoBoard:getGhostPair()
    if not self.active then return nil end
    local p = self.active
    local gy = p.y
    while self:canPlacePair(p, p.x, gy + 1, p.rot) do
        gy = gy + 1
    end
    local off = partnerOffset(p.rot)
    return {
        c1 = p.c1, c2 = p.c2, x = p.x, y = gy, rot = p.rot,
        cells = {
            { row = gy,     col = p.x,     color = p.c1 },
            { row = gy + off[2], col = p.x + off[1], color = p.c2 },
        },
    }
end

function PuyoBoard:getGravityInterval()
    return TetrisConfig.Puyo.GravityInterval or 0.8
end

function PuyoBoard:isOver()
    return self.isGameOver
end

-- 渲染层消费：取走本次被消除的格（取后清空）
function PuyoBoard:consumeCleared()
    local c = self.pendingCleared
    self.pendingCleared = nil
    return c
end

function PuyoBoard:getChain()
    return self.chain
end

-- 调试用：盘面打印
function PuyoBoard:dump()
    local s = ""
    for r = 1, self.rows do
        for c = 1, self.cols do
            s = s .. (self.grid[r][c] == 0 and "." or tostring(self.grid[r][c]))
        end
        s = s .. "\n"
    end
    return s
end

return PuyoBoard
