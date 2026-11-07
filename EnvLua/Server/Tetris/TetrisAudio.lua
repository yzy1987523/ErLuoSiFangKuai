-- 音量状态与背景音乐(BGM)控制（单例模块）。
-- 设计要点：
--   · 引擎 AudioAPI 没有全局音量接口，音量只能在每次 PlayAudio 时按 Volume(0~1) 传入，
--     因此"改音量"对正在播放的声音只能"停了重播"；瞬时音效(消行/道具)下一次播放即生效，无空隙。
--   · SFX 音量：消行/道具音效统一从这里取 GetSFXVolume()，在 TetrisGame 的两个播放入口乘上。
--   · BGM 音量：每个真人玩家用 AddTimerOnce 在音频时长(默认 2.5 分钟)到点后重播实现"循环"。
--     运行时无法获取音频真实长度，故用 DefaultAudioLen 估算，到点即重播。改音量/切歌时主动
--     RemoveTimer 旧定时器再开新定时器（避免叠加或陈旧续播）。
--   · BGM 按 AI 难度切换（TetrisConfig.Audio.DifficultyBGM）；切换时若目标 id 与当前相同则不动（避免间隙）。
--   · 关闭按钮只收起面板、不改音量（音量最低可到 0 = 静音，但不影响"关闭"语义）。
local TetrisAudio = {}

TetrisAudio.SFXVolume = 1          -- 音效音量（0~1）
TetrisAudio.BGMVolume = 0.6        -- 背景音乐默认音量（60%；档位上限仍为 100%，见 BGMVolumeMax）
TetrisAudio.BGMVolumeMax = 1          -- BGM 音量档位上限（实际传给 PlayAudio 的最大音量 = 100%）
TetrisAudio.Step = 0.1             -- 每次点击增减幅度（10 档，范围 0~BGMVolumeMax）
TetrisAudio.BGMId = nil            -- 默认 BGM 的 SoundPreset 资源键
TetrisAudio.DefaultAudioLen = 140  -- 音频时长估算(秒)：无法运行时获取，默认 2 分半；到点重播
TetrisAudio._owner = nil           -- WoWObject（用于 AddTimerOnce 循环续播定时器）
-- [psKey] = { uuid = 实例UUID, id = 当前播放的 bgmId, timer = 循环续播定时器 id }
TetrisAudio._instances = {}
TetrisAudio._players = {}          -- [psKey] = PlayerState（已开 BGM 的玩家）

local function psKey(ps)
    local ok, k = pcall(function() return ps:GetPlayerKey() end)
    if ok and k then return k end
    return ps
end

-- 由 Match 在开局初始化时调用：注入 owner 与配置
function TetrisAudio.Init(owner, cfg)
    TetrisAudio._owner = owner
    if cfg then
        if cfg.BGMId ~= nil then TetrisAudio.BGMId = cfg.BGMId end
        if cfg.Step then TetrisAudio.Step = cfg.Step end
    end
end

function TetrisAudio.GetSFXVolume() return TetrisAudio.SFXVolume end
function TetrisAudio.GetBGMVolume() return TetrisAudio.BGMVolume end

function TetrisAudio.ChangeSFX(delta)
    TetrisAudio.SFXVolume = math.max(0, math.min(1, TetrisAudio.SFXVolume + (delta or 0)))
    return TetrisAudio.SFXVolume
end

function TetrisAudio.ChangeBGM(delta)
    TetrisAudio.BGMVolume = math.max(0, math.min(TetrisAudio.BGMVolumeMax, TetrisAudio.BGMVolume + (delta or 0)))
    TetrisAudio.ApplyBGM()   -- 重新播放所有已开 BGM 以套用新音量
    return TetrisAudio.BGMVolume
end

-- 实际播放一段 bgmId（默认用 TetrisAudio.BGMId），返回实例 UUID
local function playOne(ps, bgmId)
    if not ps or type(AudioAPI) ~= "table" then
        print("[Tetris][Sound][DEBUG] playOne: AudioAPI 不可用或 ps 为空，无法播放 BGM")
        return nil
    end
    local id = bgmId or TetrisAudio.BGMId
    if not id then
        print("[Tetris][Sound][DEBUG] playOne: bgmId 为空，无法播放 BGM")
        return nil
    end
    -- 与音效(TetrisGame:PlayLineClearSound/PlayItemSound)一致：经 AssetRef 解析为句柄；
    -- 未注册(nil)则跳过并告警，不回退到原始字符串（原始字符串传给 PlayAudio 会静默失败）。
    local ref = (type(AssetRef) == "table") and AssetRef[id]
    if not ref then
        print(string.format("[Tetris][Sound][WARN] BGM 资源未注册 AssetRef[%s]，跳过（请在 VSCode 插件注册该 SoundPreset 并执行 update preset 生成 AssetRef 键）", tostring(id)))
        return nil
    end
    print(string.format("[Tetris][Sound][DEBUG] playOne: id=%s -> ref=%s BGMVolume=%s",
        tostring(id), tostring(ref), tostring(TetrisAudio.BGMVolume)))
    local uuid = nil
    local ok, err = pcall(function() uuid = AudioAPI.PlayAudio(ps, ref, TetrisAudio.DefaultAudioLen, TetrisAudio.BGMVolume, true, false, ps) end)
    if not ok then
        print("[Tetris][Sound][DEBUG] playOne: PlayAudio 抛错：" .. tostring(err))
    elseif not uuid then
        print("[Tetris][Sound][DEBUG] playOne: PlayAudio 返回 uuid=nil（播放失败，ref 可能无效）")
    else
        print("[Tetris][Sound][DEBUG] playOne: PlayAudio 成功 uuid=" .. tostring(uuid))
    end
    return uuid
