-- 详细帮助界面：由准备阶段界面的 OpenBtn 打开，BtnClose 关闭；
-- 3 个页面切换按钮(PageBtns)分别显隐对应的页面组件(Pages)（同屏只显当前页）。
-- 组件先用占位符(nil)，逻辑对 nil 容错：未放置的控件自动跳过。
pcall(require, "EnvLua.Core.Define.RcEventIdDefine")

local TetrisConfig = require("EnvLua.Server.Tetris.TetrisConfig")

local TetrisDetailHelp = {}
TetrisDetailHelp.__index = TetrisDetailHelp

local function keyOf(ps)
    if ps and type(ps.GetPlayerKey) == "function" then
        local ok, k = pcall(function() return ps:GetPlayerKey() end)
        if ok and k then return k end
    end
    return ps
end

function TetrisDetailHelp:new(owner, match)
    local o = setmetatable({}, TetrisDetailHelp)
    o.owner = owner
    o.match = match
    o.players = {}
    o._cur = {}        -- [PlayerState] = 当前页码
    o._reg = false
    o.clickEventId = (type(RcEventIdDefine) == "table" and RcEventIdDefine.CustomUIClicked) or 120000
    return o
end

local function cfgOf()
    return TetrisConfig.DetailHelp or {}
end

-- 阶段是否启用：Enabled + Panel + BtnClose（页面按钮/组件可逐个占位，nil 时自动跳过）
function TetrisDetailHelp:Available()
    local cfg = cfgOf()
    return cfg.Enabled and cfg.Panel and cfg.BtnClose
end

function TetrisDetailHelp:ShowFor(ps, id, v)
    if not id or not ps or type(CustomUIAPI) ~= "table" then return end
    pcall(function() CustomUIAPI.SetWidgetVisible(ps, id, v) end)
end

-- 标志图片(PageIndicators)用透明度控制显隐（非可见性）：v=true→不透明，false→全透明
function TetrisDetailHelp:ShowIndicatorFor(ps, id, v)
    if not id or not ps or type(CustomUIAPI) ~= "table" then return end
    pcall(function() CustomUIAPI.SetWidgetImageOpacity(ps, id, v and 1 or 0) end)
end

-- OpenBtn 归本模块配置所有，但其显示跟随准备阶段界面显隐（由 TetrisHelp:ShowPanelFor 调用）
function TetrisDetailHelp:ShowOpenBtnFor(ps, v)
    local cfg = cfgOf()
    self:ShowFor(ps, cfg.OpenBtn, v)
end

-- 切到第 n 页：仅显示 Pages[n] + 标志图片[n] + 该页的图片/文本组件；隐藏其余。
-- 切页同时执行 ApplyPageContent 设置该页的图片资源与文本。
function TetrisDetailHelp:ShowPage(ps, n)
    local cfg = cfgOf()
    local pages = cfg.Pages or {}
    local inds  = cfg.PageIndicators or {}
    local contents = cfg.PageContents or {}
    self._cur[ps] = n
    -- 1) 全部隐藏：页面容器、标志图片(透明度)、所有页的图片/文本组件
    for i, pid in ipairs(pages) do self:ShowFor(ps, pid, false) end
    for i, iid in ipairs(inds)  do self:ShowIndicatorFor(ps, iid, false) end
    for _, c in ipairs(contents) do
        for _, it in ipairs(c or {}) do
            self:ShowFor(ps, it and it.img, false)
            self:ShowFor(ps, it and it.txt, false)
        end
    end
    -- 2) 显示当前页：容器 + 标志图片(透明度) + 该页图片/文本组件
    self:ShowFor(ps, pages[n], true)
    self:ShowIndicatorFor(ps, inds[n],  true)
    for _, it in ipairs(contents[n] or {}) do
        self:ShowFor(ps, it and it.img, true)
        self:ShowFor(ps, it and it.txt, true)
    end
    -- 3) 设置当前页的图片资源与文本（专门函数，切页即执行）
    self:ApplyPageContent(ps, n)
    print(string.format("[Tetris][DetailHelp] 玩家 %s 切到第 %d 页", tostring(keyOf(ps)), n))
end

-- 按 cfg.PageContents[n] 设置某页所有项的图片资源与文本（img/res 给图片，txt/text 给文本）
function TetrisDetailHelp:_applyItems(ps, n)
    local cfg = cfgOf()
    local items = (cfg.PageContents and cfg.PageContents[n]) or {}
    for _, it in ipairs(items) do
        if it and it.img and it.res then
            local ref = (type(AssetRef) == "table" and AssetRef[it.res]) or it.res
            pcall(function() CustomUIAPI.SetImageWidgetContent(ps, it.img, ref) end)
        end
        if it and it.txt and it.text then
            pcall(function() CustomUIAPI.SetTextContent(ps, it.txt, it.text) end)
        end
    end
