-- 声音控制面板：5 个按键（关闭、BGM -/+、音效 -/+）+ 一个「打开」入口按钮。
-- 控件（PanelKey / BtnClose / BtnBgmDown / BtnBgmUp / BtnSfxDown / BtnSfxUp / OpenBtn / BgmText / SfxText）
-- 必须在编辑器 UI Editor 预放置，UUID 填到 TetrisConfig.SoundSettings（用 CreativeInstance 全局表取）。
--
-- 权威来源：
--   EnvLua/Core/LuaHint/CustomUIAPI.lua  SetWidgetVisible / SetTextContent
--   EnvLua/Core/Define/RcEventIdDefine.lua  CustomUIClicked（@output 首个为点击者 PlayerState）
pcall(require, "EnvLua.Core.Define.RcEventIdDefine")

local TetrisConfig = require("EnvLua.Server.Tetris.TetrisConfig")
local TetrisAudio = require("EnvLua.Server.Tetris.TetrisAudio")

local TetrisSoundSettings = {}
TetrisSoundSettings.__index = TetrisSoundSettings

local function cfgOf()
    return TetrisConfig.SoundSettings or {}
end

-- 阶段是否可用：Enabled 且核心控件已放置
function TetrisSoundSettings:Available()
    local cfg = cfgOf()
    if not cfg.Enabled then return false end
    return (cfg.PanelKey ~= nil and cfg.BtnClose ~= nil
        and cfg.BtnBgmDown ~= nil and cfg.BtnBgmUp ~= nil
        and cfg.BtnSfxDown ~= nil and cfg.BtnSfxUp ~= nil)
end

function TetrisSoundSettings:new(owner, match)
    local o = setmetatable({}, TetrisSoundSettings)
    o.owner = owner            -- WoWObject，用于 AddVPEvent / AddTimerOnce
    o.match = match
    o.players = match.assigned or {}
    o._reg = false
    o._openReg = false
    o.clickEventId = (type(RcEventIdDefine) == "table" and RcEventIdDefine.CustomUIClicked) or 120000
    return o
end

-- ---------------- UI 显隐 ----------------
function TetrisSoundSettings:ShowFor(ps, id, visible)
    if not id or not ps or type(CustomUIAPI) ~= "table" then return end
    pcall(function() CustomUIAPI.SetWidgetVisible(ps, id, visible) end)
end

function TetrisSoundSettings:ShowForAll(id, visible)
    if not id or type(CustomUIAPI) ~= "table" then return end
    for _, ps in ipairs(self.players) do
        self:ShowFor(ps, id, visible)
    end
end

-- 需要统一显隐的控件集合（nil 项会被 ShowAll 跳过）。
-- 注意：OpenBtn（开始界面上的入口按钮）不在此列——它的显隐由编辑器/开始界面控制，
-- 不应被声音面板的「打开/关闭」影响。
function TetrisSoundSettings:WidgetIDs()
    local cfg = cfgOf()
    return { cfg.PanelKey, cfg.BtnClose, cfg.BtnBgmDown, cfg.BtnBgmUp,
             cfg.BtnSfxDown, cfg.BtnSfxUp, cfg.BgmText, cfg.SfxText }
end

function TetrisSoundSettings:ShowAll(visible)
    for _, id in ipairs(self:WidgetIDs()) do
        if id ~= nil then self:ShowForAll(id, visible) end
    end
end

