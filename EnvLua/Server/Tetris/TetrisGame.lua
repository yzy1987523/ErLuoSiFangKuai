-- 游戏控制器：串联数据层与渲染层，负责重力 tick、UI 输入路由、生命周期。
-- 本模块不是 WoWObject，定时器与事件都借宿在 owner（ServerGameMain）上。
-- RcEventIdDefine.lua 内部是 "RcEventIdDefine = {...}"（全局表，无 return），
-- require 只会返回 nil，因此这里仅取它的"加载副作用"，使用时读全局。
pcall(require, "EnvLua.Core.Define.RcEventIdDefine")

local TetrisConfig = require("EnvLua.Server.Tetris.TetrisConfig")
local TetrisBoard = require("EnvLua.Server.Tetris.TetrisBoard")
local TetrisRenderer = require("EnvLua.Server.Tetris.TetrisRenderer")
local TetrisAI = require("EnvLua.Server.Tetris.TetrisAI")

local TetrisGame = {}
TetrisGame.__index = TetrisGame

function TetrisGame:new(owner, opts)
    local o = setmetatable({}, TetrisGame)
    o.owner = owner          -- WoWObject，用于 AddTimerOnce / AddVPEvent
    o.board = nil
    o.renderer = nil
    o.running = false
    o.playerState = (opts and opts.playerState) or nil  -- 上屏用；对战模式下由 Match 赋值
    o.playerKey = nil
    o.match = (opts and opts.match) or nil    -- 双人对战总控（存在则由它统一注册输入/判定胜负）
    o.spawnPointKey = (opts and opts.spawnPointKey) or nil
    o.index = (opts and opts.index) or 0
    o.opponent = nil         -- 对手实例（环形互指）
    o.lastSeq = 0            -- 已提示过的方块生成序号
    o.skillBars = 0          -- 当前 bar 数（0~NeedBars-1）；集满 NeedBars 兑换 1 power 后清零
    o.skillPower = 0         -- 当前 power 数（0~MaxPower）；释放技能消耗 1 个
    o.isAI = false           -- 是否 AI 托管（对手盘自动对战）
    o.aiSeq = 0              -- AI 已规划到的 spawnSeq（避免同一块重复规划）
    o.selectedSkill = nil    -- 本盘所选技能 key（"SK01"/"SK02"/"SK06"），由 Match 在开局前赋值
    o._shownHold = false     -- 当前 Hold 组件显隐状态：false=隐藏，数字=已显示的方块类型
    o._shownNext = false     -- 当前 Next 组件显隐状态：false=隐藏，数字=已显示的方块类型
    return o
end

-- ---------------- 生命周期 ----------------
function TetrisGame:Init(spawnPointKey)
    self.board = TetrisBoard:new()
    self.renderer = TetrisRenderer:new(self.owner)
    local ok = self.renderer:Build(spawnPointKey or self.spawnPointKey)
    -- 刻意不在 Build 之后立刻刷新：此时实例尚未 spawn，显隐指令会被丢弃。
    -- 实际刷新交给 Start 里的稳定期调度。
    print("[Tetris] Init, 盘面 " .. TetrisConfig.Board.Cols .. "x" .. TetrisConfig.Board.Rows)
    return ok
end

function TetrisGame:Start()
    if self.running then return end
    self.running = true
    -- 原生 UI 已在 ServerGameMain:OnStart（玩家打开游戏）统一屏蔽，此处不再重复触发
    if not self.match then
        self:RegisterInput()  -- 对战模式下由 TetrisMatch 统一注册并按玩家路由
    end
    self:ScheduleSettle()   -- 先让实例 spawn 完成并把显隐刷到位

    -- 开局先隐藏 Hold / Next 组件：尚未有方块时不应显示空槽（避免首帧闪烁）。
    do
        local ui = TetrisConfig.UI
        local ps = self:GetPlayerState()
        if ui and ps and type(CustomUIAPI) == "table" then
            pcall(function() if ui.HoldImg then CustomUIAPI.SetWidgetVisible(ps, ui.HoldImg, false) end end)
            pcall(function() if ui.NextImg then CustomUIAPI.SetWidgetVisible(ps, ui.NextImg, false) end end)
        end
    end

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
    -- 相机：AI 盘不锁；AI 在场且开启 FreeLook 时人类也不锁，便于观察双方盘面
    local lockCam = not self.isAI
    if lockCam and self.match and self.match:hasAI()
       and TetrisConfig.AI and TetrisConfig.AI.FreeLook then
        lockCam = false
    end
    if lockCam then self:ScheduleCameraSetup() end
    self:UpdateHUD()                -- 开局先置零（分数=0 消行=0 等级=1）
    self:InitSkillUI()              -- 技能：说明文本 + 蓄能条置零
    print("[Tetris] Start")
