-- Puyo 游戏控制器：串联 PuyoBoard（数据）与 PuyoRenderer（渲染），
-- 负责重力 tick、UI 输入路由、top-out 上报、HUD、固定相机。
-- 接口与 TetrisGame 对齐（Init/Start/StartSpectator/Stop/OnBtn*/opponent/playerKey/playerState/running），
-- 以便 TetrisMatch 统一调度（双人对称对战时复用同一套输入路由与胜负判定）。
pcall(require, "EnvLua.Core.Define.RcEventIdDefine")

local TetrisConfig = require("EnvLua.Server.Tetris.TetrisConfig")
local PuyoBoard = require("EnvLua.Server.Tetris.PuyoBoard")
local PuyoRenderer = require("EnvLua.Server.Tetris.PuyoRenderer")
local TetrisNativeUI = require("EnvLua.Server.Tetris.TetrisNativeUI")

local PuyoGame = {}
PuyoGame.__index = PuyoGame

function PuyoGame:new(owner, opts)
    local o = setmetatable({}, PuyoGame)
    o.owner = owner
    o.board = nil
    o.renderer = nil
    o.nativeUI = TetrisNativeUI:new(owner)
    o.running = false
    o.playerState = (opts and opts.playerState) or nil
    o.playerKey = nil
    o.match = (opts and opts.match) or nil
    o.spawnPointKey = (opts and opts.spawnPointKey) or nil
    o.index = (opts and opts.index) or 0
    o.opponent = nil
    o._resolving = false   -- 分阶段消除流程进行中标记（避免重复进入）
    return o
end

-- ---------------- 生命周期 ----------------
function PuyoGame:Init(spawnPointKey)
    self.board = PuyoBoard:new()
    self.renderer = PuyoRenderer:new(self.owner)
    local ok = self.renderer:Build(spawnPointKey or self.spawnPointKey)
    print("[Puyo] Init, 盘面 " .. TetrisConfig.Puyo.Board.Cols .. "x" .. TetrisConfig.Puyo.Board.Rows)
    return ok
end

function PuyoGame:Start()
    if self.running then return end
    self.running = true
    self.nativeUI:Hide()
    if not self.match then self:RegisterInput() end
    self:ScheduleSettle()
    self:ScheduleTick()
    self:ScheduleCameraSetup()
    self:UpdateHUD()
    print("[Puyo] Start")
end

-- 旁观盘：仅渲染盘面，不接收输入 / 不自动下落 / 不触发 top-out。
function PuyoGame:StartSpectator()
    self.running = true
    self.owner:AddTimerOnce(0.5, function()
        if not self.running then return end
        self.renderer:Update(self.board)
    end)
end

function PuyoGame:Stop()
    if not self.running then return end
    self.running = false
    self.nativeUI:Restore()
    if type(CameraAPI) == "table" then
        local ok, arr = pcall(function() return Game:GetAllPlayerStates() end)
        if ok and arr and arr.Num and arr:Num() > 0 then
            for i = 0, arr:Num() - 1 do
                local ps = arr:Get(i)
                if ps then
                    pcall(function() CameraAPI.ResetViewTarget(ps, 0) end)
                    pcall(function() CameraAPI.ResetCameraOffset(ps, 0) end)
                    pcall(function() CameraAPI.ResetCameraDistance(ps, 0) end)
                    pcall(function() CameraAPI.LockCameraInput(ps, false) end)
                    if type(PlayerAPI) == "table" then
                        pcall(function() PlayerAPI.SetPlayerSpeedMul(ps, 1) end)
                    end
                end
            end
        end
    end
    print("[Puyo] Stop")
end

-- ---------------- 开局稳定期 ----------------
function PuyoGame:ScheduleSettle()
    local r = TetrisConfig.Render
    for i = 1, r.SettleFrames do
        self.owner:AddTimerOnce(i * r.SettleInterval, function()
            if self.renderer and self.board then self.renderer:Update(self.board) end
        end)
    end
end

-- ---------------- 重力循环 ----------------
function PuyoGame:ScheduleTick()
    if not self.running then return end
    local interval = self.board:getGravityInterval()
    self.owner:AddTimerOnce(interval, function()
        if not self.running then return end
        self:OnTick()
        self:ScheduleTick()
    end)
