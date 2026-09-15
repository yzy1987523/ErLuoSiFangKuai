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
    o.playerState = nil      -- 上屏用，惰性获取
    o.lastSeq = 0            -- 已提示过的方块生成序号
    return o
end

-- ---------------- 生命周期 ----------------
function TetrisGame:Init()
    self.board = TetrisBoard:new()
    self.renderer = TetrisRenderer:new()
    local ok = self.renderer:Build()
    -- 刻意不在 Build 之后立刻刷新：此时实例尚未 spawn，显隐指令会被丢弃。
    -- 实际刷新交给 Start 里的稳定期调度。
    print("[Tetris] Init, 盘面 " .. TetrisConfig.Board.Cols .. "x" .. TetrisConfig.Board.Rows)
    return ok
end

function TetrisGame:Start()
    if self.running then return end
    self.running = true
    self.nativeUI:Hide()     -- 隐藏全部原生 UI，只留自建 CustomUI
    self:RegisterInput()
    self:ScheduleSettle()   -- 先让实例 spawn 完成并把显隐刷到位
    self:ScheduleTick()
    print("[Tetris] Start")
    self:CheckPieceSpawned()   -- 提示开局第一个方块
end

function TetrisGame:Stop()
    if not self.running then return end
    self.running = false
    self.nativeUI:Restore()  -- 回合结束还原原生 UI
    print("[Tetris] Stop")
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
    self:CheckPieceSpawned()        -- 产出新方块则上屏
    self:ReportTSpin()              -- 上报 T-Spin（若有）
    if board:isOver() then
        self:OnGameOver()
    end
end

-- ---------------- 调试：上屏输出 ----------------

-- 惰性获取 PlayerState。上屏 API 的首参必须是 PlayerState。
-- GetAllPlayerStates 返回 LuaArray，要用 :Num()/:Get(i)，下标从 0 起。
function TetrisGame:GetPlayerState()
    if self.playerState then return self.playerState end
    local ok, arr = pcall(function() return Game:GetAllPlayerStates() end)
    if ok and arr and arr:Num() > 0 then
        self.playerState = arr:Get(0)
    end
    return self.playerState
end

function TetrisGame:SendScreenMessage(content)
    print("[Tetris] " .. tostring(content))
    local ps = self:GetPlayerState()
    if not ps then return end   -- 取不到玩家时只落控制台
    local ok, err = pcall(function()
        if TetrisConfig.Debug.ShowPieceInfoPopup then
            Log.SendBattlePopupMessage(ps, content)
        else
            Log.SendQuickMenuMessage(ps, content)
        end
    end)
    if not ok then
        print("[Tetris][WARN] 上屏失败: " .. tostring(err))
    end
end

-- 每次生成新下落方块时上报一次信息
function TetrisGame:CheckPieceSpawned()
    if not TetrisConfig.Debug.ShowPieceInfo then return end
    local s = self.board and self.board.lastSpawned
    if not s or s.seq == self.lastSeq then return end
    self.lastSeq = s.seq

    local function pieceName(t)
        local def = TetrisConfig.Pieces[t]
        return (def and def.name) or "?"
    end
    local nxt = {}
    for i = 1, math.min(3, #self.board.nextQueue) do
        nxt[#nxt + 1] = pieceName(self.board.nextQueue[i])
    end

    -- string.format 的 %d 遇到 nil 会直接报错并中断后续逻辑，故统一用 %s 兜底
    local msg = string.format("方块[%s] #%s 起点=(行%s,列%s) 下一个=%s 分数=%s 消行=%s 等级=%s",
        tostring(pieceName(s.type)), tostring(s.seq), tostring(s.y), tostring(s.x),
        table.concat(nxt, ","), tostring(self.board.score),
        tostring(self.board.lines), tostring(self.board.level))
    self:SendScreenMessage(msg)
end

-- 把最近一次锁定产生的 T-Spin 上屏（消费式：上报后置回 "none" 避免重复提示）
function TetrisGame:ReportTSpin()
    if not self.board then return end
    local t = self.board.lastTSpin
    if t and t ~= "none" then
        self:SendScreenMessage("T-Spin " .. (t == "full" and "满" or "Mini"))
        self.board.lastTSpin = "none"
    end
end

function TetrisGame:OnGameOver()
    local msg = "游戏结束 分数=" .. tostring(self.board.score)
        .. " 消行=" .. tostring(self.board.lines)
    print("[Tetris] " .. msg)
    self.running = false
    if TetrisConfig.Debug.ShowGameOverInfo then
        self:SendScreenMessage(msg)
    end
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
    print("[Tetris] UI 输入已注册")
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
    self:CheckPieceSpawned()
    self:ReportTSpin()
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
        print("[Tetris] 技能按钮（未启用）")
        return
    end
end

return TetrisGame
