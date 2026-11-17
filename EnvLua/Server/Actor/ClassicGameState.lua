---@class ClassicGameState:WoWClassicGameState
-- 服务端 GameState 挂载脚本。P0 验证：注册 C→S 白名单 + 向客户端广播 ping。
local ClassicGameState = {}

local WoWClassicGameState = require("EnvLua.Core.WoWClassicGameState")

-- 排行榜类型：CustomRank[RankType]，未注入时回退数字（与 TetrisMatch:LeaderboardRankType 一致）
local function rankType(Config)
    local name = (Config.Leaderboard and Config.Leaderboard.RankType) or "Rank1"
    if type(CustomRank) ~= "table" then pcall(require, "EnvLua.Core.Define.CommonDefine") end
    if type(CustomRank) == "table" and CustomRank[name] ~= nil then return CustomRank[name] end
    local map = { Rank1 = 1, Rank2 = 2, Rank3 = 3, Rank4 = 4, Rank5 = 5 }
    return map[name] or 1
end

--- Callback after Actor BeginPlay.
-- 延迟广播，确保客户端 GameState 已就绪并能收到同名方法调用。
function ClassicGameState:OnReceiveBeginPlay()
    print("[P0][Server/GS] OnReceiveBeginPlay 触发")

    -- 1) 注册 C→S 白名单方法（后续客户端可 CallServerFunction("P0_OnClientPing")）
    local okReg, errReg = pcall(function()
        self:RegisterServerFunction("P0_OnClientPing")
        self:RegisterServerFunction("P2_OnSnapshotAck")  -- [P2] 快照回执白名单
        self:RegisterServerFunction("P5_ReportResult")       -- [P5] 结算上报
        self:RegisterServerFunction("P5_RequestLeaderboard") -- [P5] 排行榜请求
        self:RegisterServerFunction("P5_RequestAI")          -- [P5-5b] 单人请求启动 AI
        self:RegisterServerFunction("P5_ReportSnapshot")     -- [P5-5b] 双人快照中转
        self:RegisterServerFunction("P7_HideMasks")          -- [P7] 选完技能后隐藏 Mask 场景对象（ServerOnly）
        self:RegisterServerFunction("P7_RequestPlayerInfo")  -- [P7] 请求玩家名字+头像序号（服务端分配）
    end)
    print("[P0][Server/GS] RegisterServerFunction = " .. tostring(okReg) .. " " .. tostring(errReg))

    -- 2) 延迟 2 秒向客户端广播 S→C（触发客户端 ClassicGameState:P0_OnServerPing）
    local selfRef = self
    self:AddTimerOnce(2.0, function()
        local okCall, errCall = pcall(function()
            selfRef:CallClientFunctionMulticast("P0_OnServerPing", "hello-from-server")
        end)
        print("[P0][Server/GS] CallClientFunctionMulticast 发送 = " .. tostring(okCall) .. " " .. tostring(errCall))

        -- [P2] 构造真实 Board 快照并广播，验证 table 参数能否跨端传输
        local okSnap, snapOrErr = pcall(function()
            local Snapshot = require("EnvLua.Common.Tetris.TetrisSnapshot")
            local Board = require("EnvLua.Common.Tetris.TetrisBoard")
            local b = Board:new()
            -- 造几个格子，让快照非空、便于校验
            pcall(function() b.grid[20][1] = { color = 1 }; b.grid[20][2] = { color = 2 } end)
            return Snapshot.Capture(b, { tag = "P2-ai-test" })
        end)
        if okSnap and type(snapOrErr) == "table" then
            print("[P2][Server/GS] 快照已构造: rows=" .. tostring(snapOrErr.rows) ..
                " cols=" .. tostring(snapOrErr.cols) .. " gridLen=" .. tostring(#snapOrErr.grid))
            local okSend, errSend = pcall(function()
                selfRef:CallClientFunctionMulticast("P2_OnBoardSnapshot", snapOrErr)
            end)
            print("[P2][Server/GS] 广播快照(table参数) = " .. tostring(okSend) .. " " .. tostring(errSend))
        else
            print("[P2][Server/GS] 快照构造失败: " .. tostring(snapOrErr))
        end

        -- [P5-5b] 仅单人时启动 AI（双人进入后才开始游戏，此处数人数判断）
        local playerCount = 0
        pcall(function()
            local ps = Game:GetAllPlayerStates()
            if ps and ps.Num then playerCount = ps:Num() end
        end)
        print("[P5][Server/GS] 延迟检查玩家数=" .. tostring(playerCount))
        if playerCount < 2 then
            self:StartAI()
        else
            print("[P5][Server/GS] 双人模式，不启动 AI")
        end
    end)
end

-- [P5-5b] 启动服务端 AI（幂等；单人模式由客户端 P5_RequestAI 触发）
function ClassicGameState:StartAI()
    if self._p3Driver and self._p3Driver.running then return end
    local okDrv, drvOrErr = pcall(function()
        local Driver = require("EnvLua.Server.Tetris.TetrisAIDriver")
        self._p3Driver = Driver:new(self, { quality = 0.8, tag = "AI-P3", interval = 0.5, snapshotEvery = 3 })
        self._p3Driver:Start()
        return self._p3Driver
    end)
    print("[P5][Server/GS] StartAI = " .. tostring(okDrv) .. " " .. tostring(okDrv and "" or drvOrErr))
end

-- [P2] 客户端回执：客户端 ApplySnapshot 后可调此白名单方法回报。
function ClassicGameState:P2_OnSnapshotAck(tag, ok)
    print("[P2][Server/GS] P2_OnSnapshotAck 收到: tag=" .. tostring(tag) .. " ok=" .. tostring(ok))
end

-- C→S 接收端：客户端调用时触发，验证反向通道。
function ClassicGameState:P0_OnClientPing(msg)
    print("[P0][Server/GS] P0_OnClientPing 收到客户端调用: " .. tostring(msg))
end

-- ===== P5：结算上报（胜数榜：赢 +1，输不扣）=====
-- 一局结束客户端调一次；单人打 AI 也走这里（win=true 时 playerKey 是本地玩家）。
function ClassicGameState:P5_ReportResult(win, playerKey)
    print("[P5][Server/GS] ReportResult win=" .. tostring(win) .. " playerKey=" .. tostring(playerKey))
    if type(RankAPI) ~= "table" then return end
    local okCfg, Config = pcall(require, "EnvLua.Common.Tetris.TetrisConfig")
    if not okCfg or not Config then return end
    local rt = rankType(Config)
    local players = Game:GetAllPlayerStates()
    if not players or not players.Num then return end
    for i = 0, players:Num() - 1 do
        local ps = players:Get(i)
        if ps and ps.GetPlayerKey and ps:GetPlayerKey() == playerKey then
            if win then
                local cur = 0
                if RankAPI.GetPlayerScore then
                    local okScore, v = pcall(function() return RankAPI.GetPlayerScore(ps, rt) end)
                    if okScore and type(v) == "number" then cur = v end
                end
                local newVal = cur + 1
                pcall(function() RankAPI.SubmitScore(ps, rt, newVal) end)
                print("[P5][Server/GS] 玩家 " .. tostring(playerKey) .. " 胜数 " .. tostring(cur) .. " → " .. tostring(newVal))
            else
                print("[P5][Server/GS] 玩家 " .. tostring(playerKey) .. " 输，不扣胜数")
            end
            break
        end
    end
    if RankAPI.RefreshRank then pcall(function() RankAPI.RefreshRank(rt) end) end
end

-- ===== P5：排行榜读取（GetTopN → S2C 回传）=====
function ClassicGameState:P5_RequestLeaderboard()
    if type(RankAPI) ~= "table" or not RankAPI.GetTopN then return end
    local okCfg, Config = pcall(require, "EnvLua.Common.Tetris.TetrisConfig")
    if not okCfg or not Config then return end
    local okGet, list = pcall(function() return RankAPI.GetTopN(rankType(Config), 10) end)
    if okGet and type(list) == "table" then
        pcall(function() self:CallClientFunctionMulticast("P5_LeaderboardData", list) end)
        print("[P5][Server/GS] 排行榜已回传, 条数=" .. tostring(#list))
    else
        print("[P5][Server/GS] 排行榜读取失败: " .. tostring(list))
    end
end

-- ===== P5-5b：单人请求启动 AI =====
function ClassicGameState:P5_RequestAI()
    local playerCount = 0
    pcall(function()
        local ps = Game:GetAllPlayerStates()
        if ps and ps.Num then playerCount = ps:Num() end
    end)
    if playerCount >= 2 then
        print("[P5][Server/GS] P5_RequestAI 忽略：当前是双人模式(" .. tostring(playerCount) .. "人)")
        return
    end
    print("[P5][Server/GS] P5_RequestAI 单人模式，启动 AI")
    self:StartAI()
end

-- ===== P5-5b：双人快照中转（广播给所有客户端；客户端按 senderKey 过滤自己）=====
function ClassicGameState:P5_ReportSnapshot(snap)
    if type(snap) ~= "table" then return end
    local okSend, err = pcall(function()
        self:CallClientFunctionMulticast("P5_OpponentSnapshot", snap)
    end)
    if not okSend then print("[P5][Server/GS] 快照中转失败: " .. tostring(err)) end
end

-- ===== P7：选完技能后隐藏 Mask 场景对象（对齐历史 TetrisSkillSelect:HideSceneObjectsOnce）=====
-- Mask1/Mask2 是场景对象，InstanceAPI.ToggleInstanceVisible 为 ServerOnly，必须留在服务端。
-- 任意玩家点完技能即触发，全程只执行一次（场景对象为共享世界对象，隐藏影响全体玩家）。
function ClassicGameState:P7_HideMasks()
    if self._masksHidden then return end
    self._masksHidden = true
    if type(InstanceAPI) ~= "table" or type(InstanceAPI.ToggleInstanceVisible) ~= "function" then
        print("[P7][Server/GS] P7_HideMasks 跳过：InstanceAPI 不可用")
        return
    end
    local okCfg, Config = pcall(require, "EnvLua.Common.Tetris.TetrisConfig")
    if not okCfg or not Config then return end
    local list = Config.HideAfterSkill
    if type(list) ~= "table" then return end
    local hidden = 0
    for _, key in ipairs(list) do
        local id = (type(CreativeInstance) == "table" and CreativeInstance[key]) or nil
        if id ~= nil then
            local ok = pcall(function() InstanceAPI.ToggleInstanceVisible(id, false) end)
            if ok then hidden = hidden + 1 end
        end
    end
    print("[P7][Server/GS] P7_HideMasks 已隐藏 Mask 场景对象 " .. tostring(hidden) .. "/" .. tostring(#list))
end

-- ===== P7：玩家名字 + 头像序号（服务端分配，保证每人不同）=====
-- 头像不传图片本身，只分配序号 index（0/1/...），客户端按序号从 AvatarUI.AvatarPresets 选图。
-- 按 playerKey 排序后按序分配，保证双端一致、序号稳定不重复。
-- 单人 AI 对手由客户端自行用 aiName + 一个避开真人的序号填充（这里只下发真人）。
function ClassicGameState:P7_RequestPlayerInfo()
    local players = Game:GetAllPlayerStates()
    if not players or not players.Num then return end
    local list = {}
    for i = 0, players:Num() - 1 do
        local ps = players:Get(i)
        if ps then
            local key, name = 0, ""
            pcall(function() if ps.GetPlayerKey then key = ps:GetPlayerKey() or 0 end end)
            pcall(function() name = ps.PlayerName or "" end)
            list[#list + 1] = { playerKey = key, name = tostring(name), avatarIndex = 0 }
        end
    end
    table.sort(list, function(a, b) return a.playerKey < b.playerKey end)
    for i, e in ipairs(list) do e.avatarIndex = i - 1 end   -- 0 基序号
    for _, e in ipairs(list) do
        print("[P7][Server/GS] 玩家信息 key=" .. tostring(e.playerKey) ..
            " name=" .. tostring(e.name) .. " avatarIndex=" .. tostring(e.avatarIndex))
    end
    local okSend, err = pcall(function() self:CallClientFunctionMulticast("P7_PlayerInfo", list) end)
    if not okSend then print("[P7][Server/GS] P7_PlayerInfo 广播失败: " .. tostring(err)) end
end

--- Callback after Actor construction is complete.
function ClassicGameState:OnPostConstruct()
end

--- Callback for Actor EndPlay.
---@param EndPlayReason EndPlayReason End play reason.
function ClassicGameState:OnReceiveEndPlay(EndPlayReason)
end

local CClassicGameState = WoWClass(WoWClassicGameState, nil, ClassicGameState)
return CClassicGameState
