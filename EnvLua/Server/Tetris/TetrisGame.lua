-- 游戏控制器：串联数据层与渲染层，负责重力 tick、UI 输入路由、生命周期。
-- 本模块不是 WoWObject，定时器与事件都借宿在 owner（ServerGameMain）上。
-- RcEventIdDefine.lua 内部是 "RcEventIdDefine = {...}"（全局表，无 return），
-- require 只会返回 nil，因此这里仅取它的"加载副作用"，使用时读全局。
pcall(require, "EnvLua.Core.Define.RcEventIdDefine")

local TetrisConfig = require("EnvLua.Server.Tetris.TetrisConfig")
local TetrisBoard = require("EnvLua.Server.Tetris.TetrisBoard")
local TetrisRenderer = require("EnvLua.Server.Tetris.TetrisRenderer")
local TetrisNativeUI = require("EnvLua.Server.Tetris.TetrisNativeUI")

local TetrisGame = {}
TetrisGame.__index = TetrisGame

function TetrisGame:new(owner)
    local o = setmetatable({}, TetrisGame)
    o.owner = owner          -- WoWObject，用于 AddTimerOnce / AddVPEvent
    o.board = nil
    o.renderer = nil
    o.nativeUI = TetrisNativeUI:new(owner)   -- 原生 HUD / 操作按钮显隐
    o.running = false
    return o
end

-- ---------------- 生命周期 ----------------
function TetrisGame:Init()
    self.board = TetrisBoard:new()
    self.renderer = TetrisRenderer:new()
    local ok = self.renderer:Build()
    -- 刻意不在 Build 之后立刻刷新：此时实例尚未 spawn，显隐指令会被丢弃。
    -- 实际刷新交给 Start 里的稳定期调度。
    return ok
end

function TetrisGame:Start()
    if self.running then return end
    self.running = true
    self.nativeUI:Hide()     -- 隐藏全部原生 UI，只留自建 CustomUI
    self:RegisterInput()
    self:ScheduleSettle()   -- 先让实例 spawn 完成并把显隐刷到位
    self:ScheduleTick()
end

function TetrisGame:Stop()
    if not self.running then return end
    self.running = false
    self.nativeUI:Restore()  -- 回合结束还原原生 UI
end

function TetrisGame:Restart()
    self.board:reset()
    self.renderer:Clear()
    self.renderer:Update(self.board)
    if self.running then
        self:ScheduleTick()
    end
end

-- ---------------- 开局稳定期 ----------------
-- 实例创建后需若干帧才真正生成，开局短时间内高频反复下发显隐，
-- 确保每一格的隐藏指令都被真正执行（配合渲染层的 SetCellForce）。
function TetrisGame:ScheduleSettle()
    local r = TetrisConfig.Render
    for i = 1, r.SettleFrames do
        self.owner:AddTimerOnce(i * r.SettleInterval, function()
            if self.renderer and self.board then
                self.renderer:Update(self.board)
            end
        end)
    end
end

-- ---------------- 重力循环 ----------------
-- 注意：AddTimer(delay, func, 0) 实测不会触发，必须用 AddTimerOnce 递归。
function TetrisGame:ScheduleTick()
    if not self.running then return end
    local interval = self.board:getGravityInterval()
    self.owner:AddTimerOnce(interval, function()
        if not self.running then return end
        self:OnTick()
        self:ScheduleTick()
    end)
end

function TetrisGame:OnTick()
    local board = self.board
    if board:isOver() then
        self:OnGameOver()
        return
    end
    board:tick()                    -- 数据层下落一格或锁定
    self.renderer:Update(board)     -- 渲染层只跟随数据
    if board:isOver() then
        self:OnGameOver()
    end
end

-- ---------------- 结束 ----------------

function TetrisGame:OnGameOver()
    self.running = false
end

-- ---------------- UI 输入 ----------------
-- CustomUIClicked(120000)：@listen InstanceID 用于按控件过滤，@output 为点击的 PlayerState。
-- 每个按钮注册独立监听，因此回调里无需再判断来源。
function TetrisGame:RegisterInput()
    local ui = TetrisConfig.UI
    -- 读全局表；若尚未注入则回退到事件号字面量 120000
    local id = (type(RcEventIdDefine) == "table" and RcEventIdDefine.CustomUIClicked) or 120000
    if id == 120000 then
        print("[Tetris][WARN] RcEventIdDefine 未注入，使用字面量 120000")
    end

    local function bind(instanceID, handler)
        if instanceID == nil then
            print("[Tetris][WARN] 跳过未配置的按钮（InstanceUUID 为 nil）")
            return
        end
        self.owner:AddVPEvent(id, handler, self, instanceID, nil)
    end

    bind(ui.BtnLeft, TetrisGame.OnBtnLeft)
    bind(ui.BtnRight, TetrisGame.OnBtnRight)
    bind(ui.BtnRoll, TetrisGame.OnBtnRoll)
    bind(ui.BtnDown, TetrisGame.OnBtnDown)
    bind(ui.BtnHold, TetrisGame.OnBtnHold)
    bind(ui.BtnSkill, TetrisGame.OnBtnSkill)
end

-- 统一安全调用：单个操作出错不应中断整局
function TetrisGame:safeApply(fn)
    if not self.running or self.board:isOver() then return end
    local ok, err = pcall(fn)
    if not ok then
        print("[Tetris][ERROR] 操作异常: " .. tostring(err))
        return
    end
    self.renderer:Update(self.board)
    if self.board:isOver() then
        self:OnGameOver()
    end
end

function TetrisGame:OnBtnLeft()
    self:safeApply(function() self.board:move(-1) end)
end

function TetrisGame:OnBtnRight()
    self:safeApply(function() self.board:move(1) end)
end

function TetrisGame:OnBtnRoll()
    self:safeApply(function() self.board:rotate(1) end)
end

-- down 键 = 硬降（本作不提供软降）
function TetrisGame:OnBtnDown()
    self:safeApply(function() self.board:hardDrop() end)
end

function TetrisGame:OnBtnHold()
    self:safeApply(function() self.board:hold() end)
end

-- 技能：本期占位，技能系统属后续阶段
function TetrisGame:OnBtnSkill()
    if not TetrisConfig.SkillEnabled then
        return
    end
end

return TetrisGame
