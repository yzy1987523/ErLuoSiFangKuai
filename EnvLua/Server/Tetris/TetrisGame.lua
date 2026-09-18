-- 游戏控制器：串联数据层与渲染层，负责重力 tick、UI 输入路由、生命周期。
-- 本模块不是 WoWObject，定时器与事件都借宿在 owner（ServerGameMain）上。
-- RcEventIdDefine.lua 内部是 "RcEventIdDefine = {...}"（全局表，无 return），
-- require 只会返回 nil，因此这里仅取它的"加载副作用"，使用时读全局。
pcall(require, "EnvLua.Core.Define.RcEventIdDefine")

local TetrisConfig = require("EnvLua.Server.Tetris.TetrisConfig")
local TetrisBoard = require("EnvLua.Server.Tetris.TetrisBoard")
local TetrisRenderer = require("EnvLua.Server.Tetris.TetrisRenderer")
local TetrisNativeUI = require("EnvLua.Server.Tetris.TetrisNativeUI")

local TetrisGame = {}
TetrisGame.__index = TetrisGame

function TetrisGame:new(owner)
    local o = setmetatable({}, TetrisGame)
    o.owner = owner          -- WoWObject，用于 AddTimerOnce / AddVPEvent
    o.board = nil
    o.renderer = nil
    o.nativeUI = TetrisNativeUI:new(owner)   -- 原生 HUD / 操作按钮显隐
    o.running = false
    o.playerState = nil      -- 上屏用，惰性获取
    o.lastSeq = 0            -- 已提示过的方块生成序号
    return o
end

-- ---------------- 生命周期 ----------------
function TetrisGame:Init()
    self.board = TetrisBoard:new()
    self.renderer = TetrisRenderer:new(self.owner)
    local ok = self.renderer:Build()
    -- 刻意不在 Build 之后立刻刷新：此时实例尚未 spawn，显隐指令会被丢弃。
    -- 实际刷新交给 Start 里的稳定期调度。
    print("[Tetris] Init, 盘面 " .. TetrisConfig.Board.Cols .. "x" .. TetrisConfig.Board.Rows)
    return ok
end

function TetrisGame:Start()
    if self.running then return end
    self.running = true
    self.nativeUI:Hide()     -- 隐藏全部原生 UI，只留自建 CustomUI
    self:RegisterInput()
    self:ScheduleSettle()   -- 先让实例 spawn 完成并把显隐刷到位

    -- 开局预览：把 7 种方块摆在面前排成一排，暂停下落 N 秒供肉眼核对形状，再正式开始。
    -- 仅整体模式(wholePieceAttach)有效；回退模式不进预览，直接开始。
    local cfg = TetrisConfig.Render
    if cfg.PreviewBeforeStart and self.renderer and self.renderer.wholePieceAttach then
        local secs = cfg.PreviewSeconds or 1
        self.renderer:ShowcasePieces(secs)
        -- 预览过半时让 7 个方块演示一次旋转（90°），与下落同源，便于肉眼核对旋转是否正确。
        self.owner:AddTimerOnce(secs * 0.5, function()
            if self.renderer then self.renderer:PreviewRotateDemo() end
        end)
        self.owner:AddTimerOnce(secs, function()
            if not self.running then return end
            self.renderer:EndShowcase()
            self:ScheduleTick()
            self:CheckPieceSpawned()
            print("[Tetris] 预览结束，开始下落")
        end)
    else
        self:ScheduleTick()
        self:CheckPieceSpawned()
    end
    -- 开局初始消除：稳定期后触发，渲染层自动播放下落动画（AutoClearOnStart 时）
    if self:initialClearEnabled() then
        local delay = (TetrisConfig.Render.SettleFrames * TetrisConfig.Render.SettleInterval) + 0.2
        self.owner:AddTimerOnce(delay, function()
            if not self.running then return end
            self:ProcessInitialClears()
        end)
    end
    self:ScheduleCameraSetup()
    self:UpdateHUD()                -- 开局先置零（分数=0 消行=0 等级=1）
    print("[Tetris] Start")
end

-- 是否启用开局初始消除（配置开关）
function TetrisGame:initialClearEnabled()
    local cfg = TetrisConfig.InitialLayout
    return cfg and cfg.Enabled and cfg.AutoClearOnStart
end

-- 开局消除初始满行：数据层 clearLines(false) 仅清网格、不计分；渲染层下一帧自动播放 parent-shift 下落动画。
function TetrisGame:ProcessInitialClears()
    if self.board:isOver() then return end
    local cleared = self.board:clearLines(false)
    if cleared and cleared > 0 then
        self:UpdateHUD()            -- 开局预消会改变消行数
        -- 刷若干帧让渲染层消费 pendingClearedRows 并播放动画（独立于重力 tick）
        self:RefreshRenderer(10)
    end
