-- 玩法选择阶段：同图内用 CustomUI 按钮选玩法（俄罗斯方块 / 四消 / 随机），
-- 选完（或超时 / 未放置按钮）回调 TetrisMatch:OnModeSelected，由 Match 把玩家传送到出生点后开局。
--
-- 为什么不切地图：文档「切换规则」要求对局外切换，但当前 EnvLua/Preset/LevelPreset.lua
-- 只注册了 1 张关卡（59_LevelPreset_0 = 0），MultiLevelAPI.LoadLevel 没有目标图可切。
-- 故采用「回合开始先出选择界面 → 选完传送到出生点 → 开局」，等价"局外选择、传送进局"。
--
-- 权威来源：
--   EnvLua/Core/LuaHint/CustomUIAPI.lua     SetWidgetVisible / SetTextContent
--   EnvLua/Core/Define/RcEventIdDefine.lua  CustomUIClicked（@output 首个为点击者 PlayerState）
pcall(require, "EnvLua.Core.Define.RcEventIdDefine")

local TetrisConfig = require("EnvLua.Server.Tetris.TetrisConfig")

local TetrisModeSelect = {}
TetrisModeSelect.__index = TetrisModeSelect

-- 本期已实现的玩法。四消需 6×12 盘面 + 4 色预着色方块资源（见 TetrisConfig.Render.ColorModelIDs
-- 目前全为 nil = 单色），四消靠"同色连通"判定，单色不可玩，故暂不开放。
local IMPLEMENTED = {
    [TetrisConfig.GameMode.Tetris] = true,
    [TetrisConfig.GameMode.Puyo] = true,   -- 噗哟噗哟（四消）
}

-- 玩家稳定 key（仅用于日志与查表）；取不到时回退 PlayerState 本身
local function keyOf(ps)
    if ps and type(ps.GetPlayerKey) == "function" then
        local ok, k = pcall(function() return ps:GetPlayerKey() end)
        if ok and k then return k end
    end
    return ps
end

function TetrisModeSelect:new(owner, match)
    local o = setmetatable({}, TetrisModeSelect)
    o.owner = owner            -- WoWObject，用于 AddVPEvent / AddTimerOnce
    o.match = match
    o.players = {}             -- 参与选择的 PlayerState 列表
    o.choices = {}             -- [PlayerState] = 已解析的玩法
    o.done = false
    o.registered = false
    o.clickEventId = (type(RcEventIdDefine) == "table" and RcEventIdDefine.CustomUIClicked) or 120000
    return o
end

local function cfgOf()
    return TetrisConfig.ModeSelect or {}
end

-- 选择阶段是否可用：开关打开且至少放了一个选择控件（面板或按键）
function TetrisModeSelect:Available()
    local cfg = cfgOf()
    if not cfg.Enabled then return false end
    return (cfg.PanelKey ~= nil or cfg.BtnTetris ~= nil or cfg.BtnMatch4 ~= nil or cfg.BtnPuyo ~= nil)
end

-- 需要统一显隐的控件：面板 + 各玩法按键（部分引擎隐藏父面板不会级联到子控件，故逐个下发）
function TetrisModeSelect:WidgetIDs()
    local cfg = cfgOf()
    return { cfg.PanelKey, cfg.BtnTetris, cfg.BtnMatch4, cfg.BtnPuyo }
end

-- 给玩家发一条聊天框提示（失败不影响流程）
function TetrisModeSelect:Notify(ps, content)
    if not ps or type(Log) ~= "table" then return end
    pcall(function() Log.SendQuickMenuMessage(ps, content) end)
end

