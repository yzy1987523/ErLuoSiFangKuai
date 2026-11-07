-- 多语言界面：开始界面的 OpenBtn 打开；含「关闭 / 切换中文 / 切换英文 / 切换阿拉伯文」4 按钮
-- + 3 个语言标志图片(zh/en/ar) + 若干「内容组件」(图片+文本，各 3 种语言变体)。
-- 切换语言：高亮对应标志图片(透明度)、隐藏其余，并遍历内容组件按当前语言设置图片资源与文本。
pcall(require, "EnvLua.Core.Define.RcEventIdDefine")

local TetrisConfig = require("EnvLua.Server.Tetris.TetrisConfig")

local TetrisLang = {}
TetrisLang.__index = TetrisLang

local function keyOf(ps)
    if ps and type(ps.GetPlayerKey) == "function" then
        local ok, k = pcall(function() return ps:GetPlayerKey() end)
        if ok and k then return k end
    end
    return ps
end

local function cfgOf()
    return TetrisConfig.LangUI or {}
end

-- 运行时文本多语言：key -> {1=zh, 2=en, 3=ar}，与 LangKeys={zh,en,ar} 对齐。
-- 目前用于技能按钮提示（冷却中 / 能量不足）；其余硬编码文案可逐步迁移到这里。
TetrisLang.Texts = {
    SkillCooldown = { [1] = "技能冷却中", [2] = "Skill on cooldown", [3] = "المهارة قيد التبريد" },
    SkillNoPower  = { [1] = "技能 power 不足，无法释放！", [2] = "Not enough skill power to release!", [3] = "طاقة المهارة غير كافية، لا يمكن إطلاقها!" },
}

-- 按玩家当前语言解析文本：取 Texts[key][语言索引]；语言 = self._lang[ps]（未设置时回退面板默认 en=2）。
function TetrisLang:Tr(key, ps)
    local t = TetrisLang.Texts and TetrisLang.Texts[key]
    if not t then return "" end
    local n = (ps and self._lang and self._lang[ps]) or 2
    return t[n] or t[2] or t[1] or ""
end

function TetrisLang:new(owner, match)
    local o = setmetatable({}, TetrisLang)
    o.owner = owner
    o.match = match
    o.players = {}
    o._reg = false
    o.clickEventId = (type(RcEventIdDefine) == "table" and RcEventIdDefine.CustomUIClicked) or 120000
    o._lang = {}   -- 每玩家当前语言索引（1=zh, 2=en, 3=ar）
    return o
end

-- 可用：Enabled + Panel + BtnClose（OpenBtn 在开始界面上，单独控制）
function TetrisLang:Available()
    local cfg = cfgOf()
    return cfg.Enabled and cfg.Panel and cfg.BtnClose
end

function TetrisLang:ShowFor(ps, id, v)
    if not id or not ps or type(CustomUIAPI) ~= "table" then return end
    pcall(function() CustomUIAPI.SetWidgetVisible(ps, id, v) end)
end

-- 语言标志图片用可见性控制显隐（SetWidgetVisible）：当前语言显示，其余隐藏
function TetrisLang:ShowIndicatorFor(ps, id, v)
    self:ShowFor(ps, id, v)
end

-- OpenBtn 在开始界面上，显隐随开始界面（由 TetrisSkillSelect 调用）
function TetrisLang:ShowOpenBtnFor(ps, v)
    local cfg = cfgOf()
    self:ShowFor(ps, cfg.OpenBtn, v)
end

-- 打开多语言界面：隐藏开始界面（含 OpenBtn），显示本界面 + 当前语言
function TetrisLang:OpenFor(ps)
    if not self:Available() or not ps then return end
    local cfg = cfgOf()
    if self.match and self.match.skillSelect and type(self.match.skillSelect.HideStartScreenFor) == "function" then
        self.match.skillSelect:HideStartScreenFor(ps)
    end
    self:ShowFor(ps, cfg.Panel, true)
    self:ShowFor(ps, cfg.BtnClose, true)
    for _, b in ipairs(cfg.BtnLang or {}) do self:ShowFor(ps, b, true) end
    local n = self._lang[ps] or 2   -- 默认英文（LangKeys={zh,en,ar} → 2=en）
    self:ApplyLang(ps, n)
    print(string.format("[Tetris][Lang] 玩家 %s 打开多语言界面", tostring(keyOf(ps))))
end

-- 关闭多语言界面：隐藏本界面，回到开始界面（OpenBtn 随开始界面重新显示）
function TetrisLang:CloseFor(ps)
    self:HideFor(ps)
    local mm = self.match
    if mm and mm.skillSelect and type(mm.skillSelect.ShowStartScreenFor) == "function" then
        mm.skillSelect:ShowStartScreenFor(ps)
    end
    print(string.format("[Tetris][Lang] 玩家 %s 关闭多语言界面", tostring(keyOf(ps))))
end

