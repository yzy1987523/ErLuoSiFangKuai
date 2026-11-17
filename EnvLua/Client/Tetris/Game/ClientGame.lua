-- ClientGame：编排 Board 状态机 + 道具/技能/AI，不碰任何 UI 控件、不直接调引擎 API。
--
-- 纪律（见 .codebuddy/客户端重写功能清单.md）：
--   1. 不设置 board.game —— Board 残留的 UI/音效回调自然失效，表现只由 pending* 数据标记驱动。
--   2. 跨端 requester 用 playerKey 数字，不持有对方 Game 对象。
--   3. 所有 UI 表现通过 BuildUIState() 输出；渲染通过 renderer 接口；跨端通过 versus 接口。
--   4. 定时器统一走注入的 scheduler:After(seconds, fn)（引擎侧用 AddTimerOnce 递归实现）。
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
    o.scheduler = deps.scheduler or { After = function(_, fn) fn() end }
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
    self.scheduler:After(seconds or 1.7, function() self.hints[name] = nil end)
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

-- 接收对手施加的减益（由上层 Protocol 调用，纯数据写入 Board）
function ClientGame:ApplyVersusEffect(kind, n, fromKey)
    local b = self.board
    if kind == "noRotate" then
        b.noRotateNext = (b.noRotateNext or 0) + (n or 1)
        b.pendingRotateLockRequesterKey = fromKey
        self:_hint("NoRotateImg", 1.7)
    elseif kind == "swap" then
        b.swapRequested = true
        b.pendingSwapRequesterKey = fromKey
        self:_hint("FlipImg", 1.7)
    elseif kind == "garbage" then
        b:addGarbage(n or 0)
        self:_hint("GarbageImg", 1.7)
    elseif kind == "rockfall" then
        b:queueRockfall(n or 5)
    end
end

-- ===================== 消行结算（强时序，清单 §3） =====================
function ClientGame:_startClearSequence(cleared)
    if self._clearBusy then return end
    self._clearBusy = true

    -- 1) 特效：消行框 / 爆破竖列（消费 pending 标记，取后清空避免重复）
    local rows = self.board:consumeClearedRows()
    local blasts = self.board:consumeBlastFx()
    if self.renderer then
        if rows and #rows > 0 and self.renderer.ShowClearFrame then self.renderer:ShowClearFrame(rows) end
        if blasts then
            for _, fx in ipairs(blasts) do
                if self.renderer.ShowBlastColumn then self.renderer:ShowBlastColumn(fx.col) end
            end
        end
    end
    if self.board.pendingBlastImg then self:_hint("BlastImg", 1.7); self.board.pendingBlastImg = nil end
    if self.board.pendingShiftImg then self:_hint("ShiftImg", 1.7); self.board.pendingShiftImg = nil end

    local effectDur = CLEAR_CFG.EffectDuration or 0.35
    self.scheduler:After(effectDur, function() self:_finishClearSequence(cleared) end)
end

function ClientGame:_finishClearSequence(cleared)
    local b = self.board

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
    if outgoing > 0 then self:_emitVersus("garbage", outgoing) end
    self.lastOutgoing = outgoing

    if self.s06Charged then
        self.s06Charged = false
        self.cd.SK06 = nil
        self:_hint("AttackBuffImg", 1.7)
    end

    -- 8) 充能道具：取走 pendingItemCharge 转成 bar/power
    local charge = b.pendingItemCharge or 0
    if charge > 0 then
        b.pendingItemCharge = 0
        for _ = 1, charge do self:_addBar() end
        self:_hint("ChargeItemImg", 1.7)
    end

    self._clearBusy = false
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
            self.scheduler:After(interval, step)
        else
            self._rockTimer = nil
        end
    end
    self.scheduler:After(interval, step)
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
    if b.clearing then return false end
    if b.lockPaused then
        -- 锁定停顿结束：执行消行 + 开特效时序
        local cleared = b:doClear()
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
    us.skillPower = self.power
    us.skillBars = self.bars
    us.skillCd = {}
    for k in pairs(self.cd) do us.skillCd[k] = true end
    us.hintImages = {}
    for k in pairs(self.hints) do us.hintImages[k] = true end
    us.pendingSwap = b.swapLrRequesterKey ~= nil or b.pendingSwapNext == true
    us.pendingNoRotate = b.rotateLockRequesterKey ~= nil or b.noRotateNext > 0
    return us
end

return ClientGame
