-- ClientUI：只按 UIState 写控件、驱动界面流程，不读 Board/Game 玩法对象。
--
-- 根治上次三大 UI bug 的三条纪律：
--   1. 一个控件一个写入点：所有 CustomUIAPI 写操作集中在本文件，其他模块只调这里的方法。
--   2. 幂等显隐：HideInitUI / HideSkillHintUI 用标志保证只执行一次，杜绝"隐藏后又弹出"。
--   3. 防点击穿透：显示下一面板前延迟 CLICK_GUARD 秒（引擎同次点击会穿透到新显示的按钮）。
--
-- 权威 API：Core/LuaHint/CustomUIAPI.lua（全部 @realm Both；客户端首参 nil=本地玩家，这里传真实 ps）。
-- 控件 InstanceID 来自 Config.*（编辑器预放置）；RankAPI 是 ServerOnly，排行榜经 deps.requestLeaderboard 走 P6 RPC。
local Config = require("EnvLua.Common.Tetris.TetrisConfig")
local TextWrap = require("EnvLua.Common.Tetris.TetrisTextWrap")

local ClientUI = {}
ClientUI.__index = ClientUI

local CLICK_GUARD = 0.1  -- 防点击穿透延迟（秒）

local function ref(key)
    if type(key) ~= "string" or type(AssetRef) ~= "table" then return nil end
    return AssetRef[key]
end

-- 【关键】CustomUIAPI 所有写控件接口的 InstanceUUID 注解=字符串；而 Config.* 存的是
-- CreativeInstance[key] 的数字 InstanceID（只有 AddVPEvent 第 4 参 @listen 要求数字）。
-- 历史代码把数字直接传给写接口，部分控件会静默失败（排行榜文本/语言标志只显示一部分）。
-- 统一走 writeWidget：数字 + 反查 UUID 两种形式都写一遍，任一被引擎接受即生效。
local uuidCache = {}
local function reverseUuid(id)
    if type(id) ~= "number" then return nil end
    if uuidCache[id] ~= nil then return uuidCache[id] or nil end
    local found = nil
    if type(CreativeInstance) == "table" then
        for k, v in pairs(CreativeInstance) do
            if v == id then found = k break end
        end
    end
    uuidCache[id] = found or false   -- false = 查过但没有，避免重复遍历
    return found
end

local function writeWidget(id, fn)
    if not id then return end
    pcall(function() fn(id) end)
    local uuid = reverseUuid(id)
    if uuid and uuid ~= id then
        pcall(function() fn(uuid) end)
    end
end

local function enableInteract(ps, id)
    writeWidget(id, function(target)
        CustomUIAPI.SetWidgetInteraction(ps, target, true)
    end)
end

-- 【诊断】中央临时提示控件的显隐追踪：登记后 Show/HideForce/ShowForce 每次写都打印。
-- 引擎没有 GetWidgetVisible 查询 API，只能靠写入日志判断"没隐藏"还是"隐藏后又被显示"。
local TRACE_IDS = {}   -- id -> 名称，由 _traceId() 填充
local function traceName(id)
    return TRACE_IDS[id] or nil
end
local function traceWrite(self, id, what, visible)
    local name = traceName(id)
    if not name then return end
    print(string.format("[ClientUI][TRACE] %s id=%s(%s) visible=%s frame=%d",
        what, tostring(id), name, tostring(visible), self._traceFrame or -1))
end

---@param host table 提供 AddTimerOnce(delay, fn) 的宿主
---@param ps WoWPlayerStateBase|nil 真实玩家（客户端写控件首参）
---@param deps table|nil { requestLeaderboard=function(), onSubmitResult=function(win) end }
function ClientUI:new(host, ps, deps)
    deps = deps or {}
    local o = setmetatable({}, self)
    o.host = host
    o.ps = ps
    o.deps = deps
    o.lang = 2  -- 默认英文（清单 §8）
    o.screen = "none"
    o.helpPage = 1
    o.selectedSkills = {}

    o._initHidden = false
    o._hintHidden = false
    o._visible = {}       -- 控件显隐权威缓存：id -> bool（避免重复写）
    o._languageSelfKeys = {}  -- ps/key 双写（清单 §11 坑 9）
    -- [表现层] 对战 HUD 瞬时提示同步状态
    o._hintShown = {}         -- hint name -> true（当前已显示，供 diff 避免每帧写）
    o._lastComboSeq = 0       -- 上次处理的消行序号（边沿检测）
    o._comboHideTimer = nil   -- Combo 图隐藏定时器（连消刷新窗口）
    o._lastEnergyPct = nil    -- 能量条上次写入值（避免每帧写进度条）
    o._lastReady = nil        -- 技能就绪图上次状态
    -- 【诊断】登记准备界面控件，追踪每次显隐写入（确认"开始显示→后来隐藏"由哪处触发）
    local H = Config.HelpUI or {}
    if H.Panel then TRACE_IDS[H.Panel] = "HelpUI.Panel" end
    if H.BtnClose then TRACE_IDS[H.BtnClose] = "HelpUI.BtnClose" end
    return o
end

-- ===== 控件写入单一出口（所有显隐必须经过这里） =====
function ClientUI:Show(id, visible)
    if not id then return end
    visible = visible and true or false
    if self._visible[id] == visible then
        if traceName(id) then print("[ClientUI][TRACE] Show SKIP(幂等同值) id=" .. tostring(id) ..
            "(" .. traceName(id) .. ") visible=" .. tostring(visible)) end
        return
    end
    self._visible[id] = visible
    traceWrite(self, id, "Show", visible)
    writeWidget(id, function(target)
        CustomUIAPI.SetWidgetVisible(self.ps, target, visible)
    end)
end

-- 强制隐藏（绕过 _visible 幂等缓存）：父面板显示会异步带出子控件，
-- 即便缓存里已是 false 也必须重新下发，否则子控件残留可见（WaitHint/候选按钮等就栽在这）。
function ClientUI:HideForce(id)
    if not id then return end
    self._visible[id] = false
    traceWrite(self, id, "HideForce", false)
    writeWidget(id, function(target)
        CustomUIAPI.SetWidgetVisible(self.ps, target, false)
        pcall(function() CustomUIAPI.SetWidgetImageOpacity(self.ps, target, 0.0) end)
    end)
end

-- 强制显示（绕过 _visible 幂等缓存）：父面板显示会异步带出子控件，
-- 显示父面板后延迟补写子控件时必须用本方法，否则 Show 因缓存命中而跳过。
-- 同时恢复 opacity（HideForce 会把透明度压 0），避免控件可见却全透明（补6 同类坑）。
function ClientUI:ShowForce(id)
    if not id then return end
    self._visible[id] = true
    traceWrite(self, id, "ShowForce", true)
    writeWidget(id, function(target)
        CustomUIAPI.SetWidgetVisible(self.ps, target, true)
        pcall(function() CustomUIAPI.SetWidgetImageOpacity(self.ps, target, 1.0) end)
    end)
end

