-- 双人对战总控（经典对攻，最后存活胜）。
-- 持有 N 个 TetrisGame 实例（当前固定 2 人），负责：
--   1) 按 SceneObjects.SpawnPointKey / SpawnPointKey2 给每个实例分配出生点（各自一块棋盘）；
--   2) 开局枚举在场玩家，把玩家分配到棋盘实例，并互设对手；
--   3) 输入路由：每个按钮仅注册一次，按「点击者的 PlayerState」分发到其所属实例；
--   4) 胜负判定：某玩家顶出（game over）即判对手获胜，整局结束。
-- 注：屏幕显示（HUD/胜负面板）交给 TetrisGame.UpdateHUD 与上层逻辑，本模块只做逻辑与日志。
pcall(require, "EnvLua.Core.Define.RcEventIdDefine")
pcall(require, "EnvLua.Core.LuaHint.GameOutcomeAPI")
pcall(require, "EnvLua.Core.LuaHint.BattleDataAPI")
pcall(require, "EnvLua.Core.LuaHint.PlayerAPI")

local TetrisConfig = require("EnvLua.Server.Tetris.TetrisConfig")
local TetrisGame = require("EnvLua.Server.Tetris.TetrisGame")
local PuyoGame = require("EnvLua.Server.Tetris.PuyoGame")
local TetrisModeSelect = require("EnvLua.Server.Tetris.TetrisModeSelect")
local TetrisSkillSelect = require("EnvLua.Server.Tetris.TetrisSkillSelect")
local TetrisAIDifficulty = require("EnvLua.Server.Tetris.TetrisAIDifficulty")
local TetrisBehindWidget = require("EnvLua.Server.Tetris.TetrisBehindWidget")
local TetrisBackgroundWidget = require("EnvLua.Server.Tetris.TetrisBackgroundWidget")

local TetrisMatch = {}
TetrisMatch.__index = TetrisMatch

function TetrisMatch:new(owner)
    local o = setmetatable({}, TetrisMatch)
    o.owner = owner
    o.games = {}    -- [playerKey] = TetrisGame
    o.list = {}     -- 有序实例列表
    o.over = false
    o.winner = nil
    return o
end

-- 取玩家稳定 key（用于路由与查表）；取不到键时用 PlayerState 本身兜底
local function playerKeyOf(ps)
    if ps and type(ps.GetPlayerKey) == "function" then
        local ok, k = pcall(function() return ps:GetPlayerKey() end)
        if ok and k then return k end
    end
    return ps
end

