-- 帮助/玩法说明界面：分页（3 张说明图）查看，左/右翻页 + 关闭。
-- 控件需在编辑器 UI Editor 预放置，UUID 填到 TetrisConfig.HelpUI.*（用 CreativeInstance 全局表取）。
-- 未放置 / 未配置则自动跳过本阶段。
--
-- 权威来源：
--   EnvLua/Core/LuaHint/CustomUIAPI.lua  SetWidgetVisible / SetImageWidgetContent
--   EnvLua/Core/Define/RcEventIdDefine.lua  CustomUIClicked（@output 首个为点击者 PlayerState）
pcall(require, "EnvLua.Core.Define.RcEventIdDefine")

local TetrisConfig = require("EnvLua.Server.Tetris.TetrisConfig")

local TetrisHelp = {}
TetrisHelp.__index = TetrisHelp

-- 玩家稳定 key（仅用于日志）；取不到时回退 PlayerState 本身
local function keyOf(ps)
    if ps and type(ps.GetPlayerKey) == "function" then
        local ok, k = pcall(function() return ps:GetPlayerKey() end)
        if ok and k then return k end
    end
    return ps
end

function TetrisHelp:new(owner, match)
    local o = setmetatable({}, TetrisHelp)
    o.owner = owner            -- WoWObject，用于 AddVPEvent
    o.match = match
    o.players = {}             -- 参与帮助的 PlayerState 列表
    o._cur = {}                -- [PlayerState] = 当前页码
    o._reg = false
    o.clickEventId = (type(RcEventIdDefine) == "table" and RcEventIdDefine.CustomUIClicked) or 120000
    return o
end

local function cfgOf()
    return TetrisConfig.HelpUI or {}
end

-- 阶段是否可用：面板 / 图片显示组件 / 至少 1 张图都已配置
function TetrisHelp:Available()
    local cfg = cfgOf()
    return cfg.Panel and cfg.ImageView and type(cfg.Images) == "table" and #cfg.Images >= 1
end

