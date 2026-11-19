-- 俄罗斯方块 AI 对手：纯逻辑，给定 board 计算最优落点 {rot, x}。
-- 评分采用经典特征（消行 / 空洞 / 凹凸 / 总高），偏好消行多、空洞少、表面平整的摆放。
local TetrisConfig = require("EnvLua.Common.Tetris.TetrisConfig")

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

-- 评估一个盘面：分数越高越好（Dellacherie 风格特征：消行/落地高度/空洞/凹凸）
-- maxHeight 为落子后盘面最高点（行号越小越高），用于计算落地高度惩罚。
local function evaluate(g, rows, cols, maxHeight)
    local heights = {}
    local holes = 0
    for c = 1, cols do
        local h = 0
        local seen = false
        for r = 1, rows do
            if g[r][c] ~= nil then
                if not seen then h = rows - r + 1; seen = true end
            elseif seen then
                holes = holes + 1   -- 悬空空位 = 空洞
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
            if g[r][c] == nil then full = false; break end
        end
        if full then lines = lines + 1 end
    end
    -- [AI 改进] 落地高度：块堆得越高越差（y 越小越高）。用最高点代替误伤平铺的 agg 线性惩罚，
    -- 让 AI 愿意保留规整空行做消行，而不是为避免增高把方块摊得到处都是。
    local landing = rows - (maxHeight or rows) + 1   -- 越高 landing 越大
    -- 权重：消行奖励最大，空洞惩罚最重，落地高度/凹凸次之
    return lines * 120 - holes * 70 - landing * 4 - bump * 2 - agg * 0.5
end

-- 计算当前下落方块的最优落点。返回 {rot=旋转态, x=列, y=落点行} 或 nil（无合法落点=即将顶出）。
-- quality 参数保留以兼容调用方（TetrisAIDriver 按难度传入），但不再影响落点：所有难度一律取最优。
-- 难度差异改由 TetrisAIDriver 的 tier 控制（下落速度 + 技能释放时机），落点质量三档一致。
function TetrisAI.bestMove(board, quality)
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
                local maxHeight = rows  -- 落子后最高点（行号最小者）
                for _, cc in ipairs(cells) do
                    local gr = y + cc.r - 1
                    local gc = x + cc.c - 1
                    if gr >= 1 and gr <= rows and gc >= 1 and gc <= cols then
                        g[gr][gc] = type
                        if gr < maxHeight then maxHeight = gr end
                    end
                end
                local sc = evaluate(g, rows, cols, maxHeight)
                if sc > bestScore then
                    bestScore = sc
                    best = { rot = rot, x = x, y = y }
                end
            end
        end
    end
    if not best then return nil end

    -- [落点策略] 所有难度一律取最优落点：quality 只影响下落速度/技能时机，不再随机退化落点。
    -- 因此三个难度的 AI 落点质量一致，差异体现在节奏与技能释放（见 TetrisAIDriver 的 tier 逻辑）。
    return best
end

return TetrisAI
