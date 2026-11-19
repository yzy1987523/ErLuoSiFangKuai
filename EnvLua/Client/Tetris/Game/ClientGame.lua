-- ClientGame：编排 Board 状态机 + 道具/技能/AI，不碰任何 UI 控件、不直接调引擎 API。
--
-- 纪律（见 .codebuddy/客户端重写功能清单.md）：
--   1. 不设置 board.game —— Board 残留的 UI/音效回调自然失效，表现只由 pending* 数据标记驱动。
--   2. 跨端 requester 用 playerKey 数字，不持有对方 Game 对象。
--   3. 所有 UI 表现通过 BuildUIState() 输出；渲染通过 renderer 接口；跨端通过 versus 接口。
--   4. 定时器统一走注入的 scheduler.After(seconds, fn)（点号调用；引擎侧用 AddTimerOnce 递归实现）。
--      【坑】注入端 After(delay,fn) 是点号签名，若用冒号 `scheduler:After` 会把 scheduler 表当首参传入，
--      delay 收到表、fn 收到数字 → AddTimerOnce 失败且被 pcall 吞掉 → 定时器（含提示图隐藏）永不触发。
local Config = require("EnvLua.Common.Tetris.TetrisConfig")
local TetrisAI = require("EnvLua.Common.Tetris.TetrisAI")
local Interfaces = require("EnvLua.Client.Tetris.Interfaces")

local ClientGame = {}
ClientGame.__index = ClientGame

local SKILL_CFG = Config.Skill or {}
local CLEAR_CFG = Config.Clear or {}
local TIMING_CFG = Config.Timing or {}

---@param board table TetrisBoard 实例（纯数据）
---@param deps table|nil { renderer, versus, scheduler, playerKey, isAI, quality }
function ClientGame:new(board, deps)
    deps = deps or {}
    local o = setmetatable({}, self)
    o.board = board
    o.renderer = deps.renderer
    o.versus = deps.versus
    o.audio = deps.audio   -- [音效] AudioManager 实例（客户端可用），仅真人盘注入
    o.scheduler = deps.scheduler or { After = function(delay, fn) fn() end }
    o.playerKey = deps.playerKey or 0
    o.isAI = deps.isAI == true
    o.quality = deps.quality or 1.0

    -- 技能数据层（与 Board 分离，UI 只读 UIState）
    o.power = 0
    o.bars = SKILL_CFG.InitBars or 0
    o.selectedSkills = {}
    o.cd = {}
    o.s06Charged = false
    o.s07Charged = false
    o.hints = {}
    o.lastSkill = nil
    -- [表现] Combo 图边沿检测：每次真实消行 comboSeq+1、clearRows=本次行数，供 UI 显示/换图
    o.comboSeq = 0
    o.clearRows = 0
    -- [表现] 扔垃圾提示：我方发出待落地的垃圾行数（>0 显示 Send 图，定时清零）
    o.garbageSent = 0
    o._garbageSentSeq = 0

    -- 状态机
    o.running = false
    o._clearBusy = false
    o._rockTimer = nil
    o._lastSpawnSeq = board.spawnSeq or 0
    o._lastOutgoing = 0

    -- AI 难度映射（清单 §6）
    o.aiQuality = deps.quality or 1.0
    return o
end

function ClientGame:_emitVersus(kind, n, payload)
    if self.versus and type(self.versus.Send) == "function" then
        self.versus:Send(kind, n, self.playerKey, payload)
    end
end

function ClientGame:_hint(name, seconds)
    self.hints[name] = true
    local dur = seconds or 1.7
    self.scheduler.After(dur, function()
        self.hints[name] = nil
        print("[Hint] 到期清除 " .. tostring(name) .. " (" .. tostring(dur) .. "s)")
    end)
end

