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
    -- [节奏对齐] 下落/落石用时间累计控制，与真人盘一致（不随 interval 步长）
    o._fallElapsed = 0    -- 普通方块重力累计（达 getGravityInterval 下落一格）
    o._stoneElapsed = 0   -- 落石累计（达 FallingStoneInterval 下落一格）
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
            -- [统一动画框架] 分阶段坍塌展示走完后，按消行来源分支收尾：
            if self._clearIsRockfall then
                -- 落石消行：不计分/不道具/不垃圾/不攻击，afterRockfallClear 决定继续落石或结束出块。
                -- 坍塌（applyClearCollapse）已在 showRows→showCollapse 转换时执行，这里不重复。
                pcall(function() b:afterRockfallClear() end)
                self._clearIsRockfall = false
                self._clearPhase = nil
                print("[Rockfall][AI] 落石消行收尾完成 fallingStone=" .. tostring(b.fallingStone))
            else
                -- 普通消行：坍塌 → 垃圾升起 → 出块 → 消费 outgoing 上报给真人。
                pcall(function() b:applyClearCollapse() end)
                pcall(function() b:applyGarbage() end)
                local ok, err = pcall(function() b:finishClear() end)
                if not ok then print("[ClearDbg][AI][ERR] finishClear 报错: " .. tostring(err)) end
                self:_flushOutgoingToHuman(b)
                self._clearPhase = nil
                print("[ClearDbg][AI] clearing 出块完成 active=" .. tostring(b:getActive() ~= nil))
            end
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

    -- [落石] AI 盘被真人扔落石后，fallingStone 期间只驱动石头下落，禁止普通方块 spawn/重力。
    -- [节奏] 按 FallingStoneInterval（默认0.25s）累计时间才下落一格，与真人盘 ClientGame:_scheduleRockfall 一致，
    -- 不再每 0.1s 步长走一格（之前落石一闪而过看不到过程）。
    if b.fallingStone then
        -- [统一动画框架] 落石消行一旦进入 clearing，就交给 _advanceClear 走与普通消行相同的
        -- showRows(0.6s)→坍塌→showCollapse(0.3s) 分阶段，不再同步瞬间收尾。
        -- beginRockfallClear 兜底已 clearLines(false) 清满行+设 _clearFullRows/pendingClearedRows，动画数据齐备。
        if b.clearing then
            if self._clearPhase == nil then
                -- 首次进入：取被消行号播特效 + 启动分阶段（与普通消行完全一致的前摇）
                local rows = nil
                pcall(function() rows = b:consumeClearedRows() end)
                if rows and #rows > 0 and self.host and type(self.host.PlayClearFxForSeat) == "function" then
                    local oppSeat = self.host._oppSeat or 1
                    pcall(function() self.host:PlayClearFxForSeat(oppSeat, rows) end)
                    print("[Rockfall][AI] 落石消行播特效 行数=" .. tostring(#rows))
                end
                self._clearIsRockfall = true
                self._clearPhase = "showRows"
                self._clearWait = 6
                self:_broadcastSnapshot()
            end
            -- 交回主状态机驱动分阶段（下面不 return，继续走 _advanceClear）
        else
            local stoneInterval = (TetrisConfig.Timing and TetrisConfig.Timing.FallingStoneInterval) or 0.25
            self._stoneElapsed = (self._stoneElapsed or 0) + self.interval
            if self._stoneElapsed >= stoneInterval then
                self._stoneElapsed = self._stoneElapsed - stoneInterval
                pcall(function() b:stepStones() end)
                self:_broadcastSnapshot()   -- 落石每下落一格发快照，客户端能看到逐格下落
            end
            self.stepCount = self.stepCount + 1
            self:_schedule()
            return
        end
    end

    self:_advanceClear(b)
    -- 消行/锁定挂起期间禁止 spawn 与下落：否则 clearing 等待阶段 active 为 nil 会被误判为"需要出块"，
    -- 提前 spawn 破坏分阶段过程（客户端就看不到满行消失→坍塌的过程）。
    local busy = b.clearing or b.lockPaused
    if not b.isGameOver and not busy then
        if not b:getActive() then
            pcall(function() b:spawn() end)
            self._fallElapsed = 0
        elseif self.aiSeq ~= b.spawnSeq then
            -- 新块：规划一次（旋转+平移到位），本步暂不下落
            self:_planPiece(b)
            self._fallElapsed = 0
        else
            -- [节奏对齐真人] 已规划的块：按 Board 重力间隔累计时间，达一格才 softDrop，
            -- 与真人盘 getGravityInterval()（当前0.8s）一致，不再每 0.1s 落一格。
            local gInterval = 0.8
            pcall(function() gInterval = b:getGravityInterval() or 0.8 end)
            self._fallElapsed = (self._fallElapsed or 0) + self.interval
            if self._fallElapsed >= gInterval then
                self._fallElapsed = self._fallElapsed - gInterval
                local dropped = false
                pcall(function() dropped = b:softDrop() end)
                if not dropped and not b.isGameOver then
                    pcall(function() b:lockPiece() end)
                end
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

-- [垃圾桥接] AI 消行产生的攻击行同步给真人盘：消费 outgoing → 经 GameState 以 fromKey=0
-- （AI 无固定 playerKey）广播 garbage 事件；客户端 OnVersusEvent 因 from==0 不过滤，
-- 走 ApplyVersusEffect("garbage") → addGarbage + Recv 提示。同时播扔垃圾拖尾特效。
function TetrisAIDriver:_flushOutgoingToHuman(b)
    local outgoing = 0
    local stoneAttacks = 0
    pcall(function() outgoing = b:consumeOutgoingGarbage() or 0 end)
    pcall(function() stoneAttacks = b:consumeStoneAttack() or 0 end)
    if outgoing <= 0 and stoneAttacks <= 0 then return end
    local gs = Game:GetGameState()
    if not gs then return end
    -- fromKey=0：客户端过滤规则 `from ~= 0 and from == selfKey` 不会拦 AI 事件
    if outgoing > 0 then
        pcall(function()
            gs:CallClientFunctionMulticast("P5_VersusEvent", "garbage", outgoing, 0, nil)
        end)
        -- [特效] AI 盘扔垃圾：用 AI seat 播拖尾特效（起点 AI 盘、终点真人盘）。
        if self.host and type(self.host.PlayGarbageFx) == "function" then
            local aiSeat = self.host._oppSeat or 1
            pcall(function() self.host:PlayGarbageFx(aiSeat, self._fxRows) end)
        end
        print("[Versus][AI] 扔垃圾给真人 +" .. tostring(outgoing) .. " 行")
    end
    -- [落石] AI 消除落石块 → 上报真人（每个落石块一轮 5~9 随机列灰块）
    for _ = 1, stoneAttacks do
        pcall(function()
            gs:CallClientFunctionMulticast("P5_VersusEvent", "rockfall", math.random(5, 9), 0, nil)
        end)
    end
    if stoneAttacks > 0 then
        print("[Rockfall][AI] 消除落石块 " .. tostring(stoneAttacks) .. " 个 → 上报真人")
    end
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
