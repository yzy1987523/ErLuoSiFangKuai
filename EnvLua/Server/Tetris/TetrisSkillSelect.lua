-- 技能选择阶段：开局前置，先用「开始游戏」按钮触发，再出 3 个技能按钮供玩家选择
-- （SK-01 禁止转动 / SK-02 清除最下方两行 / SK-06 攻势，定义见 TetrisConfig.Skills）。
-- 选完（或超时）→ 回调 TetrisMatch:OnSkillSelected，由 Match 接管（玩法选择或直接开局）。
--
-- 与 TetrisModeSelect 同级：所有 widget 必须在编辑器 UI Editor 预放置，UUID 填到
-- TetrisConfig.SkillSelect.*（用 CreativeInstance 全局表取）。未放置则自动跳过本阶段。
--
-- 权威来源：
--   EnvLua/Core/LuaHint/CustomUIAPI.lua  SetWidgetVisible / SetWidgetInteraction / SetButtonNormalImage
--   EnvLua/Core/Define/RcEventIdDefine.lua  CustomUIClicked（@output 首个为点击者 PlayerState）
pcall(require, "EnvLua.Core.Define.RcEventIdDefine")

local TetrisConfig = require("EnvLua.Server.Tetris.TetrisConfig")

local TetrisSkillSelect = {}
TetrisSkillSelect.__index = TetrisSkillSelect

-- 玩家稳定 key（仅用于日志与查表）；取不到时回退 PlayerState 本身
local function keyOf(ps)
    if ps and type(ps.GetPlayerKey) == "function" then
        local ok, k = pcall(function() return ps:GetPlayerKey() end)
        if ok and k then return k end
    end
    return ps
end

function TetrisSkillSelect:new(owner, match)
    local o = setmetatable({}, TetrisSkillSelect)
    o.owner = owner            -- WoWObject，用于 AddVPEvent / AddTimerOnce
    o.match = match
    o.players = {}             -- 参与选择的 PlayerState 列表
    o.choices = {}             -- [PlayerState] = 已选技能 key（如 "SK01"）
    o.done = false
    o._started = false         -- 「开始游戏」是否已点击（仅一次）
    o.registered = false
    o._startReg = false
    o.clickEventId = (type(RcEventIdDefine) == "table" and RcEventIdDefine.CustomUIClicked) or 120000
    return o
end

local function cfgOf()
    return TetrisConfig.SkillSelect or {}
end

-- 阶段是否可用：开关打开且至少放了一个技能按键
function TetrisSkillSelect:Available()
    local cfg = cfgOf()
    if not cfg.Enabled then return false end
    return (cfg.BtnSK01 ~= nil or cfg.BtnSK02 ~= nil or cfg.BtnSK06 ~= nil)
end

-- 3 个技能按键对应的（控件, 技能 key）列表
function TetrisSkillSelect:SkillBinds()
    local cfg = cfgOf()
    return {
        { cfg.BtnSK01, "SK01" },
        { cfg.BtnSK02, "SK02" },
        { cfg.BtnSK06, "SK06" },
    }
end

function TetrisSkillSelect:SkillButtonIDs()
    local cfg = cfgOf()
    return { cfg.BtnSK01, cfg.BtnSK02, cfg.BtnSK06 }
end

-- 需要统一显隐的控件：开始界面 + 开始按钮 + 面板 + 3 个技能按键
function TetrisSkillSelect:WidgetIDs()
    local cfg = cfgOf()
    return { cfg.StartPanel, cfg.StartBtn, cfg.PanelKey, cfg.BtnSK01, cfg.BtnSK02, cfg.BtnSK06 }
end

function TetrisSkillSelect:SkillName(key)
    local def = TetrisConfig.Skills and TetrisConfig.Skills[key]
    return (def and def.name) or tostring(key)
end

function TetrisSkillSelect:isParticipant(ps)
    for _, p in ipairs(self.players) do if p == ps then return true end end
    return false
end

-- 给玩家发一条聊天框提示（失败不影响流程）
function TetrisSkillSelect:Notify(ps, content)
    if not ps or type(Log) ~= "table" then return end
    pcall(function() Log.SendQuickMenuMessage(ps, content) end)
end

-- ---------------- UI 显隐 ----------------
function TetrisSkillSelect:ShowForAll(id, visible)
    if not id or type(CustomUIAPI) ~= "table" then return end
    for _, ps in ipairs(self.players) do
        pcall(function() CustomUIAPI.SetWidgetVisible(ps, id, visible) end)
    end
end

function TetrisSkillSelect:ShowFor(ps, id, visible)
    if not id or not ps or type(CustomUIAPI) ~= "table" then return end
    pcall(function() CustomUIAPI.SetWidgetVisible(ps, id, visible) end)
end

function TetrisSkillSelect:ShowPanelFor(ps, visible)
    local cfg = cfgOf()
    self:ShowFor(ps, cfg.PanelKey, visible)
    for _, id in ipairs(self:SkillButtonIDs()) do
        self:ShowFor(ps, id, visible)
    end
end