-- ===================== 技能（数据层效果，不写控件） =====================
function ClientGame:SetSkills(list)
    self.selectedSkills = {}
    for _, key in ipairs(list or {}) do
        if Config.Skills and Config.Skills[key] then
            self.selectedSkills[#self.selectedSkills + 1] = key
        end
    end
end

function ClientGame:IsSkillReady(key)
    if not self:HasSkill(key) then return false end
    if (self.cd[key] or false) then return false end
    return self.power > 0
end

function ClientGame:HasSkill(key)
    for _, k in ipairs(self.selectedSkills) do if k == key then return true end end
    return false
end

--- 释放技能：扣 1 power，执行数据层效果，CD 与提示通过 UIState 输出。
---@param key string SK01/SK02/SK06/SK07/SK08
---@return boolean success, string|nil reason
function ClientGame:UseSkill(key)
    if not Config.SkillEnabled then return false, "disabled" end
    if not self:HasSkill(key) then return false, "notSelected" end
    if self.power <= 0 then return false, "noPower" end
    if self.cd[key] then return false, "cooling" end

    self.power = self.power - 1
    self.lastSkill = key
    -- [音效] 技能释放音（对齐旧 TetrisGame:PlaySkillSound）
    if self.audio and self.audio.PlaySkill then pcall(function() self.audio:PlaySkill() end) end
    local def = Config.Skills[key] or {}

    if key == "SK01" then
        -- 跨端：对手下一块禁止旋转（无 CD）
        self:_emitVersus("noRotate", 1)
    elseif key == "SK02" then
        -- 本地：清底 N 行，不计分/不送攻击
        self.board:clearBottomRows(def.clearRows or 2)
    elseif key == "SK06" then
        -- 本地增益 → 跨端伤害：下次真实消行攻击 +1，CD 在消行结算时解除
        self.s06Charged = true
        self.cd.SK06 = true
        self.board.attackBonusNext = (self.board.attackBonusNext or 0) + (def.attackBonus or 1)
    elseif key == "SK07" then
        -- 本地：下次真实消行时额外清底 1 行（ignoreState）
        self.s07Charged = true
        self.cd.SK07 = true
    elseif key == "SK08" then
        -- 跨端：对手下一个方块左右方向互换，CD 在对手块落地时解除（收 versus 回执）
        self:_emitVersus("swap", 1)
        self.cd.SK08 = true
    end

    self:_hint("BigTip_" .. key, 1.5)
    return true
end

-- 对手回执：SK08 对手当前块落地 → 解 CD
function ClientGame:OnVersusFeedback(kind, fromKey)
    if fromKey and fromKey ~= 0 and fromKey == self.playerKey then return end
    if kind == "swapLanded" then self.cd.SK08 = nil end
end

-- 受术方本地的"施法方替身"：跨端无法传真实施法方对象，用 no-op stub 让 Board 的减益
-- 状态机（spawn 应用 noRotate/swapLR、lock 解除）能推进。施法方 UI 由施法方本地 UseSkill 负责。
-- Board 在 spawnPiece 诊断行会直接调 stub:GetPlayerState()（无 pcall），故这些方法必须齐全。
function ClientGame:_makeRequesterStub()
    return {
        isAI = true,
        s08Charged = false,
        GetPlayerState = function() return nil end,
        ShowRotationRestrictCasterUI = function() end,
        ShowS08Indicator = function() end,
        UpdateSkillUI = function() end,
    }
end

-- 接收对手施加的减益（由 Battle:OnVersusEvent 调用，纯数据写入 Board）
function ClientGame:ApplyVersusEffect(kind, n, fromKey)
    local b = self.board
    if kind == "noRotate" then
        b.noRotateNext = (b.noRotateNext or 0) + (n or 1)
        b.pendingRotateLockRequester = self:_makeRequesterStub()
        self:_hint("NoRotateImg", 1.7)
    elseif kind == "swap" then
        b.swapRequested = true
        b.pendingSwapRequester = self:_makeRequesterStub()
        self._swapFromKey = fromKey or 0   -- 记录施法方，落地后回执 swapLanded 解其 CD
        self:_hint("FlipImg", 1.7)
    elseif kind == "garbage" then
        b:addGarbage(n or 0)
        -- 收垃圾提示改由状态驱动的图片系统（garbageRecv → _syncGarbageHints）负责，
        -- 不再用一次性 GarbageImg 文本提示（会在垃圾升起前就 1.7s 消失）。
    elseif kind == "rockfall" then
        b:queueRockfall(n or 5)
        self:_hint("StoneImg", 1.7)
    end
end

-- [对战] 轮询：受术方的 swap 减益被 Board 消费（当前块落地）后，回执施法方解除 SK08 CD。
-- 由 Battle 的 gravityTick 每帧调用（ClientGame.tick 有多个 early-return，放这里可靠）。
function ClientGame:pollVersusFeedback()
    local b = self.board
    local cur = (b.swapRequested == true)
    if self._prevSwapRequested == true and cur == false and self._swapFromKey then
        self:_emitVersus("swapLanded", 0)
        print("[Versus][Client] swapLanded 回执 → fromKey=" .. tostring(self._swapFromKey))
        self._swapFromKey = nil
    end
    self._prevSwapRequested = cur
end

-- ===================== 消行结算（强时序，清单 §3） =====================
function ClientGame:_startClearSequence(cleared)
    if self._clearBusy then
        print("[ClearDbg] _startClearSequence 被_clearBusy挡住 cleared=" .. tostring(cleared))
        return
    end
    self._clearBusy = true
    self._clearLastCount = cleared
    -- [表现] 触发 Combo 图：序号递增（边沿）+ 记录本次消除行数（换图）
    self.comboSeq = (self.comboSeq or 0) + 1
    self.clearRows = cleared
    -- [音效] 消行 + Combo 音（对齐旧 TetrisGame:PlayLineClearSound）
    if self.audio and self.audio.PlayLineClear then
        pcall(function() self.audio:PlayLineClear(cleared, self.board.combo or 0) end)
    end
    -- [特效提前起播] 坍塌(applyClearCollapse)要等服务端粒子特效先播：特效走影子盘 Auth_Piece RPC，
    -- 当帧 doClear 时服务端即播，RPC 往返约 0.3s；把坍塌等待 = ResumeDelay + PreClearDelay(0.5s)，
    -- 让特效领先坍塌约 0.5s。坍塌仍由本序列的 After+tick 自驱动执行（不在定时器里 doClear，保留坍塌过程）。
    local resume = CLEAR_CFG.ResumeDelay or 0.3
    local pre = (type(CLEAR_CFG.PreClearDelay) == "number") and CLEAR_CFG.PreClearDelay or 0.5
    self._clearTarget = resume + pre
    self._clearElapsed = 0
    print("[ClearDbg] _startClearSequence 开始 cleared=" .. tostring(cleared) ..
        " 定时=" .. tostring(self._clearTarget) .. "s (坍塌=" .. tostring(resume) .. "+" .. tostring(pre) .. ")")

    -- [修复] 每一步独立 pcall 断点：任何一步抛错只记日志，绝不阻断后续 After 注册与 tick 自驱动。
    -- 旧版这里任一步抛错会连带中断 scheduler:After 注册 + gravityTick 递归调度 → 表现为"消行卡住后一动不动"。
    -- [当前版本] 3D 消行框/爆破竖列框已去掉（用户要求）；仍消费标记避免数据残留。
    -- 消行表现靠服务端粒子特效（PlayClearFxForSeat）+ Combo图/分数提示。
    -- [垃圾特效] 先取走本次消除行号并留存，供稍后发 garbage 时作 payload 带出（起点按真实消行位置）
    local okFx, errFx = pcall(function()
        local rows = self.board:consumeClearedRows()
        if rows and #rows > 0 then
            self._lastClearRows = rows
        end
        self.board:consumeBlastFx()
    end)
    if not okFx then print("[ClearDbg][ERR] 消行标记清理报错(已隔离): " .. tostring(errFx)) end

    pcall(function()
        if self.board.pendingBlastImg then self:_hint("BlastImg", 1.7); self.board.pendingBlastImg = nil end
        if self.board.pendingShiftImg then self:_hint("ShiftImg", 1.7); self.board.pendingShiftImg = nil end
    end)

    -- After 只作快速通道；回调内也 pcall 防止引擎吞错。tick 自驱动是可靠兜底。
    local okTimer, errTimer = pcall(function()
        self.scheduler.After(self._clearTarget, function()
            local okF, errF = pcall(function() self:_finishClearSequence(cleared) end)
            if not okF then print("[ClearDbg][ERR] After回调内finish失败: " .. tostring(errF)) end
        end)
    end)
    if not okTimer then print("[ClearDbg][ERR] 注册消行After失败(已隔离): " .. tostring(errTimer)) end
end

function ClientGame:_finishClearSequence(cleared)
    if not self._clearBusy then
        print("[ClearDbg] _finishClearSequence 跳过(未busy/已完成，防重入)")
        return
    end
    self._clearBusy = false   -- 先清标志：After 与 tick 双通道同时到达时只执行一次
    local b = self.board
    print("[ClearDbg] _finishClearSequence 已触发 cleared=" .. tostring(cleared) ..
        " clearing=" .. tostring(b.clearing) .. " fullRows=" .. tostring(b._clearFullRows ~= nil))

    local ok, err = pcall(function()
        -- 2) 位移（早于坍塌！清单 §3 强约束）
        b:executePendingShift()
        -- 3) 坍塌
        b:applyClearCollapse()
        -- 4) SK07 额外清底行（坍塌后、垃圾前，ignoreState）
        if self.s07Charged then
            b:clearBottomRows(1, true)
            self.s07Charged = false
            self.cd.SK07 = nil
            self:_hint("S07Indicator", 1.5)
        end
        -- 5) 垃圾升起（必须在坍塌之后）
        b:applyGarbage()

        -- 6) 出下一块（内部含落石判断）
        b:finishClear()

        -- 7) 结算跨端攻击 + 技能收尾
        local outgoing = b:consumeOutgoingGarbage() or 0
        if outgoing > 0 then
            -- [垃圾特效] payload 带真实消行行号（对手据此定位拖尾起点）
            self:_emitVersus("garbage", outgoing, self._lastClearRows)
            -- [表现] 点亮"扔垃圾"提示：我方发出 N 行；对手盘垃圾升起时机客户端不可见，
            -- 用固定时长降级（GarbageHint.SendDuration，默认 2.2s）后清零隐藏。
            self._garbageSentSeq = (self._garbageSentSeq or 0) + 1
            local seq = self._garbageSentSeq
            self.garbageSent = outgoing
            local gameRef = self
            self.scheduler.After(Config.GarbageHint and Config.GarbageHint.SendDuration or 2.2, function()
                -- 代际令牌：只有本次发送的定时器能清，避免连续发送相同行数时串扰
                if gameRef._garbageSentSeq == seq then gameRef.garbageSent = 0 end
            end)
            print("[Hint] 扔垃圾 Send 提示 +" .. tostring(outgoing) .. " 行")
        end
        self.lastOutgoing = outgoing

        -- 7b) [落石] 本次消除含落石块 → 上报对手（走 versus，对齐垃圾链路）。
        -- 每个落石块触发一轮落石（5~9 随机列灰块），由对手盘下次锁定时 tryEnterRockfall 消费。
        local stoneAttacks = 0
        pcall(function() stoneAttacks = b:consumeStoneAttack() or 0 end)
        for _ = 1, stoneAttacks do
            self:_emitVersus("rockfall", math.random(5, 9))
        end
        if stoneAttacks > 0 then
            self:_hint("StoneImg", 1.7)
            if self.audio and self.audio.PlayItem then
                pcall(function() self.audio:PlayItem("stone") end)
            end
            print("[Rockfall] 真人消除落石块 " .. tostring(stoneAttacks) .. " 个 → 上报对手")
        end

        if self.s06Charged then
            self.s06Charged = false
            self.cd.SK06 = nil
            self:_hint("AttackBuffImg", 1.7)
        end

        -- 8) 充能道具：取走 pendingItemCharge 转成 bar/power
        local charge = b.pendingItemCharge or 0
        if charge > 0 then
            b.pendingItemCharge = 0
            -- [数值对齐] 服务端 ConsumeItemCharge：每个充能块直接 +1 power（受 MaxPower 限制），
            -- 不走 _addBar（3 换 1）。否则充能道具效力被削弱到 1/3。
            local maxPower = SKILL_CFG.MaxPower or 3
            self.power = math.min(self.power + charge, maxPower)
            self:_hint("ChargeItemImg", 1.7)
            if self.audio and self.audio.PlayItem then
                pcall(function() self.audio:PlayItem("charge") end)
            end
        end
    end)
    if not ok then print("[ClearDbg][ERR] _finishClearSequence 内部报错(已隔离): " .. tostring(err)) end

    print("[ClearDbg] _finishClearSequence 完成 clearing=" .. tostring(b.clearing) ..
        " active=" .. tostring(b:getActive() ~= nil) .. " isOver=" .. tostring(b:isOver()))
