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
-- 模块单例：客户端 GameState 收到服务端广播（双方就绪 AllReady）后据此回调当前实例
TetrisClient.Current = nil

local EV_CLICK = 120000
-- PlayerBorn(10000)：玩家角色在出生点生成时触发。日志证实该事件比 OnRoundStart 晚约 5s，
-- 而引擎在玩家出生时会把 CustomUI 控件重置回编辑器默认态（关闭按钮默认隐藏），
-- 导致 OnRoundStart 里提前 ShowForce 的按钮被覆盖回隐藏。故需出生后补发显示。
pcall(require, "EnvLua.Core.Define.RcEventIdDefine")
local EV_PLAYER_BORN = (type(RcEventIdDefine) == "table" and RcEventIdDefine.PlayerBorn) or 10000
local LOADING_SEC = 3
-- [BigFrame3D] Battle 构建后会立即上报 hold/next 给服务端灌 3D 大框，RPC 往返+灌图约 1~2s。
-- 若此时立刻隐藏 loading，玩家会看到一瞬默认图；故先保持 loading，缓冲后再隐藏。
local BIGFRAME_WARMUP_SEC = 1.8

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
    o._readyGen = 0             -- 双方就绪代号（与服务端握手，跨局递增）
    o._allReadyHandled = false  -- 本局是否已处理 AllReady（幂等，防补发重复进 loading）
    o._settingsLoaded = false   -- [P9] 存档是否已回传（关闭键等此标志）
    o._isFirstPlay = false      -- [P9] 是否首次玩（服务端无任何存档）
    o._langSnapshot = nil       -- [P9] 打开多语言界面时的语言快照
    o._soundSnapshot = nil      -- [P9] 打开声音界面时的音量快照
    TetrisClient.Current = o
    return o
end

-- ===== P9：设置存档（语言/音量）C→S 请求与回传应用 =====
-- GameState 在 OnStart 时刻可能尚未就绪，失败/未就绪时 0.4s 重试。
function TetrisClient:_requestSettings(tries)
    local okGs, gs = pcall(function() return Game:GetGameState() end)
    if not okGs or not gs then
        if tries > 0 then
            self.host:AddTimerOnce(0.4, function() self:_requestSettings(tries - 1) end)
        end
        return
    end
    local ok = pcall(function() gs:CallServerFunction("P9_RequestSettings", self.selfKey) end)
    if not ok and tries > 0 then
        self.host:AddTimerOnce(0.4, function() self:_requestSettings(tries - 1) end)
    else
        print("[P9][Client] 读档请求已发 key=" .. tostring(self.selfKey))
    end
end

-- [BGM] 幂等起播：OnStart 时本地玩家可能尚未生成导致 StartBGM 跳过，这里重试取 ps 并补播。
-- 已在播（bgmUUID 有效）则直接返回，不重切，避免每次调用都停旧播新。
function TetrisClient:_ensureBGM(tries)
    if not self.audio then return end
    if self.audio.bgmUUID then return end  -- 已在播，幂等跳过
    -- 只有在 audio.ps 为空时才重新取；绝不覆盖已有的有效 ps（否则所有音效/BGM 的播放目标会失效）
    if not self.audio.ps then
        local ps = nil
        if type(Game) == "table" and Game.GetPlayerStateByPlayerKey then
            local ok, p = pcall(function() return Game:GetPlayerStateByPlayerKey(nil) end)
            if ok and p then ps = p end
        end
        if not ps then
            if tries > 0 then
                self.host:AddTimerOnce(0.5, function() self:_ensureBGM(tries - 1) end)
            else
                print("[Audio][WARN] _ensureBGM 重试耗尽仍取不到本地玩家，BGM 未播放")
            end
            return
        end
        self.audio.ps = ps
        if (not self.selfKey or self.selfKey == 0) and ps.GetPlayerKey then
            self.selfKey = ps:GetPlayerKey() or 0
        end
    end
    -- StartBGM 可能因 AssetRef 尚未注入而失败；失败则继续重试，直到成功起播（幂等：已在播则上面已返回）
    local ok = self.audio:StartBGM()
    if not ok and tries > 0 then
        self.host:AddTimerOnce(0.5, function() self:_ensureBGM(tries - 1) end)
    elseif not ok then
        print("[Audio][WARN] _ensureBGM 重试耗尽，BGM 仍未起播")
    end
end

