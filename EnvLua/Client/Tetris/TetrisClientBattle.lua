-- P4-1：客户端单人闭环驱动（绕开 UI 流程，先验证双盘渲染）。
-- 本地盘：Common Board + ClientGame，重力自动演进，ClientRenderer 渲染（左）。
-- 对手盘：接收服务端 AIDriver 快照，ToRenderState → 第二个 ClientRenderer 渲染（右）。
-- 不依赖编辑器 UI 控件；用 OnRoundStart 自动启动。
local Board = require("EnvLua.Common.Tetris.TetrisBoard")
local ClientGame = require("EnvLua.Client.Tetris.Game.ClientGame")
local ClientInput = require("EnvLua.Client.Tetris.Input.ClientInput")
local ClientRenderer = require("EnvLua.Client.Tetris.Renderer.ClientRenderer")
local Snapshot = require("EnvLua.Common.Tetris.TetrisSnapshot")
local Config = require("EnvLua.Common.Tetris.TetrisConfig")

local TetrisClientBattle = {}
TetrisClientBattle.__index = TetrisClientBattle

local STEP_M = ((Config.Render or {}).CellSize or 1.0) + ((Config.Render or {}).CellGap or 0.02)

TetrisClientBattle.Current = nil  -- 当前实例，供 GameState 转发对手盘快照
TetrisClientBattle.PendingBoardTransform = nil  -- [P7] 开局广播早于 Battle 创建时的盘面基底缓存

function TetrisClientBattle:new(host)
    local o = setmetatable({}, self)
    o.host = host
    o.running = false
    o.localGame = nil
    o.localRenderer = nil
    o.oppRenderer = nil
    o.input = nil
    o._tickCount = 0
    o.selfKey = 0
    o._settled = false
    -- 由 TetrisClient 注入的回调（HUD/结算/排行榜），默认 no-op
    o.onSettle = nil
    o.onHud = nil
    o.onLeaderboard = nil
    o.onPlayerInfo = nil
    o.quality = 0.8
    o.aiName = "AI"
    -- [P7] 盘面基底 + 下落门控：必须「基底已到」且「loading 已隐藏」才开始下落
    o._boardReady = false
    o._loadingHidden = false
    o._fallStarted = false
    o._boardSeats = nil
    -- [P8] 权威对账：本地即时跑，每落一块上报 lastLockedPiece；服务端回 ack 比对 score/lines
    o._authSeq = 0
    o._authLastLockSeq = 0
    o._authAckScore = nil
    o._authAckLines = nil
    o._authMismatch = 0
    o._authTopOutReported = false
    return o
end

-- [P8] 检测本地盘新落定的块并上报（type/rot/x/y 由 Board.lockPiece 旁路记录，随机源交给客户端）
function TetrisClientBattle:_reportLockedPieces()
    if not self.running then return end
    local b = self.localGame and self.localGame.board
    if not b then return end
    -- [P8] 顶出检测放最前：顶出块是 spawn 失败块，不经过 lockPiece，lastLockedPiece 不会变化
    if b.isGameOver and b.topoutSeq and not self._authTopOutReported then
        self._authTopOutReported = true
        pcall(function()
            local gs = Game:GetGameState()
            if gs then gs:CallServerFunction("Auth_TopOut", self._authSeq) end
        end)
        print("[Auth][Client] 上报顶出 topoutSeq=" .. tostring(b.topoutSeq) .. " authSeq=" .. tostring(self._authSeq))
    end
    if not b.lastLockedPiece then return end
    local lockSeq = b.lastLockedPiece.seq or 0
    if lockSeq <= self._authLastLockSeq then return end
    self._authLastLockSeq = lockSeq
    local p = b.lastLockedPiece
    self._authSeq = self._authSeq + 1
    local seq, t, r, x, y = self._authSeq, p.type, p.rot, p.x, p.y
    pcall(function()
        local gs = Game:GetGameState()
        if gs then gs:CallServerFunction("Auth_Piece", seq, t, r, x, y) end
    end)
    if self._authSeq % 5 == 0 then
        print("[Auth][Client] 上报落块 seq=" .. tostring(seq) .. " type=" .. tostring(t) ..
            " rot=" .. tostring(r) .. " x=" .. tostring(x) .. " y=" .. tostring(y))
    end