function ClientUI:Text(id, text)
    if not id or text == nil then return end
    writeWidget(id, function(target)
        CustomUIAPI.SetTextContent(self.ps, target, tostring(text))
    end)
end

function ClientUI:Image(id, key)
    if not id then return end
    local r = ref(key)
    if not r then return end
    writeWidget(id, function(target)
        CustomUIAPI.SetImageWidgetContent(self.ps, target, r)
    end)
end

-- 按钮换图专用：按钮控件必须用 SetButtonNormalImage / SetButtonPressedImage；
-- SetImageWidgetContent 是图片控件专用，对按钮静默失败（多语言切换按钮图不换的根因）。
-- key 为资源 key 字符串（如 "23_ImagePreset_xxx"），内部转 AssetRef 句柄。
function ClientUI:ButtonImage(id, key, pressed)
    if not id or not key then return end
    local r = ref(key)
    if not r then return end
    writeWidget(id, function(target)
        if pressed then
            CustomUIAPI.SetButtonPressedImage(self.ps, target, r)
        else
            CustomUIAPI.SetButtonNormalImage(self.ps, target, r)
        end
    end)
end

function ClientUI:Opacity(id, v)
    if not id then return end
    writeWidget(id, function(target)
        CustomUIAPI.SetWidgetImageOpacity(self.ps, target, v)
    end)
end

-- 控件整体透明度（SetWidgetOpacity，区别于 SetWidgetImageOpacity 只作用于图片内容）。
-- Button 这类复合控件（底色图 + 文本）必须用本接口：编辑器把按钮默认透明度设为 0 后，
-- panel 显示带出按钮时它仍透明不闪；代码要显示按钮时用本方法把整体透明度改为 1。
function ClientUI:WidgetOpacity(id, v)
    if not id then return end
    print("[ClientUI][TRACE] WidgetOpacity id=" .. tostring(id) ..
        "(" .. tostring(traceName(id)) .. ") v=" .. tostring(v))
    writeWidget(id, function(target)
        CustomUIAPI.SetWidgetOpacity(self.ps, target, v)
    end)
end

function ClientUI:FontSize(id, size)
    if not id then return end
    writeWidget(id, function(target)
        CustomUIAPI.SetTextWidgetFontSize(self.ps, target, size)
    end)
end

-- 延迟切换到下一界面（防点击穿透）
function ClientUI:_goto(screen, fn)
    self.screen = screen
    self.host:AddTimerOnce(CLICK_GUARD, fn)
end

-- ===== 初始化显隐（幂等，杜绝重复弹出） =====
function ClientUI:HideInitUI()
    if self._initHidden then return end
    self._initHidden = true
    local C = Config
    -- 隐藏选择/Hold/Next/HUD 等（用配置里已登记的控件；nil 自动跳过）
    self:Show(C.SkillSelect and C.SkillSelect.PanelKey, false)
    self:Show(C.SkillSelect and C.SkillSelect.WaitHint, false)
    self:Show(C.UI and C.UI.HoldImg, false)
    self:Show(C.UI and C.UI.NextImg, false)
    -- Loading 遮罩/进度条编辑器可能预置常驻可见，开局强制隐藏（遮罩是图片，HideForce 连透明度一起压 0）
    self:HideForce(C.LoadingScreen)
    self:HideForce(C.LoadingProgress)
    -- 对局 HUD（头像/操作区）与游戏内声音入口：开局强制隐藏，选完技能显示 Loading 时再点亮
    self:_setHudVisible(false)
    -- 敌方分数初始化为 0（编辑器预置残留分数，如截图里的 1960），双方 HUD 文本一并归零
    self:Text(C.UI and C.UI.OpponentScoreLabel, 0)
    self:Text(C.UI and C.UI.ScoreLabel, 0)
    self:Text(C.UI and C.UI.LinesLabel, 0)
    self:Text(C.UI and C.UI.LevelLabel, 0)
    -- 注意：临时提示图不在开局隐藏——它们属于 GamePanel 的子控件，必须在 GamePanel 显示之后
    -- 再隐藏，否则 GamePanel Show(true) 时会把它们一起带出来。时机见 ShowLoading()。
end