-- 语言/音量变更后写存档（服务端 CustomSaveAPI 落盘）
function TetrisClient:_saveSettings()
    if not self.audio or not self.ui then return end
    local okGs, gs = pcall(function() return Game:GetGameState() end)
    if not okGs or not gs then return end
    local lang = self.ui.lang or 2
    local bgm = self.audio.bgmVolume or 0.6
    local sfx = self.audio.sfxVolume or 0.6
    pcall(function() gs:CallServerFunction("P9_SaveSettings", self.selfKey, lang, bgm, sfx) end)
end

-- [P9] 打开设置面板时记录快照
function TetrisClient:_snapshotLang()
    self._langSnapshot = self.ui and self.ui.lang or nil
end

function TetrisClient:_snapshotSound()
    if not self.audio then
        self._soundSnapshot = nil
        return
    end
    self._soundSnapshot = { bgm = self.audio.bgmVolume or 0.6, sfx = self.audio.sfxVolume or 0.6 }
end

-- [P9] 关闭面板时对比快照：有变化才写存档（无变化不产生 RPC）
function TetrisClient:_flushLangOnClose()
    local old = self._langSnapshot
    self._langSnapshot = nil
    if old == nil or not self.ui then return end
    local cur = self.ui.lang
    if cur == old then return end
    print("[P9][Client] 语言已改变 " .. tostring(old) .. " → " .. tostring(cur) .. "，关闭界面写存档")
    self:_saveSettings()
end

function TetrisClient:_flushSoundOnClose()
    local old = self._soundSnapshot
    self._soundSnapshot = nil
    if not old or not self.audio then return end
    local bgm = self.audio.bgmVolume or 0.6
    local sfx = self.audio.sfxVolume or 0.6
    if math.abs(bgm - old.bgm) < 0.001 and math.abs(sfx - old.sfx) < 0.001 then return end
    print("[P9][Client] 音量已改变 bgm=" .. tostring(old.bgm) .. "→" .. tostring(bgm) ..
        " sfx=" .. tostring(old.sfx) .. "→" .. tostring(sfx) .. "，关闭界面写存档")
    self:_saveSettings()
end

-- 存档回传后应用：换语言 + 按数值设置音量（BGM 音量变化才停旧重播）
function TetrisClient:OnSettingsLoaded(lang, bgm, sfx, hasSave)
    self._isFirstPlay = (hasSave ~= true)
    print("[P9][Client] 设置读档 lang=" .. tostring(lang) .. " bgm=" .. tostring(bgm) ..
        " sfx=" .. tostring(sfx) .. " hasSave=" .. tostring(hasSave) ..
        (self._isFirstPlay and "（首次玩，使用默认设置）" or ""))
    if type(lang) == "number" and lang >= 1 and lang <= 3 and self.ui then
        self.ui:SetLang(lang)  -- 更新 self.lang 并切换全部多语言内容
    end
    if self.audio then
        if type(bgm) == "number" then self.audio:SetVolume("bgm", bgm) end
        if type(sfx) == "number" then self.audio:SetVolume("sfx", sfx) end
    end
    if self.ui and self.ui.RefreshSoundText then self.ui:RefreshSoundText() end
    -- [P9] 存档已应用，放行准备界面关闭键（此时语言/音量已是存档值，或首次玩的默认值）
    self._settingsLoaded = true
    self:_showPrepareCloseBtn("SettingsLoaded")
end

