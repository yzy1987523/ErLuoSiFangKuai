-- AudioManager：按事件触发音效/BGM，管理 SFX/BGM 两套音量。
-- 权威来源：Core/LuaHint/AudioAPI.lua（PlayAudio/StopAudio/StopAudioByPlayer，@realm Both）。
--   PlayAudio(Target, AudioID, Duration, Volume, bAllMap, bShowMark, Audience) → 音频实例 UUID
--   AudioID 须经 AssetRef 解析为句柄；未注册则静默跳过；引擎无全局音量/暂停 API，音量只在播放时按 Volume 传入。
--   BGM 改音量需 StopAudio 后重播（无中途改音量 API）。
--   BGM 无引擎循环参数：靠 owner:AddTimerOnce(BGM_LOOP_SEC) 定时"停旧播新"续播（旧服务端 TetrisAudio 同款）。
local Config = require("EnvLua.Common.Tetris.TetrisConfig")

local AudioManager = {}
AudioManager.__index = AudioManager

local AUDIO_CFG = Config.Audio or {}
local DURATION = 3
local BGM_LOOP_SEC = 140  -- 一段 BGM 时长（秒）；引擎无查询音频长度 API，按估算值到点重播
local function ref(key)
    if type(key) ~= "string" or type(AssetRef) ~= "table" then return nil end
    return AssetRef[key]
end

---@param ps WoWPlayerStateBase|nil 本地玩家（真人盘；AI/旁观盘传 nil 静默跳过）
---@param owner WoWObject|nil 提供 AddTimerOnce/RemoveTimer 的宿主（TetrisClient.host），用于 BGM 循环续播
function AudioManager:new(ps, owner)
    local o = setmetatable({}, self)
    o.ps = ps
    o.owner = owner
    o.sfxVolume = 0.6
    o.bgmVolume = 0.6
    o.step = AUDIO_CFG.Step or 0.1
    o.bgmUUID = nil
    o.bgmKey = AUDIO_CFG.BGMId
    return o
end

function AudioManager:_play(key, volume)
    if not self.ps then
        print("[Audio][WARN] 音效跳过：ps 为空 key=" .. tostring(key))
        return nil
    end
    local r = ref(key)
    if not r then
        print("[Audio][WARN] 音效跳过：AssetRef 未注册 key=" .. tostring(key))
        return nil
    end
    local uuid = nil
    pcall(function()
        uuid = AudioAPI.PlayAudio(self.ps, r, DURATION, volume or self.sfxVolume, true, false, self.ps)
    end)
    return uuid
end

-- ===== 事件音效 =====
function AudioManager:PlayLock()
    local s = AUDIO_CFG.Sounds or {}
    self:_play(s.Lock)
end

function AudioManager:PlaySkill()
    local s = AUDIO_CFG.Sounds or {}
    self:_play(s.Skill)
end

function AudioManager:PlayWin() self:_play((AUDIO_CFG.Sounds or {}).Win) end
function AudioManager:PlayLose() self:_play((AUDIO_CFG.Sounds or {}).Lose) end

function AudioManager:PlayItem(itemType)
    local key = (Config.ItemSounds or {})[itemType]
    self:_play(key)
end

