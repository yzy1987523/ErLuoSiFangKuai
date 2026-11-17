-- ClientInput：把引擎 CustomUI 事件翻译成 InputAction，交给 ClientGame，不碰 UI 也不碰 Board。
--
-- 权威来源：
--   EnvLua/Core/Define/RcEventIdDefine.lua：CustomUIClicked=120000 / LongPressed=120001 / LongPressReleased=120002，
--     @listen(InstanceID number, PlayerState)，@output(PlayerState)。InstanceID 必须是 number（CreativeInstance 的值）。
--   EnvLua/Core/LuaHint/WoWObject.lua：AddVPEvent(EventID, Func, Caller, ...) / RemoveVPEvent / AddTimerOnce / RemoveTimer。
--   Config.UI（按钮 InstanceID）、Config.Input（DAS=0.16/ARR=0.06）、Config.Timing.SoftDropInterval=0.05。
--
-- 代际令牌：每次开始/停止连发都递增令牌，旧回调发现令牌不符即退出，防快速松按的幽灵连发。
local Config = require("EnvLua.Common.Tetris.TetrisConfig")

local ClientInput = {}
ClientInput.__index = ClientInput

local EV_CLICK = 120000
local EV_LONG = 120001
local EV_RELEASE = 120002

---@param host table 注册事件/定时器的宿主（WoWObject，通常为 ClientGameMain）
---@param sink table 动作接收方（ClientGame，实现 ApplyAction(action)）
function ClientInput:new(host, sink)
    local o = setmetatable({}, self)
    o.host = host
    o.sink = sink
    o.enabled = false

    local inputCfg = Config.Input or {}
    o.das = inputCfg.DAS or 0.16
    o.arr = inputCfg.ARR or 0.06
    o.softInterval = (Config.Timing and Config.Timing.SoftDropInterval) or 0.05
    o.longEnabled = inputCfg.LongPressEnabled ~= false

    -- instanceID(number) -> action 名
    local U = Config.UI or {}
    o.idToAction = {}
    if U.BtnLeft then o.idToAction[U.BtnLeft] = "left" end
    if U.BtnRight then o.idToAction[U.BtnRight] = "right" end
    if U.BtnRoll then o.idToAction[U.BtnRoll] = "roll" end
    if U.BtnDown then o.idToAction[U.BtnDown] = "down" end
    if U.BtnHold then o.idToAction[U.BtnHold] = "hold" end
    if U.BtnSkill then o.idToAction[U.BtnSkill] = "skill" end

    o._moveGen = 0
    o._dropGen = 0
    o._moveTimer = nil
    o._dropTimer = nil
    o._registered = false
    return o
end

function ClientInput:_dispatch(actionType, value)
    if not self.enabled or not self.sink then return end
    self.sink:ApplyAction({ type = actionType, value = value })
end

-- 短按：左右移一格 / 旋转 / 硬降 / hold / 技能
function ClientInput:_onClicked(instanceID)
    local a = self.idToAction[instanceID]
    if a == "left" then self:_dispatch("move", -1)
    elseif a == "right" then self:_dispatch("move", 1)
    elseif a == "roll" then self:_dispatch("rotate", 1)
    elseif a == "down" then self:_dispatch("hardDrop")
    elseif a == "hold" then self:_dispatch("hold")
    elseif a == "skill" then self:_dispatch("skill") end
end

-- 长按开始：左右进入 DAS→ARR 连发；下键进入软降连发
function ClientInput:_onLongPressed(instanceID)
    if not self.longEnabled then return end
    local a = self.idToAction[instanceID]
    if a == "left" or a == "right" then
        local dir = (a == "left") and -1 or 1
        self:_startMove(dir)
    elseif a == "down" then
        self:_startSoftDrop()
    end
end

function ClientInput:_onLongReleased(instanceID)
    local a = self.idToAction[instanceID]
    if a == "left" or a == "right" then self:_stopMove()
    elseif a == "down" then self:_stopSoftDrop() end
end

function ClientInput:_startMove(dir)
    self:_stopMove()
    self._moveGen = self._moveGen + 1
    local gen = self._moveGen
    -- DAS：首次连发延迟（先走一次，之后按 ARR 周期）
    self._moveTimer = self.host:AddTimerOnce(self.das, function()
        if self._moveGen ~= gen then return end
        self:_dispatch("move", dir)
        local function repeatMove()
            if self._moveGen ~= gen then return end
            self:_dispatch("move", dir)
            self._moveTimer = self.host:AddTimerOnce(self.arr, repeatMove)
        end
        self._moveTimer = self.host:AddTimerOnce(self.arr, repeatMove)
    end)
end

function ClientInput:_stopMove()
    self._moveGen = self._moveGen + 1
    if self._moveTimer then pcall(function() self.host:RemoveTimer(self._moveTimer) end); self._moveTimer = nil end
end

function ClientInput:_startSoftDrop()
    self:_stopSoftDrop()
    self._dropGen = self._dropGen + 1
    local gen = self._dropGen
    local function step()
        if self._dropGen ~= gen then return end
        self:_dispatch("softDrop")
        self._dropTimer = self.host:AddTimerOnce(self.softInterval, step)
    end
    self._dropTimer = self.host:AddTimerOnce(self.softInterval, step)
end

function ClientInput:_stopSoftDrop()
    self._dropGen = self._dropGen + 1
    if self._dropTimer then pcall(function() self.host:RemoveTimer(self._dropTimer) end); self._dropTimer = nil end
end

-- 注册 VP 事件：@listen(InstanceID, PlayerState)，客户端第 2 参忽略传 nil。
-- 回调签名 Func(Caller, outputs...) = Func(self, PlayerState)；InstanceID 由闭包捕获。
function ClientInput:Enable()
    if self._registered then self.enabled = true return end
    local function bind(event, handler)
        for id, _ in pairs(self.idToAction) do
            self.host:AddVPEvent(event, function(_, _ps) handler(self, id) end, self, id, nil)
        end
    end
    bind(EV_CLICK, function(ref, id) ref:_onClicked(id) end)
    bind(EV_LONG, function(ref, id) ref:_onLongPressed(id) end)
    bind(EV_RELEASE, function(ref, id) ref:_onLongReleased(id) end)
    self._registered = true
    self.enabled = true
end

function ClientInput:Disable()
    self.enabled = false
    self:_stopMove()
    self:_stopSoftDrop()
end

return ClientInput