end

-- [P8] 服务端权威 ack：与本地 score/lines 比对，不一致则计数告警（手感不受影响，仅作权威校验）
function TetrisClientBattle:OnAuthAck(seq, score, lines, over)
    self._authAckScore, self._authAckLines = score, lines
    local b = self.localGame and self.localGame.board
    if not b then return end
    local localScore, localLines = b.score or 0, b.lines or 0
    if score ~= localScore or lines ~= localLines then
        self._authMismatch = self._authMismatch + 1
        if self._authMismatch <= 3 then
            print("[Auth][Client][WARN] 权威不一致 seq=" .. tostring(seq) ..
                " 本地=" .. tostring(localScore) .. "/" .. tostring(localLines) ..
                " 服务端=" .. tostring(score) .. "/" .. tostring(lines))
        end
    end
end

-- 一局只结算一次：上报胜负到服务端（胜数榜赢+1输不扣）。
function TetrisClientBattle:_settle(win, reason)
    if self._settled then return end
    self._settled = true
    -- [P8] 结算即停本地盘：重力 tick 与落块上报都检查 running，避免结算后继续跑/产生垃圾上报
    self.running = false
    self.input:Disable()
    print("[P5] 结算: win=" .. tostring(win) .. " reason=" .. tostring(reason) .. " selfKey=" .. tostring(self.selfKey))
    local ok, gsOrErr = pcall(function()
        local gs = Game:GetGameState()
        if gs then gs:CallServerFunction("P5_ReportResult", win and true or false, self.selfKey) end
    end)
    if not ok then print("[P5] 结算上报失败: " .. tostring(gsOrErr)) end

    -- 回调 TetrisClient 显示结算面板（带双方分数）
    if self.onSettle then
        local myScore = (self.localGame and self.localGame.board.score) or 0
        local oppScore = self._lastOppScore or 0
        pcall(self.onSettle, win, myScore, oppScore)
    end

    -- 结算后延迟请求排行榜，验证上榜数据（服务端 SubmitScore+RefreshRank 需时间）
    local selfRef = self
    self.host:AddTimerOnce(0.8, function()
        pcall(function()
            local gs = Game:GetGameState()
            if gs then gs:CallServerFunction("P5_RequestLeaderboard") end
        end)
    end)
end

