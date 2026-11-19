-- AudioManager：按事件触发音效/BGM，管理 SFX/BGM 两套音量。
-- 权威来源：Core/LuaHint/AudioAPI.lua（PlayAudio/StopAudio/StopAudioByPlayer，@realm Both）。
--   PlayAudio(Target, AudioID, Duration, Volume, bAllMap, bShowMark, Audience) → 音频实例 UUID
--   AudioID 须经 AssetRef 解析为句柄；未注册则静默跳过；引擎无全局音量/暂停 API，音量只在播放时按 Volume 传入。
--   BGM 改音量需 StopAudio 后重播（无中途改音量 API）。
local Config = require("EnvLua.Common.Tetris.TetrisConfig")

local AudioManager = {}
AudioManager.__index = AudioManager

local AUDIO_CFG = Config.Audio or {}
local DURATION = 3
local function ref(key)
    if type(key) ~= "string" or type(AssetRef) ~= "table" then return nil end
    return AssetRef[key]
end

---@param ps WoWPlayerStateBase|nil 本地玩家（真人盘；AI/旁观盘传 nil 静默跳过）
function AudioManager:new(ps)
    local o = setmetatable({}, self)
    o.ps = ps
    o.sfxVolume = 0.6
    o.bgmVolume = 0.6
    o.step = AUDIO_CFG.Step or 0.1
    o.bgmUUID = nil
    o.bgmKey = AUDIO_CFG.BGMId
    return o
end

function AudioManager:_play(key, volume)
    if not self.ps then return nil end
    local r = ref(key)
    if not r then return nil end
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

-- ===== BGM（菜单起 → 难度切曲 → 开局确认 → 结算停；140s 循环由引擎侧 Duration 控制） =====
function AudioManager:StartBGM(key)
    if not self.ps then return end
    self:StopBGM()
    self.bgmKey = key or self.bgmKey
    local r = ref(self.bgmKey)
    if not r then return end
    pcall(function()
        self.bgmUUID = AudioAPI.PlayAudio(self.ps, r, 140, self.bgmVolume, true, false, self.ps)
    end)
end

function AudioManager:SwitchBGMByDifficulty(name)
    local m = AUDIO_CFG.DifficultyBGM or {}
    self:StartBGM(m[name] or self.bgmKey)
end

function AudioManager:StopBGM()
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