end

-- 连刷 N 帧渲染（用于动画播放期间没有重力 tick 的场景，如预览/初始消除阶段）
function TetrisGame:RefreshRenderer(frames)
    local r = TetrisConfig.Render
    local iv = r.SettleInterval or 0.1
    for i = 1, (frames or 6) do
        self.owner:AddTimerOnce(i * iv + 0.05, function()
            if self.renderer and self.board then
                self.renderer:Update(self.board)
            end
        end)
    end
end

-- 固定相机：玩家/出生点装置就绪后，把相机看向棋盘中心并锁定输入（装置可能晚于代码加载生成，故重试）
function TetrisGame:ScheduleCameraSetup()
    if not (self.renderer and self.renderer.GetBoardCenter) then return end
    local tries = 0
    local maxTries = 60
    local function tick()
        tries = tries + 1
        if self:SetupFixedCamera() then return end
        if tries < maxTries and self.running then
            self.owner:AddTimerOnce(0.2, tick)
        end
    end
    tick()
end

-- 把每个玩家的相机切到棋盘中心 Actor（SetViewTarget），并锁定旋转输入，实现固定看向棋盘。
-- 棋盘中心由渲染层 ResolveOrigin 依据出生点装置(SpawnPointKey)前方 BoardForwardDistM 米算出。
-- 返回 true = 已设置；false = 尚未就绪（出生点装置/玩家未注入），调用方应稍后重试。
function TetrisGame:SetupFixedCamera()
    if type(CameraAPI) ~= "table" then
        print("[Tetris][WARN] CameraAPI 未注入，跳过固定相机")
        return true
    end
    if not self.renderer then return false end
    -- 出生点装置可能晚于 Build 注入：此处重新解析并原地重摆棋盘，确保棋盘落在出生点前方
    if not self.renderer._spawnResolved then
        self.renderer:ResolveOrigin()
        self.renderer:ReanchorBorder()  -- 出生点装置注入/朝向确定后用最新 boardRight 重摆边框
        self.renderer:ReanchorBoard()   -- 同步重摆已落定静态格：初始盘面曾用旧 boardRight 摆位，须跟随到新基准（修复初始盘面偏移）
        if not self.renderer._spawnResolved then
            return false  -- 出生点装置尚未注入，等待重试
        end
        if self.board then self.renderer:Update(self.board) end  -- 用新 origin 重摆所有格子
    end
    local center = self.renderer:GetBoardCenter()
    if not center then return false end
    local ok, arr = pcall(function() return Game:GetAllPlayerStates() end)
    if not (ok and arr and arr.Num and arr:Num() > 0) then return false end
    local cam = TetrisConfig.Camera or {}
    local back = cam.CamBackM or 3          -- 相机退后距离（米，SetCameraDistance）
    local lockMove = cam.LockMovement ~= false
    local lockRot = cam.LockRotation ~= false   -- 锁摄像机旋转（看向盘心，玩家不可自由转视角）
    -- 方案：玩家自身第三人称相机，用 SetCameraOffset / SetCameraDistance 调机位。
    -- 偏移向量（局部坐标，单位米）：X 前/后、Y 左/右、Z 上/下。全部来自 TetrisConfig.Camera：
    --   OffsetXM / OffsetYM / OffsetZM（OffsetZM 兼容旧名 ZExtraM）。
    local ox = cam.OffsetXM or 0
    local oy = cam.OffsetYM or 0
    local oz = cam.OffsetZM or cam.ZExtraM or 0
    -- 偏移向量（局部坐标，米）：X 前/后、Y 左/右、Z 上/下。用 ConstructFVectorByLuaTable 构造（与 BattleBall 项目一致，已验证有效）。
    -- 关键：BlendTime 必须 >0（传 0 会被引擎忽略，ret=true 但偏移不生效）；BattleBall 项目用 0.3。
    local off = Game:ConstructFVectorByLuaTable({ X = ox, Y = oy, Z = oz })
    for i = 0, arr:Num() - 1 do
        local ps = arr:Get(i)
        if ps then
            -- 关键诊断：okOff 只是 pcall 是否抛异常；retOff 才是引擎是否接受该参数（被吞的报错在这里）
            local okOff, retOff = pcall(function() return CameraAPI.SetCameraOffset(ps, off, 0.3) end)
            local okDist, retDist = pcall(function() return CameraAPI.SetCameraDistance(ps, back, 0.3) end)
            print(string.format("[Tetris][CAM] off=(%.1f,%.1f,%.1f) SetOffset:pcall=%s ret=%s | SetDist:pcall=%s ret=%s",
                off.X, off.Y, off.Z, tostring(okOff), tostring(retOff), tostring(okDist), tostring(retDist)))
            pcall(function() CameraAPI.LockCameraInput(ps, lockRot) end)    -- 锁视角旋转（true=锁定）
            if lockMove then pcall(function() PlayerAPI.SetPlayerSpeedMul(ps, 0) end) end  -- 锁移动
        end
    end
    return true