-- 隐藏/显示本阶段全部控件（所有玩家）
function TetrisSkillSelect:ShowAll(visible)
    local ids = self:WidgetIDs()
    for _, ps in ipairs(self.players) do
        for _, id in ipairs(ids) do
            self:ShowFor(ps, id, visible)
        end
    end
end

-- ---------------- 对外：开始选择阶段 ----------------
function TetrisSkillSelect:Begin(players)
    self.players = players or {}
    self.choices = {}
    self.done = false
    self._started = false

    if #self.players == 0 or not self:Available() then
        print("[Tetris][Skill] 跳过技能选择（未启用/未放置按钮/无玩家），使用默认技能")
        self:ShowAll(false)
        self:Finish()
        return
    end

    -- 先全部隐藏，避免编辑器默认可见导致残留
    self:ShowAll(false)

    local cfg = cfgOf()
    if cfg.StartBtn then
        -- 仅显示「开始界面」（含开始按钮），点击后再出技能选择面板
        self:ShowForAll(cfg.StartPanel, true)
        self:ShowForAll(cfg.StartBtn, true)
        self:RegisterStart()
    else
        -- 无开始按钮：直接显示技能选择面板（对所有参与玩家）
        for _, ps in ipairs(self.players) do self:ShowPanelFor(ps, true) end
        self:RegisterSkills()
    end

    local secs = cfg.TimeoutSec or 20
    self.owner:AddTimerOnce(secs, function() self:OnTimeout() end)
    print(string.format("[Tetris][Skill] 等待 %d 名玩家选择技能（%.0f 秒超时）", #self.players, secs))
end

-- ---------------- 输入 ----------------
-- 「开始游戏」按钮：点击后切换出技能选择面板并注册技能按键
function TetrisSkillSelect:RegisterStart()
    if self._startReg then return end
    self._startReg = true
    local cfg = cfgOf()
    local selfRef = self
    self.owner:AddVPEvent(self.clickEventId, function(_self, ps)
        selfRef:OnStartClicked(ps)
    end, selfRef, cfg.StartBtn, nil)
    print("[Tetris][Skill] 「开始游戏」按钮已注册")
end

function TetrisSkillSelect:OnStartClicked(ps)
    if self.done or self._started then return end
    self._started = true
    local cfg = cfgOf()
    self:ShowForAll(cfg.StartPanel, false)        -- 隐藏开始界面（整体）
    self:ShowForAll(cfg.StartBtn, false)          -- 隐藏开始按钮（冗余保险）
    for _, p in ipairs(self.players) do
        self:ShowPanelFor(p, true)                -- 显示技能选择面板 + 3 个按键
    end
    self:RegisterSkills()
    print("[Tetris][Skill] 点击「开始游戏」，进入技能选择界面")
end

-- 注册 3 个技能按键的点击事件（点击者 PlayerState 由引擎回传）
function TetrisSkillSelect:RegisterSkills()
    if self.registered then return end
    self.registered = true
    local selfRef = self
    for _, b in ipairs(self:SkillBinds()) do
        if b[1] ~= nil then
            self.owner:AddVPEvent(self.clickEventId, function(_self, ps)
                selfRef:OnPick(ps, b[2])
            end, selfRef, b[1], nil)
        end
    end
    print("[Tetris][Skill] 技能按键已注册（SK01/SK02/SK06）")
end

function TetrisSkillSelect:OnPick(ps, key)
    if self.done or not ps then return end
    if not self:isParticipant(ps) then return end
    if self.choices[ps] then return end   -- 已选过，忽略重复点击

    self.choices[ps] = key

    -- 该玩家选完：其 3 个技能按钮全部失效（禁用交互）并隐藏面板
    for _, id in ipairs(self:SkillButtonIDs()) do
        if id ~= nil then
            pcall(function() CustomUIAPI.SetWidgetInteraction(ps, id, false) end)
        end
    end
    self:ShowPanelFor(ps, false)

    print(string.format("[Tetris][Skill] 玩家 %s 选择：%s", tostring(keyOf(ps)), self:SkillName(key)))
    self:Notify(ps, "已选择技能：" .. self:SkillName(key))

    -- 全部选完 → 结束选择阶段（进入玩法选择 / 开局）
    for _, p in ipairs(self.players) do
        if not self.choices[p] then return end
    end
    self:Finish()
end

function TetrisSkillSelect:OnTimeout()
    if self.done then return end
    local def = cfgOf().DefaultSkill or "SK02"
    print("[Tetris][Skill] 技能选择超时，未选择的玩家按默认技能 " .. tostring(def) .. " 开局")
    self:Finish()
end

-- ---------------- 收尾 ----------------
function TetrisSkillSelect:Finish()
    if self.done then return end
    self.done = true
    self:ShowAll(false)
    -- 未选择的玩家回填默认技能
    local def = cfgOf().DefaultSkill or "SK02"
    for _, ps in ipairs(self.players) do
        if not self.choices[ps] then
            self.choices[ps] = def
        end
    end
    if self.match then self.match:OnSkillSelected(self.choices) end
end

return TetrisSkillSelect