function AudioManager:PlayLineClear(cleared, combo)
    local cs = Config.ClearSounds or {}
    local key = cs.Default
    local comboSounds = cs.ComboSounds or {}
    if combo and combo >= (cs.ComboStart or 2) then
        local idx = combo - (cs.ComboStart or 2) + 1
        key = comboSounds[math.min(idx, #comboSounds)] or key
        if cs.PlayDefaultOnCombo then self:_play(cs.Default) end
    end
    self:_play(key)
end

-- ===== BGM（开始界面起 → 难度切曲 → 开局确认 → 结算停；引擎无循环，靠定时器到点重播） =====
function AudioManager:_scheduleBGMLoop()
    self:_cancelBGMLoop()
    if not self.owner or not self.owner.AddTimerOnce then return end
    local selfRef = self
    self.bgmLoopTimer = self.owner:AddTimerOnce(BGM_LOOP_SEC, function()
        selfRef.bgmLoopTimer = nil
        selfRef:_loopBGM()
    end)
end

function AudioManager:_cancelBGMLoop()
    if self.bgmLoopTimer and self.owner and self.owner.RemoveTimer then
        pcall(function() self.owner:RemoveTimer(self.bgmLoopTimer) end)
    end
    self.bgmLoopTimer = nil
end

function AudioManager:_loopBGM()
    if not self.bgmUUID then return end  -- 已 StopBGM，不再续播
    local key, vol = self.bgmKey, self.bgmVolume
    self:StopBGM()
    self.bgmKey = key
    self.bgmVolume = vol
    local r = ref(self.bgmKey)
    if not r then return end
    pcall(function()
        self.bgmUUID = AudioAPI.PlayAudio(self.ps, r, BGM_LOOP_SEC, self.bgmVolume, true, false, self.ps)
    end)
    self:_scheduleBGMLoop()
    print("[Audio] BGM 循环重播 key=" .. tostring(self.bgmKey) .. " uuid=" .. tostring(self.bgmUUID))
end

---@return boolean 是否成功起播（供 _ensureBGM 判断是否需要重试）
function AudioManager:StartBGM(key)
    if not self.ps then
        print("[Audio][WARN] StartBGM 跳过：ps 为空（OnStart 时本地玩家可能尚未生成）")
        return false
    end
    self.bgmKey = key or self.bgmKey
    local r = ref(self.bgmKey)
    if not r then
        -- [BGM 兜底] 默认 BGM 资源未注册时，自动尝试难度 BGM 里任一已注册的 key
        -- （开始界面用默认 BGMId，进游戏用难度 BGM；若只有难度资源注册了，开始界面就没声）
        local tried = { [self.bgmKey] = true }
        local m = AUDIO_CFG.DifficultyBGM or {}
        for _, k in pairs(m) do
            if k and not tried[k] then
                tried[k] = true
                r = ref(k)
                if r then
                    print("[Audio] 默认 BGM 未注册，回退到已注册资源 key=" .. tostring(k))
                    self.bgmKey = k
                    break
                end
            end
        end
    end
    if not r then
        print("[Audio][WARN] StartBGM 跳过：AssetRef 未注册默认 BGM 及所有难度 BGM")
        return false
    end
    self:StopBGM()  -- 先停旧的再播新的
    pcall(function()
        self.bgmUUID = AudioAPI.PlayAudio(self.ps, r, BGM_LOOP_SEC, self.bgmVolume, true, false, self.ps)
    end)
    local ok = self.bgmUUID ~= nil
    print("[Audio] StartBGM key=" .. tostring(self.bgmKey) .. " uuid=" .. tostring(self.bgmUUID) ..
        " ok=" .. tostring(ok))
    if ok then self:_scheduleBGMLoop() end
    return ok
end

function AudioManager:SwitchBGMByDifficulty(name)
    local m = AUDIO_CFG.DifficultyBGM or {}
    self:StartBGM(m[name] or self.bgmKey)
end

function AudioManager:StopBGM()
    self:_cancelBGMLoop()
    if self.bgmUUID and AudioAPI.StopAudio then
        pcall(function() AudioAPI.StopAudio(self.bgmUUID) end)
    end
    self.bgmUUID = nil
end

-- ===== 音量（±Step，clamp 0~1；BGM 改音量停旧重播） =====
local function clamp(v) if v < 0 then return 0 elseif v > 1 then return 1 end return v end

-- 绝对值设置音量（读档后按存档数值应用；BGM 改值才停旧重播，避免无谓重启）
function AudioManager:SetVolume(kind, value)
    if type(value) ~= "number" then return end
    local v = clamp(value)
    if kind == "bgm" then
        local changed = math.abs((self.bgmVolume or 0) - v) > 0.001
        self.bgmVolume = v
        if changed and self.bgmUUID then self:StartBGM(self.bgmKey) end
    elseif kind == "sfx" then
        self.sfxVolume = v
    end
end

function AudioManager:AdjustBGM(delta)
    self:SetVolume("bgm", self.bgmVolume + (delta or 0) * self.step)
    return self.bgmVolume
end

function AudioManager:AdjustSFX(delta)
    self:SetVolume("sfx", self.sfxVolume + (delta or 0) * self.step)
    return self.sfxVolume
end

return AudioManager