-- 排行榜数据到达（后续接 UI 面板，P5 先存起来）
function TetrisClientBattle:OnLeaderboard(list)
    self._leaderboard = list
    print("[P5] Battle 收到排行榜数据, 条数=" .. tostring(type(list) == "table" and #list or 0))
    if self.onLeaderboard then pcall(self.onLeaderboard, list) end
end

-- [P7] 玩家信息（服务端下发 {playerKey,name,avatarIndex}）：按 selfKey 区分我方/对方。
-- 双人：另一名真人即对方；单人：对方用 AI 难度名 + 避开真人的头像序号（真人 0 → AI 用 1）。
function TetrisClientBattle:OnPlayerInfo(list)
    if type(list) ~= "table" then return end
    local myName, myAvatar, oppName, oppAvatar = nil, 0, nil, nil
    local oppFound = false
    for _, e in ipairs(list) do
        if type(e) ~= "table" then goto continue end
        if e.playerKey == self.selfKey then
            myName = e.name
            myAvatar = e.avatarIndex or 0
        else
            oppName = e.name
            oppAvatar = e.avatarIndex or 0
            oppFound = true
        end
        ::continue::
    end
    if not oppFound then   -- 单人 AI 对手：名字取难度名，头像序号避开真人
        oppName = self.aiName or "AI"
        oppAvatar = (myAvatar + 1) % 8
    end
    print("[P7] 玩家信息: 我方=" .. tostring(myName) .. " idx=" .. tostring(myAvatar) ..
        " 对方=" .. tostring(oppName) .. " idx=" .. tostring(oppAvatar))
    if self.onPlayerInfo then pcall(self.onPlayerInfo, myName, oppName, myAvatar, oppAvatar) end
end

function TetrisClientBattle:Start()
    if self.running then return end
    self.running = true
    TetrisClientBattle.Current = self
    print("[P4] 启动单人闭环双盘渲染")

    -- 本地盘：origin 在世界原点偏左（X = -8m），对手盘偏右（X = +8m），Z 顶行 10m
    local originLocal = { X = -8.0, Y = 0.0, Z = 10.0 }
    local originOpp = { X = 8.0, Y = 0.0, Z = 10.0 }
    local right = { X = 1.0, Y = 0.0, Z = 0.0 }

    self.localRenderer = ClientRenderer:new(originLocal, right)
    self.oppRenderer = ClientRenderer:new(originOpp, right)

    local board = Board:new()
    self.localGame = ClientGame:new(board, {
        renderer = self.localRenderer,
        versus = { Send = function() end },  -- P4-1 单人不需要对战事件
        scheduler = { After = function(delay, fn) self.host:AddTimerOnce(delay, fn) end },
        playerKey = 1,
    })
    -- [P7] 不再立即 Start：等「盘面基底已到 + loading 已隐藏」才在 _tryBeginFall 里启动（原 self.localGame:Start() 已迁出）
    print("[P4] 本地盘 ClientGame 已构建（等待盘面基底）, 重力间隔=" .. tostring(board:getGravityInterval()))

    -- 诊断：6 个操作按钮 InstanceID 是否在当前工程注册（决定能否接输入）
    local U = Config.UI or {}
    print("[P4] CreativeInstance 存在=" .. tostring(type(CreativeInstance) == "table") ..
        " 按钮解析: Left=" .. tostring(U.BtnLeft) .. " Right=" .. tostring(U.BtnRight) ..
        " Roll=" .. tostring(U.BtnRoll) .. " Down=" .. tostring(U.BtnDown) ..
        " Hold=" .. tostring(U.BtnHold) .. " Skill=" .. tostring(U.BtnSkill))

    -- 接输入：包装 sink 统计每次按钮动作，验证输入真的驱动本地盘
    local selfRef = self
    local gameRef = self.localGame
    local inputSink = setmetatable({}, {
        __index = function(_, k)
            local v = gameRef[k]
            if type(v) == "function" then
                return function(_, ...)
                    if k == "ApplyAction" then
                        selfRef._inputCount = (selfRef._inputCount or 0) + 1
                        local act = ...
                        if selfRef._inputCount % 5 == 0 then
                            print("[P4] 输入累计=" .. tostring(selfRef._inputCount) ..
                                " 最近动作=" .. tostring(type(act) == "table" and act.type or "?"))
                        end
                    end
                    local result = v(gameRef, ...)
                    -- 操作后立即刷新本地盘渲染，避免等 0.8s 重力 tick 才有反馈
                    if k == "ApplyAction" and selfRef.localRenderer then
                        pcall(function() selfRef.localRenderer:Update(gameRef:BuildRenderState()) end)
                    end
                    -- [P8] 硬降/操作导致落定后，立即把该块上报服务端权威重放
                    if k == "ApplyAction" then selfRef:_reportLockedPieces() end
                    return result
                end
            end
            return v
        end,
    })
    self.input = ClientInput:new(self.host, inputSink)
    self.input:Enable()
    print("[P4] ClientInput 已启用，可点击左右/旋转/下落按钮操作本地盘")

    -- 取本地玩家 key（结算上报用）
    pcall(function()
        local ps = Game:GetPlayerStateByPlayerKey(nil)
        if ps and ps.GetPlayerKey then self.selfKey = ps:GetPlayerKey() or 0 end
    end)
    print("[P5] 本地玩家 key=" .. tostring(self.selfKey))

    -- [P7] 请求服务端分配玩家名字+头像序号（服务端按 playerKey 排序分配，回传 P7_PlayerInfo）
    pcall(function()
        local gs = Game:GetGameState()
        if gs then gs:CallServerFunction("P7_RequestPlayerInfo") end
    end)

    -- [P5-5b] 判断模式：玩家数>=2 双人，否则单人打 AI
    local playerCount = 0
    pcall(function()
        local ps = Game:GetAllPlayerStates()
        if ps and ps.Num then playerCount = ps:Num() end
    end)
    self.isVersus = playerCount >= 2
    print("[P5-5b] 玩家数=" .. tostring(playerCount) .. " 模式=" .. (self.isVersus and "双人" or "单人AI"))

    if self.isVersus then
        -- 双人：定期上报本地盘快照给服务端中转（带 senderKey）
        local battleRef = self
        local function reportSnapshot()
            if not battleRef.running or not battleRef.localGame then return end
            local snap = Snapshot.Capture(battleRef.localGame.board, { tag = "versus", senderKey = battleRef.selfKey })
            pcall(function()
                local gs = Game:GetGameState()
                if gs then gs:CallServerFunction("P5_ReportSnapshot", snap) end
            end)
            battleRef.host:AddTimerOnce(0.3, reportSnapshot)
        end
        self.host:AddTimerOnce(0.3, reportSnapshot)
    else
        -- 单人：请求服务端启动 AI（服务端也有延迟兜底，这里幂等）
        pcall(function()
            local gs = Game:GetGameState()
            if gs then gs:CallServerFunction("P5_RequestAI") end
        end)
    end

    -- [P7] 盘面基底：优先取开局广播缓存，否则请求服务端重发；5s 超时用占位基底保证不卡死
    local pending = TetrisClientBattle.PendingBoardTransform
    if pending then
        TetrisClientBattle.PendingBoardTransform = nil
        self:OnBoardTransform(pending)
    else
        pcall(function()
            local gs = Game:GetGameState()
            if gs then gs:CallServerFunction("P7_RequestBoardTransform") end
        end)
    end
    local battleRef = self
    self.host:AddTimerOnce(5.0, function()
        if not battleRef._boardReady and battleRef.running then
            print("[P7][Battle][WARN] 盘面基底 5s 未到，使用占位基底继续")
            battleRef._boardReady = true
            battleRef:_tryBeginFall()
        end
    end)
end

-- [P7] 应用服务端下发的盘面基底（seats 为两个 seat 表，按 playerKey 匹配自己/对手）。
function TetrisClientBattle:OnBoardTransform(seats)
    if type(seats) ~= "table" or #seats < 2 then return end
    local mine, other = nil, nil
    for _, s in ipairs(seats) do
        if type(s) == "table" and s.origin and s.right then
            if s.playerKey == self.selfKey and s.playerKey ~= 0 then
                mine = s
            elseif not other then
                other = s
            end
        end
    end
    -- 单人时若 selfKey 未匹配（如 selfKey=0 或读取晚于广播），退化为 seat0=自己、seat1=AI/对手
    if not mine then mine, other = seats[1], seats[2] end
    if not mine or not other then return end
    if self.localRenderer then
        self.localRenderer:SetBasis(mine.origin, mine.right)
        pcall(function() self.localRenderer:Update(self.localGame:BuildRenderState()) end)
    end
    if self.oppRenderer then self.oppRenderer:SetBasis(other.origin, other.right) end
    self._boardSeats = seats
    self._boardReady = true
    print("[P7][Battle] 盘面基底已应用 我方 origin=(" .. tostring(mine.origin.X) .. "," ..
        tostring(mine.origin.Y) .. "," .. tostring(mine.origin.Z) .. ") 对手 origin=(" ..
        tostring(other.origin.X) .. "," .. tostring(other.origin.Y) .. "," .. tostring(other.origin.Z) .. ")")
    self:_tryBeginFall()
end

-- [P7] loading 隐藏事件：由 TetrisClient 在 EnterBattle 后显式通知。
function TetrisClientBattle:SetLoadingHidden()
    self._loadingHidden = true
    self:_tryBeginFall()
end

-- [P7] 两条件齐备才启动本地盘下落（重力循环从 Start 迁出，避免 loading 期间就落块）。
function TetrisClientBattle:_tryBeginFall()
    if not (self._boardReady and self._loadingHidden and not self._fallStarted) then return end
    self._fallStarted = true
    local board = self.localGame and self.localGame.board
    if not board then return end
    self.localGame:Start()
    print("[P4] BeginFall：loading已隐藏+盘面基底已就绪，本地盘开始下落")
    local selfRef = self
    local function gravityTick()
        if not selfRef.running or not selfRef.localGame then return end
        selfRef.localGame:tick()
        selfRef.localRenderer:Update(selfRef.localGame:BuildRenderState())
        -- [P8] 重力自然落定也上报（与硬降同走 lockPiece 旁路记录，seq 去重）
        selfRef:_reportLockedPieces()
        if selfRef.onHud then pcall(selfRef.onHud, selfRef.localGame:BuildUIState(), selfRef._lastOppScore or 0) end
        selfRef._tickCount = selfRef._tickCount + 1
        if selfRef._tickCount % 20 == 0 then
            local rs = selfRef.localGame:BuildRenderState()
            local cnt = 0
            for _, line in pairs(rs.grid or {}) do for _ in pairs(line) do cnt = cnt + 1 end end
            print("[P4] 本地盘 tick#" .. tostring(selfRef._tickCount) ..
                " 已落格数=" .. tostring(cnt) ..
                " score=" .. tostring(rs and selfRef.localGame.board.score or 0))
        end
        if selfRef.localGame.board:isOver() then
            selfRef:_settle(false, "local-over")
            selfRef.input:Disable()
            return
        end
        selfRef.host:AddTimerOnce(selfRef.localGame.board:getGravityInterval(), gravityTick)
    end
    self.host:AddTimerOnce(board:getGravityInterval(), gravityTick)
end

-- 对手盘：由 GameState 的 P3_OnAISnapshot 调用，把快照画到右侧盘面。
function TetrisClientBattle:OnOpponentSnapshot(snap)
    if not self.running or not self.oppRenderer then return end
    local rs = Snapshot.ToRenderState(snap)
    self.oppRenderer:Update(rs)
    if type(snap) == "table" and snap.score then self._lastOppScore = snap.score end
    self._oppCount = (self._oppCount or 0) + 1
    if self._oppCount % 5 == 0 then
        local cnt = 0
        for _, line in pairs(rs.grid or {}) do for _ in pairs(line) do cnt = cnt + 1 end end
        print("[P4] 对手盘 快照#" .. tostring(self._oppCount) .. " 已落格数=" .. tostring(cnt) ..
            " tag=" .. tostring(snap.tag))
    end
    -- [P5] AI 盘顶出 → 玩家赢，结算一次
    if snap.over then
        self:_settle(true, "opponent-over")
    end
end

function TetrisClientBattle:Stop()
    self.running = false
    if self.input then pcall(function() self.input:Disable() end) end
    if self.localRenderer then self.localRenderer:Release() end
    if self.oppRenderer then self.oppRenderer:Release() end
    self.input, self.localRenderer, self.oppRenderer, self.localGame = nil, nil, nil, nil
    print("[P4] 停止，输入与 Renderer 已释放")
end

return TetrisClientBattle