-- 事件型临时提示图隐藏（道具消除图 / 技能特效图 / 垃圾行提示 / 落石图等）。
-- 必须在 GamePanel 显示之后调用：这些是 GamePanel 子控件，先藏后显示父容器会被引擎带出。
-- 这些都是"触发时才短暂显示"的控件，与 HideSkillHintUI 的技能锁/冷却指示器分开列，避免遗漏。
function ClientUI:_hideTransientHints()
    local U = Config.UI or {}
    -- 具名登记：{id, 名称}，名称写进 TRACE_IDS 供追踪打印用
    local named = {
        { U.ChargeItemImg, "ChargeItemImg" }, { U.BlastImg, "BlastImg" },
        { U.ShiftImg1, "ShiftImg1" }, { U.ShiftImg2, "ShiftImg2" }, { U.StoneImg, "StoneImg" },
        { U.GarbageSendHint, "GarbageSendHint" }, { U.GarbageRecvHint, "GarbageRecvHint" },
        { U.ComboImg, "UI.ComboImg(连击提示图)" },
        { Config.Skill and Config.Skill.ReadyImg, "Skill.ReadyImg(技能就绪图)" },
        { Config.HintText, "HintText(通用飘字)" },
        { Config.Skill and Config.Skill.BigTipInstance, "Skill.BigTipInstance(技能中央大图)" },
        { Config.Skills and Config.Skills.SK06 and Config.Skills.SK06.attackBuffImg, "SK06.attackBuffImg" },
        { Config.Skills and Config.Skills.SK01 and Config.Skills.SK01.rotLockCasterImg, "SK01.rotLockCasterImg" },
        { Config.Skills and Config.Skills.SK01 and Config.Skills.SK01.rotLockVictimImg, "SK01.rotLockVictimImg" },
        { Config.Skills and Config.Skills.SK07 and Config.Skills.SK07.cdIndicator, "SK07.cdIndicator" },
    }
    -- GarbageHint 多语言 12 组件（底图 base + 数字 num，zh/en/ar × Send/Recv）
    local G = Config.GarbageHint or {}
    for li, lang in pairs(G.Components or {}) do
        if type(lang) == "table" then
            for kind, pair in pairs(lang) do
                if type(pair) == "table" then
                    named[#named + 1] = { pair.base, "GarbageHint[" .. tostring(li) .. "]." .. tostring(kind) .. ".base" }
                    named[#named + 1] = { pair.num,  "GarbageHint[" .. tostring(li) .. "]." .. tostring(kind) .. ".num" }
                end
            end
        end
    end
    local hidden, skipped = 0, 0
    for _, e in ipairs(named) do
        local id, name = e[1], e[2]
        if id == nil then
            skipped = skipped + 1
            print("[ClientUI][TRACE] 初始化隐藏 SKIP（id=nil） " .. tostring(name))
        else
            TRACE_IDS[id] = name      -- 登记追踪：之后每次 Show/HideForce 都会打印
            self:HideForce(id)
            hidden = hidden + 1
        end
    end
    self._traceFrame = (self._traceFrame or 0) + 1
    print("[ClientUI][TRACE] === 初始隐藏完成 隐藏=" .. tostring(hidden) .. " 跳过(nil)=" .. tostring(skipped) ..
        " ===")
    -- 延迟复查：打一条标记，看这之后有没有 [TRACE] Show/HideForce 把这些控件重新显示
    self.host:AddTimerOnce(1.5, function()
        print("[ClientUI][TRACE] === 1.5s 复查点：若上面出现过 [TRACE] Show ...visible=true，说明被重新显示；否则是初始没隐藏成功 ===")
    end)
end

-- 对局 HUD 显示/隐藏（对齐历史 TetrisMatch:ShowLoading / HideStartScreen）。
-- ShowHudAfterSkill 存的是 UUID 字符串 key，需经 CreativeInstance[key] 取数字 ID 后 writeWidget 双写。
-- HUD 多为图片控件，显示时成对恢复 opacity=1.0（HideForce/编辑器默认透明会压下），隐藏用 HideForce。
function ClientUI:_setHudVisible(visible)
    local list = Config.ShowHudAfterSkill or {}
    local S = Config.SoundSettings or {}
    local ids = {}
    for _, key in ipairs(list) do
        if type(CreativeInstance) == "table" then
            local id = CreativeInstance[key]
            if id ~= nil then
                ids[#ids + 1] = id
                TRACE_IDS[id] = "GamePanel(对局HUD容器 " .. tostring(key) .. ")"  -- 登记追踪显示时机
            end
        end
    end
    if S.GameOpenBtn then ids[#ids + 1] = S.GameOpenBtn end
    -- 无条件打 GamePanel 当前缓存值，判断 Show 会不会被幂等跳过
    local gp = ids[1]
    if gp ~= nil then
        print("[ClientUI][TRACE] GamePanel时机: want=" .. tostring(visible) ..
            " cached=" .. tostring(self._visible[gp]) ..
            " id=" .. tostring(gp) .. " screen=" .. tostring(self.screen))
    end
    for _, id in ipairs(ids) do
        if visible then
            self:Show(id, true)
            self:Opacity(id, 1.0)
        else
            self:HideForce(id)
        end
    end
end

function ClientUI:HideSkillHintUI()
    if self._hintHidden then return end
    self._hintHidden = true
    local cds = {
        Config.Skills and Config.Skills.SK01 and Config.Skills.SK01.rotLockCasterImg,
        Config.Skills and Config.Skills.SK01 and Config.Skills.SK01.rotLockVictimImg,
        Config.Skills and Config.Skills.SK06 and Config.Skills.SK06.attackBuffImg,
        Config.Skills and Config.Skills.SK07 and Config.Skills.SK07.cdIndicator,
    }
    for _, id in ipairs(cds) do self:Show(id, false) end
end

-- ===== 开局统一初始化（旧架构由服务端 TetrisMatch:Start() 做，客户端化后搬到这里） =====
-- 一次补齐：多语言标志、排行榜文本、声音面板按钮/交互/文本、技能选择面板/槽位。
-- 全部经 Show()/Text() 幂等写入，重复调用无副作用。
function ClientUI:InitializeAll()
    self:HideInitUI()
    self:HideSkillHintUI()
    self:SetLang(self.lang)        -- 按默认语言刷 Contents + 记录语言
    self:_hideLangIndicators()     -- 面板未打开：3 个标志全隐藏（打开时才高亮当前语言）
    self:FillLeaderboard(nil)      -- 排行榜 10 行文本清空
    self:CloseLeaderboard()        -- 排行榜面板初始隐藏
    self:_initSoundPanel()
    self:_initSkillSelect()
    -- 开局控件仍在异步就绪，延迟补写一次标志隐藏（用户若已打开语言面板则跳过）
    self.host:AddTimerOnce(0.3, function()
        if self.screen ~= "lang" then self:_hideLangIndicators() end
        -- 编辑器预置的多语言图全是中文，开局这次 SetLang 写入时控件可能尚未就绪而丢失；
        -- 0.3s 后按当前语言重刷一次 Contents，保证常驻控件也切到默认语言。
        self:_applyLangContents()
    end)
end

-- 语言标志专用写入：可见性 + 透明度双管齐下（部分图片控件 SetWidgetVisible 不生效，
-- 历史 TetrisLang 注释也写明标志靠透明度高亮）。绕过 _visible 缓存，每次强制下发。
function ClientUI:_setLangIndicator(id, visible)
    if not id then
        print("[ClientUI][LangInd] id=nil 跳过")
        return
    end
    local uuid = reverseUuid(id)
    print(string.format("[ClientUI][LangInd] id=%s uuid=%s visible=%s",
        tostring(id), tostring(uuid), tostring(visible)))
    self._visible[id] = visible
    writeWidget(id, function(target)
        CustomUIAPI.SetWidgetVisible(self.ps, target, visible)
        pcall(function()
            CustomUIAPI.SetWidgetImageOpacity(self.ps, target, visible and 1.0 or 0.0)
        end)
    end)
end

function ClientUI:_hideLangIndicators()
    local L = Config.LangUI or {}
    for i = 1, 3 do
        self:_setLangIndicator(L.LangIndicators and L.LangIndicators[i], false)
    end
end

-- 声音面板内部控件（平级控件，父面板显隐不会带出它们；OpenBtn 是入口，不在其列）
function ClientUI:_soundPanelIDs()
    local S = Config.SoundSettings or {}
    return { S.PanelKey, S.BtnClose, S.BtnBgmDown, S.BtnBgmUp,
             S.BtnSfxDown, S.BtnSfxUp, S.BgmText, S.SfxText }
end

function ClientUI:_initSoundPanel()
    local S = Config.SoundSettings or {}
    -- 面板内控件：开交互 + 初始隐藏（编辑器默认可见会残留）
    for _, id in ipairs(self:_soundPanelIDs()) do
        if id then
            enableInteract(self.ps, id)
            self:Show(id, false)
        end
    end
    -- 入口按钮只开交互，不隐藏（显隐由开始界面控制）
    if S.OpenBtn then enableInteract(self.ps, S.OpenBtn) end
    if S.GameOpenBtn then enableInteract(self.ps, S.GameOpenBtn) end
    self:RefreshSoundText()
end

-- 音量百分比文本（音量值由 deps.getVolumes 提供，ClientUI 不直接依赖 AudioManager）
function ClientUI:RefreshSoundText()
    local S = Config.SoundSettings or {}
    local v = (self.deps.getVolumes and self.deps.getVolumes()) or {}
    if S.BgmText then self:Text(S.BgmText, tostring(math.floor((v.bgm or 0) * 100)) .. "%") end
    if S.SfxText then self:Text(S.SfxText, tostring(math.floor((v.sfx or 0) * 100)) .. "%") end
end

-- 技能选择控件全集（与历史 TetrisSkillSelect:WidgetIDs() 一致；均为平级控件）
function ClientUI:_skillSelectIDs()
    local S = Config.SkillSelect or {}
    local ids = {
        S.StartPanel, S.StartBtn, S.PanelKey,
        S.BtnSK01, S.BtnSK02, S.BtnSK06, S.BtnSK07, S.BtnSK08,
        S.IconSK01, S.IconSK02, S.IconSK06, S.IconSK07, S.IconSK08,
    }
    for _, t in ipairs({ S.SlotButtons, S.SlotIcons, S.SlotDescs, S.HiddenFrames }) do
        if t then for _, id in ipairs(t) do ids[#ids + 1] = id end end
    end
    return ids
end

-- 技能选择面板：开局先全部隐藏，进入时 ShowSkillSelect 再显示并填内容
function ClientUI:_initSkillSelect()
    for _, id in ipairs(self:_skillSelectIDs()) do self:Show(id, false) end
    self:Show(Config.SkillSelect and Config.SkillSelect.WaitHint, false)
end

-- ===== 开始界面（关闭 HelpUI 准备界面后进入；HelpUI 由编辑器默认显示，此处只负责隐藏） =====
function ClientUI:ShowStart()
    local H = Config.HelpUI or {}
    print("[DIAG][HelpUI] ShowStart 调用 screen=" .. tostring(self.screen) ..
        " Panel=" .. tostring(H.Panel) .. " BtnClose=" .. tostring(H.BtnClose))
    -- 关闭准备界面：面板用 HideForce+图片透明度；按钮 ONLY 用控件整体透明度（不碰 visible，便于验证透明度是否生效）。
    self:HideForce(H.Panel)
    self:Opacity(H.Panel, 0.0)
    self:WidgetOpacity(H.BtnClose, 0.0)
    self:_goto("start", function()
        local S = Config.SkillSelect or {}
        self:Show(S.StartPanel, true)   -- 开始界面稳定显示
        self:Show(S.StartBtn, true)
        self:_showStartEntrances(true)  -- 帮助/声音/语言/排行榜入口随开始界面一起显示
        -- 父面板显示会异步带出子控件、覆盖刚下发的显隐；延迟强制补写一次，避免"显示不全"。
        self.host:AddTimerOnce(0.25, function()
            if self.screen ~= "start" then return end
            self:ShowForce(S.StartPanel)
            self:ShowForce(S.StartBtn)
            self:_showStartEntrancesForce()
            self:_applyLangContents()   -- 面板带出的多语言按钮/图恢复编辑器中文，按当前语言重刷
            -- 引擎异步带出子控件时可能把 opacity 恢复，再压一次准备界面透明度防重复出现。
            self:Opacity(H.Panel, 0.0)
            self:WidgetOpacity(H.BtnClose, 0.0)
        end)
    end)
end

-- 开始界面上的各入口按钮（历史由 TetrisSkillSelect:ShowStartScreenFor 显示）
function ClientUI:_showStartEntrances(visible)
    local SD = Config.SoundSettings or {}
    local L = Config.LangUI or {}
    local LB = Config.Leaderboard or {}
    local D = Config.DetailHelp or {}
    self:Show(D.OpenBtn, visible)
    self:Show(SD.OpenBtn, visible)
    self:Show(L.OpenBtn, visible)
    self:Show(LB.OpenBtn, visible)
end

-- 入口按钮强制显示（父面板带出子控件后的补写专用，绕过 _visible 缓存并恢复 opacity）
function ClientUI:_showStartEntrancesForce()
    local SD = Config.SoundSettings or {}
    local L = Config.LangUI or {}
    local LB = Config.Leaderboard or {}
    local D = Config.DetailHelp or {}
    self:ShowForce(D.OpenBtn)
    self:ShowForce(SD.OpenBtn)
    self:ShowForce(L.OpenBtn)
    self:ShowForce(LB.OpenBtn)
end

-- 玩家点击 HelpUI 准备界面的关闭按钮：隐藏准备界面并进入开始界面（每局首次只走一次）
function ClientUI:OnPrepareClosed()
    self:ShowStart()
end

-- ===== 开始界面入口 =====
function ClientUI:OnStartClicked()
    local S = Config.SkillSelect or {}
    self:Show(S.StartPanel, false)   -- 点击开始 → 隐藏开始界面
    self:Show(S.StartBtn, false)
    self:_showStartEntrances(false)
    -- 单人先进 AI 难度，多人直接技能选择；这里由上层调用方决定下一步。
end

-- ===== AI 难度选择 =====
function ClientUI:ShowAIDifficulty()
    local A = Config.AI or {}
    self:_goto("difficulty", function()
        self:Show(A.PanelKey, true)
        self:Show(A.BtnEasy, true)
        self:Show(A.BtnNormal, true)
        self:Show(A.BtnHard, true)
        -- AI 难度按钮（Contents 第22~24项）是多语言按钮，父面板带出后按当前语言重刷
        self.host:AddTimerOnce(0.25, function()
            if self.screen == "difficulty" then self:_applyLangContents() end
        end)
    end)
end

function ClientUI:OnDifficultyChosen()
    local A = Config.AI or {}
    self:Show(A.PanelKey, false)
    self:Show(A.BtnEasy, false)
    self:Show(A.BtnNormal, false)
    self:Show(A.BtnHard, false)
    self:ShowSkillSelect()
end

-- ===== 技能选择（从 Pool 抽 2，WaitHint 父面板显示后再藏一次） =====
-- 显示技能面板时的初始化（对齐历史 TetrisSkillSelect:ShowPanelFor(ps,true)）：
-- 父容器显示会异步带出所有子控件，故候选技能按钮/未入选框/等待提示都必须在显示后再强制藏一次。
function ClientUI:_initSkillPanelShown()
    local S = Config.SkillSelect or {}
    -- 隐藏项全部用 HideForce：开局 _initSkillSelect 已把 _visible 置 false，
    -- 普通 Show(false) 会被幂等缓存跳过而不下发，父面板带出后就藏不掉了。
    for _, key in ipairs(S.Pool or {}) do
        self:HideForce(S["Btn" .. key])
        self:HideForce(S["Icon" .. key])
    end
    for _, id in ipairs(S.HiddenFrames or {}) do self:HideForce(id) end
    self:HideForce(S.WaitHint)
    -- 槽位按钮/图标复用了 BtnSK02/BtnSK07、IconSK02/IconSK07：上面 HideForce 把它们 opacity 置 0，
    -- 这里只 Show(true) 不会恢复透明度，必须显式 Opacity(1.0) 补回，否则控件可见却完全透明。
    for _, id in ipairs(S.SlotButtons or {}) do
        self:Show(id, true)
        self:Opacity(id, 1.0)
        enableInteract(self.ps, id)   -- 槽位按钮恢复交互，否则点击无响应
    end
    for _, id in ipairs(S.SlotIcons or {}) do
        self:Show(id, true)
        self:Opacity(id, 1.0)
    end
    for _, id in ipairs(S.SlotDescs or {}) do self:Show(id, true) end
end

-- 槽位图标 + 描述（对齐历史 ApplySlotContent）：图标用 iconKey（imageKey 是中央大图提示，别用错）；
-- 描述先字号后文本，按 SkillSelectWrap 折行补齐；候选集取整个 Pool 保证折行上限不随随机结果跳变。
function ClientUI:_applySkillSlots()
    local S = Config.SkillSelect or {}
    local wcfg = Config.SkillSelectWrap or Config.HelpWrap or {}
    local candidates = {}
    for _, key in ipairs(S.Pool or {}) do
        local d = self:_skillDesc(key)
        if d then candidates[#candidates + 1] = d end
    end
    local limit = TextWrap.Limit(TextWrap.MaxChars(candidates), self.lang, wcfg)
    local fontSize = TextWrap.FontSizeFor(self.lang, wcfg)
    for i, key in ipairs(self.selectedSkills or {}) do
        local def = Config.Skills and Config.Skills[key]
        local iconId = S.SlotIcons and S.SlotIcons[i]
        local descId = S.SlotDescs and S.SlotDescs[i]
        if iconId and def and def.iconKey then self:Image(iconId, def.iconKey) end
        if descId then
            local txt = self:_skillDesc(key)
            if fontSize then self:FontSize(descId, fontSize) end  -- 先字号
            if txt then
                local shown = (limit and TextWrap.WrapText) and TextWrap.WrapText(txt, limit, wcfg) or txt
                self:Text(descId, shown)                            -- 后文本
            end
        end
    end
end

function ClientUI:ShowSkillSelect()
    local S = Config.SkillSelect or {}
    local pool = {}
    for _, k in ipairs(S.Pool or {}) do pool[#pool + 1] = k end
    -- 洗牌取前 2
    for i = #pool, 2, -1 do
        local j = math.random(1, i)
        pool[i], pool[j] = pool[j], pool[i]
    end
    self.selectedSkills = { pool[1] or S.DefaultSkill, pool[2] or "SK02" }
    self:_goto("skillSelect", function()
        self:Show(S.PanelKey, true)
        self:_initSkillPanelShown()
        self:_applySkillSlots()
        -- 父面板异步带出子控件：延迟补写一次（与多语言标志同一手法）
        self.host:AddTimerOnce(0.25, function()
            if self.screen ~= "skillSelect" then return end
            self:_initSkillPanelShown()
            self:_applySkillSlots()
            self:_applyLangContents()   -- 技能面板带出的多语言按钮图按当前语言重刷
        end)
    end)
end

function ClientUI:_skillDesc(key)
    local t = Config.SkillSelectTexts and Config.SkillSelectTexts[key]
    if self.lang == 1 then
        return (Config.Skills and Config.Skills[key] and Config.Skills[key].selectDesc) or key
    end
    if t then return t[self.lang] or key end
    return key
end

function ClientUI:OnSkillChosen(slotIndex)
    local S = Config.SkillSelect or {}
    local key = self.selectedSkills[slotIndex]
    if not key then return nil end
    -- [P7 双方就绪] 选完技能只隐藏 2 个槽位（表示已选），【保留技能面板 PanelKey】——
    -- WaitHint 是技能面板的子控件，"等待对方选择技能"提示需面板在场才可见；
    -- 待双方就绪（OnAllReady）时再统一隐藏 WaitHint + PanelKey 进入 loading。
    for _, id in ipairs(S.SlotButtons or {}) do self:Show(id, false) end
    for _, id in ipairs(S.SlotIcons or {}) do self:Show(id, false) end
    for _, id in ipairs(S.SlotDescs or {}) do self:Show(id, false) end
    -- 显示等待提示：ShowForce 绕过 _visible 幂等缓存并恢复 opacity（开局 HideForce 曾压 0）。
    -- 父面板异步带出子控件可能覆盖，延迟补写一次（仍在技能选择界面时）。
    self:ShowForce(S.WaitHint)
    -- 延迟需晚于 ShowSkillSelect 的 0.25s 面板补写（内含 HideForce(WaitHint)），
    -- 否则快速点击时补写会覆盖刚显示的等待提示；0.4s 保证本补写在最后。
    self.host:AddTimerOnce(0.4, function()
        if self.screen == "skillSelect" then self:ShowForce(S.WaitHint) end
    end)
    self._waitingHintShown = true
    print("[P7][Ready][ClientUI] 已选技能 → 显示 WaitHint=" .. tostring(S.WaitHint) ..
        " 等待对方就绪")
    return key
end

-- [P7 双方就绪] 全员就绪：隐藏"等待对方"提示与技能选择面板（对齐旧 TetrisMatch：loading 时统一隐藏选择界面）。
function ClientUI:OnAllReady()
    local S = Config.SkillSelect or {}
    self:HideForce(S.WaitHint)
    self:HideForce(S.PanelKey)
    self._waitingHintShown = false
    print("[P7][Ready][ClientUI] 全员就绪 → 已隐藏 WaitHint + PanelKey（双方就绪隐藏清单应用完成）")
end

-- ===== Loading（对齐历史 TetrisMatch:ShowLoading）=====
-- 选完技能显示遮罩 + 进度条，LoadingTime 秒内 0→100；进入对局时 HideLoading。
function ClientUI:ShowLoading()
    local id = Config.LoadingScreen
    local pid = Config.LoadingProgress
    self.screen = "loading"
    local function apply(visible)
        if id then self:Show(id, visible) end
        if pid then self:Show(pid, visible) end
        -- HideForce 开局把遮罩/进度条 opacity 压 0，显示时必须成对恢复，否则可见但全透明（补6 同类坑）
        if visible then
            if id then self:Opacity(id, 1.0) end
            if pid then self:Opacity(pid, 1.0) end
        end
    end
    self.host:AddTimerOnce(CLICK_GUARD, function()
        apply(true)
        self:_setHudVisible(true)   -- ① 先显示 GamePanel（对局 HUD 父容器）
        -- ② 再隐藏临时提示图：它们是 GamePanel 子控件，父容器显示会带出，必须在显示之后藏
        self:_hideTransientHints()
        -- ③ GamePanel 带出的多语言图会被引擎恢复成编辑器预置的中文，必须按当前语言重刷一次
        self:_applyLangContents()
        print("[P7][Ready][ClientUI] Loading 显隐清单已应用：显示 LoadingScreen/进度条/对局HUD；隐藏 技能面板/WaitHint/临时提示图")
        -- ④ 父容器异步带出子控件，延迟补写一次确保干净（隐藏 + 语言图重刷都要补）
        self.host:AddTimerOnce(0.3, function()
            if self._loadingVisible then
                self:_hideTransientHints()
                self:_applyLangContents()
            end
        end)
        self:_setLoadingProgress(0)
        self._loadingVisible = true
        self._progressGen = (self._progressGen or 0) + 1
        local myGen = self._progressGen
        local duration = Config.LoadingTime or 3
        local step, elapsed = 0.5, 0
        local function tick()
            if self._progressGen ~= myGen or not self._loadingVisible then return end
            elapsed = elapsed + step
            self:_setLoadingProgress(math.min(100, math.floor(elapsed / duration * 100 + 0.5)))
            if elapsed < duration then self.host:AddTimerOnce(step, tick) end
        end
        self.host:AddTimerOnce(0.5, tick)   -- 先让遮罩渲染出来再启动填充
    end)
end

function ClientUI:HideLoading()
    self._loadingVisible = false
    self._progressGen = (self._progressGen or 0) + 1   -- 令牌杀死进行中的进度动画
    local id = Config.LoadingScreen
    local pid = Config.LoadingProgress
    if id then self:Show(id, false) end
    if pid then
        self:Show(pid, false)
        self:_setLoadingProgress(0)
    end
end

function ClientUI:_setLoadingProgress(value)
    local pid = Config.LoadingProgress
    if not pid then return end
    writeWidget(pid, function(target)
        CustomUIAPI.SetProgressBarWidgetMaxValue(self.ps, target, 100)
        CustomUIAPI.SetProgressBarWidgetMinValue(self.ps, target, 0)
        CustomUIAPI.SetProgressBarWidgetValue(self.ps, target, value)
    end)
end

function ClientUI:EnterBattle()
    self.screen = "battle"
    self:HideLoading()
    self:HideSkillHintUI()
end

-- ===== 帮助界面（3 页，透明度标志，三语折行，先字号后文本） =====
function ClientUI:ShowDetailHelp()
    local D = Config.DetailHelp or {}
    self:_goto("help", function()
        self:Show(D.Panel, true)
        self:SetHelpPage(1)
    end)
end

function ClientUI:CloseDetailHelp()
    local D = Config.DetailHelp or {}
    self:Show(D.Panel, false)
    self.screen = "prepare"
end

function ClientUI:SetHelpPage(page)
    local D = Config.DetailHelp or {}
    page = math.max(1, math.min(3, page or 1))
    self.helpPage = page
    for i = 1, 3 do self:Show(D.Pages and D.Pages[i], i == page) end
    -- 页码标志用透明度（清单 §8）
    for i = 1, 3 do self:Opacity(D.PageIndicators and D.PageIndicators[i], i == page and 1.0 or 0.0) end
    self:_applyHelpText(page)
end

function ClientUI:_applyHelpText(page)
    local D = Config.DetailHelp or {}
    local wrap = Config.HelpWrap or {}
    local contents = D.PageContents and D.PageContents[page] or {}
    local texts = Config.HelpTexts and Config.HelpTexts[page] or {}
    local candidates = {}
    for _, row in ipairs(texts) do if row then candidates[#candidates + 1] = row[self.lang] end end
    local limit = TextWrap.Limit(TextWrap.MaxChars(candidates), self.lang, wrap)
    local fontSize = TextWrap.FontSizeFor(self.lang, wrap)
    for i, item in ipairs(contents) do
        local txt = texts[i] and texts[i][self.lang]
        if not txt and item.text then txt = item.text end
        if txt then
            local id = item.txt
            if fontSize then self:FontSize(id, fontSize) end  -- 先字号
            local out = (limit and TextWrap.WrapLines) and TextWrap.WrapLines(txt, limit) or txt
            self:Text(id, out)                                  -- 后文本
        end
        if item.img then self:Image(item.img, item.res) end
    end
end

-- ===== 多语言界面（标志用可见性；_lang 必须 ps 对象+key 双写） =====
function ClientUI:ShowLangSelect()
    local L = Config.LangUI or {}
    self:_goto("lang", function()
        self:Show(L.Panel, true)
        self:Show(L.BtnClose, true)
        for _, b in ipairs(L.BtnLang or {}) do self:Show(b, true) end
        self:SetLang(self.lang)   -- 只高亮当前语言标志，其余隐藏；并刷 Contents（与历史 OpenFor 一致）
        -- 父面板显示会带出子控件（引擎异步），延迟补写一次标志显隐，否则刚藏掉的又冒出来
        self.host:AddTimerOnce(0.25, function() self:SetLang(self.lang) end)
    end)
end

function ClientUI:CloseLangSelect()
    local L = Config.LangUI or {}
    self:Show(L.Panel, false)
    self:Show(L.BtnClose, false)
    for _, b in ipairs(L.BtnLang or {}) do self:Show(b, false) end
    self:_hideLangIndicators()
end

function ClientUI:SetLang(lang)
    if lang < 1 or lang > 3 then return end
    self.lang = lang
    local L = Config.LangUI or {}
    -- 标志用可见性 + 透明度，强制写入（不经 Show 的幂等缓存）
    for i = 1, 3 do self:_setLangIndicator(L.LangIndicators and L.LangIndicators[i], i == lang) end
    -- ps 对象 + playerKey 双写（上层可读取 self.languageSelfKeys）
    self._languageSelfKeys.lang = lang
    self._languageSelfKeys.psKey = self.ps and self.ps.GetPlayerKey and self.ps:GetPlayerKey() or nil
    -- 静态 Contents 只换内容不碰显隐
    self:_applyLangContents()
    if self.screen == "help" then self:_applyHelpText(self.helpPage) end
end

function ClientUI:_applyLangContents()
    local L = Config.LangUI or {}
    for _, item in ipairs(L.Contents or {}) do
        if item.txt and item.texts then self:Text(item.txt, item.texts[self.lang]) end
        if item.img and item.imgs then self:Image(item.img, item.imgs[self.lang]) end
        if item.btn and item.btnNormal then
            local normalKey = item.btnNormal[self.lang]
            self:ButtonImage(item.btn, normalKey, false)
            -- 按下图缺失时回退到当前语言的常态图（对齐服务端 TetrisLang.ApplyContents），
            -- 否则按下态永远显示编辑器预置图、不随语言切换。
            local pressedKey = (item.btnPressed and item.btnPressed[self.lang]) or normalKey
            self:ButtonImage(item.btn, pressedKey, true)
        end
    end
end

-- ===== 音效面板（BGM/SFX ±0.1，由 deps 提供的回调执行） =====
function ClientUI:AdjustVolume(kind, delta)
    if self.deps.adjustVolume then self.deps.adjustVolume(kind, delta) end
    self:RefreshSoundText()   -- 点击后立刻刷新百分比，给玩家可见反馈
end

function ClientUI:ShowSoundPanel()
    self:_goto("sound", function()
        for _, id in ipairs(self:_soundPanelIDs()) do self:Show(id, true) end
        self:RefreshSoundText()
    end)
end

function ClientUI:HideSoundPanel()
    for _, id in ipairs(self:_soundPanelIDs()) do self:Show(id, false) end
end

-- ===== 排行榜（RankAPI ServerOnly；经 deps.requestLeaderboard 走 P6 RPC） =====
function ClientUI:OpenLeaderboard()
    local L = Config.Leaderboard or {}
    self:FillLeaderboard(nil)   -- 先清空：避免编辑器默认占位文本或上一局残留
    self:Show(L.Panel, true)
    if self.deps.requestLeaderboard then self.deps.requestLeaderboard() end
end

function ClientUI:CloseLeaderboard()
    local L = Config.Leaderboard or {}
    self:Show(L.Panel, false)
end

--- 由服务端 RPC 回传的排行榜数据填充 10 行
function ClientUI:FillLeaderboard(entries)
    local L = Config.Leaderboard or {}
    for i = 1, 10 do
        local e = entries and entries[i]
        self:Text(L.NameText and L.NameText[i], e and e.Name or "")
        self:Text(L.WinText and L.WinText[i], e and tostring(e.Value) or "")
    end
end

-- ===== 对局 HUD：名字 + 头像（服务端分配序号，客户端按序号选图） =====
-- myName/oppName 为显示名；myAvatar/oppAvatar 为 0 基序号，从 AvatarUI.AvatarPresets 取图（取模防越界）。
function ClientUI:SetPlayerInfo(myName, oppName, myAvatar, oppAvatar)
    local N = Config.NameUI or {}
    local A = Config.AvatarUI or {}
    local pool = A.AvatarPresets or {}
    if #pool == 0 then
        print("[ClientUI][WARN] AvatarPresets 为空，跳过头像设置")
        return
    end
    local function avatarKey(idx)
        if type(idx) ~= "number" then return nil end
        local i = (idx % #pool) + 1
        return pool[i]
    end
    -- 名字
    if myName then self:Text(N.SelfName, myName) end
    if oppName then self:Text(N.OppName, oppName) end
    -- 头像：先确保可见并恢复透明度（HideForce 开局压过 0），再写图
    local function setAvatar(id, idx)
        if not id then return end
        local key = avatarKey(idx)
        if not key then return end
        self:Show(id, true)
        self:Opacity(id, 1.0)
        self:Image(id, key)
    end
    setAvatar(A.SelfAvatarIcon, myAvatar)
    setAvatar(A.OppAvatarIcon, oppAvatar)
    print("[ClientUI] 玩家信息已写入: " .. tostring(myName) .. " idx=" .. tostring(myAvatar) ..
        " / " .. tostring(oppName) .. " idx=" .. tostring(oppAvatar))
end

-- ===== 对战 HUD（收 UIState + 对手分数，驱动所有即时表现）=====
function ClientUI:UpdateHUD(state, opponentScore)
    if type(state) ~= "table" then return end
    local U = Config.UI or {}
    self:Text(U.ScoreLabel, state.score)
    self:Text(U.LinesLabel, state.lines)
    self:Text(U.LevelLabel, state.level)
    if opponentScore ~= nil then self:Text(U.OpponentScoreLabel, opponentScore) end

    self:_syncEnergyBar(state)
    self:_syncReadyAndPower(state)
    self:_syncCombo(state)
    self:_syncTransientHints(state.hintImages)
    self:_syncGarbageHints(state)
end

-- 能量条：倒置渲染，写值=(1-bars/need)×100；设置 Min/Max/Value，值变化才写（避免刷屏）。
function ClientUI:_syncEnergyBar(state)
    local S = Config.Skill or {}
    local id = state.energyBar or S.EnergyBar
    if not id then return end
    local need = S.NeedBars or 3
    local progress = (state.skillBars or 0) / need
    if progress > 1 then progress = 1 end
    local inverted = (1 - progress) * 100
    -- Max 设一次；Value 每次都要写（引擎进度条值不缓存），但值相同则跳过减少 RPC
    if self._energyBarId ~= id then
        self._energyBarId = id
        writeWidget(id, function(target)
            CustomUIAPI.SetProgressBarWidgetMinValue(self.ps, target, 0)
            CustomUIAPI.SetProgressBarWidgetMaxValue(self.ps, target, 100)
        end)
        self._lastEnergyPct = nil
    end
    if self._lastEnergyPct ~= inverted then
        self._lastEnergyPct = inverted
        writeWidget(id, function(target)
            CustomUIAPI.SetProgressBarWidgetValue(self.ps, target, inverted)
        end)
    end
end

-- 技能就绪图 + Power 槽：有 power 且目标技能就绪时点亮 ReadyImg；按钮透明度按 power 调。
function ClientUI:_syncReadyAndPower(state)
    local S = Config.Skill or {}
    local power = state.skillPower or 0
    local ready = power > 0
    if self._lastReady ~= ready then
        self._lastReady = ready
        if ready then self:ShowForce(S.ReadyImg) else self:HideForce(S.ReadyImg) end
    end
    -- Power 槽换图：按 power 数把对应槽换成满图/空图
    local slots = S.PowerSlots or {}
    for i, sid in ipairs(slots) do
        local key = (i <= power) and S.PowerFullImg or S.PowerEmptyImg
        if key then self:Image(sid, key) end
    end
end

-- Combo 图：comboSeq 递增（真实消行）时按本次行数换图并显示，ComboImgDuration 秒后隐藏；连消刷新窗口。
function ClientUI:_showComboImage(rows)
    local U = Config.UI or {}
    local id = U.ComboImg
    if not id then return end
    local byRows = U.ComboImgByRows or {}
    local rowKey = byRows[rows] or byRows[5]
    if rowKey then self:Image(id, rowKey) end
    self:ShowForce(id)
    if self._comboHideTimer then
        pcall(function() self.host:RemoveTimer(self._comboHideTimer) end)
        self._comboHideTimer = nil
    end
    local dur = U.ComboImgDuration or 1.7
    self._comboHideTimer = self.host:AddTimerOnce(dur, function()
        self:HideForce(id)
        self._comboHideTimer = nil
    end)
end

function ClientUI:_syncCombo(state)
    local seq = state.comboSeq or 0
    if seq > (self._lastComboSeq or 0) then
        self._lastComboSeq = seq
        self:_showComboImage(state.clearRows or 0)
    end
end

-- 瞬时提示图：按 hintImages 集合 diff 显示/隐藏。显示=ShowForce(恢复 opacity)+换图，隐藏=HideForce。
-- name → {控件 id 列表} 映射，覆盖 ClientGame 所有 _hint(name) 名称。
function ClientUI:_syncTransientHints(hints)
    hints = (type(hints) == "table") and hints or {}
    local U = Config.UI or {}
    local S = Config.Skill or {}
    local skills = Config.Skills or {}
    local SK01 = skills.SK01 or {}
    local SK06 = skills.SK06 or {}
    local SK07 = skills.SK07 or {}
    local SK08 = skills.SK08 or {}
    -- 名称 → 控件列表（有的名称对应两张图，如 Shift/Flip）
    local MAP = {
        BlastImg      = { U.BlastImg },
        ChargeItemImg = { U.ChargeItemImg },
        StoneImg      = { U.StoneImg },
        ShiftImg      = { U.ShiftImg1, U.ShiftImg2 },
        NoRotateImg   = { SK01.rotLockCasterImg, SK01.rotLockVictimImg },
        FlipImg       = { SK08.indicator, SK08.flipVictimImgs[1], SK08.flipVictimImgs[2], SK08.flipVictimImgs[3] },
        S07Indicator  = { SK07.cdIndicator },
        AttackBuffImg = { SK06.attackBuffImg },
    }
    -- 先处理"当前有、上次无"（新触发）：显示
    for name, ids in pairs(MAP) do
        local want = hints[name] == true
        if want and not self._hintShown[name] then
            self._hintShown[name] = true
            for _, id in ipairs(ids) do
                if id then self:ShowForce(id) end
            end
            print("[ClientUI][Hint] 显示 " .. name .. " → " .. tostring(#ids) .. " 控件")
        end
    end
    -- BigTip：单独遍历所有 BigTip_SKxx（任一为真时显示大图并换图）
    local anyBigTip = nil
    for name, _ in pairs(hints) do
        if type(name) == "string" and name:sub(1, 8) == "BigTip_S" then anyBigTip = name break end
    end
    if anyBigTip and not self._hintShown.BigTip then
        self._hintShown.BigTip = true
        self:ShowForce(S.BigTipInstance)
        self:_syncBigTipImage(hints)
        print("[ClientUI][Hint] 显示 BigTip: " .. tostring(anyBigTip))
    end
    -- 再处理"上次有、当前无"（到期）：隐藏。BigTip 延后到单独判定（上面 anyBigTip）
    for name, ids in pairs(MAP) do
        if self._hintShown[name] and hints[name] ~= true then
            self._hintShown[name] = nil
            for _, id in ipairs(ids) do
                if id then self:HideForce(id) end
            end
        end
    end
    if self._hintShown.BigTip and not anyBigTip then
        self._hintShown.BigTip = nil
        self:HideForce(S.BigTipInstance)
    end
end

-- 技能中央大图换图：按当前提示的技能 key + 语言取图（无多语图时回退该技能 imageKey）。
function ClientUI:_syncBigTipImage(hints)
    local S = Config.Skill or {}
    local id = S.BigTipInstance
    if not id then return end
    for name, _ in pairs(hints) do
        if type(name) == "string" and name:sub(1, 8) == "BigTip_S" then
            local key = name:sub(8)
            local def = Config.Skills and Config.Skills[key]
            local imgKey = nil
            local multi = Config.SkillBigTipImages and Config.SkillBigTipImages[key]
            if multi then imgKey = multi[self.lang] end
            if not imgKey and def then imgKey = def.imageKey end
            if imgKey then self:Image(id, imgKey) end
            return
        end
    end
end

-- ===================== 垃圾行提示（状态驱动，对齐旧 TetrisGame:UpdateGarbageHints） =====================
-- Recv（被攻击）：我盘 pendingGarbage>0 时显示当前语言 Recv 底图+数字图，垃圾升起归零时隐藏。
-- Send（我攻击）：garbageSent>0 时显示当前语言 Send 底图+数字图，归零时隐藏。
-- 12 组件 = 3语言×{Send,Recv}×{base,num}；底图已在场景按语言+类型设好，运行时只显隐 + 给 num 换图。
function ClientUI:_garbageComp(typeKey, lang)
    local G = Config.GarbageHint or {}
    local comp = G.Components and G.Components[lang] and G.Components[lang][typeKey]
    return comp, G
end

-- 隐藏某类型全部 3 语言的 base+num（语言切换/归零时用）
function ClientUI:_hideAllGarbage(typeKey)
    for l = 1, 3 do
        local comp = self:_garbageComp(typeKey, l)
        if comp then
            self:HideForce(comp.base)
            self:HideForce(comp.num)
        end
    end
end

-- 点亮某类型当前语言组件 + 设置数字图（行数 1~8）
function ClientUI:_flashGarbage(typeKey, count)
    local lang = self.lang or 2
    local comp, G = self:_garbageComp(typeKey, lang)
    if not comp then return end
    -- 先隐藏其它语言，避免残留
    for l = 1, 3 do
        if l ~= lang then
            local other = self:_garbageComp(typeKey, l)
            if other then self:HideForce(other.base); self:HideForce(other.num) end
        end
    end
    -- 数字图换图（语言无关共用）
    local n = math.max(1, math.min(count or 1, 8))
    local numKey = G.NumImages and G.NumImages[n]
    if numKey and comp.num then self:Image(comp.num, numKey) end
    self:ShowForce(comp.base)
    self:ShowForce(comp.num)
end

function ClientUI:_syncGarbageHints(state)
    local G = Config.GarbageHint or {}
    if G.Enabled == false then return end
    local recv = state.garbageRecv or 0
    local sent = state.garbageSent or 0

    -- RECV：状态翻转时点亮/隐藏；数量变化时只换数字图
    if recv > 0 then
        if not self._recvShowing then
            self:_flashGarbage("Recv", recv)
            self._recvShowing = true
            print("[Hint] 收垃圾 Recv 提示 +" .. tostring(recv) .. " 行")
        elseif self._recvCount ~= recv then
            local comp, cfg = self:_garbageComp("Recv", self.lang or 2)
            local n = math.max(1, math.min(recv, 8))
            local numKey = cfg.NumImages and cfg.NumImages[n]
            if numKey and comp and comp.num then self:Image(comp.num, numKey) end
        end
    elseif self._recvShowing then
        self:_hideAllGarbage("Recv")
        self._recvShowing = false
        print("[Hint] 收垃圾 Recv 提示隐藏（垃圾已升起）")
    end
    self._recvCount = recv

    -- SEND：状态翻转时点亮/隐藏；数量变化只换数字图
    if sent > 0 then
        if not self._sendShowing then
            self:_flashGarbage("Send", sent)
            self._sendShowing = true
        elseif self._sendCount ~= sent then
            local comp, cfg = self:_garbageComp("Send", self.lang or 2)
            local n = math.max(1, math.min(sent, 8))
            local numKey = cfg.NumImages and cfg.NumImages[n]
            if numKey and comp and comp.num then self:Image(comp.num, numKey) end
        end
    elseif self._sendShowing then
        self:_hideAllGarbage("Send")
        self._sendShowing = false
    end
    self._sendCount = sent
end

-- ===== 结算（显示双方分数+胜者；ExitBtn 语义=重置） =====
function ClientUI:ShowSettle(score1, score2, winnerName)
    local S = Config.Settle or {}
    self:_goto("settle", function()
        self:Show(S.PanelKey, true)
        self:Text(S.P1Score, score1)
        self:Text(S.P2Score, score2)
        self:Text(S.WinnerLabel, winnerName)
    end)
end

function ClientUI:OnExitClicked()
    local S = Config.Settle or {}
    self:Show(S.PanelKey, false)
    self:_setHudVisible(false)   -- 回开始界面：隐藏上一局对局 HUD（含游戏内声音入口）
    self.screen = "none"
    -- 重置：回到开始界面（不显示准备界面），重置幂等标志以便下一局重新隐藏
    self._initHidden = false
    self._hintHidden = false
    self:ShowStart()
end

return ClientUI
