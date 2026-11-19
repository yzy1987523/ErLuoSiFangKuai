-- P3：服务端 AI 对手（纯数据，无界面/无 Actor/无结算/无排行榜）。
-- 持有一个 Board，用 TetrisAI 决策 + Bot 内部状态机推进，周期性产出快照供广播给客户端对手盘。
-- 只依赖 Common 纯逻辑 + host 的定时器，不依赖任何 Server 渲染/UI/音效模块。
local Board = require("EnvLua.Common.Tetris.TetrisBoard")
local TetrisAI = require("EnvLua.Common.Tetris.TetrisAI")
local Snapshot = require("EnvLua.Common.Tetris.TetrisSnapshot")
local TetrisConfig = require("EnvLua.Common.Tetris.TetrisConfig")

local TetrisAIDriver = {}
TetrisAIDriver.__index = TetrisAIDriver

-- 难度档位：按 quality 阈值划分（与 GameState 背景键 <=0.6/<=0.9 一致）
--   easy   (<=0.6)：不主动加速，按 Board 原重力间隔慢速逐格下落；技能等 5 回合
--   normal (<=0.9)：主动软降（每 interval 一格）；技能等 3 回合
--   hard   (>0.9) ：调整落点后直接硬降；满能量立即放技能
local function tierOf(quality)
    if quality <= 0.6 then return "easy" end
    if quality <= 0.9 then return "normal" end
    return "hard"