-- 对外：开始帮助阶段（对所有参与玩家显示第 1 页）
function TetrisHelp:Begin(players)
    self.players = players or {}
    if not self:Available() then
        print("[Tetris][Help] 跳过帮助界面（未启用/未放置控件/无图片）")
        return
    end
    local cfg = cfgOf()
    for _, ps in ipairs(self.players) do
        self:ShowFor(ps, cfg.Panel, true)
        self:ShowFor(ps, cfg.BtnClose, true)
        self:ShowFor(ps, cfg.BtnRight, true)
        self:ShowFor(ps, cfg.BtnLeft, false)   -- 第 1 页不显示“左”
        self:SetPage(ps, 1)
    end
    self:Register()
    print(string.format("[Tetris][Help] 帮助界面已显示（%d 名玩家，共 %d 张图）", #self.players, #cfg.Images))
end

function TetrisHelp:ShowFor(ps, id, v)
    if not id or not ps or type(CustomUIAPI) ~= "table" then return end
    pcall(function() CustomUIAPI.SetWidgetVisible(ps, id, v) end)
end

function TetrisHelp:SetImage(ps, imgKey)
    local cfg = cfgOf()
    if not cfg.ImageView or not imgKey then return end
    local id = (type(AssetRef) == "table" and AssetRef[imgKey]) or imgKey
    pcall(function() CustomUIAPI.SetImageWidgetContent(ps, cfg.ImageView, id) end)
end

-- 设置某玩家页码，并同步左/右按钮显隐：
--   第 1 页隐藏“左”；最后 1 页隐藏“右”；关闭始终显示。
function TetrisHelp:SetPage(ps, n)
    local cfg = cfgOf()
    local total = #cfg.Images
    if n < 1 then n = 1 end
    if n > total then n = total end
    self._cur[ps] = n
    self:SetImage(ps, cfg.Images[n])
    self:ShowFor(ps, cfg.BtnLeft,  n > 1)
    self:ShowFor(ps, cfg.BtnRight, n < total)
    self:ShowFor(ps, cfg.BtnClose, true)
    print(string.format("[Tetris][Help] 玩家 %s 翻到第 %d/%d 页（左=%s 右=%s）",
        tostring(keyOf(ps)), n, total, tostring(n > 1), tostring(n < total)))
end

function TetrisHelp:Next(ps)
    local cfg = cfgOf()
    local n = (self._cur[ps] or 1) + 1
    if n <= #cfg.Images then self:SetPage(ps, n) end
end

function TetrisHelp:Prev(ps)
    local n = (self._cur[ps] or 1) - 1
    if n >= 1 then self:SetPage(ps, n) end
end

function TetrisHelp:HideFor(ps)
    local cfg = cfgOf()
    self:ShowFor(ps, cfg.Panel, false)
    self:ShowFor(ps, cfg.BtnLeft, false)
    self:ShowFor(ps, cfg.BtnRight, false)
    self:ShowFor(ps, cfg.BtnClose, false)
    -- 关闭帮助界面后，显示该玩家的「开始游戏」界面（串行流程：先看帮助，再进开始界面）
    local mm = self.match
    if mm and mm.skillSelect and type(mm.skillSelect.ShowStartScreenFor) == "function" then
        mm.skillSelect:ShowStartScreenFor(ps)
    end
end

-- 开始界面上的「帮助」按钮：点击后隐藏该玩家开始界面，显示并初始化帮助界面（回到第 1 页）
function TetrisHelp:OpenFromButton(ps)
    if not self:Available() or not ps then return end
    -- 先隐藏该玩家的开始界面（帮助覆盖其上），再显示并初始化帮助
    local mm = self.match
    if mm and mm.skillSelect and type(mm.skillSelect.HideStartScreenFor) == "function" then
        mm.skillSelect:HideStartScreenFor(ps)
    end
    self:ShowForPlayer(ps)
end

-- 对单个玩家显示帮助界面并初始化到第 1 页（用于从开始界面的「帮助」按钮重新打开）
function TetrisHelp:ShowForPlayer(ps)
    if not self:Available() or not ps then return end
    self:Register()   -- 防御性：确保按钮已注册（正常在 Begin 时已注册）
    local cfg = cfgOf()
    self:ShowFor(ps, cfg.Panel, true)
    self:ShowFor(ps, cfg.BtnClose, true)
    self:ShowFor(ps, cfg.BtnRight, true)
    self:ShowFor(ps, cfg.BtnLeft, false)   -- 第 1 页不显示“左”
    self:SetPage(ps, 1)                    -- 初始化：第 1 张图 + 左/右显隐
    print(string.format("[Tetris][Help] 玩家 %s 通过「帮助」按钮打开帮助（已初始化到第 1 页）", tostring(keyOf(ps))))
end

function TetrisHelp:HideAll()
    for _, ps in ipairs(self.players) do
        self:HideFor(ps)
    end
end

function TetrisHelp:Register()
    if self._reg then return end
    if not self:Available() then return end
    self._reg = true
    local cfg = cfgOf()
    local selfRef = self
    if cfg.BtnRight then
        self.owner:AddVPEvent(self.clickEventId, function(_self, ps)
            selfRef:Next(ps)
        end, selfRef, cfg.BtnRight, nil)
    end
    if cfg.BtnLeft then
        self.owner:AddVPEvent(self.clickEventId, function(_self, ps)
            selfRef:Prev(ps)
        end, selfRef, cfg.BtnLeft, nil)
    end
    if cfg.BtnClose then
        self.owner:AddVPEvent(self.clickEventId, function(_self, ps)
            selfRef:HideFor(ps)
        end, selfRef, cfg.BtnClose, nil)
    end
    if cfg.OpenBtn then
        self.owner:AddVPEvent(self.clickEventId, function(_self, ps)
            selfRef:OpenFromButton(ps)
        end, selfRef, cfg.OpenBtn, nil)
    end
    print("[Tetris][Help] 帮助界面按钮（左/右/关闭/打开）已注册")
end

return TetrisHelp