end

function ClientGame:_addBar()
    local need = SKILL_CFG.NeedBars or 3
    local maxPower = SKILL_CFG.MaxPower or 3
    self.bars = self.bars + 1
    if self.bars >= need then
        self.bars = 0
        if self.power < maxPower then self.power = self.power + 1 end
    end
end

-- ===================== 落石节奏 =====================
function ClientGame:_scheduleRockfall()
    if self._rockTimer then return end
    local interval = TIMING_CFG.FallingStoneInterval or 0.25
    self._rockTimer = true
    local function step()
        if not self.running or not self.board.fallingStone then
            self._rockTimer = nil
            return
        end
        local still = self.board:stepStones()
        if still then
            self.scheduler.After(interval, step)
        else
            self._rockTimer = nil
        end
    end
    self.scheduler.After(interval, step)
end

-- [落石] Board:beginRockfallClear 回调：落石堆叠成满行时的消行表现序列。
-- 落石消行不计分/不触发道具/不送攻击：播消行音 → 延迟清除 → 坍塌 → afterRockfallClear 收尾。
-- [当前版本] 3D 消行框已去掉（用户要求），保留音效与坍塌；rows 参数仍由 Board 传入但不再用于画框。
function ClientGame:BeginRockfallClearSequence(rows)
    if self._rockfallSeqScheduled then return end
    self._rockfallSeqScheduled = true
    local cfg = Config.Clear or {}
    local effectDur = cfg.ResumeDelay or 0.3
    local clearDelay = cfg.ClearDelay or 0.5
    -- 播消行音（不画框）
    if self.audio and self.audio.PlayLineClear then pcall(function() self.audio:PlayLineClear(0, 0) end) end
    -- 延迟后：清除满行（不计分）+ 坍塌（落石消行不做位移/不升普通垃圾）
    self.scheduler.After(effectDur, function()
        if not self.running or not self.board then return end
        local b = self.board
        b:clearLines(false)
        b:applyClearCollapse()
        if self.renderer then pcall(function() self.renderer:Update(self:BuildRenderState()) end) end
    end)
    -- 收尾：afterRockfallClear 决定继续落石还是结束
    self.scheduler.After(effectDur + clearDelay, function()
        self._rockfallSeqScheduled = false
        if not self.running or not self.board then return end
        self.board:afterRockfallClear()
    end)
