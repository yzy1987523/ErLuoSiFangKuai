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
end

-- 开局：枚举在场玩家 → 分配棋盘 → 互设对手 → 注册输入 → 玩法选择阶段（选完传送+开局）
function TetrisMatch:Start()
    -- 枚举在场玩家，并配对其 pawn 世界坐标（米），用于按"实际站位"分配棋盘。
    -- GetAllPlayerStates / GetAllPlayerPawns 同序：第 i 个玩家态 ↔ 第 i 个 pawn。
    local players = {}   -- { ps = PlayerState, locM = {X,Y,Z} 米 | nil }
    local okS, arr = pcall(function() return Game:GetAllPlayerStates() end)
    local okP, parr = pcall(function() return Game:GetAllPlayerPawns() end)
    if okS and arr and arr.Num then
        for i = 0, arr:Num() - 1 do
            local ps = arr:Get(i)
            if ps then
                local locM = nil
                local pawn = (okP and parr and parr.Num and parr:Num() > i) and parr:Get(i) or nil
                if pawn and pawn.K2_GetActorLocation then
                    local okL, lc = pcall(function() return pawn:K2_GetActorLocation() end)
                    if okL and lc and lc.X then
                        locM = { X = lc.X / 100, Y = lc.Y / 100, Z = lc.Z / 100 }  -- 厘米→米
                    end
                end
                players[#players + 1] = { ps = ps, locM = locM }
            end
        end
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
    for _, p in ipairs(players) do if not p.locM then allHaveLoc = false end end

    local function dist2(a, b)
        if not a or not b then return nil end
        return (a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2
    end

    -- 分配：优先按"站在哪个出生装置前 → 控制哪块盘"（解决玩家序与装置序不一致导致的反盘）；
    -- 任一坐标缺失时退化为顺序分配（第 i 个玩家 → 第 i 个棋盘）。
    if #players > 0 and haveAll and allHaveLoc then
        local taken = {}
        for _, p in ipairs(players) do
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
            local p = players[i]
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

    -- 输入路由：每个按钮注册一次，按点击者 PlayerState 分发（避免每个实例重复注册互相覆盖）
    self:RegisterInput()

    -- 存下已分配玩家，供技能选择结束后继续玩法选择使用
    self.assigned = assigned

    -- 初始 Loading：打开游戏即显示，10 秒后自动隐藏（露出技能选择界面）。
    -- _enteredGame 标记是否已进入“选技能后的开局阶段”；进入后 10 秒超时隐藏不再生效，
    -- 改由“对象生成完成”逻辑隐藏（见 OnSkillSelected）。
    self._enteredGame = false
    self:ShowLoading(true)
    self.owner:AddTimerOnce(10, function()
        if not self._enteredGame then
            self:ShowLoading(false)
            print("[Tetris][Loading] 初始 10 秒超时，隐藏 loading")
        end
    end)

    -- 技能选择阶段（开局前置）：先用 UI 选技能 → 选完 → 再进入玩法选择 / 直接开局。
    -- 选择按钮未放置时（占位/未注入）自动跳过，使用默认技能。
    self.skillSelect = TetrisSkillSelect:new(self.owner, self)
    self.skillSelect:Begin(assigned)
end

-- 技能选择结束（或跳过）：按各玩家所选技能记录后，进入玩法选择（若启用）或直接开局。
-- skillChoices: [PlayerState] = 技能 key（如 "SK01"）。未选择则回退默认技能。
function TetrisMatch:OnSkillSelected(skillChoices)
    self.skillChoices = skillChoices or {}
    -- 选完技能：进入开局阶段（_enteredGame 让初始 10s 超时隐藏失效）。
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
    -- 显示 loading（10s 进度条）。分阶段构建在 loading 显示期间立即开始进行；
    -- 10s 到时并不立即隐藏，而是等方框生成完后才隐藏并开局落方块（见 TryStartGameplay）。
    self._loadingTimeUp = false
    self._borderDone = false
    self._started = false
    self:ShowLoading(true)
    local selfRef = self
    self.owner:AddTimerOnce(10, function()
        selfRef._loadingTimeUp = true
        selfRef:TryStartGameplay()   -- loading 到时：若方框已生成完则隐藏+开局；否则等方框
    end)
    -- 延迟 1 秒再开始分阶段构建（利用 loading 显示窗口；延后启动避免与开局时序冲突）。
    self.owner:AddTimerOnce(0.5, function() self:BuildGames() end)
end

-- 构建棋盘并启动分阶段构建（落方块延后到 loading 隐藏后，由 TryStartGameplay 触发）。
function TetrisMatch:BuildGames()
    local M = TetrisConfig.GameMode
    for i, g in ipairs(self.list) do
        -- 分配到玩家的盘 → 用该玩家所选玩法；旁观盘 → 用默认/强制玩法
        local mode = g.playerState and (self.choices[g.playerState] or M.Tetris) or self:initialMode()
        -- 用正确模式重建实例（保留出生点/分配/序号），避免俄罗斯方块占位被直接 Start
        local ng = self:createGame(mode, g.spawnPointKey, g.index)
        ng.playerState = g.playerState
        ng.playerKey = g.playerKey
        ng.opponent = g.opponent
        -- 所选技能：分配到玩家的盘取该玩家所选，否则回退默认技能
        ng.selectedSkill = (g.playerState and self.skillChoices and self.skillChoices[g.playerState])
            or (TetrisConfig.SkillSelect and TetrisConfig.SkillSelect.DefaultSkill) or "SK02"
        self.list[i] = ng
        if g.playerKey then self.games[g.playerKey] = ng end
        local ok = ng:Init(g.spawnPointKey)
        if not ok then
            print(string.format("[Tetris][Versus][WARN] 棋盘#%d 玩法=%s 初始化失败（出生点未注入？）",
                tostring(g.index), tostring(mode)))
        end
    end
    -- 重新互设对手：上面的重建替换了实例，旧 opponent 链接已指向被替换的对象
    if #self.list > 1 then
        for i, g in ipairs(self.list) do
            g.opponent = self.list[i % #self.list + 1]
        end
    end
    -- 启动分阶段构建状态机（生成 4*7*2 子块 → 设置 14 整体 → 方框 → 静态池 400）。
    self._build = { phase = "genChildren", childTarget = 4 * 7 * 2, staticTarget = 400,
                    childAttempts = 0, borderAttempts = 0, setupTries = 0 }
    self:StepBuild()
    print("[Tetris][Versus] 分阶段构建启动")
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
    for _, g in ipairs(self.list) do
        if g.playerState then
            g:Start()
        elseif TetrisConfig.AI and TetrisConfig.AI.Enabled then
            g.isAI = true
            g:Start()
        else
            g:StartSpectator()
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
    -- 进度条：显示时先归零，延迟 0.5s 再启动 10s 填充动画（让 loading 先渲染出来）；隐藏时停止动画并归零。
    -- 幂等：已在显示中则不打断/不重启动画，避免 Start()/OnModeSelected() 被重复触发时进度动画启动多次。
    if visible then
        if self._loadingVisible then return end
        self._loadingVisible = true
        for _, ps in ipairs(list) do self:SetLoadingProgress(ps, 0) end
        local selfRef = self
        self.owner:AddTimerOnce(0.5, function()
            if selfRef._loadingVisible then selfRef:StartLoadingProgress(10) end
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
    durationSec = durationSec or 10
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

-- 给全体玩家弹出结算面板，分 3 个文本显示：玩家1分数 / 玩家2分数 / 胜者ID
function TetrisMatch:ShowSettle(reason)
    local cfg = TetrisConfig.Settle
    if not (cfg and cfg.Enabled) then return end
    if type(CustomUIAPI) ~= "table" then return end

    -- 按 index 取玩家1(index=0)/玩家2(index=1) 分数；同时算最高分为兜底胜者
    local p1Score, p2Score = 0, 0
    local best, bestKey = nil, nil
    for _, g in ipairs(self.list) do
        local score = (g.board and g.board.score) or 0
        if g.index == 1 then p2Score = score
        else p1Score = score end   -- index 0（或缺失）按玩家1
        if best == nil or score > best then best, bestKey = score, g.playerKey end
    end
    local winnerKey
    if reason == "lose" and self.winner then
        winnerKey = self.winner.playerKey
    else
        winnerKey = bestKey
    end
    local winnerTxt = "胜者: " .. tostring(winnerKey or "?")

    for _, ps in ipairs(self:AllPlayerStates()) do
        if cfg.PanelKey then
            pcall(function() CustomUIAPI.SetWidgetVisible(ps, cfg.PanelKey, true) end)
        end
        if cfg.P1Score then
            pcall(function() CustomUIAPI.SetTextContent(ps, cfg.P1Score, "玩家1 分数: " .. tostring(p1Score)) end)
        end
        if cfg.P2Score then
            pcall(function() CustomUIAPI.SetTextContent(ps, cfg.P2Score, "玩家2 分数: " .. tostring(p2Score)) end)
        end
        if cfg.WinnerLabel then
            pcall(function() CustomUIAPI.SetTextContent(ps, cfg.WinnerLabel, winnerTxt) end)
        end
        if cfg.ExitBtn then
            pcall(function() CustomUIAPI.SetWidgetVisible(ps, cfg.ExitBtn, true) end)
        end
    end
    self:RegisterExitBtn()   -- 注册「结束游戏」按钮点击（仅一次）
    print("[Tetris][Settle] 结算面板已弹出 reason=" .. tostring(reason))
end

-- 结算界面「结束游戏」按钮：注册一次点击监听，点击执行 GameOutcomeAPI.SetRoundGameEnd(true)
function TetrisMatch:RegisterExitBtn()
    local cfg = TetrisConfig.Settle
    if not cfg or not cfg.ExitBtn then return end          -- 未配置按钮则不注册
    if self._exitBtnReg then return end                    -- 防重复注册
    self._exitBtnReg = true
    local owner = self.owner
    if not owner or type(owner.AddVPEvent) ~= "function" then return end
    local clickId = (type(RcEventIdDefine) == "table" and RcEventIdDefine.CustomUIClicked) or 120000
    local selfRef = self
    owner:AddVPEvent(clickId, function(_self, ps)
        -- 仅在对局已结束（结算面板已弹）时生效，避免对局中误触提前结束
        if not selfRef.over then return end
        print("[Tetris][Settle] 「结束游戏」按钮被点击（" .. tostring(ps) .. "），先上报胜负+分数，再 SetRoundGameEnd")
        -- 胜负 + 分数上报（之前在 OnPlayerOut 弹窗前执行，现延迟到此处点击结束按钮时）
        if selfRef.winner then
            pcall(function() selfRef:ReportOutcome(selfRef.winner, selfRef.winner.opponent) end)
        end
        if type(GameOutcomeAPI) == "table" and type(GameOutcomeAPI.SetRoundGameEnd) == "function" then
            pcall(function() GameOutcomeAPI.SetRoundGameEnd(true) end)
        else
            print("[Tetris][Settle][WARN] GameOutcomeAPI.SetRoundGameEnd 不可用")
        end
    end, selfRef, cfg.ExitBtn, nil)
    print("[Tetris][Settle] 「结束游戏」按钮点击已注册")
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

return TetrisMatch