end

-- 旁观盘（无人控制）：仅实例化并渲染盘面 + 预览方块，不锁定相机 / 不接收输入 / 不自动下落。
-- 用于单人时也能展示「另一块棋盘」的布局（不被玩家数量门控）；不会触发 top-out，因此不会误判胜负。
function TetrisGame:StartSpectator()
    self.running = true
    self.previewShown = false
    self.owner:AddTimerOnce(0.5, function()
        if not self.running then return end
        self.renderer:Update(self.board)   -- 摆好边框与空格子（边框可见，呈现棋盘外形）
        if not self.previewShown then
            if self.renderer and self.renderer.wholePieceAttach then
                self.renderer:ShowcasePieces(2)   -- 棋盘上方展示 7 个预览方块，明确「这是一块棋盘」
            end
            self.previewShown = true
        end
    end)
end

-- 把本盘分配的玩家传送到出生点装置位置。
-- 时机：玩法选择结束之后、相机锁定之前（先站到出生点，再由 Start 锁定相机看向盘心）。
-- 单位：InstanceAPI.GetInstanceLocation 与 PlayerAPI.TeleportPawn 同为 Domain API，均为米，无需换算。
-- 来源：EnvLua/Core/LuaHint/PlayerAPI.lua:245 TeleportPawn(PlayerState, SetToLocation)
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
    -- 对战：仅把相机设给「本实例分配的玩家」；单人/未分配时退化为全部玩家
    local targets = {}
    if self.playerState then
        targets = { self.playerState }
    else
        for i = 0, arr:Num() - 1 do
            local ps = arr:Get(i)
            if ps then targets[#targets + 1] = ps end
        end
    end
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
    for _, ps in ipairs(targets) do
            -- 关键诊断：okOff 只是 pcall 是否抛异常；retOff 才是引擎是否接受该参数（被吞的报错在这里）
            local okOff, retOff = pcall(function() return CameraAPI.SetCameraOffset(ps, off, 0.3) end)
            local okDist, retDist = pcall(function() return CameraAPI.SetCameraDistance(ps, back, 0.3) end)
            print(string.format("[Tetris][CAM] off=(%.1f,%.1f,%.1f) SetOffset:pcall=%s ret=%s | SetDist:pcall=%s ret=%s",
                off.X, off.Y, off.Z, tostring(okOff), tostring(retOff), tostring(okDist), tostring(retDist)))
            pcall(function() CameraAPI.LockCameraInput(ps, lockRot) end)    -- 锁视角旋转（true=锁定）
            if lockMove then pcall(function() PlayerAPI.SetPlayerSpeedMul(ps, 0) end) end  -- 锁移动
    end
    return true
end

function TetrisGame:Stop()
    if not self.running then return end
    self.running = false
    -- 原生 UI 在进入游戏时即屏蔽，且不再还原（保持隐藏直到进程结束）
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
    self:maybeScheduleLockFlash()   -- 锁定后满行：先渲染展示 LockFlashDelay 秒，再消行
    self:flushOutgoingGarbage()     -- 对战：把本步消除产生的垃圾行发给对手
    self.renderer:Update(board)     -- 渲染层只跟随数据
    self:maybeScheduleClearResume() -- 消行挂起则延时到动画结束再出块
    self:UpdateHUD()                -- 刷新分数 / 消行 / 等级
    self:CheckPieceSpawned()        -- 产出新方块则上屏
    self:CheckReceivedGarbage()    -- 本步是否被对手扔了垃圾（无满行→lockPiece 内已注入）
    if self.isAI then self:aiStep() end   -- AI：定位本块 + 蓄满放技能
    if board:isOver() then
        self:OnGameOver()
    end
end

-- 锁定后满行：在 LockFlashDelay 秒的"落地停顿"内渲染展示锁定态（满行亮起的一瞬），
-- 停顿结束后调用 board:doClear() 执行真正的消行，再走现有 ClearDelay 下落动画。
-- 用 _lockFlashScheduled 防重入：hardDrop 与重力 tick 都可能触发锁定，只调度一次。
function TetrisGame:maybeScheduleLockFlash()
    if not self.board or not self.board.lockPaused then return end
    if self._lockFlashScheduled then return end
    self._lockFlashScheduled = true
    local fd = (TetrisConfig.Clear and TetrisConfig.Clear.LockFlashDelay) or 0.35
    self.owner:AddTimerOnce(fd, function()
        self._lockFlashScheduled = false
        if not self.running or not self.board then return end
        local cleared = self.board:doClear()
        self:onLinesCleared(cleared)    -- 技能蓄能：累计消行次数
        self:flushOutgoingGarbage()     -- 消行产生的垃圾行发给对手
        self:CheckReceivedGarbage()    -- 有满行→doClear 内 applyGarbage 已注入垃圾，弹提示
        if self.renderer and self.board then self.renderer:Update(self.board) end
        self:maybeScheduleClearResume() -- clearing=true → 等 ClearDelay 后 finishClear
        self:UpdateHUD()
        self:CheckPieceSpawned()
        if self.board:isOver() then self:OnGameOver() end
    end)
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
    if self.isAI then return nil end   -- AI 盘不向任何玩家写 HUD/相机
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
    local ps = self:GetPlayerState()
    if not ps or type(CustomUIAPI) ~= "table" then return end
    self:UpdateHoldNextUI()                       -- 2D Hold / Next 方块预览
    self:UpdateOpponentHUD()                      -- 对手分数
    local ui = TetrisConfig.UI
    if not (ui.ScoreLabel or ui.LinesLabel or ui.LevelLabel) then return end
    local function set(id, text)
        if not id then return end
        pcall(function() CustomUIAPI.SetTextContent(ps, id, text) end)
    end
    set(ui.ScoreLabel, "分数: " .. tostring(b.score))
    set(ui.LinesLabel, "消行: " .. tostring(b.lines))
    set(ui.LevelLabel, "等级: " .. tostring(b.level))
end

-- 2D UI：把 Hold / Next 方块显示到图片组件（SetImageWidgetContent 换图）。
-- 仅当方块类型变化时才下发，避免每帧重复 set；无暂存 / 无预览时隐藏对应组件。
-- 控件 / 图片资源见 TetrisConfig.UI.HoldImg / NextImg / TetrisConfig.PieceImages。
function TetrisGame:UpdateHoldNextUI()
    local b = self.board
    if not b then return end
    local ui = TetrisConfig.UI
    if not (ui and (ui.HoldImg or ui.NextImg)) then return end
    local imgs = TetrisConfig.PieceImages
    local ps = self:GetPlayerState()
    if not ps or type(CustomUIAPI) ~= "table" then return end

    -- 把 PieceImages[type] 的 AssetRef 键解析成实际 ImageID（与项目里特效/方块预设解析一致）
    local function resolveImg(t)
        local key = (t and imgs) and imgs[t] or nil
        if not key then return nil end
        return (type(AssetRef) == "table" and AssetRef[key]) or key
    end

    -- Hold（board.holdType：1..7 或 nil）
    if ui.HoldImg then
        local ht = b:getHoldType()
        local imgID = resolveImg(ht)
        if imgID then
            if self._shownHold ~= ht then
                pcall(function()
                    CustomUIAPI.SetImageWidgetContent(ps, ui.HoldImg, imgID)
                    CustomUIAPI.SetWidgetVisible(ps, ui.HoldImg, true)
                end)
                self._shownHold = ht
            end
        elseif self._shownHold ~= false then
            pcall(function() CustomUIAPI.SetWidgetVisible(ps, ui.HoldImg, false) end)
            self._shownHold = false
        end
    end

    -- Next（预览队列首个：nextQueue[1]）
    if ui.NextImg then
        local nq = b:getNextQueue()
        local nt = (nq and nq[1]) or nil
        local imgID = resolveImg(nt)
        if imgID then
            if self._shownNext ~= nt then
                pcall(function()
                    CustomUIAPI.SetImageWidgetContent(ps, ui.NextImg, imgID)
                    CustomUIAPI.SetWidgetVisible(ps, ui.NextImg, true)
                end)
                self._shownNext = nt
            end
        elseif self._shownNext ~= false then
            pcall(function() CustomUIAPI.SetWidgetVisible(ps, ui.NextImg, false) end)
            self._shownNext = false
        end
    end
end

-- 把对手分数显示到 2D 文本（TetrisConfig.UI.OpponentScoreLabel）。
-- 对手即 self.opponent（对战 / 人机互指，已在 TetrisMatch:Start 设置）；读其 board.score 刷给本玩家。
function TetrisGame:UpdateOpponentHUD()
    local id = TetrisConfig.UI and TetrisConfig.UI.OpponentScoreLabel
    if not id then return end
    local ps = self:GetPlayerState()
    if not ps or type(CustomUIAPI) ~= "table" then return end
    local opp = self.opponent
    local score = (opp and opp.board and opp.board.score) or 0
    pcall(function() CustomUIAPI.SetTextContent(ps, id, "" .. tostring(score)) end)
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

-- 对战：把本局消除产生的「攻击垃圾行」发给对手（写入对手 board.pendingGarbage，
-- 对手下次 lockPiece 时由 applyGarbage 注入底部）。无对手 / 已结束则不发。
function TetrisGame:flushOutgoingGarbage()
    local b = self.board
    if not b then return end
    local n = b:consumeOutgoingGarbage()
    if not n or n <= 0 then return end
    if self.match and self.match.over then return end
    if self.opponent and self.opponent.board and not self.opponent.board:isOver() then
        self.opponent.board:addGarbage(n)
        self:ShowHint("即将给对手扔出 " .. tostring(n) .. " 行垃圾！")   -- 消行攻击提示
        if TetrisConfig.Debug and TetrisConfig.Debug.PrintGarbage then
            print(string.format("[Tetris][Versus] 玩家 %s 消行 → 给对手发 %d 行垃圾", tostring(self.playerKey), n))
        end
    end
end

function TetrisGame:OnGameOver()
    local msg = "游戏结束 分数=" .. tostring(self.board.score)
        .. " 消行=" .. tostring(self.board.lines)
    self.running = false
    self:UpdateHUD()                -- 结束时定格最终分数
    if self.match then self.match:OnPlayerOut(self) end  -- 对战：上报总控判胜负
    if TetrisConfig.Debug.ShowGameOverInfo then
        self:SendScreenMessage(msg)
    end
end

-- ---------------- UI 输入 ----------------
-- CustomUIClicked(120000)：@listen InstanceID 用于按控件过滤，@output 为点击的 PlayerState。
-- 每个按钮注册独立监听，因此回调里无需再判断来源。
function TetrisGame:RegisterInput()
    local ui = TetrisConfig.UI
    -- 读全局表；若尚未注入则回退到事件号字面量
    local id     = (type(RcEventIdDefine) == "table" and RcEventIdDefine.CustomUIClicked) or 120000
    local idLong = (type(RcEventIdDefine) == "table" and RcEventIdDefine.CustomUILongPressed) or 120001
    local idRel  = (type(RcEventIdDefine) == "table" and RcEventIdDefine.CustomUILongPressReleased) or 120002
    if id == 120000 then
        print("[Tetris][WARN] RcEventIdDefine 未注入，使用字面量 120000/120001/120002")
    end

    local function bind(instanceID, handler, evtId)
        evtId = evtId or id
        if instanceID == nil then
            print("[Tetris][WARN] 跳过未配置的按钮（InstanceUUID 为 nil）")
            return
        end
        self.owner:AddVPEvent(evtId, handler, self, instanceID, nil)
    end

    bind(ui.BtnLeft, TetrisGame.OnBtnLeft)
    bind(ui.BtnRight, TetrisGame.OnBtnRight)
    bind(ui.BtnRoll, TetrisGame.OnBtnRoll)
    bind(ui.BtnDown, TetrisGame.OnBtnDown)
    bind(ui.BtnHold, TetrisGame.OnBtnHold)
    bind(ui.BtnSkill, TetrisGame.OnBtnSkill)
    -- 左右键长按：长按进入连发（DAS/ARR）
    bind(ui.BtnLeft, TetrisGame.OnBtnLeftHold, idLong)
    bind(ui.BtnLeft, TetrisGame.OnBtnLeftRelease, idRel)
    bind(ui.BtnRight, TetrisGame.OnBtnRightHold, idLong)
    bind(ui.BtnRight, TetrisGame.OnBtnRightRelease, idRel)
    -- 下键长按：长按软降、抬起停止
    bind(ui.BtnDown, TetrisGame.OnBtnDownHold, idLong)
    bind(ui.BtnDown, TetrisGame.OnBtnDownRelease, idRel)
    print("[Tetris] UI 输入已注册（含左右/下长按）")
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
    self:flushOutgoingGarbage()     -- 对战：把本步消除产生的垃圾行发给对手
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

-- ---------------- 左右键长按（DAS/ARR 自动横移） ----------------
-- 短按：OnBtnLeft/Right 已处理（点一次移一格）。
-- 长按：引擎 CustomUILongPressed 触发 OnBtnXxxHold（StartMoveRepeat），
--       CustomUILongPressReleased 触发 OnBtnXxxRelease（StopMoveRepeat）。
function TetrisGame:OnBtnLeftHold()
    if not TetrisConfig.Input or TetrisConfig.Input.LongPressEnabled then
        self:StartMoveRepeat(-1)
    end
end

function TetrisGame:OnBtnRightHold()
    if not TetrisConfig.Input or TetrisConfig.Input.LongPressEnabled then
        self:StartMoveRepeat(1)
    end
end

function TetrisGame:OnBtnLeftRelease()
    self:StopMoveRepeat()
end

function TetrisGame:OnBtnRightRelease()
    self:StopMoveRepeat()
end

-- 启动左右长按连发：先立即移一格（按下即响应），再过 DAS 间隔进入 ARR 连发。
-- 用 _moveHoldGen 代际令牌防止残留定时器串扰（快速松按之间旧链自动失效）。
function TetrisGame:StartMoveRepeat(dir)
    if not self.running or (self.board and self.board:isOver()) then return end
    self._moveHoldDir = dir
    self._moveHoldGen = (self._moveHoldGen or 0) + 1
    local gen = self._moveHoldGen
    local cfg = TetrisConfig.Input or {}
    local das = cfg.DAS or 0.16
    local arr = cfg.ARR or 0.06
    local selfRef = self
    selfRef:safeApply(function() selfRef.board:move(dir) end)
    local function repeatStep()
        if not selfRef.running or selfRef._moveHoldGen ~= gen or selfRef._moveHoldDir ~= dir then
            return
        end
        selfRef:safeApply(function() selfRef.board:move(dir) end)
        selfRef.owner:AddTimerOnce(arr, repeatStep)
    end
    self.owner:AddTimerOnce(das, repeatStep)
end

-- 停止长按连发：抬换代际令牌，pending 定时器下一帧自检失效后不再续发。
function TetrisGame:StopMoveRepeat()
    self._moveHoldDir = nil
    self._moveHoldGen = (self._moveHoldGen or 0) + 1
end

function TetrisGame:OnBtnRoll()
    self:safeApply(function() self.board:rotate(1) end)
end

-- down 键：短按 = 硬降（落到底并锁定）；长按 = 软降（见 OnBtnDownHold）。
function TetrisGame:OnBtnDown()
    self:safeApply(function() self.board:hardDrop() end)
    self:maybeScheduleLockFlash()   -- 硬降直接锁定，需触发落地停顿调度（不走重力 tick）
end

-- ---------------- 下键长按（软降连发） ----------------
-- 短按（OnBtnDown）已做硬降；长按进入软降：每 SoftDropInterval 下落一格，松手即停。
function TetrisGame:OnBtnDownHold()
    if not TetrisConfig.Input or TetrisConfig.Input.LongPressEnabled then
        self:StartSoftDrop()
    end
end

function TetrisGame:OnBtnDownRelease()
    self:StopSoftDrop()
end

-- 启动软降连发：按 Timing.SoftDropInterval 间隔持续 softDrop()，触底时 softDrop 自动 no-op。
-- 用 _softDropGen 代际令牌防止残留定时器串扰。
function TetrisGame:StartSoftDrop()
    if not self.running or (self.board and self.board:isOver()) then return end
    self._softDropGen = (self._softDropGen or 0) + 1
    local gen = self._softDropGen
    local interval = (TetrisConfig.Timing and TetrisConfig.Timing.SoftDropInterval) or 0.05
    local selfRef = self
    local function step()
        if not selfRef.running or selfRef._softDropGen ~= gen then return end
        selfRef:safeApply(function() selfRef.board:softDrop() end)
        selfRef.owner:AddTimerOnce(interval, step)
    end
    self.owner:AddTimerOnce(interval, step)
end

function TetrisGame:StopSoftDrop()
    self._softDropGen = (self._softDropGen or 0) + 1
end

function TetrisGame:OnBtnHold()
    self:safeApply(function() self.board:hold() end)
end

-- ---------------- 技能（蓄能条 + 释放） ----------------
-- 蓄能：每消除 1 行得 1 个 bar；集满 NeedBars 个 bar 兑换 1 个 power（bar 清零）。
-- 释放：点击技能按钮 → 若有 power，消耗 1 个 power 发动所选技能效果。
-- 控件 UUID 见 TetrisConfig.Skill.Bars / PowerSlots / DescText / IconImage。

-- 返回本盘所选技能的定义（TetrisConfig.Skills[key]）；无则回退默认技能
function TetrisGame:GetSelectedSkillDef()
    local key = self.selectedSkill
        or (TetrisConfig.SkillSelect and TetrisConfig.SkillSelect.DefaultSkill)
    return (key and TetrisConfig.Skills and TetrisConfig.Skills[key]) or nil
end

-- 开局初始化：写说明文本（替换为所选技能说明）+ 蓄能条置零 + 把局内技能按钮图片换成所选技能
function TetrisGame:InitSkillUI()
    local cfg = TetrisConfig.Skill
    if not cfg then return end
    self.skillBars = 0
    self.skillPower = 0
    local ps = self:GetPlayerState()
    if ps and type(CustomUIAPI) == "table" then
        -- 说明文本：用所选技能的 desc 替换通用说明
        local def = self:GetSelectedSkillDef()
        local desc = (def and def.desc) or cfg.Desc or ""
        if cfg.DescText then
            pcall(function() CustomUIAPI.SetTextContent(ps, cfg.DescText, desc) end)
        end
        -- 局内技能 icon 图片：换成所选技能的图片（ApplyImageToSkillIcon 开关）
        if TetrisConfig.SkillSelect and TetrisConfig.SkillSelect.ApplyImageToSkillIcon
           and def and def.imageKey and cfg.IconImage then
            local imgID = (type(AssetRef) == "table" and AssetRef[def.imageKey]) or def.imageKey
            pcall(function() CustomUIAPI.SetImageWidgetContent(ps, cfg.IconImage, imgID) end)
        end
    end
    if TetrisConfig.HintText then
        pcall(function() CustomUIAPI.SetWidgetVisible(ps, TetrisConfig.HintText, false) end)
    end
    self:UpdateSkillUI()
end

-- 本次 lock 消行后按「行数」累加 bar（cleared = 本次消除行数）
--   每消除 1 行得 1 个 bar；集满 NeedBars 个 bar 兑换 1 个 power（bar 清零）；最多持有 MaxPower 个 power。
function TetrisGame:onLinesCleared(cleared)
    if not cleared or cleared <= 0 then return end
    local cfg = TetrisConfig.Skill
    if not cfg then return end
    local needBars = cfg.NeedBars or 3
    local maxPower = cfg.MaxPower or 3
    for _ = 1, cleared do
        if self.skillPower >= maxPower then break end   -- power 已满，不再累积 bar
        self.skillBars = self.skillBars + 1
        if self.skillBars >= needBars then
            self.skillBars = 0
            self.skillPower = math.min(self.skillPower + 1, maxPower)
        end
    end
    self:UpdateSkillUI()
end

-- 刷新技能 UI：bar 图片按当前 bar 数显隐；power 图片组件按当前 power 数换「有/无」图
function TetrisGame:UpdateSkillUI()
    local cfg = TetrisConfig.Skill
    if not cfg then return end
    local ps = self:GetPlayerState()
    if not ps or type(CustomUIAPI) ~= "table" then return end

    -- bar 图片：bar0..bar2 分别表示第 1~3 格；bar 数 >= 该格序号则显示
    local bars = cfg.Bars or {}
    for i, id in ipairs(bars) do
        pcall(function() CustomUIAPI.SetWidgetVisible(ps, id, self.skillBars >= i) end)
    end

    -- power 图片组件：按 power 数把对应槽位替换为「有 power」图，其余为「无 power」图
    local slots = cfg.PowerSlots or {}
    local emptyID = (type(AssetRef) == "table" and AssetRef[cfg.PowerEmptyImg]) or cfg.PowerEmptyImg
    local fullID  = (type(AssetRef) == "table" and AssetRef[cfg.PowerFullImg]) or cfg.PowerFullImg
    for i, id in ipairs(slots) do
        local imgID = (self.skillPower >= i) and fullID or emptyID
        pcall(function() CustomUIAPI.SetImageWidgetContent(ps, id, imgID) end)
    end

    -- 技能按钮：有 power 才可交互，无 power 禁用（避免玩家空点）
    local btn = TetrisConfig.UI.BtnSkill
    if btn then
        pcall(function() CustomUIAPI.SetWidgetInteraction(ps, btn, self.skillPower > 0) end)
    end
end

-- 技能按钮：蓄满才释放；按本盘所选技能决定效果，释放后清空蓄能。
--   SK01 禁止转动：给对手盘注入 noRotateNext，其下一块无法旋转（敌方减益）
--   SK02 清除最下方两行：本盘网格下移 clearRows 行（己方增益，不计分/不送攻击）
--   SK06 攻势：本盘 attackBonusNext=1，下次消行攻击行数 +1（己方增益）
--   其他 / 兜底：沿用原「向对手扔垃圾」逻辑
function TetrisGame:OnBtnSkill()
    if not TetrisConfig.SkillEnabled then
        print("[Tetris] 技能按钮（未启用）")
        return
    end
    if not self.running or (self.board and self.board:isOver()) then return end
    local cfg = TetrisConfig.Skill
    if not cfg then return end
    if self.skillPower <= 0 then
        print("[Tetris][Skill] power 不足，无法释放")
        self:ShowHint("技能 power 不足，无法释放！")
        return
    end
    self.skillPower = self.skillPower - 1

    local key = self.selectedSkill
        or (TetrisConfig.SkillSelect and TetrisConfig.SkillSelect.DefaultSkill) or "SK02"
    local over = self.match and self.match.over

    if key == "SK01" then
        -- 敌方减益：对手接下来 1 个方块无法旋转
        if self.opponent and self.opponent.board and not self.opponent.board:isOver() and not over then
            self.opponent.board.noRotateNext = (self.opponent.board.noRotateNext or 0) + 1
        end
        self:ShowHint("技能【禁止转动】发动：对手下个方块无法旋转！")
    elseif key == "SK02" then
        -- 己方增益：清除最下方两行
        local def = self:GetSelectedSkillDef()
        local n = (def and def.clearRows) or 2
        local cleared = self.board:clearBottomRows(n)
        self.renderer:Update(self.board)
        self:ShowHint("技能【清除最下方 " .. tostring(cleared) .. " 行】发动！")
    elseif key == "SK06" then
        -- 己方增益：下次消行攻击 +1
        self.board.attackBonusNext = (self.board.attackBonusNext or 0) + 1
        self:ShowHint("技能【攻势】发动：下次消行攻击行数 +1！")
    else
        -- 兜底：未知技能 key（正常不会走到，selectedSkill 必为 SK01/02/06）
        print("[Tetris][Skill] 未知技能 key：" .. tostring(key))
    end

    self:UpdateSkillUI()
    print("[Tetris][Skill] 释放技能 " .. tostring(key) .. "（玩家 " .. tostring(self.playerKey) .. "）")
end

-- ---------------- 通用游戏提示（飘字，显示 1 秒后隐藏） ----------------
-- 文本控件见 TetrisConfig.HintText。每次调用刷新内容与显示，1 秒后自动隐藏；
-- 用 _hintSeq 防止「连续提示时旧的定时器提前把新的提示隐藏」。
function TetrisGame:ShowHint(text)
    local id = TetrisConfig.HintText
    if not id or type(CustomUIAPI) ~= "table" then return end
    local ps = self:GetPlayerState()
    if not ps then return end
    self._hintSeq = (self._hintSeq or 0) + 1
    local seq = self._hintSeq
    pcall(function()
        CustomUIAPI.SetTextContent(ps, id, text or "")
        CustomUIAPI.SetWidgetVisible(ps, id, true)
    end)
    if self.owner and self.owner.AddTimerOnce then
        local dur = TetrisConfig.HintDuration or 1
        self.owner:AddTimerOnce(dur, function()
            if self._hintSeq ~= seq then return end   -- 已被新提示覆盖，不隐藏
            pcall(function() CustomUIAPI.SetWidgetVisible(ps, id, false) end)
        end)
    end
end

-- 检测本盘刚被注入的垃圾行数（board.lastAppliedGarbage），有则弹提示并清零
function TetrisGame:CheckReceivedGarbage()
    if not self.board or not self.board.lastAppliedGarbage or self.board.lastAppliedGarbage <= 0 then
        return
    end
    local n = self.board.lastAppliedGarbage
    self.board.lastAppliedGarbage = 0
    self:ShowHint("你被对手扔来 " .. tostring(n) .. " 行垃圾！")
end

-- ---------------- AI 决策（对手盘自动对战） ----------------
-- 每块新方块生成后调用一次：用 TetrisAI 选最优（朝向 + 列），旋转/平移到位后
-- 交还给重力自然下落（可见「落点被自动选好 + 方块掉落」）。蓄满则自动放技能。
function TetrisGame:aiStep()
    if not self.isAI or not self.running then return end
    local b = self.board
    if not b or b:isOver() or b.clearing or b.lockPaused then return end

    -- 有 power 自动放技能（按本盘所选技能效果）
    local scfg = TetrisConfig.Skill
    if scfg and self.skillPower >= 1 then
        self:OnBtnSkill()
    end

    local a = b:getActive()
    if not a then return end
    if self.aiSeq == b.spawnSeq then return end   -- 本块已规划，不再动
    local plan = TetrisAI.bestMove(b)
    self.aiSeq = b.spawnSeq
    if not plan then return end

    -- 旋转到目标朝向（带 SRS 踢墙，最多尝试 4 次）
    local guard = 0
    while b.active and b.active.rot ~= plan.rot and guard < 5 do
        if not b:rotate(1) then break end
        guard = guard + 1
    end
    -- 水平平移到目标列（到顶后由重力自然下落）
    guard = 0
    while b.active and b.active.x ~= plan.x and guard < (b.cols + 2) do
        local dx = b.active.x < plan.x and 1 or -1
        if not b:move(dx) then break end
        guard = guard + 1
    end
    if self.renderer then self.renderer:Update(b) end
end

return TetrisGame
