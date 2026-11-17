-- P3：服务端 AI 对手（纯数据，无界面/无 Actor/无结算/无排行榜）。
-- 持有一个 Board，用 TetrisAI 决策 + Bot 内部状态机推进，周期性产出快照供广播给客户端对手盘。
-- 只依赖 Common 纯逻辑 + host 的定时器，不依赖任何 Server 渲染/UI/音效模块。
local Board = require("EnvLua.Common.Tetris.TetrisBoard")
local TetrisAI = require("EnvLua.Common.Tetris.TetrisAI")
local Snapshot = require("EnvLua.Common.Tetris.TetrisSnapshot")
local TetrisConfig = require("EnvLua.Common.Tetris.TetrisConfig")

local TetrisAIDriver = {}
TetrisAIDriver.__index = TetrisAIDriver

function TetrisAIDriver:new(host, opts)
    opts = opts or {}
    local o = setmetatable({}, self)
    o.host = host
    o.quality = opts.quality or 0.8
    o.tag = opts.tag or "AI"
    o.interval = opts.interval or 0.15        -- AI 决策/推进步长（秒）
    o.snapshotEvery = opts.snapshotEvery or 3 -- 每 N 步广播一次快照
    o.board = nil
    o.running = false
    o.stepCount = 0
    o.aiSeq = 0
    o._timer = nil
    return o
end

function TetrisAIDriver:Start()
    if self.running then return end
    self.board = Board:new()
    self.board.index = 1
    self.board.isAI = true
    self.board:spawn()
    self.running = true
    self.stepCount = 0
    print("[P3][AIDriver] Start quality=" .. tostring(self.quality) .. " tag=" .. tostring(self.tag))
    self:_schedule()
end

function TetrisAIDriver:Stop()
    self.running = false
    print("[P3][AIDriver] Stop")
end

function TetrisAIDriver:_schedule()
    if not self.running then return end
    local selfRef = self
    self._timer = self.host:AddTimerOnce(self.interval, function() selfRef:_step() end)
end

-- 推进游戏层状态机：lockPaused → doClear → clearing → 坍塌 → finishClear。
function TetrisAIDriver:_advanceClear(b)
    if b.lockPaused then
        pcall(function() b:doClear() end)
    end
    if b.clearing then
        -- applyClearCollapse 会让上方块下落；随后解除 clearing 并出下一块
        pcall(function() b:applyClearCollapse() end)
        pcall(function() b:finishClear() end)
    end
end

-- AI 决策：旋转+平移到 bestMove，然后硬降落子（避开 lock delay，纯数据快速演进）。
function TetrisAIDriver:_aiPlace(b)
    if b.isGameOver or b.clearing or b.lockPaused then return end
    local a = b:getActive()
    if not a then return end
    if self.aiSeq == b.spawnSeq then return end  -- 本块已规划
    local plan = TetrisAI.bestMove(b, self.quality)
    self.aiSeq = b.spawnSeq
    if not plan then return end
    local guard = 0
    while b.active and b.active.rot ~= plan.rot and guard < 5 do
        if not b:rotate(1) then break end
        guard = guard + 1
    end
    guard = 0
    while b.active and b.active.x ~= plan.x and guard < (b.cols + 2) do
        local dx = b.active.x < plan.x and 1 or -1
        if not b:move(dx) then break end
        guard = guard + 1
    end
    pcall(function() b:hardDrop() end)
end

function TetrisAIDriver:_step()
    if not self.running then return end
    local b = self.board
    if not b then self:_schedule(); return end

    self:_advanceClear(b)
    if not b.isGameOver then
        if not b:getActive() then
            pcall(function() b:spawn() end)
        else
            self:_aiPlace(b)
        end
    end

    self.stepCount = self.stepCount + 1
    if self.stepCount % self.snapshotEvery == 0 or b.isGameOver then
        self:_broadcastSnapshot()
    end
    if b.isGameOver then
        print("[P3][AIDriver] AI 顶出，停止。score=" .. tostring(b.score))
        self.running = false
        return
    end
    self:_schedule()
end

function TetrisAIDriver:_broadcastSnapshot()
    local snap = Snapshot.Capture(self.board, { tag = self.tag })
    -- 通过 GameState 广播：方法名 P3_OnAISnapshot 需在客户端 ClassicGameState 定义
    local ok, err = pcall(function()
        local gs = Game:GetGameState()
        if gs then gs:CallClientFunctionMulticast("P3_OnAISnapshot", snap) end
    end)
    if not ok then
        print("[P3][AIDriver] 广播快照失败: " .. tostring(err))
    end
end

return TetrisAIDriver
