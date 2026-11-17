-- TetrisClient：客户端总控，驱动 UI 流程状态机（准备→开始→难度→技能→Loading），
-- 并串联 UI/音效；对局本体交给 TetrisClientBattle（双盘渲染+输入+结算上报）。
-- 由 ClientGameMain 转发生命周期；不直接写控件（在 ClientUI）、不做玩法渲染（在 Battle）。
--
-- 流程：准备 → 开始 → (帮助/语言/声音/排行榜) → AI难度 → 技能选择 → Loading → 对战 → 结算 → 重置
-- 权威事件：CustomUIClicked=120000（InstanceID 必须 number，见 RcEventIdDefine.lua）
local Config = require("EnvLua.Common.Tetris.TetrisConfig")
local ClientUI = require("EnvLua.Client.Tetris.UI.ClientUI")
local AudioManager = require("EnvLua.Client.Tetris.Audio.AudioManager")
local Battle = require("EnvLua.Client.Tetris.TetrisClientBattle")

local TetrisClient = {}
TetrisClient.__index = TetrisClient

local EV_CLICK = 120000
local LOADING_SEC = 3

---@param host WoWGameMain 提供 AddVPEvent/AddTimerOnce/AddTimer 的宿主
function TetrisClient:new(host)
    local o = setmetatable({}, self)
    o.host = host
    o.phase = "init"
    o.board = nil
    o.renderer = nil
    o.game = nil
    o.input = nil
    o.ui = nil
    o.protocol = nil
    o.audio = nil
    o.selfKey = 0
    o.opponentBoard = nil  -- 对手盘镜像（收到快照后渲染，P6）
    o._tickTimer = nil
    o._flowButtons = {}
    return o
end

-- ===== 初始化（OnStart） =====
function TetrisClient:Init()
    local ps = nil
    if type(Game) == "table" and Game.GetPlayerStateByPlayerKey then
        local ok, p = pcall(function() return Game:GetPlayerStateByPlayerKey(nil) end)
        if ok then ps = p end
    end
    if ps and ps.GetPlayerKey then self.selfKey = ps:GetPlayerKey() or 0 end

    -- 音效（真人盘才建）
    self.audio = AudioManager:new(ps)
    self.audio:StartBGM()

    -- UI（流程 + HUD）
    local selfRef = self
    self.ui = ClientUI:new(self.host, ps, {
        requestLeaderboard = function()
            -- 新架构：排行榜经 GameState 的 P5 白名单方法请求，数据回传到 Battle.Current.OnLeaderboard
            pcall(function()
                local gs = Game:GetGameState()
                if gs then gs:CallServerFunction("P5_RequestLeaderboard") end
            end)
        end,
        adjustVolume = function(kind, delta)
            if not selfRef.audio then return end
            if kind == "bgm" then selfRef.audio:AdjustBGM(delta) else selfRef.audio:AdjustSFX(delta) end
        end,
        getVolumes = function()
            if not selfRef.audio then return { bgm = 0.6, sfx = 0.6 } end
            return { bgm = selfRef.audio.bgmVolume or 0.6, sfx = selfRef.audio.sfxVolume or 0.6 }
        end,
    })

    -- 流程按钮注册
    self:_registerFlowButtons()
end

