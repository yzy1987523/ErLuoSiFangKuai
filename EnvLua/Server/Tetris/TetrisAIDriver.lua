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
    o._clearPhase = nil   -- 消行分阶段：showRows → showCollapse → 出块
    o._clearWait = 0      -- 当前阶段剩余等待步数
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

-- 推进游戏层状态机：lockPaused → doClear → clearing(满行消失) → 坍塌 → 出块。
-- 拆成多步 + 每步发快照，客户端才能看到「满行亮起消失 → 上方块下落 → 出下一块」的完整消行过程；
-- 旧版在同一步跑完 doClear→collapse→finishClear，客户端只看到整行瞬间消失、无过程。
function TetrisAIDriver:_advanceClear(b)
    if b.lockPaused then
        local cleared = 0
        local ok, err = pcall(function() cleared = b:doClear() end)
        if not ok then print("[ClearDbg][AI][ERR] doClear 报错: " .. tostring(err)) end
        -- [特效] 对方/AI 盘消行：取被消行号，经 host(GameState) 在 seat1 播粒子特效（SceneEffectAPI ServerOnly），
        -- 并暂存行号随快照下发，让客户端 oppRenderer 也能画 3D 消行框。
        if cleared > 0 then
            local rows = b:consumeClearedRows()
            self._fxRows = (rows and #rows > 0) and rows or nil
            if self._fxRows and self.host and type(self.host.PlayClearFxForSeat) == "function" then
                -- [特效] AI 盘用缓存的对手 seat（可能 0 或 1），与我方真人 seat 相反，避免特效左右互换
                local oppSeat = self.host._oppSeat or 1
                pcall(function() self.host:PlayClearFxForSeat(oppSeat, self._fxRows) end)
            end
        end
        print("[ClearDbg][AI] lockPaused→doClear cleared=" .. tostring(cleared) ..
            " clearing=" .. tostring(b.clearing))
        if cleared > 0 and b.clearing then
            self._clearPhase = "showRows"
            self._clearWait = 6   -- 6 步 × 0.1s ≈ 0.6s 展示满行消失
        end
        return
    end
    if b.clearing then
        if self._clearPhase == "showRows" then
            self._clearWait = (self._clearWait or 0) - 1
            if self._clearWait > 0 then
                print("[ClearDbg][AI] clearing 展示满行消失 left=" .. tostring(self._clearWait))
                return
            end
            local ok, err = pcall(function() b:applyClearCollapse() end)
            if not ok then print("[ClearDbg][AI][ERR] applyClearCollapse 报错: " .. tostring(err)) end
            self._clearPhase = "showCollapse"
            self._clearWait = 3   -- 3 步 × 0.1s ≈ 0.3s 展示坍塌后阵列
            print("[ClearDbg][AI] clearing 已坍塌，等待出块")
            return
        elseif self._clearPhase == "showCollapse" then
            self._clearWait = (self._clearWait or 0) - 1
            if self._clearWait > 0 then
                print("[ClearDbg][AI] clearing 展示坍塌 left=" .. tostring(self._clearWait))
                return
            end
            local ok, err = pcall(function() b:finishClear() end)
            if not ok then print("[ClearDbg][AI][ERR] finishClear 报错: " .. tostring(err)) end
            self._clearPhase = nil
            print("[ClearDbg][AI] clearing 出块完成 active=" .. tostring(b:getActive() ~= nil))
            return
        else
            -- 兜底：clearing 挂起但无阶段记录 → 直接收尾，防止卡死
            pcall(function() b:applyClearCollapse() end)
            pcall(function() b:finishClear() end)
            self._clearPhase = nil
            print("[ClearDbg][AI] clearing 兜底收尾 clearing=" .. tostring(b.clearing))
            return
        end
    end
end

-- AI 规划：新块 spawn 后决策一次，旋转+平移到 bestMove 的 x/rot（不下落）。
-- 之后由 _step 每步 softDrop 一格，客户端就能看到逐格下落过程。
function TetrisAIDriver:_planPiece(b)
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
end

function TetrisAIDriver:_step()
    if not self.running then return end
    local b = self.board
    if not b then self:_schedule(); return end

    self:_advanceClear(b)
    -- 消行/锁定挂起期间禁止 spawn 与下落：否则 clearing 等待阶段 active 为 nil 会被误判为"需要出块"，
    -- 提前 spawn 破坏分阶段过程（客户端就看不到满行消失→坍塌的过程）。
    local busy = b.clearing or b.lockPaused
    if not b.isGameOver and not busy then
        if not b:getActive() then
            pcall(function() b:spawn() end)
        elseif self.aiSeq ~= b.spawnSeq then
            -- 新块：规划一次（旋转+平移到位），本步暂不下落
            self:_planPiece(b)
        else
            -- 已规划：逐格下落一格；触底则锁定（等价于硬降落点，但中间状态可见）
            local dropped = false
            pcall(function() dropped = b:softDrop() end)
            if not dropped and not b.isGameOver then
                pcall(function() b:lockPiece() end)
            end
        end
    end

    self.stepCount = self.stepCount + 1
    -- 每步发快照：客户端能看到 active.y 逐格递增的下落过程
    if b.isGameOver or self.snapshotEvery <= 1 or self.stepCount % self.snapshotEvery == 0 then
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
    -- [特效] 随快照下发一次性消行框行号（客户端 oppRenderer 据此画 3D 框），发后清空避免重复
    if self._fxRows then
        snap.clearedRows = self._fxRows
        self._fxRows = nil
    end
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