-- 打开面板（对所有参与玩家显示），并刷新音量百分比文本
function TetrisSoundSettings:OpenForAll(ps)
    local cfg = cfgOf()
    local ok = self:Available()
    print(string.format("[Tetris][Sound][DEBUG] OpenForAll 调用 ps=%s Available=%s | Panel=%s Close=%s BgmD=%s BgmU=%s SfxD=%s SfxU=%s",
        tostring(ps), tostring(ok),
        tostring(cfg.PanelKey), tostring(cfg.BtnClose), tostring(cfg.BtnBgmDown), tostring(cfg.BtnBgmUp),
        tostring(cfg.BtnSfxDown), tostring(cfg.BtnSfxUp)))
    if not ok then
        print("[Tetris][Sound][DEBUG] 因 Available=false 直接返回（检查 Enabled 与 6 个核心控件是否都填了 UUID）")
        return
    end
    self:ShowAll(true)
    self:RefreshText()
    print("[Tetris][Sound][DEBUG] 面板已 ShowAll(true)，玩家数=" .. tostring(#self.players))
end

-- 音量百分比文本（控件可选；未配置则跳过）
function TetrisSoundSettings:RefreshText()
    local cfg = cfgOf()
    local sfxPct = math.floor(TetrisAudio.GetSFXVolume() * 100)
    local bgmPct = math.floor(TetrisAudio.GetBGMVolume() * 100)
    for _, ps in ipairs(self.players) do
        if cfg.SfxText then
            pcall(function() CustomUIAPI.SetTextContent(ps, cfg.SfxText, tostring(sfxPct) .. "%") end)
        end
        if cfg.BgmText then
            pcall(function() CustomUIAPI.SetTextContent(ps, cfg.BgmText, tostring(bgmPct) .. "%") end)
        end
    end
end

-- ---------------- 输入 ----------------
function TetrisSoundSettings:RegisterButtons()
    if self._reg then return end
    self._reg = true
    if not self:Available() then
        print("[Tetris][Sound] 声音控制面板未启用/未放置控件，跳过按钮注册")
        return
    end
    local cfg = cfgOf()
    local selfRef = self
    print(string.format("[Tetris][Sound][DEBUG] RegisterButtons: Panel=%s Close=%s BgmD=%s BgmU=%s SfxD=%s SfxU=%s BgmTxt=%s SfxTxt=%s players=%d",
        tostring(cfg.PanelKey), tostring(cfg.BtnClose), tostring(cfg.BtnBgmDown), tostring(cfg.BtnBgmUp),
        tostring(cfg.BtnSfxDown), tostring(cfg.BtnSfxUp), tostring(cfg.BgmText), tostring(cfg.SfxText), #self.players))
    local function bind(id, fn)
        if id ~= nil then
            self.owner:AddVPEvent(self.clickEventId, function(_self, ps)
                if fn then fn(ps) end
            end, selfRef, id, nil)
        end
    end
    -- 关闭：仅收起面板，不改音量
    bind(cfg.BtnClose, function(ps) selfRef:ShowAll(false) end)
    -- BGM 音量 -/+
    bind(cfg.BtnBgmDown, function(ps) TetrisAudio.ChangeBGM(-TetrisAudio.Step); selfRef:RefreshText() end)
    bind(cfg.BtnBgmUp,   function(ps) TetrisAudio.ChangeBGM( TetrisAudio.Step); selfRef:RefreshText() end)
    -- 音效音量 -/+
    bind(cfg.BtnSfxDown, function(ps) TetrisAudio.ChangeSFX(-TetrisAudio.Step); selfRef:RefreshText() end)
    bind(cfg.BtnSfxUp,   function(ps) TetrisAudio.ChangeSFX( TetrisAudio.Step); selfRef:RefreshText() end)

    -- 显式开启所有面板控件的交互（按钮需可点击才生效；可见性由 ShowAll 控制）
    for _, id in ipairs(self:WidgetIDs()) do
        if id ~= nil then
            for _, p in ipairs(self.players) do
                pcall(function() CustomUIAPI.SetWidgetInteraction(p, id, true) end)
            end
        end
    end
    -- 初始全部隐藏，避免编辑器默认可见导致残留
    self:ShowAll(false)
    print("[Tetris][Sound][DEBUG] 声音控制按钮已注册（关闭/BGM±/音效±），交互已开启")
end

-- 注册「打开声音面板」入口按钮（控件需在编辑器预放置；点击 → 显示面板）
function TetrisSoundSettings:RegisterOpenBtn()
    if self._openReg then return end
    local cfg = cfgOf()
    if not cfg or cfg.OpenBtn == nil then
        print("[Tetris][Sound][DEBUG] RegisterOpenBtn 跳过：OpenBtn=nil（未配置打开入口按钮）")
        return
    end
    self._openReg = true
    local selfRef = self
    -- 显式开启入口按钮交互（按钮需可点击才收得到 CustomUIClicked）
    for _, p in ipairs(self.players) do
        pcall(function() CustomUIAPI.SetWidgetInteraction(p, cfg.OpenBtn, true) end)
    end
    self.owner:AddVPEvent(self.clickEventId, function(_self, ps)
        print(string.format("[Tetris][Sound][DEBUG] OpenBtn 被点击 ps=%s（clickEventId=%s）", tostring(ps), tostring(selfRef.clickEventId)))
        selfRef:OpenForAll(ps)
    end, selfRef, cfg.OpenBtn, nil)
    print(string.format("[Tetris][Sound][DEBUG] 「打开声音面板」入口按钮已注册 OpenBtn=%s 玩家数=%d", tostring(cfg.OpenBtn), #self.players))
end

return TetrisSoundSettings