-- 解析玩法：随机 → 从已实现玩法中抽；未实现 → 上屏提示并回退俄罗斯方块
function TetrisModeSelect:Resolve(mode, ps)
    local M = TetrisConfig.GameMode
    if mode == M.Random then
        local pool = {}
        for m in pairs(IMPLEMENTED) do pool[#pool + 1] = m end
        table.sort(pool)
        local picked = pool[math.random(1, #pool)]
        print("[Tetris][Mode] 随机玩法 -> " .. tostring(picked))
        return picked or M.Tetris
    end
    if not IMPLEMENTED[mode] then
        print("[Tetris][Mode] 玩法 " .. tostring(mode) .. " 尚未实现，回退 " .. tostring(M.Tetris))
        self:Notify(ps, "四消玩法开发中，本局先按俄罗斯方块开局")
        return M.Tetris
    end
    return mode
end

function TetrisModeSelect:DefaultMode()
    return self:Resolve(cfgOf().DefaultMode or TetrisConfig.GameMode.Tetris)
end

-- ---------------- 对外：开始选择阶段 ----------------
function TetrisModeSelect:Begin(players)
    self.players = players or {}
    if #self.players == 0 or not self:Available() then
        print("[Tetris][Mode] 跳过选择阶段（未启用 / 按钮未放置 / 无玩家），直接开局")
        self:Finish()
        return
    end
    self:ShowUI(true)
    self:Register()
    local secs = cfgOf().TimeoutSec or 20
    self.owner:AddTimerOnce(secs, function() self:OnTimeout() end)
    print(string.format("[Tetris][Mode] 等待 %d 名玩家选择玩法（%.0f 秒超时）", #self.players, secs))
end

-- ---------------- UI ----------------
function TetrisModeSelect:ShowUI(visible)
    if type(CustomUIAPI) ~= "table" then
        print("[Tetris][WARN] CustomUIAPI 不可用，选择 UI 无法显示")
        return
    end
    local ids = self:WidgetIDs()
    for _, ps in ipairs(self.players) do
        for _, id in ipairs(ids) do
            if id ~= nil then
                pcall(function() CustomUIAPI.SetWidgetVisible(ps, id, visible) end)
            end
        end
    end
end

-- ---------------- 输入 ----------------
-- 每个按钮注册一次；回调由引擎带上「点击者 PlayerState」，据此记录该玩家的玩法。
function TetrisModeSelect:Register()
    if self.registered then return end
    self.registered = true
    local cfg = cfgOf()
    local M = TetrisConfig.GameMode
    local binds = {
        { cfg.BtnTetris, M.Tetris },
        { cfg.BtnMatch4, M.Match4 },
        { cfg.BtnPuyo, M.Puyo },
    }
    local selfRef = self
    for _, b in ipairs(binds) do
        if b[1] ~= nil then
            self.owner:AddVPEvent(self.clickEventId, function(_self, ps)
                selfRef:OnPick(ps, b[2])
            end, selfRef, b[1], nil)
        end
    end
    print("[Tetris][Mode] 玩法选择按钮已注册")
end

function TetrisModeSelect:OnPick(ps, mode)
    if self.done or not ps then return end
    -- 只接受参与本局选择玩家的点击
    local belong = false
    for _, p in ipairs(self.players) do if p == ps then belong = true break end end
    if not belong then return end

    local resolved = self:Resolve(mode, ps)
    self.choices[ps] = resolved
    -- 该玩家选完即隐藏其选择 UI
    if type(CustomUIAPI) == "table" then
        for _, id in ipairs(self:WidgetIDs()) do
            if id ~= nil then
                pcall(function() CustomUIAPI.SetWidgetVisible(ps, id, false) end)
            end
        end
    end
    print(string.format("[Tetris][Mode] 玩家 %s 选择：%s -> %s",
        tostring(keyOf(ps)), tostring(mode), tostring(resolved)))

    -- 全部选完 → 结束选择阶段（传送 + 开局）
    for _, p in ipairs(self.players) do
        if not self.choices[p] then return end
    end
    self:Finish()
end

function TetrisModeSelect:OnTimeout()
    if self.done then return end
    print("[Tetris][Mode] 选择超时，未选择的玩家按默认玩法开局")
    self:Finish()
end

-- ---------------- 收尾 ----------------
function TetrisModeSelect:Finish()
    if self.done then return end
    self.done = true
    self:ShowUI(false)
    for _, ps in ipairs(self.players) do
        if not self.choices[ps] then
            self.choices[ps] = self:DefaultMode()
        end
    end
    if self.match then self.match:OnModeSelected(self.choices) end
end

return TetrisModeSelect