-- 仅隐藏本界面（不回显开始界面）
-- 注：Contents 是「全局多语言组件注册表」，只换内容、不控制显隐，不属于面板内容；
--     此处只隐藏面板自身的容器/按钮/语言标志，不触碰 Contents（关闭面板不应藏掉常驻多语言组件）。
function TetrisLang:HideFor(ps)
    local cfg = cfgOf()
    self:ShowFor(ps, cfg.Panel, false)
    self:ShowFor(ps, cfg.BtnClose, false)
    for _, b in ipairs(cfg.BtnLang or {}) do self:ShowFor(ps, b, false) end
    for _, i in ipairs(cfg.LangIndicators or {}) do self:ShowIndicatorFor(ps, i, false) end
end

-- 切换语言到第 n 个（1=zh, 2=en, 3=ar）：记录 + 应用（标志图 + 内容）
function TetrisLang:SwitchLang(ps, n)
    if not ps or not n then return end
    self._lang[ps] = n
    self:ApplyLang(ps, n)
    print(string.format("[Tetris][Lang] 玩家 %s 切换语言 -> %s", tostring(keyOf(ps)), tostring((cfgOf().LangKeys or {})[n])))
end

-- 应用第 n 种语言：1) 面板语言标志图片显隐 + 2) 全局多语言组件(Contents)换内容
function TetrisLang:ApplyLang(ps, n)
    local cfg = cfgOf()
    local inds = cfg.LangIndicators or {}
    -- 1) 标志图片：只显示第 n 个，其余改为透明
    for i, iid in ipairs(inds) do
        self:ShowIndicatorFor(ps, iid, i == n)
    end
    -- 2) 全局多语言组件换内容（只换内容，不控制显隐）
    self:ApplyContents(ps, n)
end

-- 只刷新全局多语言组件 Contents 的内容（图片/文本/按钮图），不触碰显隐、不触碰面板标志图。
-- 供 ApplyLang 调用；也可单独用于「开局按已定语言统一刷一次」（玩家未打开过语言面板时同样生效）。
function TetrisLang:ApplyContents(ps, n)
    local cfg = cfgOf()
    local langKey = (cfg.LangKeys or {})[n]
    if not ps or type(CustomUIAPI) ~= "table" then return end
    for _, c in ipairs(cfg.Contents or {}) do
        if c and c.img and c.imgs then
            local ref = c.imgs[n] or (langKey and c.imgs[langKey])
            if ref then
                local r = (type(AssetRef) == "table" and AssetRef[ref]) or ref
                pcall(function() CustomUIAPI.SetImageWidgetContent(ps, c.img, r) end)
            end
        end
        if c and c.txt and c.texts then
            local t = c.texts[n] or (langKey and c.texts[langKey])
            if t then
                pcall(function() CustomUIAPI.SetTextContent(ps, c.txt, t) end)
            end
        end
        -- 按钮组件：常态图按当前语言替换；按下图若单独配了 btnPressed 用它，否则与常态同图
        -- （按下/常态用同一张图，编辑器已通过改颜色区分按下态，故 btnPressed 可留空）
        if c and c.btn and c.btnNormal then
            local refN = c.btnNormal[n] or (langKey and c.btnNormal[langKey])
            if refN then
                local rn = (type(AssetRef) == "table" and AssetRef[refN]) or refN
                pcall(function() CustomUIAPI.SetButtonNormalImage(ps, c.btn, rn) end)
                local refP = (c.btnPressed and (c.btnPressed[n] or (langKey and c.btnPressed[langKey]))) or refN
                local rp = (type(AssetRef) == "table" and AssetRef[refP]) or refP
                pcall(function() CustomUIAPI.SetButtonPressedImage(ps, c.btn, rp) end)
            end
        end
    end
end

-- 开局统一刷新：对每位玩家按其当前语言（未设置回退 en=2）刷新 Contents 内容。
-- 只换内容不碰显隐，故不会把面板标志图显示出来；保证玩家从未打开语言面板时，多语言组件也已按当前语言设好。
function TetrisLang:ApplyContentsForAll()
    for _, ps in ipairs(self.players or {}) do
        if ps then self:ApplyContents(ps, self._lang[ps] or 2) end
    end
end

-- 注册点击：OpenBtn(打开) / BtnClose(关闭) / 3 个 BtnLang(切换语言)
function TetrisLang:Register()
    if self._reg then return end
    local cfg = cfgOf()
    if not cfg.OpenBtn then return end   -- 没 OpenBtn 则不注册（界面也打不开）
    self._reg = true
    local selfRef = self
    self.owner:AddVPEvent(self.clickEventId, function(_self, ps)
        selfRef:OpenFor(ps)
    end, selfRef, cfg.OpenBtn, nil)
    if cfg.BtnClose then
        self.owner:AddVPEvent(self.clickEventId, function(_self, ps)
            selfRef:CloseFor(ps)
        end, selfRef, cfg.BtnClose, nil)
    end
    for i, b in ipairs(cfg.BtnLang or {}) do
        if b then
            self.owner:AddVPEvent(self.clickEventId, function(_self, ps)
                selfRef:SwitchLang(ps, i)
            end, selfRef, b, nil)
        end
    end
    print("[Tetris][Lang] 多语言界面按钮已注册")
end

return TetrisLang