end

-- 为某玩家安排下一次循环重播定时器：先 RemoveTimer 旧的（若有），再 AddTimerOnce(DefaultAudioLen) 新定时器
local function scheduleLoop(ps, k, bgmId)
    local cur = TetrisAudio._instances[k] or {}
    if cur.timer then pcall(function() TetrisAudio._owner:RemoveTimer(cur.timer) end) end
    if TetrisAudio._owner and TetrisAudio._owner.AddTimerOnce then
        pcall(function()
            cur.timer = TetrisAudio._owner:AddTimerOnce(TetrisAudio.DefaultAudioLen, function()
                TetrisAudio:_loopPlay(ps, k, bgmId)
            end)
        end)
    end
    TetrisAudio._instances[k] = cur
end

-- 循环续播回调：该玩家仍在播则停旧播新，并重新安排下一次定时器
function TetrisAudio:_loopPlay(ps, k, bgmId)
    if TetrisAudio._players[k] ~= ps then return end   -- 该玩家已停止 BGM，不再续播
    local cur = TetrisAudio._instances[k] or {}
    if cur.uuid then pcall(function() AudioAPI.StopAudio(cur.uuid) end) end
    cur.uuid = playOne(ps, bgmId)
    cur.id = bgmId
    TetrisAudio._instances[k] = cur
    scheduleLoop(ps, k, bgmId)
end

-- 为某玩家开始 BGM（并安排循环续播定时器）。
-- 切换规则：目标 id 与当前已在播的 id 相同且实例有效 → 不重启（避免间隙）；否则停旧重播。
function TetrisAudio.StartBGM(ps, bgmId)
    if not ps then
        print("[Tetris][Sound][DEBUG] StartBGM: ps 为空，跳过")
        return
    end
    local k = psKey(ps)
    bgmId = bgmId or TetrisAudio.BGMId
    local cur = TetrisAudio._instances[k]
    if cur and cur.id == bgmId and cur.uuid then
        print("[Tetris][Sound][DEBUG] StartBGM: 同 id 已在播，跳过（不重切）")
        return   -- 同样的 BGM 已在播，不重启
    end
    print(string.format("[Tetris][Sound][DEBUG] StartBGM: 启动/重播 BGM id=%s", tostring(bgmId)))
    -- 切歌/启动：主动终止旧定时器与旧音频，再开新的（避免叠加或陈旧续播）
    if cur and cur.timer then pcall(function() TetrisAudio._owner:RemoveTimer(cur.timer) end) end
    if cur and cur.uuid then pcall(function() AudioAPI.StopAudio(cur.uuid) end) end
    TetrisAudio._players[k] = ps
    TetrisAudio._instances[k] = { uuid = playOne(ps, bgmId), id = bgmId }
    scheduleLoop(ps, k, bgmId)
end

-- 套用当前 BGMVolume：对所有已开 BGM 的玩家，主动终止旧定时器与旧音频，停旧重播以套用新音量（保持各自 id）
function TetrisAudio.ApplyBGM()
    for k, ps in pairs(TetrisAudio._players) do
        if ps then
            local cur = TetrisAudio._instances[k] or {}
            local id = cur.id or TetrisAudio.BGMId
            if cur.timer then pcall(function() TetrisAudio._owner:RemoveTimer(cur.timer) end) end
            if cur.uuid then pcall(function() AudioAPI.StopAudio(cur.uuid) end) end
            cur.uuid = playOne(ps, id)
            cur.id = id
            TetrisAudio._instances[k] = cur
            scheduleLoop(ps, k, id)
        end
    end
end

function TetrisAudio.StopBGM(ps)
    if not ps then return end
    local k = psKey(ps)
    local cur = TetrisAudio._instances[k]
    if cur and cur.timer then pcall(function() TetrisAudio._owner:RemoveTimer(cur.timer) end) end
    if cur and cur.uuid then pcall(function() AudioAPI.StopAudio(cur.uuid) end) end
    TetrisAudio._instances[k] = nil
    TetrisAudio._players[k] = nil
end

-- 停止全部 BGM：停掉所有已播实例与循环定时器
function TetrisAudio.StopAllBGM()
    for k, ps in pairs(TetrisAudio._players) do
        local cur = TetrisAudio._instances[k]
        if cur and cur.timer then pcall(function() TetrisAudio._owner:RemoveTimer(cur.timer) end) end
        if cur and cur.uuid then pcall(function() AudioAPI.StopAudio(cur.uuid) end) end
    end
    TetrisAudio._players = {}
    TetrisAudio._instances = {}
end

return TetrisAudio