-- 流程按钮（准备/开始/难度/技能/帮助/语言/声音/排行榜/结算）
function TetrisClient:_registerFlowButtons()
    local U = Config.UI or {}
    local S = Config.SkillSelect or {}
    local A = Config.AI or {}
    local H = Config.HelpUI or {}
    local D = Config.DetailHelp or {}
    local L = Config.LangUI or {}
    local SD = Config.SoundSettings or {}
    local LB = Config.Leaderboard or {}
    local ST = Config.Settle or {}

    -- 绑定时跳过 nil ID（控件未在编辑器放置时 ci() 返回 nil），避免 table index is nil 崩溃。
    local function bind(id, fn)
        if type(id) ~= "number" then return end
        self.host:AddVPEvent(EV_CLICK, function() fn() end, self, id, nil)
        self._flowButtons[#self._flowButtons + 1] = id
    end

    bind(H.BtnClose, function() self.ui:OnPrepareClosed() end)
    bind(D.OpenBtn, function() self.ui:ShowDetailHelp() end)
    bind(D.BtnClose, function() self.ui:CloseDetailHelp() end)
    bind(S.StartBtn, function() self:_onStartGame() end)
    bind(A.BtnEasy, function() self:_onDifficulty("Easy") end)
    bind(A.BtnNormal, function() self:_onDifficulty("Normal") end)
    bind(A.BtnHard, function() self:_onDifficulty("Hard") end)
    bind(SD.OpenBtn, function() self.ui:ShowSoundPanel() end)
    bind(SD.BtnClose, function() self.ui:HideSoundPanel() end)
    bind(LB.OpenBtn, function() self.ui:OpenLeaderboard() end)
    bind(LB.CloseBtn, function() self.ui:CloseLeaderboard() end)
    bind(L.OpenBtn, function() self.ui:ShowLangSelect() end)
    bind(L.BtnClose, function() self.ui:CloseLangSelect() end)
    bind(ST.ExitBtn, function() self:_onSettleExit() end)
    for _, id in ipairs(D.PageBtns or {}) do
        bind(id, function() self.ui:SetHelpPage((self.ui.helpPage % 3) + 1) end)
    end
    for i, id in ipairs(L.BtnLang or {}) do
        local lang = i
        bind(id, function() self.ui:SetLang(lang) end)
    end
    for i, id in ipairs(S.SlotButtons or {}) do
        local slot = i
        bind(id, function() self:_onSkillSlot(slot) end)
    end
    bind(SD.BtnBgmDown, function() self.ui:AdjustVolume("bgm", -1) end)
    bind(SD.BtnBgmUp, function() self.ui:AdjustVolume("bgm", 1) end)
    bind(SD.BtnSfxDown, function() self.ui:AdjustVolume("sfx", -1) end)
    bind(SD.BtnSfxUp, function() self.ui:AdjustVolume("sfx", 1) end)
end

-- ===== 流程状态转换 =====
function TetrisClient:_onStartGame()
    self.ui:OnStartClicked()
    if Config.AI and Config.AI.Enabled then
        self.ui:ShowAIDifficulty()
    else
        self.ui:ShowSkillSelect()
    end
end

function TetrisClient:_onDifficulty(name)
    local level = (Config.AI and Config.AI.DifficultyLevels and Config.AI.DifficultyLevels[name]) or {}
    self.aiQuality = level.Quality or 0.8
    self.aiName = level.Name or "AI"
    self.ui:OnDifficultyChosen()
end

function TetrisClient:_onSkillSlot(index)
    local key = self.ui:OnSkillChosen(index)
    if not key then return end
    self.selectedSkill = key
    -- 选完技能通知服务端隐藏 Mask 场景对象（ToggleInstanceVisible 是 ServerOnly，只能在服务端做）
    pcall(function()
        local gs = Game:GetGameState()
        if gs then gs:CallServerFunction("P7_HideMasks") end
    end)
    self.ui:ShowLoading()
    self.host:AddTimerOnce(LOADING_SEC, function() self:_startBattle() end)
end

function TetrisClient:_startBattle()
    -- 新架构：对局本体交给 Battle（双盘渲染+输入+模式判断+结算上报）。
    -- 这里只负责 UI 流程切换 + 通过回调把 HUD/结算/排行榜接回 TetrisClient。
    local selfRef = self
    self.ui:HideSkillHintUI()
    self.ui:EnterBattle()
    self.phase = "battle"

    local ok, err = pcall(function()
        self.battle = Battle:new(self.host)
        -- 回调：结算显示（Battle 已完成服务端上报）
        self.battle.onSettle = function(win, score, opponentScore)
            selfRef:_endBattle(win, score, opponentScore)
        end
        -- 回调：HUD 更新（第二参=对手分数）
        self.battle.onHud = function(uiState, opponentScore)
            if selfRef.ui then selfRef.ui:UpdateHUD(uiState, opponentScore) end
        end
        -- 回调：排行榜数据 → 填表
        self.battle.onLeaderboard = function(list)
            if selfRef.ui then selfRef.ui:FillLeaderboard(list) end
        end
        -- 回调：玩家名字 + 头像序号 → 写对局 HUD
        self.battle.onPlayerInfo = function(myName, oppName, myAvatar, oppAvatar)
            if selfRef.ui then selfRef.ui:SetPlayerInfo(myName, oppName, myAvatar, oppAvatar) end
        end
        -- 难度传给 AI（单人时 Battle 会用服务端 AI，难度影响 quality）
        self.battle.quality = self.aiQuality or 0.8
        self.battle.aiName = self.aiName or "AI"
        self.battle:Start()
    end)
    if not ok then
        print("[TetrisClient] _startBattle 失败: " .. tostring(err))
        return
    end

    -- 音效：开局确认（切曲）
    if self.audio then self.audio:SwitchBGMByDifficulty(self.aiQuality == 0.55 and "Easy" or self.aiQuality == 0.8 and "Normal" or "Hard") end
end

function TetrisClient:_endBattle(win, score, opponentScore)
    self.phase = "settle"
    if self.audio then
        if win then self.audio:PlayWin() else self.audio:PlayLose() end
        self.audio:StopBGM()
    end
    local winnerName = win and "YOU" or (self.aiName or "AI")
    self.ui:ShowSettle(score or 0, opponentScore or 0, winnerName)
end

function TetrisClient:_onSettleExit()
    if self.phase ~= "settle" then return end
    -- 对局清理（服务端胜负上报已由 Battle 的 _settle 完成）
    if self.battle then pcall(function() self.battle:Stop() end); self.battle = nil end
    self.ui:OnExitClicked()
    self.phase = "prepare"
end

-- ===== 生命周期（ClientGameMain 转发） =====
function TetrisClient:OnRoundStart()
    if self.phase == "init" then
        self.ui:InitializeAll()   -- 控件已在场：补齐初始显隐/标志/排行榜文本/声音交互
        -- HelpUI（准备界面）由编辑器默认显示：开局代码不显示也不隐藏它。
        -- 玩家点关闭按钮 → OnPrepareClosed → ShowStart 才隐藏 HelpUI 并显示开始界面。
        self.phase = "prepare"
    end
end

function TetrisClient:OnRoundEnd()
    self.phase = "over"
    if self.battle then pcall(function() self.battle:Stop() end); self.battle = nil end
    if self.audio then self.audio:StopBGM() end
end

function TetrisClient:OnDestroy()
    self:OnRoundEnd()
end

return TetrisClient
