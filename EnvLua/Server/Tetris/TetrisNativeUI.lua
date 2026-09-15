-- 原生 UI（引擎自带 HUD 与屏幕操作按钮）统一隐藏/还原。
-- 权威来源：
--   EnvLua/Core/LuaHint/NativeControlAPI.lua  （Domain API，全局表，无需 require）
--   EnvLua/Core/Define/CommonDefine.lua:668   （全局枚举 NativeControlType = 1~30）
-- CommonDefine.lua 内部是 "NativeControlType = {...}" 全局赋值、无 return，
-- require 只为取它的加载副作用，故用 pcall 包住。
pcall(require, "EnvLua.Core.Define.CommonDefine")

local TetrisConfig = require("EnvLua.Server.Tetris.TetrisConfig")

local TetrisNativeUI = {}
TetrisNativeUI.__index = TetrisNativeUI

local MAX_TYPE = 30   -- 文档声明 ControlType 取值 1~30

function TetrisNativeUI:new(owner)
    local o = setmetatable({}, TetrisNativeUI)
    o.owner = owner             -- WoWObject，用于 AddTimerOnce / AddVPEvent
    o.hidden = false
    o.types = TetrisNativeUI.CollectTypes()
    o.bornRegistered = false
    -- 玩家出生后原生 UI 会随角色重建，需对新玩家补发一次
    o.playerBornEventId = (type(RcEventIdDefine) == "table" and RcEventIdDefine.PlayerBorn) or 10000
    return o
end

-- 收集要控制的控件类型：全局枚举可用则取其全部值，否则回退 1~30；再剔除保留项。
function TetrisNativeUI.CollectTypes()
    local list = {}
    local seen = {}
    if type(NativeControlType) == "table" then
        for _, v in pairs(NativeControlType) do
            if type(v) == "number" and not seen[v] then
                seen[v] = true
                list[#list + 1] = v
            end
        end
    end
    if #list == 0 then
        print("[Tetris][WARN] NativeControlType 未注入，回退使用 1~" .. tostring(MAX_TYPE))
        for i = 1, MAX_TYPE do list[i] = i end
    end
    table.sort(list)

    local keep = (TetrisConfig.NativeUI and TetrisConfig.NativeUI.KeepTypes) or {}
    if #keep == 0 then return list end
    local keepSet = {}
    for _, v in ipairs(keep) do keepSet[v] = true end
    local out = {}
    for _, v in ipairs(list) do
        if not keepSet[v] then out[#out + 1] = v end
    end
    return out
end

-- 对全体玩家下发一次。返回成功下发条数。
function TetrisNativeUI:ApplyAll(bVisible)
    if type(NativeControlAPI) ~= "table" then
        print("[Tetris][WARN] NativeControlAPI 不可用，跳过原生 UI 显隐")
        return 0
    end
    local n = 0
    for _, t in ipairs(self.types) do
        local ok, err = pcall(function()
            NativeControlAPI.SetAllPlayersNativeControlVisible(t, bVisible)
        end)
        if ok then
            n = n + 1
        else
            -- 单个类型失败不应中断其余类型
            print("[Tetris][WARN] SetAllPlayersNativeControlVisible 失败 type=" .. tostring(t)
                .. " err=" .. tostring(err))
        end
    end
    return n
end

-- 对单个玩家下发（新玩家出生后补发用）。
function TetrisNativeUI:ApplyToPlayer(ps, bVisible)
    if not ps or type(NativeControlAPI) ~= "table" then return end
    for _, t in ipairs(self.types) do
        pcall(function() NativeControlAPI.SetNativeControlVisible(ps, t, bVisible) end)
    end
end

-- ---------------- 对外：隐藏 / 还原 ----------------
function TetrisNativeUI:Hide()
    local cfg = TetrisConfig.NativeUI
    if not (cfg and cfg.Enabled) then return end
    self.hidden = true
    self:ApplyAll(false)

    -- 角色生成/切场景后原生 UI 可能被重建，开局多刷几次（与渲染层 Settle 同理）
    for i = 1, (cfg.RetryFrames or 0) do
        self.owner:AddTimerOnce(i * (cfg.RetryInterval or 0.5), function()
            if self.hidden then self:ApplyAll(false) end
        end)
    end
    self:RegisterPlayerBorn()
end

function TetrisNativeUI:Restore()
    if not self.hidden then return end
    self.hidden = false
    self:ApplyAll(true)
end

-- ---------------- 新玩家补发 ----------------
-- PlayerBorn(10000)：@listen PlayerState, TeamID 均传 nil 表示不过滤；@output 首个为 PlayerState。
function TetrisNativeUI:RegisterPlayerBorn()
    if self.bornRegistered then return end
    self.bornRegistered = true
    local ok, err = pcall(function()
        self.owner:AddVPEvent(self.playerBornEventId, TetrisNativeUI.OnPlayerBorn, self, nil, nil)
    end)
    if not ok then
        print("[Tetris][WARN] PlayerBorn 注册失败: " .. tostring(err))
    end
end

function TetrisNativeUI:OnPlayerBorn(ps)
    if self.hidden then
        self:ApplyToPlayer(ps, false)
    end
end

return TetrisNativeUI