end

-- [落石] Board 回调：ScheduleRockfallClearResume（兜底路径，BeginRockfallClearSequence 已覆盖，这里只清标记）
function ClientGame:ScheduleRockfallClearResume()
    -- 正常路径已由 BeginRockfallClearSequence 的定时器收尾；此回调仅 Board 兜底分支会调。
end

-- [落石] 落石结束：Board 会据此正常 spawn 下一块（spawn 在 Board:onRockfallFallingDone/afterRockfallClear 内已调）
function ClientGame:OnRockfallEnd()
    print("[Rockfall] 落石结束，恢复正常下落")
end

-- ===================== 主循环 =====================
function ClientGame:Start()
    self.running = true
end

function ClientGame:Stop()
    self.running = false
end

--- 每帧/每重力周期推进。返回是否发生了状态变化。
function ClientGame:tick()
    local b = self.board
    if not self.running or b:isOver() then return false end
    if b.fallingStone then
        self:_scheduleRockfall()
        return true
    end
    if b.clearing then
        -- [修复] 消行恢复改为重力 tick 自驱动：不依赖独立的 After timer。
        -- 即使 timer 丢失/回调被引擎吞掉，已验证稳定的重力循环仍能推进消行，杜绝永久卡死。
        if not self._clearBusy then
            -- 异常兜底：clearing 挂起但没有消行流程在跑 → 直接收尾，防止卡死
            print("[ClearDbg] tick clearing=true 但 clearBusy=false，强制收尾")
            local okR, errR = pcall(function() b:finishClear() end)
            if not okR then print("[ClearDbg][ERR] 强制收尾失败: " .. tostring(errR)) end
            return true
        end
        self._clearElapsed = (self._clearElapsed or 0) + b:getGravityInterval()
        local target = self._clearTarget or 0.35
        print("[ClearDbg] tick 消行等待 elapsed=" .. tostring(self._clearElapsed) ..
            "/" .. tostring(target) .. " clearFullRows=" .. tostring(b._clearFullRows ~= nil))
        if self._clearElapsed >= target then
            local okF, errF = pcall(function() self:_finishClearSequence(self._clearLastCount or 0) end)
            if not okF then print("[ClearDbg][ERR] tick自驱动finish失败: " .. tostring(errF)) end
        end
        return false
    end
    if b.lockPaused then
        -- 锁定停顿结束：执行消行 + 开特效时序（坍塌链保持 tick 主循环驱动，不在定时器里 doClear）
        local cleared = b:doClear()
        print("[ClearDbg] tick lockPaused→doClear cleared=" .. tostring(cleared) ..
            " clearing=" .. tostring(b.clearing) .. " clearBusy=" .. tostring(self._clearBusy) ..
            " fullRows=" .. tostring(b._clearFullRows ~= nil))
        if cleared > 0 then
            -- 消 N 行 = N 个 bar（清单 §7：消 1 行得 1 bar）
            for _ = 1, cleared do self:_addBar() end
            self:_startClearSequence(cleared)
        end
        return true
    end

    -- AI 每块规划一次（spawnSeq 去重，hold 不递增）
    if self.isAI and b.spawnSeq ~= self._lastSpawnSeq and b:getActive() then
        self._lastSpawnSeq = b.spawnSeq
        self:aiStep()
        -- AI 自动放技能（power >= 1 时随机放已选技能）
        if self.power > 0 and #self.selectedSkills > 0 then
            self:UseSkill(self.selectedSkills[math.random(#self.selectedSkills)])
        end
    end

    return b:tick()
end

--- AI：bestMove → 设置 rot/x → 硬降（不旋转动画，直接落子）。
function ClientGame:aiStep()
    local b = self.board
    local mv = TetrisAI.bestMove(b, self.aiQuality)
    if not mv or not b.active then return end
    b.active.rot = mv.rot
    b.active.x = mv.x
    b:hardDrop()
end

-- 直接输入动作（Input 层调用，外观层不碰控件）
function ClientGame:ApplyAction(action)
    local b = self.board
    if not self.running or b:isOver() then return end
    if action.type == "move" then b:move(action.value or 0)
    elseif action.type == "rotate" then b:rotate(action.value or 1)
    elseif action.type == "softDrop" then b:softDrop()
    elseif action.type == "hardDrop" then b:hardDrop()
    elseif action.type == "hold" then b:hold()
    elseif action.type == "skill" then self:UseSkill(action.value) end
end

-- ===================== 输出（纯数据，下游只读） =====================
function ClientGame:BuildRenderState()
    local b = self.board
    local rs = Interfaces.NewRenderState()
    rs.grid = b.grid
    local a = b:getActive()
    if a then
        rs.active = { type = a.type, rot = a.rot, x = a.x, y = a.y, cells = b:getActiveCells() }
    end
    rs.ghost = b:getGhostCells()
    rs.nextQueue = b:getNextQueue()
    rs.holdType = b:getHoldType()
    rs.effects = {
        clearing = b.clearing or false,
        lockPaused = b.lockPaused or false,
        fallingStone = b.fallingStone or false,
        garbage = b.lastAppliedGarbage or 0,
        blast = b.pendingBlastFx,
        stone = b.stones,
    }
    return rs
end

function ClientGame:BuildUIState()
    local b = self.board
    local us = Interfaces.NewUIState()
    us.score = b.score or 0
    us.lines = b.lines or 0
    us.level = b.level or 1
    us.combo = b.combo or 0
    us.comboSeq = self.comboSeq or 0
    us.clearRows = self.clearRows or 0
    us.skillPower = self.power
    us.skillBars = self.bars
    us.skillCd = {}
    for k in pairs(self.cd) do us.skillCd[k] = true end
    us.hintImages = {}
    for k in pairs(self.hints) do us.hintImages[k] = true end
    -- [垃圾提示] RECV=我盘待注入行数；SEND=我方已发出待落地行数
    us.garbageRecv = b.pendingGarbage or 0
    us.garbageSent = self.garbageSent or 0
    us.pendingSwap = b.swapLrRequesterKey ~= nil or b.pendingSwapNext == true
    us.pendingNoRotate = b.rotateLockRequesterKey ~= nil or b.noRotateNext > 0
    return us
end

return ClientGame
