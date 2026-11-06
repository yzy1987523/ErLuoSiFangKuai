-- 准备阶段空闲展示版：开局前置默认显示，仅作空闲展示 + 一个「关闭」按钮。
-- 内含 OpenBtn（显示由本模块控制，点击事件由 TetrisDetailHelp 接管：点它打开详细帮助）。
-- 本界面显隐由 Begin/HideFor 控制，不受详细帮助开关影响。
pcall(require, "EnvLua.Core.Define.RcEventIdDefine")

local TetrisConfig = require("EnvLua.Server.Tetris.TetrisConfig")

local TetrisHelp = {}
TetrisHelp.__index = TetrisHelp

local function keyOf(ps)
    if ps and type(ps.GetPlayerKey) == "function" then
        local ok, k = pcall(function() return ps:GetPlayerKey() end)
        if ok and k then return k end
    end
    return ps
end

function TetrisHelp:new(owner, match)
    local o = setmetatable({}, TetrisHelp)
    o.owner = owner
    o.match = match
    o.players = {}
    o._reg = false
    o.clickEventId = (type(RcEventIdDefine) == "table" and RcEventIdDefine.CustomUIClicked) or 120000
    return o
end

local function cfgOf()
    return TetrisConfig.HelpUI or {}
end

-- 阶段是否可用：Panel + BtnClose 已配置
function TetrisHelp:Available()
    local cfg = cfgOf()
    return cfg.Panel and cfg.BtnClose
end

function TetrisHelp:ShowFor(ps, id, v)
    if not id or not ps or type(CustomUIAPI) ~= "table" then return end
    pcall(function() CustomUIAPI.SetWidgetVisible(ps, id, v) end)
end

-- 显示/隐藏 准备阶段界面整体（Panel + BtnClose）。
-- 注意：OpenBtn 已归 DetailHelp 配置所有，但其显示需跟随本界面显隐，故委托 DetailHelp 控制。
function TetrisHelp:ShowPanelFor(ps, v)
    local cfg = cfgOf()
    self:ShowFor(ps, cfg.Panel, v)
    self:ShowFor(ps, cfg.BtnClose, v)
    -- OpenBtn 已不在此界面（改在开始界面）：显示准备阶段界面时确保它隐藏，避免开始界面默认可见时透出
    if v then
        local mm = self.match
        if mm and mm.detailHelp and type(mm.detailHelp.ShowOpenBtnFor) == "function" then
            mm.detailHelp:ShowOpenBtnFor(ps, false)
        end
    end
end

-- 对外：开始准备阶段（对所有参与玩家显示界面）
function TetrisHelp:Begin(players)
    self.players = players or {}
    if not self:Available() then
        print("[Tetris][Help] 跳过准备阶段界面（未启用/未放置控件）")
        return
    end
    for _, ps in ipairs(self.players) do
        self:ShowPanelFor(ps, true)
    end
    self:Register()
    print(string.format("[Tetris][Help] 准备阶段界面已显示（%d 名玩家）", #self.players))
end

-- 隐藏单个玩家的准备阶段界面（并回到「开始游戏」界面）
function TetrisHelp:HideFor(ps)
    local cfg = cfgOf()
    self:ShowPanelFor(ps, false)
    -- 顺手确保详细帮助已隐藏（仅隐藏，不回显本界面）
    if self.match and self.match.detailHelp and type(self.match.detailHelp.HideFor) == "function" then
        self.match.detailHelp:HideFor(ps)
    end
    local mm = self.match
    if mm and mm.skillSelect and type(mm.skillSelect.ShowStartScreenFor) == "function" then
        mm.skillSelect:ShowStartScreenFor(ps)
    end
end

function TetrisHelp:HideAll()
    for _, ps in ipairs(self.players) do
        self:HideFor(ps)
    end
end

-- 注册：仅「关闭」按钮（OpenBtn 的点击由 TetrisDetailHelp 接管）
function TetrisHelp:Register()
    if self._reg then return end
    if not self:Available() then return end
    self._reg = true
    local cfg = cfgOf()
    local selfRef = self
    if cfg.BtnClose then
        self.owner:AddVPEvent(self.clickEventId, function(_self, ps)
            selfRef:HideFor(ps)
        end, selfRef, cfg.BtnClose, nil)
    end
    print("[Tetris][Help] 准备阶段界面「关闭」按钮已注册")
end

return TetrisHelp
