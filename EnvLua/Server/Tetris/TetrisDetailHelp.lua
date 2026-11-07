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

-- ---------------- 帮助文本宽度适配（按字符数折行） ----------------
-- UMG 文本框宽度有限，长文案会溢出。CustomUIAPI.SetTextContent 只吃纯字符串、无自动换行接口，
-- 故写入前自行按「UTF-8 字符数」插入 \n。计数不能用 #s（字节数）：中文 3 字节/字、阿语 2 字节/字。
-- 每行上限 X = 当前语言下全部帮助文本中最长一条的字符数 × Ratio(默认 0.5，即减半)，见 TetrisConfig.HelpWrap。

-- UTF-8 字符串 → 字符数组（逐字符；不依赖 utf8 库，兼容 Lua 5.1）
local function utf8Chars(s)
    local t, i, n = {}, 1, #s
    while i <= n do
        local b = s:byte(i)
        local w = 1
        if b >= 0xF0 and b <= 0xF7 then w = 4
        elseif b >= 0xE0 and b <= 0xEF then w = 3
        elseif b >= 0xC0 and b <= 0xDF then w = 2 end
        if i + w - 1 > n then w = 1 end
        t[#t + 1] = s:sub(i, i + w - 1)
        i = i + w
    end
    return t
end

-- 计算当前语言的每行上限 X：XByLang 指定则直接用（中文固定 6）；
-- 否则遍历 3 页帮助文本取最长字符数、减半（向上取整）；返回 nil 表示不启用折行
local function wrapLimitFor(lang)
    local w = TetrisConfig.HelpWrap
    if not w or not w.Enabled then return nil end
    -- 按语言写死的 X 优先（如中文固定 6）；未指定的语言走下面的「最长减半」动态计算
    local fixed = w.XByLang and w.XByLang[lang]
    if fixed and fixed >= 1 then return fixed end
    local maxLen = 0
    for p = 1, 3 do
        local page = TetrisConfig.HelpTexts and TetrisConfig.HelpTexts[p]
        if page then
            for i = 1, #page do
                local t = page[i] and page[i][lang]
                if t then
                    local c = #utf8Chars(t)
                    if c > maxLen then maxLen = c end
                end
            end
        end
    end
    if maxLen <= 0 then return nil end
    -- 向上取整：保证「最长一条」减半后正好折成 2 行（floor 时 2X < maxLen 会切成 3 行）
    local x = math.ceil(maxLen * (w.Ratio or 0.5))
    local minC = w.MinChars or 1
    if x < minC then x = minC end
    return x
end

-- 当前语言对应的字号：FontSizeByLang[lang] 优先，未配置则回退 FontSize；都没配返回 nil（不改动控件）
local function fontSizeFor(lang)
    local w = TetrisConfig.HelpWrap
    if not w then return nil end
    return (w.FontSizeByLang and w.FontSizeByLang[lang]) or w.FontSize
end

-- 折行：文本字符数超过 limit 时按每行 ≤ limit 字符插入 \n。
-- 优先在行尾附近的空白/连字符处断开（不拆开英文、阿语单词）；无空白（中文）则按字符硬切。
local function wrapText(s, limit)
    if not limit or limit < 1 then return s end
    -- 已有换行先分段，各段独立折行（避免把 \n 当普通字符计入行宽）
    if s:find("\n", 1, true) then
        local parts, out = {}, {}
        for seg in (s .. "\n"):gmatch("([^\n]*)\n") do parts[#parts + 1] = seg end
        for _, seg in ipairs(parts) do out[#out + 1] = wrapText(seg, limit) end
        return table.concat(out, "\n")
    end
    local cs = utf8Chars(s)
    if #cs <= limit then return s end
    local lines, start = {}, 1
    while start <= #cs do
        local stop = math.min(start + limit - 1, #cs)
        if stop >= #cs then
            lines[#lines + 1] = table.concat(cs, "", start, #cs)
            break
        end
        local cut = nil
        local minCut = start + math.floor(limit * 0.6)
        for j = stop, minCut, -1 do
            if cs[j] == " " or cs[j] == "\t" or cs[j] == "-" then cut = j break end
        end
        if cut then
            lines[#lines + 1] = table.concat(cs, "", start, cut - 1)
            start = cut + 1
            while cs[start] == " " or cs[start] == "\t" do start = start + 1 end
        else
            lines[#lines + 1] = table.concat(cs, "", start, stop)
            start = stop + 1
        end
    end
    -- 每行去掉首尾空白：既清掉断点残留空格，也避免阿语(RTL)双向排版把空格挪到行首
    local cleaned = {}
    for _, line in ipairs(lines) do
        local s2 = (line:gsub("^%s+", ""):gsub("%s+$", ""))
        if s2 ~= "" then cleaned[#cleaned + 1] = s2 end
    end
    return table.concat(cleaned, "\n")
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

-- 按 cfg.PageContents[n] 设置某页所有项的图片资源与文本。
-- 文本改为「当前语言」：TetrisConfig.HelpTexts[页][项][lang]（doc/技能.xls 三语文案）；
-- 缺项（如页3 左移/右移暂无译文）则回退 it.text，仍为 nil 就跳过（保持编辑器预设文本）。
function TetrisDetailHelp:_applyItems(ps, n)
    local cfg = cfgOf()
    local items = (cfg.PageContents and cfg.PageContents[n]) or {}
    local langUI = self.match and self.match.langUI
    local lang = (langUI and type(langUI.LangIndexOf) == "function" and langUI:LangIndexOf(ps)) or 2
    local pageTexts = TetrisConfig.HelpTexts and TetrisConfig.HelpTexts[n]
    local limit = wrapLimitFor(lang)
    local fontSize = fontSizeFor(lang)
    print(string.format("[Tetris][Help][Wrap] 页=%d lang=%d 每行上限X=%s 字号=%s",
        n, lang, tostring(limit or "关闭"), tostring(fontSize or "默认")))
    for i, it in ipairs(items) do
        if it and it.img and it.res then
            local ref = (type(AssetRef) == "table" and AssetRef[it.res]) or it.res
            pcall(function() CustomUIAPI.SetImageWidgetContent(ps, it.img, ref) end)
        end
        if it and it.txt then
            -- 先设字号再写文本：字号变化会影响 UMG 布局，顺序反了可能用旧字号排版
            if fontSize then
                pcall(function() CustomUIAPI.SetTextWidgetFontSize(ps, it.txt, fontSize) end)
            end
            local t = pageTexts and pageTexts[i] and pageTexts[i][lang]
            t = t or it.text
            if t then
                local shown = wrapText(t, limit)
                pcall(function() CustomUIAPI.SetTextContent(ps, it.txt, shown) end)
                local wcfg = TetrisConfig.HelpWrap
                if wcfg and wcfg.DebugWrap and shown ~= t then
                    local function vis(x)
                        return (x:gsub(" ", "·"):gsub("\n", "⏎\n"))
                    end
                    print(string.format("[Tetris][Help][Wrap][DBG] 页=%d 项=%d\n  前=%s\n  后=%s",
                        n, i, vis(t), vis(shown)))
                end
            end
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
