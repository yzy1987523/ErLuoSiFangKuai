-- Interfaces: 客户端分层之间的「纯数据结构」契约。
-- 纪律（见 .codebuddy/客户端重写功能清单.md 的重写原则）：
--   1. 层间只传本文件定义的表，禁止传 Game/Board/Actor/UI 对象或回调。
--   2. 每个结构都是 plain table，字段含义明确，不嵌套引擎对象。
--   3. 下游只读上游数据，不反向写入。

local Interfaces = {}

--- 渲染层输入：Renderer 只按这份数据画方块，不判定玩法。
---@class RenderState
---@field grid table<number, table<number, table|nil>>  -- grid[row][col] = {color=1..8, item=nil|9..12} 或 nil
---@field active table|nil        -- 当前活动块 {type, rot, x, y, cells}（来自 board:getActive()）
---@field ghost table|nil         -- 落点格数组（来自 board:getGhostCells()）
---@field nextQueue number[]      -- 下一个方块类型队列（长度 3）
---@field holdType number|nil     -- hold 区方块类型
---@field effects table           -- 特效标记：clearing/garbage/blastColumn/stoneFalling 等（Renderer 自行消费）
Interfaces.RenderState = {
    grid = {}, active = nil, ghost = nil,
    nextQueue = {}, holdType = nil, effects = {},
}

--- UI 层输入：UI 只按这份数据写控件，不读玩法对象。
---@class UIState
---@field score number
---@field lines number
---@field level number
---@field combo number
---@field skillPower number        -- 当前 power 数 0..3
---@field skillCd table<string, boolean>  -- 各技能冷却标记 {SK06=true,...}
---@field opponentScore number
---@field hintImages table<string, boolean> -- 道具提示图显隐 {BlastImg=true,...}
---@field lang number              -- 1=zh 2=en 3=ar
---@field pendingSwap boolean      -- SK08 受害者左右对调中（UI 轮询显示 3 图）
---@field pendingNoRotate boolean  -- SK01 受害者禁止转动中
Interfaces.UIState = {
    score = 0, lines = 0, level = 1, combo = 0,
    skillPower = 0, skillCd = {}, opponentScore = 0,
    hintImages = {}, lang = 2,
    pendingSwap = false, pendingNoRotate = false,
}

--- 输入层输出：Input 把引擎事件翻译成这个动作，交给编排层。
---@class InputAction
---@field type string  -- "move"|"rotate"|"softDrop"|"hardDrop"|"hold"|"skill"
---@field value number|nil  -- move 的方向 ±1；rotate 的朝向；其余 nil
Interfaces.InputAction = { type = "", value = nil }

--- 跨端事件：唯一的网络消息结构，requester 用 fromKey 字符串（不持有对象）。
---@field kind string  -- "garbage"|"noRotate"|"swap"|"rockfall"|"snapshot"
---@field n number|nil      -- 垃圾行数/减益层数
---@field fromKey number    -- 发起方 PlayerKey
---@field payload string|nil -- snapshot 时的序列化盘面
Interfaces.VersusEvent = { kind = "", n = nil, fromKey = 0, payload = nil }

--- 盘面坐标（服务端下发，单位米；Renderer 内部转厘米）。
---@field ox number @field oy number @field oz number
---@field rx number @field ry number @field rz number
Interfaces.BoardTransform = { ox = 0, oy = 0, oz = 0, rx = 0, ry = 0, rz = 0 }

--- 工厂方法：返回一份新的、可独立修改的表（避免共享引用被污染）。
function Interfaces.NewRenderState() return {
    grid = {}, active = nil, ghost = nil, nextQueue = {}, holdType = nil, effects = {},
} end
function Interfaces.NewUIState() return {
    score = 0, lines = 0, level = 1, combo = 0, skillPower = 0,
    skillCd = {}, opponentScore = 0, hintImages = {}, lang = 2,
    pendingSwap = false, pendingNoRotate = false,
} end
function Interfaces.NewVersusEvent(kind, n, fromKey, payload) return {
    kind = kind, n = n, fromKey = fromKey, payload = payload,
} end

return Interfaces
