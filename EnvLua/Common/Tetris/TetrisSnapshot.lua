-- 棋盘快照：把 Board 的渲染相关状态打包成可跨端传输的精简 table。
-- 供 P2 验证「服务端发快照 → 客户端收快照 → ApplySnapshot 渲染」链路。
-- 纯 Lua，不依赖引擎 API，双端可用。
local TetrisSnapshot = {}

local Board = require("EnvLua.Common.Tetris.TetrisBoard")

-- 从真实 Board 实例构造快照 table。
-- grid 用扁平字符串编码：每格 1 字符（空='.'，色 1..8 用字符 '1'..'8'，道具格用其 item 值字符）。
-- 之所以不用嵌套 table，是为规避 RPC 对深层 table 的未知限制；扁平字符串最稳。
function TetrisSnapshot.Capture(board, meta)
    local rows, cols = board.rows, board.cols
    local lines = {}
    for r = 1, rows do
        local buf = {}
        for c = 1, cols do
            local cell = board.grid[r] and board.grid[r][c]
            if not cell then
                buf[#buf + 1] = "."
            elseif type(cell) == "number" then
                buf[#buf + 1] = tostring(cell)
            elseif type(cell) == "table" then
                -- { color=..., item=... }：优先用 item（道具块），否则 color
                local v = cell.item or cell.color or 0
                buf[#buf + 1] = string.char(48 + (v % 10))  -- 0->'0' 9->'9'
            else
                buf[#buf + 1] = "."
            end
        end
        lines[#lines + 1] = table.concat(buf)
    end
    local a = board:getActive()
    return {
        rows = rows,
        cols = cols,
        grid = table.concat(lines, "|"),   -- 行间用 | 分隔
        active = a and { type = a.type, rot = a.rot, x = a.x, y = a.y } or nil,
        activeCells = board.getActiveCells and board:getActiveCells() or nil,  -- P4 对手盘活动块渲染
        score = board.score or 0,
        lines = board.lines or 0,
        level = board.level or 1,
        over = board.isGameOver and true or false,
        tag = meta and meta.tag or "",            -- 发送方标识（AI/对手）
        senderKey = meta and meta.senderKey or 0, -- P5-5b 双人快照：发送者 playerKey，客户端据此过滤自己
    }
end

-- 从快照 table 还原可读信息（P2 只做校验打印，P4 接 Renderer）。
function TetrisSnapshot.Describe(snap)
    if type(snap) ~= "table" then return "非法快照:" .. tostring(snap) end
    local gridLen = snap.grid and #snap.grid or 0
    local rowCount = 0
    if type(snap.grid) == "string" then
        for _ in snap.grid:gmatch("[^|]+") do rowCount = rowCount + 1 end
    end
    return string.format("tag=%s %dx%d grid字符数=%d 行数=%d score=%s lines=%s level=%s over=%s active=%s",
        tostring(snap.tag), tostring(snap.cols), tostring(snap.rows), gridLen, rowCount,
        tostring(snap.score), tostring(snap.lines), tostring(snap.level), tostring(snap.over),
        snap.active and (tostring(snap.active.type) .. "@" .. tostring(snap.active.x) .. "," .. tostring(snap.active.y)) or "nil")
end

-- 把快照写回一个 Board 实例的渲染相关字段（P3 用于本地镜像校验；P4 供对手盘 Renderer 读取）。
function TetrisSnapshot.ApplyToBoard(snap, board)
    if type(snap) ~= "table" or not board then return false end
    local rows, cols = snap.rows or board.rows, snap.cols or board.cols
    board.rows, board.cols = rows, cols
    board.grid = board.grid or {}
    local rowIdx = 0
    for line in tostring(snap.grid or ""):gmatch("[^|]+") do
        rowIdx = rowIdx + 1
        if rowIdx <= rows then
            board.grid[rowIdx] = board.grid[rowIdx] or {}
            for c = 1, cols do
                local ch = line:sub(c, c)
                if ch == "." or ch == "" then
                    board.grid[rowIdx][c] = nil
                else
                    local v = tonumber(ch)
                    if v then board.grid[rowIdx][c] = { color = v } end
                end
            end
        end
    end
    board.score = snap.score or 0
    board.lines = snap.lines or 0
    board.level = snap.level or 1
    board.isGameOver = snap.over and true or false
    board.active = snap.active and {
        type = snap.active.type, rot = snap.active.rot, x = snap.active.x, y = snap.active.y,
    } or nil
    return true
end

-- 把快照转成 ClientRenderer 需要的 RenderState（对手盘渲染用）。
-- RenderState: grid[row][col]={color=1..8,item=nil}, active={cells={{row,col,colorType}}}, ghost=nil
function TetrisSnapshot.ToRenderState(snap)
    local rs = { grid = {}, active = nil, ghost = nil, nextQueue = {}, holdType = nil, effects = {} }
    if type(snap) ~= "table" then return rs end
    local rows, cols = snap.rows or 20, snap.cols or 10
    local r = 0
    for line in tostring(snap.grid or ""):gmatch("[^|]+") do
        r = r + 1
        if r <= rows then
            rs.grid[r] = {}
            for c = 1, cols do
                local ch = line:sub(c, c)
                if ch ~= "." and ch ~= "" then
                    local v = tonumber(ch)
                    if v then rs.grid[r][c] = { color = v } end
                end
            end
        end
    end
    if type(snap.activeCells) == "table" and #snap.activeCells > 0 then
        rs.active = { cells = snap.activeCells }
    elseif snap.active then
        rs.active = { type = snap.active.type, rot = snap.active.rot, x = snap.active.x, y = snap.active.y, cells = {} }
    end
    return rs
end

return TetrisSnapshot
