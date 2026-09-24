-- 双人对战总控（经典对攻，最后存活胜）。
-- 持有 N 个 TetrisGame 实例（当前固定 2 人），负责：
--   1) 按 SceneObjects.SpawnPointKey / SpawnPointKey2 给每个实例分配出生点（各自一块棋盘）；
--   2) 开局枚举在场玩家，把玩家分配到棋盘实例，并互设对手；
--   3) 输入路由：每个按钮仅注册一次，按「点击者的 PlayerState」分发到其所属实例；
--   4) 胜负判定：某玩家顶出（game over）即判对手获胜，整局结束。
-- 注：屏幕显示（HUD/胜负面板）交给 TetrisGame.UpdateHUD 与上层逻辑，本模块只做逻辑与日志。
pcall(require, "EnvLua.Core.Define.RcEventIdDefine")
pcall(require, "EnvLua.Core.LuaHint.GameOutcomeAPI")

local TetrisConfig = require("EnvLua.Server.Tetris.TetrisConfig")
local TetrisGame = require("EnvLua.Server.Tetris.TetrisGame")
local PuyoGame = require("EnvLua.Server.Tetris.PuyoGame")
local TetrisModeSelect = require("EnvLua.Server.Tetris.TetrisModeSelect")

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

    -- 玩法选择阶段：先用 UI 选玩法 → 选完把玩家传送到出生点 → 再逐个开局。
    -- 选择按钮未放置时（占位/未注入）自动跳过，保持「开局即玩」的旧行为。
    self.modeSelect = TetrisModeSelect:new(self.owner, self)
    self.modeSelect:Begin(assigned)
end

-- 玩法选择结束（或跳过选择）：按各玩家所选玩法，用正确模式构建棋盘并开局。
-- choices: [PlayerState] = 玩法（"tetris"/"puyo"）。未选择则回退默认玩法。
function TetrisMatch:OnModeSelected(choices)
    self.choices = choices or {}
    local M = TetrisConfig.GameMode
    for i, g in ipairs(self.list) do
        -- 分配到玩家的盘 → 用该玩家所选玩法；旁观盘 → 用默认/强制玩法
        local mode = g.playerState and (self.choices[g.playerState] or M.Tetris) or self:initialMode()
        -- 用正确模式重建实例（保留出生点/分配/序号），避免俄罗斯方块占位被直接 Start
        local ng = self:createGame(mode, g.spawnPointKey, g.index)
        ng.playerState = g.playerState
        ng.playerKey = g.playerKey
        ng.opponent = g.opponent
        self.list[i] = ng
        if g.playerKey then self.games[g.playerKey] = ng end
        local ok = ng:Init(g.spawnPointKey)
        if ok then
            if ng.playerState then
                ng:Start()
            elseif TetrisConfig.AI and TetrisConfig.AI.Enabled then
                ng.isAI = true          -- 空盘改为 AI 自动对战（玩家能看到其盘面下落）
                ng:Start()
            else
                ng:StartSpectator()
            end
            print(string.format("[Tetris][Versus] 棋盘#%d 玩家=%s 玩法=%s 已开局",
                tostring(ng.index), tostring(ng.playerKey), tostring(mode)))
        else
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
    self:StartMatchTimer()
    print("[Tetris][Versus] 对局开始")
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
    local id = (type(RcEventIdDefine) == "table" and RcEventIdDefine.CustomUIClicked) or 120000
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
    print("[Tetris][Versus] 输入路由已注册（" .. #binds .. " 个按钮）")
end

-- 某玩家顶出 → 对手获胜，整局结束
function TetrisMatch:OnPlayerOut(loser)
    if self.over then return end
    local winner = loser.opponent
    self.winner = winner
    self:EndMatch("lose", false)
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
    for _, g in ipairs(self.list) do
        if g.running then g:Stop() end
    end
    self:ShowSettle(reason)
    if early then self:CallEndGameAPI() end
    print(string.format("[Tetris][Versus] 结算 reason=%s early=%s 胜者=%s",
        tostring(reason), tostring(early),
        self.winner and tostring(self.winner.playerKey) or "?"))
end

-- 给全体玩家弹出结算面板并显示分数
function TetrisMatch:ShowSettle(reason)
    local cfg = TetrisConfig.Settle
    if not (cfg and cfg.Enabled) then return end
    if type(CustomUIAPI) ~= "table" then return end
    local lines = {}
    local best, bestKey = nil, nil
    for _, g in ipairs(self.list) do
        local score = (g.board and g.board.score) or 0
        local name = g.playerKey and tostring(g.playerKey) or ("玩家" .. tostring(g.index))
        lines[#lines + 1] = name .. "  分数: " .. tostring(score)
        if best == nil or score > best then best, bestKey = score, g.playerKey end
    end
    local winnerTxt
    if reason == "lose" and self.winner then
        winnerTxt = "胜者: " .. tostring(self.winner.playerKey or "?")
    else
        winnerTxt = "胜者: " .. tostring(bestKey or "?")
    end
    local text = "【结算】\n" .. table.concat(lines, "\n") .. "\n" .. winnerTxt
    for _, ps in ipairs(self:AllPlayerStates()) do
        if cfg.PanelKey then
            pcall(function() CustomUIAPI.SetWidgetVisible(ps, cfg.PanelKey, true) end)
        end
        if cfg.ScoreLabel then
            pcall(function() CustomUIAPI.SetTextContent(ps, cfg.ScoreLabel, text) end)
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
        print("[Tetris][Settle] 「结束游戏」按钮被点击（" .. tostring(ps) .. "），执行 SetRoundGameEnd")
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