-- ===== 初始化（OnStart） =====
function TetrisClient:Init()
    local ps = nil
    if type(Game) == "table" and Game.GetPlayerStateByPlayerKey then
        local ok, p = pcall(function() return Game:GetPlayerStateByPlayerKey(nil) end)
        if ok then ps = p end
    end
    if ps and ps.GetPlayerKey then self.selfKey = ps:GetPlayerKey() or 0 end

    -- [P9] 开局读档：尽早向服务端请求语言/音量设置，回传后由 OnSettingsLoaded 应用（带重试）
    self:_requestSettings(12)

    -- 音效（真人盘才建）；传 host 供 BGM 循环定时器使用
    -- [BGM] 不在此起播：BGM 仅在 ClientUI:ShowStart() 时经 onStartScreen 回调触发
    self.audio = AudioManager:new(ps, self.host)

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
            -- [P9] 不在此写存档，等关闭声音界面时对比快照决定是否写入
        end,
        getVolumes = function()
            if not selfRef.audio then return { bgm = 0.6, sfx = 0.6 } end
            return { bgm = selfRef.audio.bgmVolume or 0.6, sfx = selfRef.audio.sfxVolume or 0.6 }
        end,
        -- [BGM] 进入开始界面时由 UI 回调起播（覆盖 H.BtnClose/Init 等所有入口）
        onStartScreen = function()
            selfRef:_ensureBGM(16)
        end,
    })

    -- 流程按钮注册
    self:_registerFlowButtons()
    -- 关闭按钮默认隐藏（编辑器端也把它设为默认隐藏，这里代码兜底）：
    -- 等 OnRoundStart 再显示，避开回合启动前后引擎恢复默认可见导致准备界面重复出现。
    local H = Config.HelpUI or {}
    print("[DIAG][HelpUI] Init 阶段 phase=" .. tostring(self.phase) ..
        " BtnClose=" .. tostring(H.BtnClose) .. " → WidgetOpacity(0) ONLY")
    -- 按钮显隐 ONLY 用整体透明度，不碰 SetWidgetVisible；便于验证 SetWidgetOpacity 是否生效。
    if self.ui then self.ui:WidgetOpacity(H.BtnClose, 0.0) end

    -- 玩家出生后补发显示：引擎在出生时把 CustomUI 重置回编辑器默认态（隐藏），
    -- 会覆盖 OnRoundStart 提前下发的 ShowForce。监听 PlayerBorn 在出生后重新显示。
    -- @listen 前两参 PlayerState/TeamID 传 nil 表示不过滤；@output 首个为 PlayerState。
    local selfRef = self
    pcall(function()
        self.host:AddVPEvent(EV_PLAYER_BORN, function()
            print("[DIAG][HelpUI] PlayerBorn 触发 → 补发关闭按钮")
            selfRef:_showPrepareCloseBtn("PlayerBorn")
        end, self, nil, nil)
    end)
end

-- 显示准备界面关闭按钮（带 screen 守卫：玩家已点关闭进入后续界面后不再补发，避免游戏中误显示）。
function TetrisClient:_showPrepareCloseBtn(tag)
    if not self.ui then return end
    -- [P9] 等存档回传后才显示：确保玩家点关闭进入开始界面时，语言/音量已按存档应用好。
    if not self._settingsLoaded then
        print("[DIAG][HelpUI] _showPrepareCloseBtn(" .. tostring(tag) .. ") 跳过：存档未回传")
        return
    end
    -- 仅在仍停留准备界面（screen 为 none/prepare）时补发；开始界面及之后一律跳过。
    local sc = self.ui.screen
    if sc ~= "none" and sc ~= "prepare" then
        print("[DIAG][HelpUI] _showPrepareCloseBtn(" .. tostring(tag) .. ") 跳过 screen=" .. tostring(sc))
        return
    end
    local H = Config.HelpUI or {}
    print("[DIAG][HelpUI] _showPrepareCloseBtn(" .. tostring(tag) .. ") → WidgetOpacity(1) ONLY screen=" .. tostring(sc))
    -- 按钮显隐 ONLY 用整体透明度：0→1 点亮，不碰 SetWidgetVisible。
    self.ui:WidgetOpacity(H.BtnClose, 1.0)
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

    bind(H.BtnClose, function()
        self.ui:OnPrepareClosed()   -- 进入开始界面（BGM 由 ShowStart 内部的 onStartScreen 回调起播）
    end)
    bind(D.OpenBtn, function() self.ui:ShowDetailHelp() end)
    bind(D.BtnClose, function() self.ui:CloseDetailHelp() end)
    bind(S.StartBtn, function() self:_onStartGame() end)
    bind(A.BtnEasy, function() self:_onDifficulty("Easy") end)
    bind(A.BtnNormal, function() self:_onDifficulty("Normal") end)
    bind(A.BtnHard, function() self:_onDifficulty("Hard") end)
    bind(SD.OpenBtn, function()
        self:_snapshotSound()
        self.ui:ShowSoundPanel()
    end)
    -- [声音] 游戏界面内的声音入口按钮：同样打开声音面板（原来只配了显隐，忘了绑点击）
    bind(SD.GameOpenBtn, function()
        self:_snapshotSound()
        self.ui:ShowSoundPanel()
    end)
    bind(SD.BtnClose, function()
        self.ui:HideSoundPanel()
        self:_flushSoundOnClose()
    end)
    bind(LB.OpenBtn, function() self.ui:OpenLeaderboard() end)
    bind(LB.CloseBtn, function() self.ui:CloseLeaderboard() end)
    bind(L.OpenBtn, function()
        self:_snapshotLang()
        self.ui:ShowLangSelect()
    end)
    bind(L.BtnClose, function()
        self.ui:CloseLangSelect()
        self:_flushLangOnClose()
    end)
    bind(ST.ExitBtn, function() self:_onSettleExit() end)
    for _, id in ipairs(D.PageBtns or {}) do
        bind(id, function() self.ui:SetHelpPage((self.ui.helpPage % 3) + 1) end)
    end
    for i, id in ipairs(L.BtnLang or {}) do
        local lang = i
        bind(id, function()
            self.ui:SetLang(lang)  -- [P9] 只切界面语言，关闭语言界面时对比快照再决定是否写存档
        end)
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
    self._allReadyHandled = false   -- 新一局：允许再次处理全员就绪广播
    self.ui:OnStartClicked()
    if Config.AI and Config.AI.Enabled then
        self.ui:ShowAIDifficulty()
    else
        self.ui:ShowSkillSelect()
    end