end

function TetrisGame:Stop()
    if not self.running then return end
    self.running = false
    self.nativeUI:Restore()  -- 回合结束还原原生 UI
    -- 还原相机与玩家状态（解锁视角/移动、复位偏移与速度）
    if type(CameraAPI) == "table" then
        local ok, arr = pcall(function() return Game:GetAllPlayerStates() end)
        if ok and arr and arr:Num() and arr:Num() > 0 then
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
    -- 销毁虚拟相机机位 Actor，避免残留堆积
    if self._camRig then
        pcall(function() if type(self._camRig.K2_DestroyActor) == "function" then self._camRig:K2_DestroyActor() end end)
        self._camRig = nil
    end
    print("[Tetris] Stop")
end

function TetrisGame:Restart()
    self.board:reset()
    self.renderer:Clear()
    self.renderer:Update(self.board)
    self:UpdateHUD()                -- 重开置零
    if self.running then
        self:ScheduleTick()
    end
    -- 重开也播放初始消除动画（实例已就绪，直接刷帧）
    if self:initialClearEnabled() then
        self:ProcessInitialClears()
    end
end

-- ---------------- 开局稳定期 ----------------
-- 实例创建后需若干帧才真正生成，开局短时间内高频反复下发显隐，
-- 确保每一格的隐藏指令都被真正执行（配合渲染层的 SetCellForce）。
function TetrisGame:ScheduleSettle()
    local r = TetrisConfig.Render
    for i = 1, r.SettleFrames do
        self.owner:AddTimerOnce(i * r.SettleInterval, function()
            if self.renderer and self.board then
                self.renderer:Update(self.board)
            end
        end)
    end
end

-- ---------------- 重力循环 ----------------
-- 注意：AddTimer(delay, func, 0) 实测不会触发，必须用 AddTimerOnce 递归。
function TetrisGame:ScheduleTick()
    if not self.running then return end
    local interval = self.board:getGravityInterval()
    self.owner:AddTimerOnce(interval, function()
        if not self.running then return end
        self:OnTick()
        self:ScheduleTick()
    end)
end

function TetrisGame:OnTick()
    local board = self.board
    if board:isOver() then
        self:OnGameOver()
        return
    end
    board:tick()                    -- 数据层下落一格或锁定
    self.renderer:Update(board)     -- 渲染层只跟随数据
    self:maybeScheduleClearResume() -- 消行挂起则延时到动画结束再出块
    self:UpdateHUD()                -- 刷新分数 / 消行 / 等级
    self:CheckPieceSpawned()        -- 产出新方块则上屏
    if board:isOver() then
        self:OnGameOver()
    end
end

-- 消行期间（board.clearing）在动画时长 ClearDelay 后调用 finishClear() 出下一个块。
-- 用 _clearResumeScheduled 防重入：多个 tick 帧只调度一次。
function TetrisGame:ScheduleClearResume()
    if self._clearResumeScheduled then return end
    self._clearResumeScheduled = true
    local delay = (TetrisConfig.Clear and TetrisConfig.Clear.ClearDelay) or 0.5
    self.owner:AddTimerOnce(delay, function()
        self._clearResumeScheduled = false
        if not self.running or not self.board then return end
        self.board:finishClear()
        if self.renderer and self.board then self.renderer:Update(self.board) end
        self:CheckPieceSpawned()
        if self.board:isOver() then self:OnGameOver() end
    end)
end

function TetrisGame:maybeScheduleClearResume()
    if self.board and self.board.clearing then
        self:ScheduleClearResume()
    end
end

-- ---------------- 调试：上屏输出 ----------------

-- 惰性获取 PlayerState。上屏 API 的首参必须是 PlayerState。
-- GetAllPlayerStates 返回 LuaArray，要用 :Num()/:Get(i)，下标从 0 起。
function TetrisGame:GetPlayerState()
    if self.playerState then return self.playerState end
    local ok, arr = pcall(function() return Game:GetAllPlayerStates() end)
    if ok and arr and arr:Num() > 0 then
        self.playerState = arr:Get(0)
    end
    return self.playerState
end

function TetrisGame:SendScreenMessage(content)
    local ps = self:GetPlayerState()
    if not ps then return end   -- 取不到玩家时只落控制台
    local ok, err = pcall(function()
        if TetrisConfig.Debug.ShowPieceInfoPopup then
            Log.SendBattlePopupMessage(ps, content)
        else
            Log.SendQuickMenuMessage(ps, content)
        end
    end)
    if not ok then
        print("[Tetris][WARN] 上屏失败: " .. tostring(err))
    end
end

