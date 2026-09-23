-- 俄罗斯方块 AI 对手：纯逻辑，给定 board 计算最优落点 {rot, x}。
-- 评分采用经典特征（消行 / 空洞 / 凹凸 / 总高），偏好消行多、空洞少、表面平整的摆放。
local TetrisConfig = require("EnvLua.Server.Tetris.TetrisConfig")

local TetrisAI = {}

-- 复制当前盘面（仅值），用于模拟落子后评估
local function cloneGrid(board)
    local g = {}
    for r = 1, board.rows do
        g[r] = {}
        for c = 1, board.cols do
            g[r][c] = board.grid[r][c]
        end
    end
    return g
end

-- 评估一个盘面：分数越高越好
local function evaluate(g, rows, cols)
    local heights = {}
    local holes = 0
    for c = 1, cols do
        local h = 0
        local seen = false
        for r = 1, rows do
            if g[r][c] ~= 0 then
                if not seen then h = rows - r + 1; seen = true end
            elseif seen then
                holes = holes + 1   -- 悬空空格 = 空洞
            end
        end
        heights[c] = h
    end
    local agg = 0
    for c = 1, cols do agg = agg + heights[c] end
    local bump = 0
    for c = 1, cols - 1 do bump = bump + math.abs(heights[c] - heights[c + 1]) end
    local lines = 0
    for r = 1, rows do
        local full = true
        for c = 1, cols do
            if g[r][c] == 0 then full = false; break end
        end
        if full then lines = lines + 1 end
    end
    -- 权重：消行奖励最大，空洞惩罚最重
    return lines * 100 - holes * 60 - bump * 3 - agg * 2
end

-- 计算当前下落方块的最优落点。返回 {rot=旋转态, x=列} 或 nil（无合法落点=即将顶出）
function TetrisAI.bestMove(board)
    local cols = board.cols
    local rows = board.rows
    local active = board:getActive()
    if not active then return nil end
    local type = active.type

    local best = nil
    local bestScore = -1e9
    for rot = 1, 4 do
        local cells = board:getPieceCells(type, rot)
        for x = 1, cols do
            -- 顶部合法性（y=1）；不合法直接跳过该列
            if board:canPlace({ type = type }, x, 1, rot) then
                -- 向下落到最低合法位置
                local y = 1
                while board:canPlace({ type = type }, x, y + 1, rot) do y = y + 1 end
                -- 模拟落子后的盘面
                local g = cloneGrid(board)
                for _, cc in ipairs(cells) do
                    local gr = y + cc.r - 1
                    local gc = x + cc.c - 1
                    if gr >= 1 and gr <= rows and gc >= 1 and gc <= cols then
                        g[gr][gc] = type
                    end
                end
                local sc = evaluate(g, rows, cols)
                if sc > bestScore then
                    bestScore = sc
                    best = { rot = rot, x = x }
                end
            end
        end
    end
    return best
end

return TetrisAI
