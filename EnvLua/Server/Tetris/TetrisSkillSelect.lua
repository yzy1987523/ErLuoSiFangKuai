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
    o._sceneHidden = false     -- 选完技能隐藏场景对象是否已执行（仅一次）
    o.clickEventId = (type(RcEventIdDefine) == "table" and RcEventIdDefine.CustomUIClicked) or 120000
    return o
end

local function cfgOf()
    return TetrisConfig.SkillSelect or {}
end

-- 开始界面上的「帮助」按钮 id（定义在 TetrisConfig.HelpUI.OpenBtn）；帮助未配置时为 nil
local function helpBtnId()
    return (TetrisConfig.HelpUI and TetrisConfig.HelpUI.OpenBtn) or nil
end

-- 阶段是否可用：开关打开且至少放了一个技能按键
function TetrisSkillSelect:Available()
    local cfg = cfgOf()
    if not cfg.Enabled then return false end
    return (cfg.SlotButtons ~= nil and #cfg.SlotButtons >= 2)
end

function TetrisSkillSelect:SkillButtonIDs()
    local cfg = cfgOf()
    return cfg.SlotButtons or {}
end

-- 开局从候选技能池随机抽 2 个技能（Fisher-Yates 洗牌取前 2），写入 self.slotSkills = {key1, key2}
function TetrisSkillSelect:PickRandomSkills()
    local cfg = cfgOf()
    local pool = (cfg.Pool and #cfg.Pool >= 2) and cfg.Pool or { "SK01", "SK02", "SK06", "SK07", "SK08" }
    local t = {}
    for _, k in ipairs(pool) do t[#t + 1] = k end
    for i = #t, 2, -1 do
        local j = math.random(i)
        t[i], t[j] = t[j], t[i]
    end
    self.slotSkills = { t[1], t[2] }
    print(string.format("[Tetris][Skill] 随机技能池 -> %s / %s", tostring(t[1]), tostring(t[2])))
end

-- 需要统一显隐的控件：开始界面 + 开始按钮 + 面板 + 3 个技能按键
function TetrisSkillSelect:WidgetIDs()
    local cfg = cfgOf()
    local ids = { cfg.StartPanel, cfg.StartBtn, cfg.PanelKey,
                  cfg.BtnSK01, cfg.BtnSK02, cfg.BtnSK06, cfg.BtnSK07, cfg.BtnSK08,
                  cfg.IconSK01, cfg.IconSK02, cfg.IconSK06, cfg.IconSK07, cfg.IconSK08 }
    for _, t in ipairs({ cfg.SlotButtons, cfg.SlotIcons, cfg.SlotDescs, cfg.HiddenFrames }) do
        if t then for _, id in ipairs(t) do ids[#ids + 1] = id end end
    end
    -- 初始化（技能选择阶段）即隐藏 SK01 被限制方提示图：编辑器默认可见，仅对局中对方限制我方旋转时才显示，与是否选技能无关
    local sk1 = TetrisConfig.Skills and TetrisConfig.Skills.SK01
    if sk1 and sk1.rotLockVictimImg then ids[#ids + 1] = sk1.rotLockVictimImg end
    return ids
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
    if visible then
        -- 先隐藏候选池里所有旧技能按钮/图标（面板若为父容器会自动带出子控件，这里强制只保留 2 个槽位）
        for _, key in ipairs(cfg.Pool or {}) do
            local b = cfg["Btn" .. key]
            local ic = cfg["Icon" .. key]
            if b then self:ShowFor(ps, b, false) end
            if ic then self:ShowFor(ps, ic, false) end
        end
        -- 隐藏其余 3 个已有技能框（未入选技能的容器/背景）
        for _, id in ipairs(cfg.HiddenFrames or {}) do self:ShowFor(ps, id, false) end
        -- 隐藏“等待对手”提示：它是技能面板（父容器）的子控件，ShowPanelFor 显示父面板时会把它一起带出，
        -- 故必须在这里（父面板显示之后）再隐藏一次，否则会像上面 3 个框那样被父面板带出而“隐藏失败”。
        if cfg.WaitHint then self:ShowFor(ps, cfg.WaitHint, false) end
        -- 显示 2 个槽位的按钮 / 图标 / 描述文本，并恢复按钮交互
        for _, id in ipairs(self:SkillButtonIDs()) do
            self:ShowFor(ps, id, true)
            if id ~= nil and type(CustomUIAPI) == "table" then
                pcall(function() CustomUIAPI.SetWidgetInteraction(ps, id, true) end)
            end
        end
        for _, id in ipairs(cfg.SlotIcons or {}) do self:ShowFor(ps, id, true) end
        for _, id in ipairs(cfg.SlotDescs or {}) do self:ShowFor(ps, id, true) end
        self:ApplySlotContent(ps)
    else
        for _, id in ipairs(self:SkillButtonIDs()) do self:ShowFor(ps, id, false) end
        for _, id in ipairs(cfg.SlotIcons or {}) do self:ShowFor(ps, id, false) end
        for _, id in ipairs(cfg.SlotDescs or {}) do self:ShowFor(ps, id, false) end
    end
end

-- 把 2 个槽位的图标设为对应技能的 iconKey 图片，并把描述文本设为技能的 selectDesc
function TetrisSkillSelect:ApplySlotContent(ps)
    if not ps or type(CustomUIAPI) ~= "table" then return end
    local cfg = cfgOf()
    if not cfg then return end
    local skills = self.slotSkills or {}
    for i = 1, 2 do
        local key = skills[i]
        if key then
            local iconWid = cfg.SlotIcons and cfg.SlotIcons[i]
            local descWid = cfg.SlotDescs and cfg.SlotDescs[i]
            local def = TetrisConfig.Skills and TetrisConfig.Skills[key]
            if iconWid and def and def.iconKey then
                local imgID = (type(AssetRef) == "table" and AssetRef[def.iconKey]) or def.iconKey
                pcall(function() CustomUIAPI.SetImageWidgetContent(ps, iconWid, imgID) end)
            end
            if descWid and def and def.selectDesc then
                pcall(function() CustomUIAPI.SetTextContent(ps, descWid, def.selectDesc) end)
            end
        end
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
    self:PickRandomSkills()   -- 开局从候选池随机抽 2 个技能填入 2 个槽位

    if #self.players == 0 or not self:Available() then
        print("[Tetris][Skill] 跳过技能选择（未启用/未放置按钮/无玩家），使用默认技能")
        self:HideSceneObjectsOnce()   -- 技能选择被跳过时同样兜底隐藏场景对象（仅一次）
        self:ShowAll(false)
        self:Finish()
        return
    end

    -- 先全部隐藏，避免编辑器默认可见导致残留
    self:ShowAll(false)

    local cfg = cfgOf()
    if cfg.StartBtn then
        -- 「开始界面」延后显示：本方法不再直接显示，由 Match 控制时机——
        -- 有「帮助界面」时先弹帮助，玩家关闭帮助后再调用 ShowStartScreenFor 显示开始界面；
        -- 无帮助界面时 Match 会在 Begin 后立即调用 ShowStartScreen 显示。
        -- （开始按钮事件注册放在 ShowStartScreen / ShowStartScreenFor 内。）
    else
        -- 无开始按钮：直接显示技能选择面板（对所有参与玩家）
        for _, ps in ipairs(self.players) do self:ShowPanelFor(ps, true) end
        self:RegisterSkills()
    end

    -- 已移除超时计时：玩家必须手动选完技能才开局（全部选完 → Finish → OnSkillSelected）。
    -- 若需「无人选则自动兜底开局」，可在此恢复：
    --   self.owner:AddTimerOnce(cfg.TimeoutSec or 20, function() self:OnTimeout() end)
    print(string.format("[Tetris][Skill] 等待 %d 名玩家选择技能（无超时，需全部选完才开局）", #self.players))
end

-- 显示「开始游戏」界面（含开始按钮 + 帮助按钮），并注册开始按钮事件。
-- 由 Match 在“无帮助界面”时直接调用；或玩家关闭帮助界面后（ShowStartScreenFor）逐人调用。
function TetrisSkillSelect:ShowStartScreen()
    local cfg = cfgOf()
    if not cfg.StartBtn then return end
    self:ShowForAll(cfg.StartPanel, true)
    self:ShowForAll(cfg.StartBtn, true)
    self:ShowForAll(helpBtnId(), true)
    self:RegisterStart()
    print("[Tetris][Skill] 显示开始界面（全部玩家）")
end

-- 仅对单个玩家显示「开始游戏」界面（玩家关闭自己的帮助界面后调用）
function TetrisSkillSelect:ShowStartScreenFor(ps)
    local cfg = cfgOf()
    if not cfg.StartBtn or not ps then return end
    self:ShowFor(ps, cfg.StartPanel, true)
    self:ShowFor(ps, cfg.StartBtn, true)
    self:ShowFor(ps, helpBtnId(), true)
    self:RegisterStart()
end

-- 仅对单个玩家隐藏「开始游戏」界面（玩家点击帮助按钮打开帮助时调用）
function TetrisSkillSelect:HideStartScreenFor(ps)
    local cfg = cfgOf()
    if not ps then return end
    self:ShowFor(ps, cfg.StartPanel, false)
    self:ShowFor(ps, cfg.StartBtn, false)
    self:ShowFor(ps, helpBtnId(), false)
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

-- 直接显示技能选择面板 + 3 个按键并注册（跳过「开始游戏」界面）；供 AiPanel 选完难度后调用
function TetrisSkillSelect:ShowSkillPanel()
    for _, p in ipairs(self.players) do
        self:ShowPanelFor(p, true)
    end
    self:RegisterSkills()
    print("[Tetris][Skill] 进入技能选择界面")
end

function TetrisSkillSelect:OnStartClicked(ps)
    if self.done or self._started then return end
    self._started = true
    local cfg = cfgOf()
    -- 点击「开始游戏」：此刻才隐藏原生 UI（不在 OnStart 隐藏，规避联机延迟开局的时机竞争）
    if self.owner and self.owner.nativeUI then
        self.owner.nativeUI:Hide()
    end
    self:ShowForAll(cfg.StartPanel, false)        -- 隐藏开始界面（整体）
    self:ShowForAll(cfg.StartBtn, false)          -- 隐藏开始按钮（冗余保险）

    -- 点击「开始游戏」后再统一隐藏一次所有“初始不应显示”的组件（Hold/Next/Combo/垃圾/BigTip/
    -- 技能指示器/道具提示图等），确保进入技能选择前这些控件不会因编辑器默认可见而残留显示。
    -- HideInitUI 内部对每个棋盘实例执行，AI 盘（无 PlayerState）自动跳过。
    local mm = self.match
    if mm and type(mm.list) == "table" then
        print("[Tetris][Skill] 点击开始游戏后，再次执行 HideInitUI")
        for _, g in ipairs(mm.list) do
            if type(g.HideInitUI) == "function" then g:HideInitUI() end
        end
    end

    -- 单击 StartBtn 后才据单人判定：单人 + AI 难度面板可用 → 先弹 AiPanel（选完难度再出技能面板）；
    -- 否则（双人 / 面板未配置）直接出技能面板。
    -- 惰性 require：避免与 TetrisAIDifficulty 形成加载期循环依赖（其顶部 require 了本模块）。
    local m = self.match
    local isSingle = (m and m.realPlayers or 0) < 2
    local TetrisAIDifficulty = require("EnvLua.Server.Tetris.TetrisAIDifficulty")
    print(string.format("[Tetris][Skill] 「开始游戏」被点击（realPlayers=%s，isSingle=%s）→ %s",
        tostring(m and m.realPlayers), tostring(isSingle),
        (isSingle and TetrisAIDifficulty and TetrisAIDifficulty:Available()) and "弹 AiPanel（延迟一帧显示）" or "直接进技能选择（延迟一帧显示）"))
    if isSingle and TetrisAIDifficulty and TetrisAIDifficulty:Available() then
        local ai = TetrisAIDifficulty:new(self.owner, m)
        m.aiSelect = ai
        -- 延迟一帧再弹 AiPanel：避免“开始游戏”这一下点击穿透到随即出现的难度按钮，
        -- 否则同一点击会同时触发 OnStartClicked 与 OnPick(Easy)，表现为“没点难度却已选中”。
        self.owner:AddTimerOnce(0.1, function() ai:Begin(self.players) end)
    else
        -- 同样延迟一帧，避免点击穿透到技能按钮（双人径直进技能选择时同理）
        self.owner:AddTimerOnce(0.1, function() self:ShowSkillPanel() end)
    end
end

-- 注册 3 个技能按键的点击事件（点击者 PlayerState 由引擎回传）
function TetrisSkillSelect:RegisterSkills()
    if self.registered then return end
    self.registered = true
    local selfRef = self
    local btns = self:SkillButtonIDs()
    for i, id in ipairs(btns) do
        if id ~= nil then
            local idx = i
            self.owner:AddVPEvent(self.clickEventId, function(_self, ps)
                local key = selfRef.slotSkills and selfRef.slotSkills[idx]
                if key then selfRef:OnPick(ps, key) end
            end, selfRef, id, nil)
        end
    end
    print("[Tetris][Skill] 技能按键已注册（2 槽位随机技能）")
end

-- 技能选择阶段“等待对手”提示：自己已选完、但仍有对手未选时，给已选完的一方显示；
-- 全员选完（即将进入 loading）时隐藏。控件 ID 取自 TetrisConfig.SkillSelect.WaitHint（ci() 解析）。
function TetrisSkillSelect:RefreshWaitHint()
    print(string.format("[Tetris][WaitHint]================》"))
    local hintID = TetrisConfig.SkillSelect.WaitHint
    if not hintID or type(CustomUIAPI) ~= "table" then return end
    local allChosen = true
    for _, p in ipairs(self.players) do
        if not self.choices[p] then allChosen = false break end
    end
    for _, p in ipairs(self.players) do
        -- 仅“自己已选、对手未齐”的一方看到提示（单人局无对手，不会出现）
        local show = (not allChosen) and (self.choices[p] ~= nil)
        pcall(function() CustomUIAPI.SetWidgetVisible(p, hintID, show) end)
        if show then
            print(string.format("[Tetris][WaitHint] 显示等待对手提示 -> 玩家 %s（对方尚未选完）", tostring(keyOf(p))))
        end
    end
end

function TetrisSkillSelect:OnPick(ps, key)
    if self.done or not ps then return end
    if not self:isParticipant(ps) then return end
    if self.choices[ps] then return end   -- 已选过，忽略重复点击

    self.choices[ps] = key
    self:HideSceneObjectsOnce()   -- 任意玩家点完技能即隐藏场景对象（全程只执行一次）

    -- 该玩家选完：其 3 个技能按钮全部失效（禁用交互）；面板暂不隐藏，
    -- 待 loading 隐藏时由 TetrisMatch 统一隐藏选择界面。
    for _, id in ipairs(self:SkillButtonIDs()) do
        if id ~= nil then
            pcall(function() CustomUIAPI.SetWidgetInteraction(ps, id, false) end)
        end
    end

    self:RefreshWaitHint()   -- 更新“等待对手”提示：自己已选、对手未齐则显示

    print(string.format("[Tetris][Skill] 玩家 %s 选择：%s", tostring(keyOf(ps)), self:SkillName(key)))
    self:Notify(ps, "已选择技能：" .. self:SkillName(key))

    -- 全部选完 → 结束选择阶段（进入玩法选择 / 开局）
    for _, p in ipairs(self.players) do
        if not self.choices[p] then return end
    end
    self:Finish()
end

-- ---------------- 收尾 ----------------
-- 选完技能后隐藏指定场景对象：任意玩家点完即触发，全程只执行一次。
-- 场景对象为共享世界对象，用 InstanceAPI.ToggleInstanceVisible(uuid, false) 隐藏，影响全体玩家。
function TetrisSkillSelect:HideSceneObjectsOnce()
    if self._sceneHidden then return end
    self._sceneHidden = true
    local list = TetrisConfig.HideAfterSkill
    if type(list) ~= "table" or type(InstanceAPI) ~= "table" then return end
    for _, key in ipairs(list) do
        local id = (type(CreativeInstance) == "table" and CreativeInstance[key]) or nil
        if id ~= nil then
            pcall(function() InstanceAPI.ToggleInstanceVisible(id, false) end)
        end
    end
    print("[Tetris][Skill] 已隐藏选技能阶段场景对象（一次性）")
end

function TetrisSkillSelect:Finish()
    if self.done then return end
    self.done = true
    self:RefreshWaitHint()   -- 全员选完，隐藏“等待对手”提示（即将进入 loading）
    -- 不在此隐藏选择界面：保持可见，待 loading 隐藏时由 TetrisMatch 统一隐藏。
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