end

function PuyoGame:OnTick()
    local board = self.board
    if board:isOver() then self:OnGameOver() return end
    board:tick()
    self.renderer:Update(board)
    self:UpdateHUD()
    -- 锁定后进入分阶段消除流程（停顿→回收+特效→等特效完→下落）
    if board.resolving and not self._resolving then
        self:BeginResolve()
    end
    if board:isOver() then self:OnGameOver() end
end

-- ---------------- 固定相机 ----------------
function PuyoGame:ScheduleCameraSetup()
    if not (self.renderer and self.renderer.GetBoardCenter) then return end
    local tries = 0
    local maxTries = 60
    local function tick()
        tries = tries + 1
        if self:SetupFixedCamera() then return end
        if tries < maxTries and self.running then self.owner:AddTimerOnce(0.2, tick) end
    end
    tick()
end

function PuyoGame:SetupFixedCamera()
    if type(CameraAPI) ~= "table" then return true end
    if not self.renderer then return false end
    if not self.renderer._spawnResolved then
        self.renderer:ResolveOrigin()
        if not self.renderer._spawnResolved then return false end
        if self.board then self.renderer:Update(self.board) end
        self.renderer:ReanchorBorder()
    end
    local center = self.renderer:GetBoardCenter()
    if not center then return false end
    local ok, arr = pcall(function() return Game:GetAllPlayerStates() end)
    if not (ok and arr and arr.Num and arr:Num() > 0) then return false end
    local targets = {}
    if self.playerState then targets = { self.playerState }
    else for i = 0, arr:Num() - 1 do local ps = arr:Get(i) if ps then targets[#targets + 1] = ps end end end
    local cam = TetrisConfig.Camera or {}
    local back = cam.CamBackM or 3
    local lockMove = cam.LockMovement ~= false
    local lockRot = cam.LockRotation ~= false
    local ox = cam.OffsetXM or 0
    local oy = cam.OffsetYM or 0
    local oz = cam.OffsetZM or cam.ZExtraM or 0
    local off = Game:ConstructFVectorByLuaTable({ X = ox, Y = oy, Z = oz })
    for _, ps in ipairs(targets) do
        pcall(function() CameraAPI.SetCameraOffset(ps, off, 0.3) end)
        pcall(function() CameraAPI.SetCameraDistance(ps, back, 0.3) end)
        pcall(function() CameraAPI.LockCameraInput(ps, lockRot) end)
        if lockMove then pcall(function() PlayerAPI.SetPlayerSpeedMul(ps, 0) end) end
    end
    return true
end

-- ---------------- HUD ----------------
function PuyoGame:GetPlayerState()
    if self.playerState then return self.playerState end
    local ok, arr = pcall(function() return Game:GetAllPlayerStates() end)
    if ok and arr and arr:Num() > 0 then self.playerState = arr:Get(0) end
    return self.playerState
end

function PuyoGame:UpdateHUD()
    local b = self.board
    if not b then return end
    local ui = TetrisConfig.UI
    if not (ui.ScoreLabel or ui.LinesLabel or ui.LevelLabel) then return end
    local ps = self:GetPlayerState()
    if not ps or type(CustomUIAPI) ~= "table" then return end
    local function set(id, text)
        if not id then return end
        pcall(function() CustomUIAPI.SetTextContent(ps, id, text) end)
    end
    set(ui.ScoreLabel, "分数: " .. tostring(b.score))
    set(ui.LinesLabel, "连锁: " .. tostring(b:getChain()))
    set(ui.LevelLabel, "列: " .. tostring(b.cols) .. " 行: " .. tostring(b.rows))
end

-- ---------------- top-out ----------------
function PuyoGame:OnGameOver()
    local msg = "游戏结束 分数=" .. tostring(self.board.score) .. " 连锁=" .. tostring(self.board:getChain())
    self.running = false
    self:UpdateHUD()
    if self.match then self.match:OnPlayerOut(self) end
    if TetrisConfig.Debug and TetrisConfig.Debug.ShowGameOverInfo then self:SendScreenMessage(msg) end
end

function PuyoGame:SendScreenMessage(content)
    local ps = self:GetPlayerState()
    if not ps then return end
    pcall(function()
        if TetrisConfig.Debug and TetrisConfig.Debug.ShowPieceInfoPopup then
            Log.SendBattlePopupMessage(ps, content)
        else
            Log.SendQuickMenuMessage(ps, content)
        end
    end)
end

-- ---------------- UI 输入 ----------------
function PuyoGame:RegisterInput()
    local ui = TetrisConfig.UI
    local id = (type(RcEventIdDefine) == "table" and RcEventIdDefine.CustomUIClicked) or 120000
    local function bind(instanceID, handler)
        if instanceID == nil then return end
        self.owner:AddVPEvent(id, handler, self, instanceID, nil)
    end
    bind(ui.BtnLeft, PuyoGame.OnBtnLeft)
    bind(ui.BtnRight, PuyoGame.OnBtnRight)
    bind(ui.BtnRoll, PuyoGame.OnBtnRoll)
    bind(ui.BtnDown, PuyoGame.OnBtnDown)
    bind(ui.BtnHold, PuyoGame.OnBtnHold)
    bind(ui.BtnSkill, PuyoGame.OnBtnSkill)
    print("[Puyo] UI 输入已注册")
end

function PuyoGame:safeApply(fn)
    if not self.running or self.board:isOver() then return end
    local ok, err = pcall(fn)
    if not ok then
        print("[Puyo][ERROR] 操作异常: " .. tostring(err))
        return
    end
    self.renderer:Update(self.board)
    self:UpdateHUD()
    if self.board.resolving and not self._resolving then
        self:BeginResolve()
    end
    if self.board:isOver() then self:OnGameOver() end
end

-- ---------------- 分阶段消除流程 ----------------
-- 序列：检测本步消除组 → 等待 ClearPauseSec（方块仍可见）→ 回收 + 播放特效
--       → 等待 ClearEffectDuration（特效播完）→ 下落 → 进入下一连锁步（递归）
function PuyoGame:BeginResolve()
    if self._resolving then return end
    if not self.board.resolving then return end
    self._resolving = true
    self:ResolveStep()
end

function PuyoGame:ResolveStep()
    local board = self.board
    local cells = board:findStepClears()
    if not cells then
        -- 无更多消除：结束流程，生成下一对
        board.resolving = false
        self._resolving = false
        board:spawn()
        self.renderer:Update(board)
        self:UpdateHUD()
        if board:isOver() then self:OnGameOver() end
        return
    end

    self.renderer:Update(board)  -- 停顿期间方块仍可见
    local pause = (TetrisConfig.Puyo and TetrisConfig.Puyo.ClearPauseSec) or 0.35
    self.owner:AddTimerOnce(pause, function()
        if not self.running or board.isGameOver then return end
        -- 回收方块 + 在每格播放特效
        board:reclaim(cells)
        self.renderer:Update(board)
        self:UpdateHUD()
        self:PlayClearEffects(cells)
        local dur = (TetrisConfig.Puyo and TetrisConfig.Puyo.ClearEffectDuration) or 0.5
        self.owner:AddTimerOnce(dur, function()
            if not self.running or board.isGameOver then return end
            board:applyGravityAll()   -- 特效播完后执行下落
            self.renderer:Update(board)
            self:UpdateHUD()
            self:ResolveStep()        -- 下一连锁步
        end)
    end)
end

function PuyoGame:PlayClearEffects(cells)
    for _, cell in ipairs(cells) do
        self.renderer:PlayClearEffectAt(cell.row, cell.col)
    end
end

function PuyoGame:OnBtnLeft() self:safeApply(function() self.board:move(-1) end) end
function PuyoGame:OnBtnRight() self:safeApply(function() self.board:move(1) end) end
function PuyoGame:OnBtnRoll() self:safeApply(function() self.board:rotate(1) end) end
function PuyoGame:OnBtnDown() self:safeApply(function() self.board:hardDrop() end) end
function PuyoGame:OnBtnHold() end   -- Puyo 无 Hold
function PuyoGame:OnBtnSkill()      -- 技能占位
    if not TetrisConfig.SkillEnabled then print("[Puyo] 技能按钮（未启用）") end
end

return PuyoGame