end

-- 按当前语言取 AI 角色名：DifficultyLevels[key].Name = {zh, en, ar}，顺序与 LangKeys 一致。
-- 兼容旧的字符串 Name（未迁移三语时直接返回）。
function TetrisClient:GetAIName()
    local key = self.aiLevelKey
    if not key then return self.aiName or "AI" end
    local level = (Config.AI and Config.AI.DifficultyLevels and Config.AI.DifficultyLevels[key]) or {}
    local name = level.Name
    if type(name) == "table" then
        local lang = (self.ui and self.ui.lang) or 2
        return name[lang] or name[2] or name[1] or "AI"
    end
    return name or "AI"
end

function TetrisClient:_onDifficulty(name)
    local level = (Config.AI and Config.AI.DifficultyLevels and Config.AI.DifficultyLevels[name]) or {}
    self.aiLevelKey = name              -- 保存难度 key，显示时按当前语言现取角色名
    self.aiQuality = level.Quality or 0.8
    self.aiName = self:GetAIName()
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
    -- [P7 双方就绪] 选完技能仅上报"本方已就绪"，不再自己进 loading：
    -- 自己选完后 UI 显示 WaitHint（等待对方选择技能），等服务端确认双方（单人为 AI）都就绪后
    -- 广播 P7_AllReady，两端一起进 loading。单人 AI 视为恒就绪，仍走同一条双方就绪流程。
    self.phase = "ready"
    self:_reportPlayerReady()
end

-- [P7 双方就绪] 上报本玩家就绪给服务端仲裁。gen 代号防跨局/漏收串扰。
function TetrisClient:_reportPlayerReady()
    self._readyGen = self._readyGen or 0
    local ok, err = pcall(function()
        local gs = Game:GetGameState()
        if gs then gs:CallServerFunction("P7_PlayerReady", self.selfKey or 0, self._readyGen) end
    end)
    print("[P7][Ready][Client] 上报 ready selfKey=" .. tostring(self.selfKey) ..
        " gen=" .. tostring(self._readyGen) .. " ok=" .. tostring(ok) .. (ok and "" or (" err=" .. tostring(err))))
    -- 兜底重发：广播万一漏收（晚进入者），只要仍停在 ready 阶段就每 1.5s 重发一次；
    -- 服务端按 playerKey 去重 + gen 落后补发，OnAllReady 幂等，重发安全。
    self.host:AddTimerOnce(1.5, function()
        if self.phase == "ready" and not self._allReadyHandled then self:_reportPlayerReady() end
    end)
end

-- [P7 双方就绪] 服务端广播全员就绪：隐藏等待提示/技能面板 → 进 loading → LOADING_SEC 秒后一起开局。
-- 幂等：服务端为补发漏收者可能多次广播，本方只处理一次。
function TetrisClient:OnAllReady(gen)
    if self._allReadyHandled then
        print("[P7][Ready][Client] AllReady 重复广播，幂等跳过 gen=" .. tostring(gen))
        return
    end
    self._allReadyHandled = true
    self._readyGen = (tonumber(gen) or 0) + 1   -- 推进代号，供下一局握手
    self.phase = "loading"
    print("[P7][Ready][Client] AllReady 收到 gen=" .. tostring(gen) ..
        " → 新代号=" .. tostring(self._readyGen))
    self.ui:OnAllReady()                              -- ① 隐藏等待提示 + 技能选择面板
    self.ui:ShowLoading()                             -- ② 遮罩/进度条/HUD 显示 + 临时提示隐藏（含延迟补写）
    self.host:AddTimerOnce(LOADING_SEC, function() self:_startBattle() end)  -- ③ 双方就绪后 loading 展示 → 开局