end

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
    -- [难度控制] 档位 + 技能释放等待回合数
    o.tier = tierOf(o.quality)
    o.skillDelayTurns = (o.tier == "easy" and 5) or (o.tier == "normal" and 3) or 0
    -- [技能] AI 用与玩家相同的技能；能量/回合状态（与真人规则一致：消行得 bar，满 NeedBars 换 power）
    o.skillKey = opts.skillKey or nil
    o._bars = 0
    o._power = 0
    o._turnsSinceCast = 0  -- 距上次释放技能已过的落块回合（用于「等待 X 回合」）
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
        local scoreBefore = b.score or 0
        -- [爆破行预检] doClear 前满行仍在网格里，先查出含爆破块的行号；清行后就查不到了。
        local blastRows = nil
        local okPre, rowsPre = pcall(function() return b:getFullRows() end)
        if okPre and rowsPre and #rowsPre > 0 then
            local okB, br = pcall(function() return b:getBlastRows(rowsPre) end)
            if okB and br and #br > 0 then blastRows = br end
        end
        local cleared = 0
        local ok, err = pcall(function() cleared = b:doClear() end)
        if not ok then print("[ClearDbg][AI][ERR] doClear 报错: " .. tostring(err)) end
        if cleared > 0 then self:_addEnergy(cleared) end  -- [技能] 消行积累能量（与真人规则一致）
        -- [特效] 对方/AI 盘消行：取被消行号，经 host(GameState) 在 seat1 播粒子特效（SceneEffectAPI ServerOnly），
        -- 并暂存行号随快照下发，让客户端 oppRenderer 也能画 3D 消行框。
        if cleared > 0 then
            local rows = b:consumeClearedRows()
            self._fxRows = (rows and #rows > 0) and rows or nil
            -- [垃圾特效] 单独留存消行行号：_fxRows 会随快照被清空，垃圾事件在稍后的收尾才发，
            -- 需要独立字段保证 payload 拿到真实行号。
            self._garbageRows = self._fxRows
            if self._fxRows and self.host then
                -- [特效] AI 盘用缓存的对手 seat（可能 0 或 1），与我方真人 seat 相反，避免特效左右互换
                local oppSeat = self.host._oppSeat or 1
                if type(self.host.PlayClearFxForSeat) == "function" then
                    -- 爆炸行传 blastRows：这些行改用与竖版相同的 100032，不播普通 3617487677
                    pcall(function() self.host:PlayClearFxForSeat(oppSeat, self._fxRows, blastRows) end)
                end
                -- [爆破特效] AI 盘爆破消列：服务端播竖版光束（与消行特效同源同 seat）
                local blastFx = b:consumeBlastFx()
                if blastFx and #blastFx > 0 and type(self.host.PlayBlastFxForSeat) == "function" then
                    pcall(function() self.host:PlayBlastFxForSeat(oppSeat, blastFx) end)
                end
                -- [飘字] AI 盘也弹 +XX / 连击评价（3D Actor，全员可见）
                if type(self.host.PlayScorePopupForSeat) == "function" then
                    local delta = (b.score or 0) - scoreBefore
                    pcall(function()
                        self.host:PlayScorePopupForSeat(oppSeat, self._fxRows, delta, b.combo or 0)
                    end)
                end
            end
        end
        print("[ClearDbg][AI] lockPaused→doClear cleared=" .. tostring(cleared) ..
            " clearing=" .. tostring(b.clearing))
        if cleared > 0 and b.clearing then
            self._clearPhase = "showRows"
            if blastRows and #blastRows > 0 then
                -- [爆炸消行] 特效同帧照常起播、完整播完(EffectDuration≈1s)后，再额外等 0.8s 才坍塌。
                -- 等待 = EffectDuration + BlastAfterFxDelay，按 driver 步长换算为 showRows 步数。
                local cl = TetrisConfig.Clear or {}
                local effDur = (type(cl.EffectDuration) == "number") and cl.EffectDuration or 1.0
                local afterFx = (type(cl.BlastAfterFxDelay) == "number") and cl.BlastAfterFxDelay or 0.4
                local blastWait = effDur + afterFx
                self._clearWait = math.max(1, math.floor(blastWait / (self.interval or 0.1) + 0.5))
            else
                self._clearWait = 6   -- 普通消行 6 步 × 0.1s ≈ 0.6s 展示满行消失
            end
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
    -- [落点校准] 旋转(SRS踢墙)/平移可能把块停在错误位置（顶部被占、noRotate 减益、踢墙偏移），
    -- 导致后续下落/硬降落在差位置（表现为「有时直接落下」）。校验未到位则直接把活动块设到
    -- bestMove 评估的精确落点（plan.x/plan.y/plan.rot），保证执行与评估一致。
    if b.active and (b.active.x ~= plan.x or b.active.rot ~= plan.rot) then
        if plan.y then
            local ok, pos = pcall(function()
                b.active.x = plan.x
                b.active.y = plan.y
                b.active.rot = plan.rot
                b.active.noRotate = nil
                b:markGhostDirty()
                return true
            end)
            if ok and pos then
                print("[P3][AIDriver] 落点校准→直接定位 x=" .. tostring(plan.x) ..
                    " y=" .. tostring(plan.y) .. " rot=" .. tostring(plan.rot))
                -- 直接定位到底：本块已就位，下一 _step 会走 lockPiece（softDrop 失败）或 hardDrop
            end
        end
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
            pcall(function() b:advance("aiIdle") end)   -- 统一门禁：落石轮次在 lock 后消费，此处仅空盘兜底出块
            self._fallElapsed = 0
        elseif self.aiSeq ~= b.spawnSeq then
            -- 新块：规划一次（旋转+平移到位），本步暂不下落
            self:_planPiece(b)
            self._fallElapsed = 0
            -- [回合] 每个新方块判定一次是否释放技能（回合累计在 _maybeCastSkill 内、有能量后才计）
            self:_maybeCastSkill(b)
        else
            -- [难度控制] 三档下落方式：
            --   hard   ：落点已在 _planPiece 调整到位，直接硬降落定（本步即锁）
            --   normal ：主动软降——每步下落一格，比原重力快
            --   easy   ：不主动加速，按 Board 原重力间隔（0.8s）逐格软降
            if self.tier == "hard" then
                pcall(function() b:hardDrop() end)
            elseif self.tier == "normal" then
                local dropped = false
                pcall(function() dropped = b:softDrop() end)
                if not dropped and not b.isGameOver then
                    pcall(function() b:lockPiece() end)
                end
            else
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
        -- [垃圾特效] payload 带 AI 本次消行行号，客户端据此定位拖尾起点（服务端 PlayGarbageFx 已由 SpawnSide=Client 关闭）
        pcall(function()
            gs:CallClientFunctionMulticast("P5_VersusEvent", "garbage", outgoing, 0, self._garbageRows)
        end)
        self._garbageRows = nil
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

-- [技能] 消行积累能量：每消 1 行得 1 bar，满 NeedBars 换 1 power（与真人 TetrisGame:onLinesCleared 一致）
function TetrisAIDriver:_addEnergy(cleared)
    local cfg = TetrisConfig.Skill or {}
    local need = cfg.NeedBars or 3
    local maxPower = cfg.MaxPower or 3
    for _ = 1, cleared do
        if (self._power or 0) >= maxPower then break end
        self._bars = (self._bars or 0) + 1
        if self._bars >= need then
            self._bars = 0
            self._power = math.min((self._power or 0) + 1, maxPower)
        end
    end
end

-- [技能] 每产出一块（一个回合）判定一次是否释放：
--   需已选技能 + 有 power；简单/普通按 skillDelayTurns 等回合，困难(0)立即放。
--   释放后回合计数归零（重新计数）。
function TetrisAIDriver:_maybeCastSkill(b)
    if not self.skillKey then return end
    if (self._power or 0) <= 0 then return end  -- 没能量：不计时、不放
    if b.isGameOver or b.clearing or b.lockPaused then return end
    -- 有能量起，每产出一个新方块算一回合；达到 wait 回合才释放（困难 wait=0 → 立即）
    self._turnsSinceCast = (self._turnsSinceCast or 0) + 1
    local need = self.skillDelayTurns or 0
    if self._turnsSinceCast < need then
        print("[Skill][AI] 等待释放 turns=" .. tostring(self._turnsSinceCast) .. "/" .. tostring(need))
        return
    end
    self:_castSkill(b, self.skillKey)
    self._power = (self._power or 0) - 1
    self._turnsSinceCast = 0  -- 释放后重新计数
end

-- [技能] 施放：self-buff 直接改 AI 盘；debuff 经 GameState 广播给真人客户端（from=0 不过滤）。
-- 效果对齐 TetrisGame:OnBtnSkill；UI 提示走现有 versus/快照链，不在本纯数据层绘制。
function TetrisAIDriver:_castSkill(b, key)
    print("[Skill][AI] 释放技能 key=" .. tostring(key) .. " tier=" .. tostring(self.tier))
    local gs = Game:GetGameState()
    local function broadcast(kind, n)
        if not gs then return end
        pcall(function() gs:CallClientFunctionMulticast("P5_VersusEvent", kind, n or 1, 0, nil) end)
    end
    if key == "SK01" then
        -- 敌方减益：真人下一块无法旋转
        broadcast("noRotate", 1)
    elseif key == "SK08" then
        -- 敌方减益：真人方向左右对调
        broadcast("swap", 1)
    elseif key == "SK02" then
        -- 己方增益：清 AI 盘最下方 N 行
        local def = TetrisConfig.Skills and TetrisConfig.Skills.SK02
        local n = (def and def.clearRows) or 2
        pcall(function() b:clearBottomRows(n) end)
    elseif key == "SK06" then
        -- 己方增益：下次消行攻击 +1
        b.attackBonusNext = (b.attackBonusNext or 0) + 1
    elseif key == "SK07" then
        -- 己方增益：下次消行额外多消一行（简化为立即清 AI 盘最下方 1 行）
        pcall(function() b:clearBottomRows(1, true) end)
    else
        print("[Skill][AI] 未知技能 key=" .. tostring(key))
    end
end

return TetrisAIDriver