-- 每次生成新下落方块时上报一次信息
-- 分数 / 消行 / 等级 HUD：通过预置的 CustomUI 文本控件显示（CustomUIAPI.SetTextContent）。
-- 控件 UUID 见 TetrisConfig.UI.*Label；任意一项未配置则自动跳过（不报错）。
function TetrisGame:UpdateHUD()
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
    set(ui.LinesLabel, "消行: " .. tostring(b.lines))
    set(ui.LevelLabel, "等级: " .. tostring(b.level))
end

function TetrisGame:CheckPieceSpawned()
    if not TetrisConfig.Debug.ShowPieceInfo then return end
    local s = self.board and self.board.lastSpawned
    if not s or s.seq == self.lastSeq then return end
    self.lastSeq = s.seq

    local function pieceName(t)
        local def = TetrisConfig.Pieces[t]
        return (def and def.name) or "?"
    end
    local nxt = {}
    for i = 1, math.min(3, #self.board.nextQueue) do
        nxt[#nxt + 1] = pieceName(self.board.nextQueue[i])
    end

    -- string.format 的 %d 遇到 nil 会直接报错并中断后续逻辑，故统一用 %s 兜底
    local msg = string.format("方块[%s] #%s 起点=(行%s,列%s) 下一个=%s 分数=%s 消行=%s 等级=%s",
        tostring(pieceName(s.type)), tostring(s.seq), tostring(s.y), tostring(s.x),
        table.concat(nxt, ","), tostring(self.board.score),
        tostring(self.board.lines), tostring(self.board.level))
    self:SendScreenMessage(msg)
end

function TetrisGame:OnGameOver()
    local msg = "游戏结束 分数=" .. tostring(self.board.score)
        .. " 消行=" .. tostring(self.board.lines)
    self.running = false
    self:UpdateHUD()                -- 结束时定格最终分数
    if TetrisConfig.Debug.ShowGameOverInfo then
        self:SendScreenMessage(msg)
    end
end

-- ---------------- UI 输入 ----------------
-- CustomUIClicked(120000)：@listen InstanceID 用于按控件过滤，@output 为点击的 PlayerState。
-- 每个按钮注册独立监听，因此回调里无需再判断来源。
function TetrisGame:RegisterInput()
    local ui = TetrisConfig.UI
    -- 读全局表；若尚未注入则回退到事件号字面量 120000
    local id = (type(RcEventIdDefine) == "table" and RcEventIdDefine.CustomUIClicked) or 120000
    if id == 120000 then
        print("[Tetris][WARN] RcEventIdDefine 未注入，使用字面量 120000")
    end

    local function bind(instanceID, handler)
        if instanceID == nil then
            print("[Tetris][WARN] 跳过未配置的按钮（InstanceUUID 为 nil）")
            return
        end
        self.owner:AddVPEvent(id, handler, self, instanceID, nil)
    end

    bind(ui.BtnLeft, TetrisGame.OnBtnLeft)
    bind(ui.BtnRight, TetrisGame.OnBtnRight)
    bind(ui.BtnRoll, TetrisGame.OnBtnRoll)
    bind(ui.BtnDown, TetrisGame.OnBtnDown)
    bind(ui.BtnHold, TetrisGame.OnBtnHold)
    bind(ui.BtnSkill, TetrisGame.OnBtnSkill)
    print("[Tetris] UI 输入已注册")
end

-- 统一安全调用：单个操作出错不应中断整局
function TetrisGame:safeApply(fn)
    if not self.running or self.board:isOver() then return end
    local ok, err = pcall(fn)
    if not ok then
        print("[Tetris][ERROR] 操作异常: " .. tostring(err))
        return
    end
    self.renderer:Update(self.board)
    self:maybeScheduleClearResume() -- 消行挂起则延时到动画结束再出块
    self:UpdateHUD()                -- 刷新分数 / 消行 / 等级
    self:CheckPieceSpawned()
    if self.board:isOver() then
        self:OnGameOver()
    end
end

function TetrisGame:OnBtnLeft()
    self:safeApply(function() self.board:move(-1) end)
end

function TetrisGame:OnBtnRight()
    self:safeApply(function() self.board:move(1) end)
end

function TetrisGame:OnBtnRoll()
    self:safeApply(function() self.board:rotate(1) end)
end

-- down 键 = 硬降（本作不提供软降）
function TetrisGame:OnBtnDown()
    self:safeApply(function() self.board:hardDrop() end)
end

function TetrisGame:OnBtnHold()
    self:safeApply(function() self.board:hold() end)
end

-- 技能：本期占位，技能系统属后续阶段
function TetrisGame:OnBtnSkill()
    if not TetrisConfig.SkillEnabled then
        print("[Tetris] 技能按钮（未启用）")
        return
    end
end

return TetrisGame