end

-- 专门函数：第 1 页 技能说明（每个技能：图标图片 + 说明文本）
function TetrisDetailHelp:ApplySkillPage(ps)
    self:_applyItems(ps, 1)
end

-- 专门函数：第 2 页 道具说明（每个道具：图标图片 + 说明文本）
function TetrisDetailHelp:ApplyItemPage(ps)
    self:_applyItems(ps, 2)
end

-- 专门函数：第 3 页 操作按钮说明（每个操作：图标图片 + 说明文本）
function TetrisDetailHelp:ApplyOpPage(ps)
    self:_applyItems(ps, 3)
end

-- 打开/切到某页时执行的"图片+文本设置"（按页分发到专门函数）
function TetrisDetailHelp:ApplyPageContent(ps, n)
    if n == 1 then self:ApplySkillPage(ps)
    elseif n == 2 then self:ApplyItemPage(ps)
    elseif n == 3 then self:ApplyOpPage(ps)
    end
end

-- 仅隐藏本界面（不回显准备阶段界面）：用于准备阶段关闭 / 重开时清理
function TetrisDetailHelp:HideFor(ps)
    local cfg = cfgOf()
    self:ShowFor(ps, cfg.Panel, false)
    for _, b in ipairs(cfg.PageBtns or {}) do self:ShowFor(ps, b, false) end
    for _, i in ipairs(cfg.PageIndicators or {}) do self:ShowIndicatorFor(ps, i, false) end
    for _, p in ipairs(cfg.Pages or {}) do self:ShowFor(ps, p, false) end
    for _, c in ipairs(cfg.PageContents or {}) do
        for _, it in ipairs(c or {}) do
            self:ShowFor(ps, it and it.img, false)
            self:ShowFor(ps, it and it.txt, false)
        end
    end
end

-- 打开详细帮助（隐藏准备阶段界面，显示本界面 + 第 1 页）
function TetrisDetailHelp:OpenFor(ps)
    if not self:Available() or not ps then return end
    local cfg = cfgOf()
    -- OpenBtn 在开始界面上：打开详细帮助时隐藏「开始游戏」界面（含 OpenBtn），而非准备阶段界面
    if self.match and self.match.skillSelect and type(self.match.skillSelect.HideStartScreenFor) == "function" then
        self.match.skillSelect:HideStartScreenFor(ps)
    end
    self:ShowFor(ps, cfg.Panel, true)
    for _, b in ipairs(cfg.PageBtns or {}) do self:ShowFor(ps, b, true) end
    self:ShowPage(ps, 1)
    print(string.format("[Tetris][DetailHelp] 玩家 %s 打开详细帮助", tostring(keyOf(ps))))
end

-- 关闭详细帮助：隐藏本界面，回到「开始游戏」界面（不再回显 HelpUI；HelpUI 仅默认显示一次）
function TetrisDetailHelp:CloseFor(ps)
    self:HideFor(ps)
    local mm = self.match
    if mm and mm.skillSelect and type(mm.skillSelect.ShowStartScreenFor) == "function" then
        mm.skillSelect:ShowStartScreenFor(ps)
    end
    print(string.format("[Tetris][DetailHelp] 玩家 %s 关闭详细帮助", tostring(keyOf(ps))))
end

function TetrisDetailHelp:HideAll()
    for _, ps in ipairs(self.players) do
        self:HideFor(ps)
    end
end

-- 注册点击事件：OpenBtn（打开）、3 个 PageBtns（切页）、BtnClose（关闭）
function TetrisDetailHelp:Register()
    if self._reg then return end
    if not self:Available() then return end
    self._reg = true
    local cfg = cfgOf()
    local selfRef = self
    if cfg.OpenBtn then
        self.owner:AddVPEvent(self.clickEventId, function(_self, ps)
            selfRef:OpenFor(ps)
        end, selfRef, cfg.OpenBtn, nil)
    end
    for i, b in ipairs(cfg.PageBtns or {}) do
        if b then
            self.owner:AddVPEvent(self.clickEventId, function(_self, ps)
                selfRef:ShowPage(ps, i)
            end, selfRef, b, nil)
        end
    end
    if cfg.BtnClose then
        self.owner:AddVPEvent(self.clickEventId, function(_self, ps)
            selfRef:CloseFor(ps)
        end, selfRef, cfg.BtnClose, nil)
    end
    print("[Tetris][DetailHelp] 详细帮助按钮（打开/切页/关闭）已注册")
end

return TetrisDetailHelp