end

function TetrisClient:_startBattle()
    -- 新架构：对局本体交给 Battle（双盘渲染+输入+模式判断+结算上报）。
    -- 这里只负责 UI 流程切换 + 通过回调把 HUD/结算/排行榜接回 TetrisClient。
    local selfRef = self
    self.ui:HideSkillHintUI()
    self.phase = "battle"
    -- [BigFrame3D] 不再立即 EnterBattle 隐藏 loading：先构建 Battle（内部立即上报 hold/next），
    -- 等 RPC 往返把 3D 大框灌好后，再隐藏 loading + 启动重力，避免玩家看到一瞬默认图。

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
        -- 回调：玩家名字 + 头像序号 → 写对局 HUD（并缓存名字供结算拼整句用）
        self.battle.onPlayerInfo = function(myName, oppName, myAvatar, oppAvatar)
            selfRef.myName = myName
            selfRef.oppName = oppName
            if selfRef.ui then selfRef.ui:SetPlayerInfo(myName, oppName, myAvatar, oppAvatar) end
        end
        -- 难度传给 AI（单人时 Battle 会用服务端 AI，难度影响 quality）
        self.battle.quality = self.aiQuality or 0.8
        self.battle.aiName = self:GetAIName()
        -- [技能修复] 把选中的技能 key 传给 Battle → ClientGame:SetSkills + ClientInput（否则技能全部不可用）
        self.battle.selectedSkill = self.selectedSkill
        -- [音效修复] 把 AudioManager 传给 Battle → ClientGame（消行/Combo/技能/道具音效）
        self.battle.audio = selfRef.audio
        print("[Skill] TetrisClient 注入选中技能=" .. tostring(self.selectedSkill))
        self.battle:Start()
        -- [P7/BigFrame3D] 缓冲后再隐藏 loading + 启动重力：
        -- Start() 已立即上报 hold/next，等 BIGFRAME_WARMUP_SEC 让 RPC 往返把服务端 3D 大框灌好，
        -- 玩家看到对局的瞬间大框图已就绪；同时避免玩家在 loading 期间看到方块提前下落。
        self.host:AddTimerOnce(BIGFRAME_WARMUP_SEC, function()
            if not selfRef.battle then return end
            selfRef.ui:EnterBattle()             -- 隐藏 loading 遮罩
            selfRef.battle:SetLoadingHidden()    -- 满足下落门控，开始重力
            print("[P7/BigFrame3D] 灌图缓冲 " .. tostring(BIGFRAME_WARMUP_SEC) ..
                "s 结束 → 隐藏 loading + 启动重力")
        end)
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
    local winnerName = win and (self.myName or "YOU") or self:GetAIName()
    self.ui:ShowSettle(score or 0, opponentScore or 0, winnerName, self.myName, self.oppName)
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
    local H = Config.HelpUI or {}
    print("[DIAG][HelpUI] OnRoundStart phase=" .. tostring(self.phase) ..
        " BtnClose=" .. tostring(H.BtnClose))
    if self.phase == "init" then
        self.ui:InitializeAll()   -- 控件已在场：补齐初始显隐/标志/排行榜文本/声音交互
        self:_requestSettings(6)  -- [P9] 补发读档请求（Init 时服务端白名单可能尚未注册）
        -- [P9] 存档回传兜底：6s 内服务端无响应（白名单未注册/请求丢失）则强制放行，避免玩家卡在准备界面。
        self.host:AddTimerOnce(6.0, function()
            if not self._settingsLoaded then
                print("[P9][Client] 存档回传超时，强制放行关闭按钮")
                self._settingsLoaded = true
                self:_showPrepareCloseBtn("SettingsTimeout")
            end
        end)
        -- 回合开始先显示一次（出生前的即时表现）；玩家出生后由 PlayerBorn 补发覆盖引擎重置。
        self:_showPrepareCloseBtn("OnRoundStart")
        -- 兜底：客户端若收不到 PlayerBorn VP 事件，用延迟重试在出生窗口内再补发几次。
        -- screen 守卫确保玩家一旦点关闭进入后续界面就停止补发，不会在游戏中误显示。
        local delays = { 1.0, 2.5, 4.0, 6.0, 8.0 }
        for _, d in ipairs(delays) do
            self.host:AddTimerOnce(d, function() self:_showPrepareCloseBtn("retry@" .. tostring(d)) end)
        end
        -- 玩家点关闭按钮 → OnPrepareClosed → ShowStart 隐藏 HelpUI 并显示开始界面。
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
