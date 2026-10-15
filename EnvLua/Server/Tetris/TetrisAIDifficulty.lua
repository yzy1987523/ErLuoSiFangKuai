-- 单人 AI 难度选择阶段：仅单人模式进入。
-- 显示 AiPanel + 3 个难度按钮（简单/普通/困难），玩家选完难度后写入 match.aiDifficulty，
-- 再进入技能选择阶段（TetrisSkillSelect:Begin）。双人或控件未配置则跳过（由 Match 直接进技能选择）。
--
-- 与 TetrisSkillSelect 同级：所有 widget 必须在编辑器 UI Editor 预放置，UUID 填到
-- TetrisConfig.AI.{PanelKey,BtnEasy,BtnNormal,BtnHard}（用 CreativeInstance 全局表取）。未放置则自动跳过本阶段。
--
-- 权威来源：
--   EnvLua/Core/LuaHint/CustomUIAPI.lua  SetWidgetVisible / SetWidgetInteraction
--   EnvLua/Core/Define/RcEventIdDefine.lua  CustomUIClicked（@output 首个为点击者 PlayerState）
pcall(require, "EnvLua.Core.Define.RcEventIdDefine")

local TetrisConfig = require("EnvLua.Server.Tetris.TetrisConfig")
local TetrisSkillSelect = require("EnvLua.Server.Tetris.TetrisSkillSelect")

local TetrisAIDifficulty = {}
TetrisAIDifficulty.__index = TetrisAIDifficulty

local function cfgOf()
    return TetrisConfig.AI or {}
end

-- 难度按钮对应的（控件, 难度 key）；顺序与编辑器放置一致：简单 / 普通 / 困难
function TetrisAIDifficulty:LevelBinds()
    local cfg = cfgOf()
    return {
        { cfg.BtnEasy,   "Easy" },
        { cfg.BtnNormal, "Normal" },
        { cfg.BtnHard,   "Hard" },
    }
end

function TetrisAIDifficulty:LevelName(key)
    return ({ Easy = "简单", Normal = "普通", Hard = "困难" })[key] or tostring(key)
end

-- 需要统一显隐的控件：容器面板 + 3 个难度按钮
function TetrisAIDifficulty:WidgetIDs()
    local cfg = cfgOf()
    return { cfg.PanelKey, cfg.BtnEasy, cfg.BtnNormal, cfg.BtnHard }
end

-- 阶段是否可用：AI 开启且 4 个控件都已放置
function TetrisAIDifficulty:Available()
    local cfg = cfgOf()
    if not cfg.Enabled then return false end
    return (cfg.PanelKey ~= nil and cfg.BtnEasy ~= nil and cfg.BtnNormal ~= nil and cfg.BtnHard ~= nil)
end

function TetrisAIDifficulty:new(owner, match)
    local o = setmetatable({}, TetrisAIDifficulty)
    o.owner = owner            -- WoWObject，用于 AddVPEvent
    o.match = match
    o.players = {}             -- 参与选择的 PlayerState 列表
    o.done = false
    o.registered = false
    o.clickEventId = (type(RcEventIdDefine) == "table" and RcEventIdDefine.CustomUIClicked) or 120000
    return o
end

-- ---------------- UI 显隐 ----------------
function TetrisAIDifficulty:ShowForAll(id, visible)
    if not id or type(CustomUIAPI) ~= "table" then return end
    for _, ps in ipairs(self.players) do
        pcall(function() CustomUIAPI.SetWidgetVisible(ps, id, visible) end)
    end
end

-- 隐藏/显示本阶段全部控件（所有玩家）
function TetrisAIDifficulty:ShowAll(visible)
    for _, id in ipairs(self:WidgetIDs()) do
        self:ShowForAll(id, visible)
    end
end

-- ---------------- 对外：开始选择阶段 ----------------
function TetrisAIDifficulty:Begin(players)
    self.players = players or {}

    if #self.players == 0 or not self:Available() then
        print("[Tetris][AI] 跳过 AI 难度选择（未启用/未放置控件/无玩家），直接进入技能选择")
        self:ProceedToSkillSelect()
        return
    end

    -- 先全部隐藏，避免编辑器默认可见导致残留
    self:ShowAll(false)

    -- 显示 AiPanel + 3 个难度按钮（对所有参与玩家）
    local cfg = cfgOf()
    self:ShowForAll(cfg.PanelKey, true)
    for _, b in ipairs(self:LevelBinds()) do
        if b[1] ~= nil then self:ShowForAll(b[1], true) end
    end

    self:RegisterLevels()
    print(string.format("[Tetris][AI] 等待 %d 名玩家选择 AI 难度（简单/普通/困难）", #self.players))
end

-- 注册 3 个难度按钮的点击事件（点击者 PlayerState 由引擎回传）
function TetrisAIDifficulty:RegisterLevels()
    if self.registered then return end
    self.registered = true
    local selfRef = self
    for _, b in ipairs(self:LevelBinds()) do
        if b[1] ~= nil then
            self.owner:AddVPEvent(self.clickEventId, function(_self, ps)
                selfRef:OnPick(ps, b[2])
            end, selfRef, b[1], nil)
        end
    end
    print("[Tetris][AI] 难度按钮已注册（Easy/Normal/Hard）")
end

function TetrisAIDifficulty:OnPick(ps, level)
    if self.done or not ps then return end
    self.done = true
    self.match.aiDifficulty = level
    print(string.format("[Tetris][AI] 玩家选择 AI 难度：%s", self:LevelName(level)))

    -- 隐藏 AiPanel + 难度按钮，进入技能选择阶段
    self:ShowAll(false)
    self:ProceedToSkillSelect()
end

-- 无论是否经过本阶段，最终都进入技能选择（由 Match 决定是否启用技能选择）
function TetrisAIDifficulty:ProceedToSkillSelect()
    -- 复用点击 StartBtn 时建立的技能选择实例（已 Begin，仅差显示面板），避免重弹开始界面
    if self.match and self.match.skillSelect then
        self.match.skillSelect:ShowSkillPanel()
    else
        self.match.skillSelect = TetrisSkillSelect:new(self.match.owner, self.match)
        self.match.skillSelect:Begin(self.players)
    end
end

return TetrisAIDifficulty