-- 出生点 key 列表：SpawnPointKey（玩家1）+ SpawnPointKey2（玩家2）+ …（可扩展 N 人）
function TetrisMatch:spawnKeys()
    local so = TetrisConfig.SceneObjects or {}
    local keys = {}
    if so.SpawnPointKey then keys[#keys + 1] = so.SpawnPointKey end
    if so.SpawnPointKey2 then keys[#keys + 1] = so.SpawnPointKey2 end
    if #keys == 0 then keys[#keys + 1] = nil end
    return keys
end

-- 初始模式：调试 ForceGameMode 优先，否则俄罗斯方块（正常选择流程可覆盖）
function TetrisMatch:initialMode()
    if TetrisConfig.ForceGameMode then return TetrisConfig.ForceGameMode end
    return TetrisConfig.GameMode.Tetris
end

-- 按模式工厂化创建游戏实例（Tetris / Puyo 共用同一套 match 调度）
function TetrisMatch:createGame(mode, spawnKey, index)
    if mode == TetrisConfig.GameMode.Puyo then
        return PuyoGame:new(self.owner, { match = self, spawnPointKey = spawnKey, index = index })
    end
    return TetrisGame:new(self.owner, { match = self, spawnPointKey = spawnKey, index = index })
end

-- 建立棋盘实例占位（仅创建对象 + 记录出生点，不构建方块）。
-- 实际棋盘（方块/渲染）推迟到 OnModeSelected，按玩家所选玩法用正确模式构建一次，
-- 避免「先按默认俄罗斯方块建好、再被选择覆盖」导致选 puyo 却开成俄罗斯方块。
function TetrisMatch:Init()
    local keys = self:spawnKeys()
    local mode = self:initialMode()
    for i, sk in ipairs(keys) do
        local g = self:createGame(mode, sk, i)
        self.list[#self.list + 1] = g
    end
    print(string.format("[Tetris][Versus] Match.Init 建立 %d 个棋盘占位（预览模式=%s，实际模式待选择）", #self.list, tostring(mode)))
    -- 解耦生成：在 Init（OnStart，游戏加载即执行）阶段就基于出生点装置直接生成背后 3D UI 挂件，
    -- 不再依赖 renderer 的盘面基底（boardCenter/boardForward/boardYaw）。生成逻辑见 TetrisBehindWidget，
    -- 仅依赖出生点装置(CreativeInstance) + ActorPreset(AssetRef)，因此在加载时即可尝试生成；
    -- 若出生点/资源在 OnStart 尚未就绪而失败，OnModeSelected→BuildGames 会再兜底一次。
    if TetrisConfig.BehindBoardWidget and TetrisConfig.BehindBoardWidget.Enabled then
        self._behindWidgets = {}
        for i, g in ipairs(self.list) do
            -- 仅 tetris 渲染器挂接背后挂件（PuyoRenderer 无该方法）
            if g.renderer and type(g.renderer.BuildBehindBoardWidget) == "function" then
                local actor = TetrisBehindWidget.Spawn(g.spawnPointKey, g.index)
                self._behindWidgets[i] = actor
                if actor then g.renderer._behindWidgetActor = actor end
            end
        end
    end
    -- 准备阶段内重试：Init 当下若出生点/资源未注入导致生成失败，每 0.2s 重试，
    -- 一旦就绪立即生成（不拖到加载阶段）。进入加载构建(BuildGames)后由兜底接管，停止重试。
    if self._behindWidgets then
        self._bwRetry = { pending = {}, tries = 0, max = 150 }
        for i, actor in pairs(self._behindWidgets) do
            if not actor then self._bwRetry.pending[i] = true end
        end
        if next(self._bwRetry.pending) then
            self:_retryBehindWidgets()
        end
    end
        -- 远景背景 3D UI（背景图）：与 BehindBoardWidget 同思路，但纯背景、不挂接 renderer、不依赖文本组件。
    -- 每个棋盘各 1 个（双盘 = 2 个），基于出生点装置直接生成；失败则准备阶段重试 + BuildGames 兜底。
    if TetrisConfig.BackgroundWidget and TetrisConfig.BackgroundWidget.Enabled then
        self._bgWidgets = {}
        for i, g in ipairs(self.list) do
            local actor = TetrisBackgroundWidget.Spawn(g.spawnPointKey, g.index)
            self._bgWidgets[i] = actor
        end
        -- 准备阶段重试：Init 当下若出生点/资源未注入导致生成失败，每 0.2s 重试，直至就绪或进入加载构建。
        self._bgRetry = { pending = {}, tries = 0, max = 150 }
        for i, actor in pairs(self._bgWidgets) do
            if not actor then self._bgRetry.pending[i] = true end
        end
        if next(self._bgRetry.pending) then
            self:_retryBackgroundWidgets()
        end
    end
end

-- 准备/选择阶段内的轻量重试：等待出生点装置(CreativeInstance)与 ActorPreset(AssetRef) 注入就绪后生成挂件。
-- 进入加载构建(BuildGames 设 _buildGamesStarted)后停止，交由 BuildGames 兜底；max 次(30s)为安全网。
function TetrisMatch:_retryBehindWidgets()
    if not self._bwRetry or not next(self._bwRetry.pending) then return end
    if self._buildGamesStarted then  -- 已进加载构建，交给 BuildGames 兜底
        self._bwRetry.pending = {}
        return
    end
    self._bwRetry.tries = (self._bwRetry.tries or 0) + 1
    if self._bwRetry.tries > (self._bwRetry.max or 150) then
        print(string.format("[Tetris][Widget][WARN] 准备阶段重试超时(%d次)，交由加载阶段兜底", self._bwRetry.tries))
        self._bwRetry.pending = {}
        return
    end
    for i in pairs(self._bwRetry.pending) do
        local g = self.list[i]
        if g and g.renderer and type(g.renderer.BuildBehindBoardWidget) == "function" then
            local actor = TetrisBehindWidget.Spawn(g.spawnPointKey, g.index)
            if actor then
                self._behindWidgets[i] = actor
                g.renderer._behindWidgetActor = actor
                self._bwRetry.pending[i] = nil
                print(string.format("[Tetris][Widget] 准备阶段重试成功生成 index=%s (第%d次)",
                    tostring(g.index), self._bwRetry.tries))
            end
        end
    end
    if next(self._bwRetry.pending) then
        self.owner:AddTimerOnce(0.2, function() self:_retryBehindWidgets() end)
    end
end

-- 远景背景 3D UI 准备阶段重试：等待出生点装置(CreativeInstance)与 ActorPreset(AssetRef) 注入就绪后生成。
-- 进入加载构建(BuildGames 设 _buildGamesStarted)后停止，交由 BuildGames 兜底；max 次(30s)为安全网。
function TetrisMatch:_retryBackgroundWidgets()
    if not self._bgRetry or not next(self._bgRetry.pending) then return end
    if self._buildGamesStarted then  -- 已进加载构建，交给 BuildGames 兜底
        self._bgRetry.pending = {}
        return
    end
    self._bgRetry.tries = (self._bgRetry.tries or 0) + 1
    if self._bgRetry.tries > (self._bgRetry.max or 150) then
        print(string.format("[Tetris][BGWidget][WARN] 准备阶段重试超时(%d次)，交由加载阶段兜底", self._bgRetry.tries))
        self._bgRetry.pending = {}
        return
    end
    for i in pairs(self._bgRetry.pending) do
        local g = self.list[i]
        if g then
            local actor = TetrisBackgroundWidget.Spawn(g.spawnPointKey, g.index)
            if actor then
                self._bgWidgets[i] = actor
                self._bgRetry.pending[i] = nil
                print(string.format("[Tetris][BGWidget] 准备阶段重试成功生成 index=%s (第%d次)",
                    tostring(g.index), self._bgRetry.tries))
            end
        end
    end
    if next(self._bgRetry.pending) then
        self.owner:AddTimerOnce(0.2, function() self:_retryBackgroundWidgets() end)
    end
end

-- 开局：枚举在场玩家 → 分配棋盘 → 互设对手 → 注册输入 → 玩法选择阶段（选完传送+开局）
function TetrisMatch:Start()
    -- ===== 第一阶段：玩家枚举/分配/注册输入/隐藏初始界面（仅首次执行一次）=====
    -- OnRoundStart 可能多次回调 Start，且首次回调时 CreativeInstance 控件可能尚未注入；
    -- 用 _setupDone 保证分配/注册只做一次，避免重复分配与重复注册输入。
    if not self._setupDone then
    -- 枚举在场玩家，并配对其 pawn 世界坐标（米），用于按"实际站位"分配棋盘。
    -- GetAllPlayerStates / GetAllPlayerPawns 同序：第 i 个玩家态 ↔ 第 i 个 pawn。
    local players = {}   -- { ps = PlayerState, locM = {X,Y,Z} 米 | nil, hasPawn = bool }
    local okS, arr = pcall(function() return Game:GetAllPlayerStates() end)
    local okP, parr = pcall(function() return Game:GetAllPlayerPawns() end)
    -- 安全取数组长度：GetAllPlayerPawns 等在部分环境会返回空/失效 LuaArray，直接 :Num() 会抛 C++ 错，用 pcall 兜住。
    local function safeNum(a)
        if not a then return 0 end
        local ok, n = pcall(function() return a:Num() end)
        return (ok and type(n) == "number") and n or 0
    end
    local pawnCount = safeNum(parr)   -- 真人 pawn 数（0 表示接口不可用，回退到 PlayerState 计数）
    local pawnN = pawnCount
    local stateN = safeNum(arr)
    if okS and arr and arr.Num then
        for i = 0, stateN - 1 do
            local ps = arr:Get(i)
            if ps then
                local locM = nil
                local pawn = nil
                if i < pawnN then
                    local okG, p = pcall(function() return parr:Get(i) end)
                    if okG then pawn = p end
                end
                if pawn and pawn.K2_GetActorLocation then
                    local okL, lc = pcall(function() return pawn:K2_GetActorLocation() end)
                    if okL and lc and lc.X then
                        locM = { X = lc.X / 100, Y = lc.Y / 100, Z = lc.Z / 100 }  -- 厘米→米
                    end
                end
                players[#players + 1] = { ps = ps, locM = locM, hasPawn = pawn ~= nil }
            end
        end
    end
    -- 仅"有 pawn 的真人"参与分配：引擎单人/测试环境会多报一个无 pawn 的 PlayerState，
    -- 若把它也算进 assigned，会导致：单人被误判为双人（AiPanel 不弹）、且空盘无法变 AI 对手。
    -- pawn 接口不可用时回退到 PlayerState 计数（原行为，无法剔除幽灵态），避免分配为空导致流程中断。
    local realPlayers, contenders
    if pawnCount > 0 then
        realPlayers = pawnCount
        contenders = {}
        for _, p in ipairs(players) do
            if p.hasPawn then contenders[#contenders + 1] = p end
        end
    else
        realPlayers = #players
        contenders = players
    end

    -- 取每块棋盘的出生装置世界坐标（米），供"最近分配"比对。
    local function boardSpawnLoc(g)
        local key = g.spawnPointKey
        if not key or type(CreativeInstance) ~= "table" or type(InstanceAPI) ~= "table" then return nil end
        local id = CreativeInstance[key]
        if id == nil then return nil end
        local ok, loc = pcall(function() return InstanceAPI.GetInstanceLocation(id) end)
        if ok and loc and loc.X then return { X = loc.X, Y = loc.Y, Z = loc.Z } end
        return nil
    end
    local spawnLocs = {}
    local haveAll = true
    for _, g in ipairs(self.list) do
        local sl = boardSpawnLoc(g)
        spawnLocs[g] = sl
        if not sl then haveAll = false end
    end
    local allHaveLoc = true
    for _, p in ipairs(contenders) do if not p.locM then allHaveLoc = false end end

    local function dist2(a, b)
        if not a or not b then return nil end
        return (a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2
    end

    -- 分配：优先按"站在哪个出生装置前 → 控制哪块盘"（解决玩家序与装置序不一致导致的反盘）；
    -- 任一坐标缺失时退化为顺序分配（第 i 个玩家 → 第 i 个棋盘）。
    if #contenders > 0 and haveAll and allHaveLoc then
        local taken = {}
        for _, p in ipairs(contenders) do
            local best, bestD = nil, nil
            for _, g in ipairs(self.list) do
                if not taken[g] then
                    local d = dist2(spawnLocs[g], p.locM)
                    if bestD == nil or (d ~= nil and d < bestD) then best, bestD = g, d end
                end
            end
            if best then
                taken[best] = true
                best.playerState = p.ps
                best.playerKey = playerKeyOf(p.ps)
                self.games[best.playerKey] = best
            end
        end
    else
        for i, g in ipairs(self.list) do
            local p = contenders[i]
            if p then
                g.playerState = p.ps
                g.playerKey = playerKeyOf(p.ps)
                self.games[g.playerKey] = g
            end
        end
    end

    -- 已分配到棋盘的玩家（参与玩法选择）
    local assigned = {}
    for _, g in ipairs(self.list) do
        if g.playerState then assigned[#assigned + 1] = g.playerState end
    end

    -- 互设对手（环形：2 人时互为对手；>2 时循环到下一个）
    if #self.list > 1 then
        for i, g in ipairs(self.list) do
            g.opponent = self.list[i % #self.list + 1]
        end
    end

    -- 开局随机分配头像：每个玩家从 AvatarPresets 中取一个（2 人时洗牌保证互不相同）
    self:AssignAvatars()

    -- 输入路由：每个按钮注册一次，按点击者 PlayerState 分发（避免每个实例重复注册互相覆盖）
    self:RegisterInput()

    -- 存下已分配玩家，供技能选择结束后继续玩法选择使用
    self.assigned = assigned

    -- 不显示开局初始 Loading：技能选择界面直接呈现，Loading 仅保留在「选完技能后对象生成期」
    -- （见 OnModeSelected）。_enteredGame 仍用于标记已进入开局阶段，供隐藏 loading 时联动隐藏
    -- 技能/玩法选择界面。
    self._enteredGame = false

    -- 开始界面（StartPanel / StartBtn）默认隐藏：在技能选择初始化(Begin)前先强制隐藏，
    -- 避免编辑器默认设为可见导致 loading 期闪烁；真正的显示由 TetrisSkillSelect:Begin 在初始化时执行。
    do
        local scfg = TetrisConfig.SkillSelect or {}
        local hud = TetrisConfig.ShowHudAfterSkill
        if type(CustomUIAPI) == "table" then
            for _, ps in ipairs(assigned) do
                if scfg.StartPanel then pcall(function() CustomUIAPI.SetWidgetVisible(ps, scfg.StartPanel, false) end) end
                if scfg.StartBtn   then pcall(function() CustomUIAPI.SetWidgetVisible(ps, scfg.StartBtn, false) end) end
                -- 游戏内 HUD 默认隐藏（选完技能、显示 loading 时才显示）
                if type(hud) == "table" and type(CreativeInstance) == "table" then
                    for _, key in ipairs(hud) do
                        local hid = CreativeInstance[key]
                        if hid ~= nil then pcall(function() CustomUIAPI.SetWidgetVisible(ps, hid, false) end) end
                    end
                end
            end
        end
    end

        self.realPlayers = realPlayers
    end  -- _setupDone

    -- ===== 第二阶段：开局前置阶段 =====
    -- init 只显示「开始游戏」界面（StartPanel + StartBtn）；单击 StartBtn 后，
    -- 由 TetrisSkillSelect:OnStartClicked 据单人判定决定是否弹 AiPanel（难度选择），再进入技能选择。
    -- 这里只负责建立并 Begin 技能选择阶段（显示开始界面）。
    -- 仅触发一次（_phaseInitiated 守卫），避免 OnRoundStart 多次回调导致重复 Begin。
    if self._phaseInitiated then return end
    self._phaseInitiated = true
    self.skillSelect = TetrisSkillSelect:new(self.owner, self)
    self.skillSelect:Begin(self.assigned)
end

-- 技能选择结束（或跳过）：按各玩家所选技能记录后，进入玩法选择（若启用）或直接开局。
-- skillChoices: [PlayerState] = 技能 key（如 "SK01"）。未选择则回退默认技能。
function TetrisMatch:OnSkillSelected(skillChoices)
    self.skillChoices = skillChoices or {}
    -- 选完技能：进入开局阶段（_enteredGame 标记，供隐藏 loading 时联动隐藏选择界面）。
    -- loading 在真正开始生成对象时（OnModeSelected）再显示，避免盖住中间的玩法选择界面。
    self._enteredGame = true
    if TetrisConfig.ModeSelect and TetrisConfig.ModeSelect.Enabled then
        -- 仍走「玩法选择」步骤
        self.modeSelect = TetrisModeSelect:new(self.owner, self)
        self.modeSelect:Begin(self.assigned or {})
    else
        -- 跳过玩法选择，直接按默认玩法开局
        self:OnModeSelected({})
    end
end

-- 玩法选择结束（或跳过选择）：按各玩家所选玩法，用正确模式构建棋盘并开局。
-- choices: [PlayerState] = 玩法（"tetris"/"puyo"）。未选择则回退默认玩法。
function TetrisMatch:OnModeSelected(choices)
    self.choices = choices or {}
    -- 显示 loading（LoadingTime 秒进度条）。
    self._loadingTimeUp = false
    self._started = false
    self:ShowLoading(true)
    local selfRef = self
    if self._restart then
        -- 重开：实例与渲染器已生成（首局 BuildGames 已建好），直接复用，不再新建实例 / 不再重建渲染器。
        -- 仅按当前选择刷新每盘属性（技能 / AI / 对手），并把 _borderDone 置真（渲染器已就绪），
        -- 等 loading 到时即可直接 g:Start() 复用既有实例。
        self._restart = false
        self._borderDone = true
        self:ApplyModeToGames(choices)
        self.owner:AddTimerOnce(TetrisConfig.LoadingTime, function()
            selfRef._loadingTimeUp = true
            selfRef:TryStartGameplay()
        end)
    else
        -- 首次构建：显示 loading 期间进行分阶段构建（BuildGames → StepBuild → 完成边框后开局落方块）。
        self._borderDone = false
        self.owner:AddTimerOnce(TetrisConfig.LoadingTime, function()
            selfRef._loadingTimeUp = true
            selfRef:TryStartGameplay()   -- loading 到时：若方框已生成完则隐藏+开局；否则等方框
        end)
        -- 延迟 1 秒再开始分阶段构建（利用 loading 显示窗口；延后启动避免与开局时序冲突）。
        self.owner:AddTimerOnce(0.5, function() self:BuildGames() end)
    end
end

-- 重开复用既有实例时，按当前选择刷新每盘属性（技能 / AI / 对手），不重建渲染器。
-- 首次构建仍由 BuildGames 完成「实例创建 + 渲染器构建」；本函数仅用于重开，复用已生成的实例。
function TetrisMatch:ApplyModeToGames(choices)
    local defaultSkill = (TetrisConfig.SkillSelect and TetrisConfig.SkillSelect.DefaultSkill) or "SK02"
    for i, g in ipairs(self.list) do
        if not g then goto continue end
        -- 分配到玩家的盘 → 用该玩家所选技能；旁观盘（无真人）→ 默认技能
        g.selectedSkill = (g.playerState and self.skillChoices and self.skillChoices[g.playerState]) or defaultSkill
        if not g.playerState then
            -- 无真人分配：单人模式下作为 AI 对手
            g.isAI = true
            local lv = self.aiDifficulty or (TetrisConfig.AI and TetrisConfig.AI.DefaultDifficulty) or "Normal"
            local lvl = (TetrisConfig.AI and TetrisConfig.AI.DifficultyLevels) or {}
            g.aiQuality = (lvl[lv] and lvl[lv].Quality) or 1.0
        else
            g.isAI = false
        end
        ::continue::
    end
    -- 重新互设对手（环形互指，顺序不变）
    if #self.list > 1 then
        for i, g in ipairs(self.list) do
            g.opponent = self.list[i % #self.list + 1]
        end
    end
end

-- 根据各盘对手类型，刷新远景背景挂件内图片子控件(正方形 29)的图：真人/简单/普通/困难 各一张。
-- 控件/玩家未就绪时自动重试若干次（与 WidgetComponent 控件初始化时机保持一致）。
function TetrisMatch:RefreshBackgroundOpponentImages()
    local cfg = TetrisConfig.BackgroundWidget
    if not (cfg and cfg.Enabled and cfg.ImageChildName and cfg.OpponentImages) then return end
    if not self._bgWidgets then return end
    local pending = {}
    for i, g in ipairs(self.list) do
        local actor = self._bgWidgets[i]
        local opp = g and g.opponent
        if actor and opp then
            -- 对手类型：有 playerState = 真人；否则为 AI，难度取对手自身 aiDifficulty，缺失回退 match 级难度
            local kind
            if opp.playerState then
                kind = "Human"
            else
                kind = (opp.aiDifficulty)
                    or self.aiDifficulty
                    or (TetrisConfig.AI and TetrisConfig.AI.DefaultDifficulty)
                    or "Normal"
            end
            local key = cfg.OpponentImages[kind]
            if key then
                local imgID = (type(AssetRef) == "table" and AssetRef[key]) or key
                pending[#pending + 1] = { actor = actor, name = cfg.ImageChildName, imgID = imgID }
            end
        end
    end
    if #pending > 0 then self:_applyBgOpponentImages(pending, 0) end
end

function TetrisMatch:_applyBgOpponentImages(pending, tries)
    if not pending or #pending == 0 then return end
    local remain = {}
    for _, p in ipairs(pending) do
        local ok = false
        pcall(function() ok = TetrisBackgroundWidget.SetChildImage(p.actor, p.name, p.imgID) end)
        if not ok then remain[#remain + 1] = p end
    end
    if #remain > 0 and tries < 10 then
        self.owner:AddTimerOnce(0.3, function()
            self:_applyBgOpponentImages(remain, tries + 1)
        end)
    end
end

-- 构建棋盘并启动分阶段构建（落方块延后到 loading 隐藏后，由 TryStartGameplay 触发）。
function TetrisMatch:BuildGames()
    self._buildGamesStarted = true  -- 进入加载构建：停止准备阶段挂件重试，改由本函数兜底
    local M = TetrisConfig.GameMode
    local defaultSkill = (TetrisConfig.SkillSelect and TetrisConfig.SkillSelect.DefaultSkill) or "SK02"
    local reusedAll = true  -- 是否全部复用既有实例（重开）
    for i, g in ipairs(self.list) do
        -- 分配到玩家的盘 → 用该玩家所选玩法；旁观盘 → 用默认/强制玩法
        local mode = g.playerState and (self.choices[g.playerState] or M.Tetris) or self:initialMode()
        if g.renderer then
            -- 已构建过（重开复用）：不新建实例、不重建渲染器，仅刷新属性并保留既有挂件/渲染器
            reusedAll = reusedAll and true
            g.selectedSkill = (g.playerState and self.skillChoices and self.skillChoices[g.playerState]) or defaultSkill
            if not g.playerState then
                -- 无真人分配：单人模式下作为 AI 对手
                g.isAI = true
                local lv = self.aiDifficulty or (TetrisConfig.AI and TetrisConfig.AI.DefaultDifficulty) or "Normal"
                local lvl = (TetrisConfig.AI and TetrisConfig.AI.DifficultyLevels) or {}
                g.aiQuality = (lvl[lv] and lvl[lv].Quality) or 1.0
            else
                g.isAI = false
            end
        else
            -- 首次构建：用正确模式重建实例（保留出生点/分配/序号），避免俄罗斯方块占位被直接 Start
            reusedAll = false
            local ng = self:createGame(mode, g.spawnPointKey, g.index)
            ng.playerState = g.playerState
            ng.playerKey = g.playerKey
            ng.opponent = g.opponent
            ng.avatarKey = g.avatarKey   -- 沿用 Start()/AssignAvatars 已随机分配的头像（BuildGames 会替换实例，否则头像丢失）
            -- 沿用 match 级 AI 难度（对手标识图等需按难度区分的地方要用到）；缺省回退 DefaultDifficulty
            ng.aiDifficulty = self.aiDifficulty or (TetrisConfig.AI and TetrisConfig.AI.DefaultDifficulty) or "Normal"
            -- 所选技能：分配到玩家的盘取该玩家所选，否则回退默认技能
            ng.selectedSkill = (g.playerState and self.skillChoices and self.skillChoices[g.playerState])
                or defaultSkill
            -- 背后 3D UI 挂件（解耦于 renderer，归 Match 持有 self._behindWidgets）：
            -- Init 已基于出生点尝试生成（可能因装置/资源未就绪失败）；此处（OnModeSelected 已就绪）兜底补一次。
            -- 仅 tetris 渲染器(有 BuildBehindBoardWidget)挂接；puyo 盘不挂接并销毁已生成的 widget，保持原语义。
            local bwSupports = ng.renderer and type(ng.renderer.BuildBehindBoardWidget) == "function"
            if bwSupports then
                if not self._behindWidgets[i] then
                    self._behindWidgets[i] = TetrisBehindWidget.Spawn(g.spawnPointKey, g.index)
                end
                ng.renderer._behindWidgetActor = self._behindWidgets[i] or nil
            elseif self._behindWidgets[i] then
                pcall(function()
                    if type(self._behindWidgets[i].K2_DestroyActor) == "function" then
                        self._behindWidgets[i]:K2_DestroyActor()
                    end
                end)
                self._behindWidgets[i] = nil
            end
            -- 远景背景 3D UI（背景图）：兜底补生成（Init 未就绪时）。纯背景、不挂接 renderer，
            -- 每个棋盘各 1 个，已生成则跳过（幂等）。
            if TetrisConfig.BackgroundWidget and TetrisConfig.BackgroundWidget.Enabled then
                if not self._bgWidgets then self._bgWidgets = {} end
                if not self._bgWidgets[i] then
                    self._bgWidgets[i] = TetrisBackgroundWidget.Spawn(g.spawnPointKey, g.index)
                end
            end
            self.list[i] = ng
            if g.playerKey then self.games[g.playerKey] = ng end
            local ok = ng:Init(g.spawnPointKey)
            if not ok then
                print(string.format("[Tetris][Versus][WARN] 棋盘#%d 玩法=%s 初始化失败（出生点未注入？）",
                    tostring(g.index), tostring(mode)))
            end
        end
    end
    -- 重新互设对手（环形互指，顺序不变）
    if #self.list > 1 then
        for i, g in ipairs(self.list) do
            g.opponent = self.list[i % #self.list + 1]
        end
    end
    self:RefreshBackgroundOpponentImages()   -- 按对手类型刷新远景背景挂件内"正方形 29"标识图
    if reusedAll then
        -- 全部复用既有实例与渲染器：无需分阶段构建，直接标记边框完成并交由 TryStartGameplay 开局
        self._borderDone = true
        print("[Tetris][Versus] 复用既有实例与渲染器，跳过分阶段构建（不新建实例）")
        self:TryStartGameplay()
    else
        -- 首次构建：启动分阶段构建状态机（生成 4*7*2 子块 → 设置 14 整体 → 方框 → 静态池 400）。
        self._build = { phase = "genChildren", childTarget = 4 * 7 * 2, staticTarget = 400,
                        childAttempts = 0, borderAttempts = 0, setupTries = 0 }
        self:StepBuild()
        print("[Tetris][Versus] 分阶段构建启动")
    end
end

-- 分阶段构建状态机：genChildren → setupPieces(≤3次) → genBorder → genStatic(0.25s/个)。
-- 关键修复：每个阶段动作完成后都必须挂下一个定时器，否则会卡死在某阶段不前进。
-- 这里用尾部统一自调度（非终态则按阶段 delay 续跑），不再依赖分支各自挂定时器。
function TetrisMatch:StepBuild()
    local b = self._build
    if not b or b.phase == "done" then return end
    local renderers = {}
    for _, g in ipairs(self.list) do if g.renderer then renderers[#renderers + 1] = g.renderer end end
    if #renderers == 0 then return end

    local totalChildren, allActiveOk, allBorderOk, totalStatic = 0, true, true, 0
    for _, r in ipairs(renderers) do
        totalChildren = totalChildren + r:PieceChildCount()
        if not r:ActivePiecesComplete() then allActiveOk = false end
        if not r:BorderDone() then allBorderOk = false end
        totalStatic = totalStatic + #r.pool
    end

    if b.phase == "genChildren" then
        for _, r in ipairs(renderers) do pcall(function() r:GenPieceChildren() end) end
        b.childAttempts = (b.childAttempts or 0) + 1
        if totalChildren >= b.childTarget or b.childAttempts > 8 then
            b.phase = "setupPieces"; b.setupTries = 0
            print(string.format("[Tetris][Build] 子块生成 %d/%d，进入设置阶段", totalChildren, b.childTarget))
        end

    elseif b.phase == "setupPieces" then
        b.setupTries = (b.setupTries or 0) + 1
        for _, r in ipairs(renderers) do pcall(function() r:SetupPieceRoots() end) end
        if allActiveOk or b.setupTries >= 3 then
            b.phase = "genBorder"
            print(string.format("[Tetris][Build] 14 个活动方块设置完成（第%d次），进入方框阶段", b.setupTries))
        end

    elseif b.phase == "genBorder" then
        for _, r in ipairs(renderers) do pcall(function() r:GenBorder() end) end
        b.borderAttempts = (b.borderAttempts or 0) + 1
        if allBorderOk or b.borderAttempts > 25 then
            b.phase = "genStatic"
            self._borderDone = true
            print(string.format("[Tetris][Build] 方框生成 %s，进入静态池阶段", allBorderOk and "完成" or "超时"))
            self:TryStartGameplay()  -- 若 loading 已到时则隐藏+开局；否则等 loading
        end

    elseif b.phase == "genStatic" then
        for _, r in ipairs(renderers) do pcall(function() r:GenStaticOne() end) end
        if totalStatic >= b.staticTarget then
            b.phase = "done"
            print(string.format("[Tetris][Build] 静态池 %d/%d 达标，分阶段构建完成", totalStatic, b.staticTarget))
        end
    end

    -- 尾部统一自调度：非终态必挂下一个 StepBuild（生成/轮询阶段 0.2s，静态池 0.25s/个）。
    if b.phase ~= "done" then
        local delay = (b.phase == "genStatic") and 0.25 or 0.2
        self.owner:AddTimerOnce(delay, function() self:StepBuild() end)
    end
end

-- 尝试开局落方块：仅在 loading 已到时 且 方框已生成完 后执行一次（隐藏 loading + 各盘 Start）。
function TetrisMatch:TryStartGameplay()
    if self._started then return end
    if not self._loadingTimeUp then return end
    if not self._borderDone then return end
    self._started = true
    self:ShowLoading(false)

    -- 单人/双人判定：用"可操作 pawn 数"判定真人（比 GetAllPlayerStates():Num() 更准，
    -- 单人环境引擎可能多报一个无 pawn 的 PlayerState）。真人 <2 => 单人（多余盘作 AI 对手）；
    -- >=2 => 双人（正常对战）。盘面恒为 2（spawnKeys 配 2 个出生点）。
    local stateCount, pawnCount = 0, 0
    local okS, pstates = pcall(function() return Game:GetAllPlayerStates() end)
    if okS and pstates then
        local okN, n = pcall(function() return pstates:Num() end)
        if okN and type(n) == "number" then stateCount = n end
    end
    local okP, parrs = pcall(function() return Game:GetAllPlayerPawns() end)
    if okP and parrs then
        local okN, n = pcall(function() return parrs:Num() end)
        if okN and type(n) == "number" then pawnCount = n end
    end
    local realPlayers = (pawnCount > 0) and pawnCount or stateCount
    local isSingle = realPlayers < 2
    print(string.format("[Tetris][Versus] 模式=%s（盘面数=%d）",
        isSingle and "单人(AI对手)" or "双人", #self.list))

    for _, g in ipairs(self.list) do
        if g.playerState then
            g:Start()
        else
            -- 无真人分配：单人模式下作为 AI 对手（双人模式两盘都已分配真人，不会走到这）
            g.isAI = true
            -- 应用玩家在 AiPanel 选的难度（缺省回退 DefaultDifficulty），落到 AI 盘落子质量
            local lv = self.aiDifficulty or (TetrisConfig.AI and TetrisConfig.AI.DefaultDifficulty) or "Normal"
            local lvl = (TetrisConfig.AI and TetrisConfig.AI.DifficultyLevels) or {}
            g.aiQuality = (lvl[lv] and lvl[lv].Quality) or 1.0
            g:Start()
        end
    end
    self:StartMatchTimer()
    print("[Tetris][Versus] 对局开始（loading 隐藏后）")
end

-- ---------------- Loading 加载界面控制 ----------------
-- 显隐 Loading 控件（对全部已分配玩家；无分配时退化为全部在线玩家）。
function TetrisMatch:ShowLoading(visible)
    local id = TetrisConfig.LoadingScreen
    if not id or type(CustomUIAPI) ~= "table" then
        print("[Tetris][Loading] 未配置 LoadingScreen 或 CustomUIAPI 未注入，跳过")
        return
    end
    local list = self.assigned or {}
    if #list == 0 then
        local ok, arr = pcall(function() return Game:GetAllPlayerStates() end)
        if ok and arr and arr.Num then
            local t = {}
            for i = 0, arr:Num() - 1 do local ps = arr:Get(i); if ps then t[#t + 1] = ps end end
            list = t
        end
    end
    local pid = TetrisConfig.LoadingProgress
    for _, ps in ipairs(list) do
        pcall(function() CustomUIAPI.SetWidgetVisible(ps, id, visible) end)
        if pid then pcall(function() CustomUIAPI.SetWidgetVisible(ps, pid, visible) end) end
    end
    print(string.format("[Tetris][Loading] %s -> %d 名玩家", visible and "显示" or "隐藏", #list))
    -- 进度条：显示时先归零，延迟 0.5s 再启动 LoadingTime 秒填充动画（让 loading 先渲染出来）；隐藏时停止动画并归零。
    -- 幂等：已在显示中则不打断/不重启动画，避免 Start()/OnModeSelected() 被重复触发时进度动画启动多次。
    if visible then
        -- 选完技能后显示的 HUD：与 loading 一并显示给全体真人（幂等；仅控制显示，不在隐藏 loading 时关闭）
        local hud = TetrisConfig.ShowHudAfterSkill
        if type(hud) == "table" and type(CreativeInstance) == "table" then
            for _, key in ipairs(hud) do
                local hid = CreativeInstance[key]
                if hid ~= nil then
                    for _, ps in ipairs(list) do
                        pcall(function() CustomUIAPI.SetWidgetVisible(ps, hid, true) end)
                    end
                end
            end
        end
        if self._loadingVisible then return end
        self._loadingVisible = true
        for _, ps in ipairs(list) do self:SetLoadingProgress(ps, 0) end
        local selfRef = self
        self.owner:AddTimerOnce(0.5, function()
            if selfRef._loadingVisible then selfRef:StartLoadingProgress(TetrisConfig.LoadingTime) end
        end)
    else
        self._loadingVisible = false
        self:StopLoadingProgress()
        for _, ps in ipairs(list) do self:SetLoadingProgress(ps, 0) end
        -- 进入开局阶段后：技能/玩法选择界面随 loading 一起隐藏；
        -- 开局前(初始 10s 超时)的选择界面不动，由 _enteredGame 守卫。
        if self._enteredGame then
            if self.skillSelect then self.skillSelect:ShowAll(false) end
            if self.modeSelect then self.modeSelect:ShowUI(false) end
        end
    end
end

-- 设置单个玩家进度条值（0~100）。引擎真实接口：SetProgressBarWidgetValue（另可设 Min/Max）。
function TetrisMatch:SetLoadingProgress(ps, value)
    local id = TetrisConfig.LoadingProgress
    if not id or not ps or type(CustomUIAPI) ~= "table" then return end
    pcall(function()
        CustomUIAPI.SetProgressBarWidgetMaxValue(ps, id, 100)
        CustomUIAPI.SetProgressBarWidgetMinValue(ps, id, 0)
        CustomUIAPI.SetProgressBarWidgetValue(ps, id, value)
    end)
end

-- 进度条动画：durationSec 秒内从 0 填充到 100%，每 0.5s 刷新一次。
-- 用 _progressGen 令牌杀死旧动画：每次(重新)启动或停止都自增，tick 只在属于自己的 gen 下才继续，
-- 避免“旧动画未停又启动新动画”导致进度条来回弹。
function TetrisMatch:StartLoadingProgress(durationSec)
    durationSec = durationSec or TetrisConfig.LoadingTime
    self._progressGen = (self._progressGen or 0) + 1
    local myGen = self._progressGen
    local selfRef = self
    local step = 0.5
    local elapsed = 0
    local function tick()
        if selfRef._progressGen ~= myGen then return end  -- 已被新动画/停止取代，旧链自然死亡
        elapsed = elapsed + step
        local pct = math.min(100, math.floor(elapsed / durationSec * 100 + 0.5))
        local list = selfRef.assigned or {}
        if #list == 0 then
            local ok, arr = pcall(function() return Game:GetAllPlayerStates() end)
            if ok and arr and arr.Num then
                local t = {}
                for i = 0, arr:Num() - 1 do local ps = arr:Get(i); if ps then t[#t + 1] = ps end end
                list = t
            end
        end
        for _, ps in ipairs(list) do selfRef:SetLoadingProgress(ps, pct) end
        if elapsed < durationSec then
            selfRef.owner:AddTimerOnce(step, tick)
        end
    end
    self.owner:AddTimerOnce(step, tick)
    print(string.format("[Tetris][Loading] 进度条动画启动（%ds 填充）", durationSec))
end

-- 中止进度条动画（loading 隐藏时调用）：自增令牌，使所有进行中的 tick 自然死亡。
function TetrisMatch:StopLoadingProgress()
    self._progressGen = (self._progressGen or 0) + 1
end

-- 是否存在 AI 托管的盘（用于单人模式 FreeLook / 相机判断）
function TetrisMatch:hasAI()
    for _, g in ipairs(self.list) do
        if g.isAI then return true end
    end
    return false
end

-- 输入路由：所有玩家共用同一套 CustomUI 按钮（相同 InstanceUUID），
-- 点击回调由引擎带上「点击者 PlayerState」，据此找到其所属实例并派发对应操作。
function TetrisMatch:RegisterInput()
    local ui = TetrisConfig.UI
    local id     = (type(RcEventIdDefine) == "table" and RcEventIdDefine.CustomUIClicked) or 120000
    local idLong = (type(RcEventIdDefine) == "table" and RcEventIdDefine.CustomUILongPressed) or 120001
    local idRel  = (type(RcEventIdDefine) == "table" and RcEventIdDefine.CustomUILongPressReleased) or 120002
    local selfRef = self
    -- 路由闭包：引擎调用约定为 cb(registeredSelf, eventOutput1, ...)，eventOutput1 = 点击者 PlayerState
    local function route(action)
        return function(_self, ps)
            local key = playerKeyOf(ps)
            local g = selfRef.games[key]
            if g then
                local fn = g["OnBtn" .. action]
                if fn then fn(g) end
            end
        end
    end
    local binds = {
        { ui.BtnLeft,  "Left" },
        { ui.BtnRight, "Right" },
        { ui.BtnRoll,  "Roll" },
        { ui.BtnDown,  "Down" },
        { ui.BtnHold,  "Hold" },
        { ui.BtnSkill, "Skill" },
    }
    for _, b in ipairs(binds) do
        if b[1] ~= nil then
            self.owner:AddVPEvent(id, route(b[2]), selfRef, b[1], nil)
        end
    end
    -- 左右键长按：长按进入连发（DAS/ARR），抬起停止；下键长按 = 软降
    local holdBinds = {
        { ui.BtnLeft,  "LeftHold" },
        { ui.BtnRight, "RightHold" },
        { ui.BtnLeft,  "LeftRelease" },
        { ui.BtnRight, "RightRelease" },
        { ui.BtnDown,  "DownHold" },
        { ui.BtnDown,  "DownRelease" },
    }
    for _, b in ipairs(holdBinds) do
        if b[1] ~= nil then
            local evt = (string.find(b[2], "Release") and idRel) or idLong
            self.owner:AddVPEvent(evt, route(b[2]), selfRef, b[1], nil)
        end
    end
    print("[Tetris][Versus] 输入路由已注册（" .. #binds .. " 个按钮 + 左右长按）")
end

-- 某玩家顶出 → 对手获胜，整局结束
function TetrisMatch:OnPlayerOut(loser)
    if self.over then return end
    local winner = loser.opponent
    self.winner = winner
    -- 胜负 + 分数上报从「弹窗前」改到「点击结束游戏按钮时」执行（见 RegisterExitBtn），
    -- 这里只记录胜者并弹结算面板。
    self:EndMatch("lose", false)
end

-- 把胜负与分数上报给引擎，让官方结算/排名/MVP 知道结果。
-- 队伍 ID 用各棋盘的 index（稳定唯一、重建实例也保留）；只上报有真人 PlayerState 的队伍（AI 盘无 PlayerState，跳过）。
-- OutcomeType 取值见 TetrisConfig.Settle.OutcomeType（引擎桩未给枚举，需平台确认）。
function TetrisMatch:ReportOutcome(winner, loser)
    local cfg = TetrisConfig.Settle
    if not (cfg and cfg.ReportOutcome) then return end
    if type(GameOutcomeAPI) ~= "table" or type(GameOutcomeAPI.SetTeamRoundOutcome) ~= "function" then
        print("[Tetris][Outcome][WARN] GameOutcomeAPI.SetTeamRoundOutcome 不可用，跳过引擎胜负上报")
        return
    end
    local O = cfg.OutcomeType or { Win = 1, Lose = 2, Draw = 3 }
    for _, g in ipairs(self.list) do
        if g.playerState then
            -- 取玩家真实队伍 ID（PlayerAPI.GetPlayerTeamID）；取不到则回退棋盘 index
            local teamID
            pcall(function()
                if type(PlayerAPI) == "table" and type(PlayerAPI.GetPlayerTeamID) == "function" then
                    teamID = PlayerAPI.GetPlayerTeamID(g.playerState)
                end
            end)
            if type(teamID) ~= "number" then teamID = g.index end
            local outcome = (g == winner) and O.Win or (g == loser) and O.Lose or O.Draw
            local endFighting = (g == winner)   -- 胜者那次结束本轮战斗
            pcall(function() GameOutcomeAPI.SetTeamRoundOutcome(teamID, outcome, endFighting) end)
            print(string.format("[Tetris][Outcome] 队伍#%d → outcome=%s endFighting=%s",
                tostring(teamID), tostring(outcome), tostring(endFighting)))
        end
    end
    -- 分数推给引擎战斗数据（影响官方排名 / 结算面板）
    if type(BattleDataAPI) == "table" and type(BattleDataAPI.SetPlayerIntegral) == "function" then
        for _, g in ipairs(self.list) do
            if g.playerState and g.board then
                pcall(function() BattleDataAPI.SetPlayerIntegral(g.playerState, g.board.score or 0) end)
            end
        end
    end
end

-- 取全体玩家 PlayerState（用于给所有人弹结算）
function TetrisMatch:AllPlayerStates()
    local out = {}
    local ok, arr = pcall(function() return Game:GetAllPlayerStates() end)
    if ok and arr and arr.Num then
        for i = 0, arr:Num() - 1 do
            local ps = arr:Get(i)
            if ps then out[#out + 1] = ps end
        end
    end
    return out
end

-- 整局结束：停所有棋盘 + 弹结算面板；early=true 时额外调用「结束游戏」API
function TetrisMatch:EndMatch(reason, early)
    self.over = true
    -- for _, g in ipairs(self.list) do
    --     if g.running then g:Stop() end
    -- end
    self:ShowSettle(reason)
    -- if early then self:CallEndGameAPI() end
    -- print(string.format("[Tetris][Versus] 结算 reason=%s early=%s 胜者=%s",
    --     tostring(reason), tostring(early),
    --     self.winner and tostring(self.winner.playerKey) or "?"))
end

-- 取某盘面在结算界面应显示的称号：
-- 玩家盘 → 玩家显示名（PlayerState.PlayerName 只读字段）；AI 盘 → 按难度取 AI 角色名（见 TetrisConfig.AI.DifficultyLevels[lv].Name）。
function TetrisMatch:GameDisplayName(g)
    if g and g.playerState then
        local nm = nil
        pcall(function() nm = g.playerState.PlayerName end)
        if type(nm) == "string" and nm ~= "" then return nm end
        return tostring(g.playerKey or "玩家")
    end
    -- AI 盘：按当前难度取角色名（Easy=小白 / Normal=强敌 / Hard=大师）
    local cfg = TetrisConfig.AI or {}
    local lv = self.aiDifficulty or cfg.DefaultDifficulty or "Normal"
    local lvl = cfg.DifficultyLevels or {}
    return (lvl[lv] and lvl[lv].Name) or lv
end

-- 开局随机分配头像：先把 AvatarPresets 去重、洗牌，再对所有棋盘（含 AI 盘）轮转分配。
-- 真人 / AI 都从这里取头像；2 名玩家时保证双方头像值不同（去重后按棋盘序号轮转，互不重复）。
function TetrisMatch:AssignAvatars()
    local cfg = TetrisConfig.AvatarUI
    if not cfg or not cfg.AvatarPresets or #cfg.AvatarPresets == 0 then return end
    -- 去重：避免池中重复图导致两盘分到同一张头像（保证「双方不同」）
    local seen = {}
    local uniq = {}
    for _, p in ipairs(cfg.AvatarPresets) do
        if not seen[p] then seen[p] = true; uniq[#uniq + 1] = p end
    end
    local pool = {}
    for _, p in ipairs(uniq) do pool[#pool + 1] = p end
    for i = #pool, 2, -1 do
        local j = math.random(i)
        pool[i], pool[j] = pool[j], pool[i]
    end
    -- 对所有棋盘（含 AI 盘）轮转分配：2 盘 + 去重后 >=2 张时双方必然不同；盘数超过池大小才会重复
    for i, g in ipairs(self.list) do
        g.avatarKey = pool[(i - 1) % #pool + 1]
    end
end

-- 给全体玩家弹出结算面板，分 3 个文本显示：玩家A分数 / 玩家B分数 / 胜者
function TetrisMatch:ShowSettle(reason)
    local cfg = TetrisConfig.Settle
    if not (cfg and cfg.Enabled) then return end
    if type(CustomUIAPI) ~= "table" then return end

    -- 按 index 取玩家1(index=0)/玩家2(index=1) 的分数与称号；同时算最高分为兜底胜者
    local p1Score, p2Score = 0, 0
    local p1Name, p2Name = "?", "?"
    local best, bestName = nil, nil
    for _, g in ipairs(self.list) do
        local score = (g.board and g.board.score) or 0
        local name = self:GameDisplayName(g)
        if g.index == 1 then
            p2Score = score; p2Name = name
        else
            p1Score = score; p1Name = name   -- index 0（或缺失）按玩家1
        end
        if best == nil or score > best then best, bestName = score, name end
    end
    local winnerName
    if reason == "lose" and self.winner then
        winnerName = self:GameDisplayName(self.winner)
    else
        winnerName = bestName
    end
    local winnerTxt = "胜者: " .. tostring(winnerName or "?")

    for _, ps in ipairs(self:AllPlayerStates()) do
        if cfg.PanelKey then
            pcall(function() CustomUIAPI.SetWidgetVisible(ps, cfg.PanelKey, true) end)
        end
        if cfg.P1Score then
            pcall(function() CustomUIAPI.SetTextContent(ps, cfg.P1Score, p1Name .. " 分数: " .. tostring(p1Score)) end)
        end
        if cfg.P2Score then
            pcall(function() CustomUIAPI.SetTextContent(ps, cfg.P2Score, p2Name .. " 分数: " .. tostring(p2Score)) end)
        end
        if cfg.WinnerLabel then
            pcall(function() CustomUIAPI.SetTextContent(ps, cfg.WinnerLabel, winnerTxt) end)
        end
        if cfg.ExitBtn then
            pcall(function() CustomUIAPI.SetWidgetVisible(ps, cfg.ExitBtn, true) end)
        end
    end
    self:RegisterResetBtn()   -- 注册「重置游戏」按钮点击（仅一次）
    print("[Tetris][Settle] 结算面板已弹出 reason=" .. tostring(reason))
end

-- 结算界面「重置游戏」按钮（即原 ExitBtn 控件）：注册一次点击监听，
-- 点击后不清算/不退出对局，直接重置回「开始游戏」界面（见 ResetGame）。
function TetrisMatch:RegisterResetBtn()
    local cfg = TetrisConfig.Settle
    if not cfg or not cfg.ExitBtn then return end          -- 未配置按钮则不注册
    if self._exitBtnReg then return end                    -- 防重复注册
    self._exitBtnReg = true
    local owner = self.owner
    if not owner or type(owner.AddVPEvent) ~= "function" then return end
    local clickId = (type(RcEventIdDefine) == "table" and RcEventIdDefine.CustomUIClicked) or 120000
    local selfRef = self
    owner:AddVPEvent(clickId, function(_self, ps)
        -- 仅在对局已结束（结算面板已弹）时生效，避免对局中误触
        if not selfRef.over then return end
        print("[Tetris][Settle] 「重置游戏」按钮被点击（" .. tostring(ps) .. "），清空盘面并回到开始界面")
        selfRef:ResetGame()
    end, selfRef, cfg.ExitBtn, nil)
    print("[Tetris][Settle] 「重置游戏」按钮点击已注册")
end

-- 调用「结束游戏」API（提前触发结算时）。未配置则回退 Match.Stop()
function TetrisMatch:CallEndGameAPI()
    local fn = TetrisConfig.Settle and TetrisConfig.Settle.EndGameCall
    if type(fn) == "function" then
        local ok, err = pcall(fn, self)
        if not ok then print("[Tetris][Settle][WARN] EndGameCall 失败: " .. tostring(err)) end
    else
        pcall(function() self:Stop() end)
        print("[Tetris][Settle] 未配置 EndGameCall，回退 Match.Stop()（OnRoundEnd）")
    end
end

-- 对局时间上限计时：到点触发 timeup 结算
function TetrisMatch:StartMatchTimer()
    local sec = (TetrisConfig.Settle and TetrisConfig.Settle.TimeLimitSec) or 0
    if sec and sec > 0 then
        self.owner:AddTimerOnce(sec, function()
            if not self.over then self:EndMatch("timeup", false) end
        end)
        print("[Tetris][Versus] 对局限时 " .. tostring(sec) .. "s 已启动")
    end
end

-- 提前触发结算（供外部/调试按钮调用）：弹结算并调用「结束游戏」API
function TetrisMatch:TriggerEarlySettle()
    self:EndMatch("manual", true)
end

function TetrisMatch:Stop()
    for _, g in ipairs(self.list) do
        g:Stop()
    end
    print("[Tetris][Versus] Match.Stop")
end

-- 结算界面「重置游戏」按钮：不清算/不退出对局，而是清空所有盘面并暂停下落，
-- 回到「开始游戏」界面，等待玩家点击开始 → 技能选择 → 重新开局。
function TetrisMatch:ResetGame()
    local cfg = TetrisConfig.Settle
    local players = self:AllPlayerStates()
    if type(CustomUIAPI) == "table" then
        for _, ps in ipairs(players) do
            if cfg and cfg.PanelKey then pcall(function() CustomUIAPI.SetWidgetVisible(ps, cfg.PanelKey, false) end) end
            if cfg and cfg.ExitBtn  then pcall(function() CustomUIAPI.SetWidgetVisible(ps, cfg.ExitBtn, false) end) end
            -- 隐藏上一局的对局内 HUD（随 loading 显示的 HUD），避免堆在开始界面上
            for _, key in ipairs(TetrisConfig.ShowHudAfterSkill or {}) do
                local hid = (type(CreativeInstance) == "table" and CreativeInstance[key]) or nil
                if hid ~= nil then pcall(function() CustomUIAPI.SetWidgetVisible(ps, hid, false) end) end
            end
        end
    end
    -- 逐个盘面：清空 / 暂停下落 / 重置能量（立即清屏；重开局时 BuildGames 会重建新实例）
    for _, g in ipairs(self.list) do
        if type(g.Reset) == "function" then g:Reset() end
    end
    -- 清对局结束态，允许再次结算
    self.over = false
    self.winner = nil
    -- 标记「重开」：下次进入 OnModeSelected 时复用已生成的实例与渲染器，不再新建/重建
    self._restart = true
    -- 重新显示「开始游戏」界面（StartPanel + StartBtn），点击开始 → 技能选择 → 重新开局
    -- 之后流程会再次走 OnModeSelected（重置 _started/_loadingTimeUp/_borderDone），可正常重开局
    if self.skillSelect then
        self.skillSelect:Begin(self.assigned or {})
    end
    print("[Tetris][Settle] 已重置游戏，回到开始界面")
end

return TetrisMatch
