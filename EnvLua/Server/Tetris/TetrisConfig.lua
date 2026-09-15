-- 俄罗斯方块配置：盘面尺寸、方块定义、手感参数、渲染映射。
-- 纯数据，不依赖引擎 API。
local TetrisConfig = {}

-- ===================== 盘面 =====================
TetrisConfig.Board = {
    Cols = 10,   -- 宽（列）；9×20=180，上下两区各 90，低于单资源 ≈100 上限
    Rows = 20,   -- 高（行）
    -- 网格坐标约定：row 1 = 最顶行，row Rows = 最底行；col 1 = 最左列
}

-- ===================== 方块（四格骨牌） =====================
-- 7 种标准 Tetromino，spawn 形态用 0/1 矩阵表示（1 = 占位）。
-- 旋转态由矩阵旋转自动生成，O 型旋转后形态不变。
TetrisConfig.PieceType = {
    I = 1, O = 2, T = 3, J = 4, L = 5, S = 6, Z = 7,
}

TetrisConfig.Pieces = {
    [TetrisConfig.PieceType.I] = {
        name = "I",
        shape = {
            { 0, 0, 0, 0 },
            { 1, 1, 1, 1 },
            { 0, 0, 0, 0 },
            { 0, 0, 0, 0 },
        },
    },
    [TetrisConfig.PieceType.O] = {
        name = "O",
        shape = {
            { 1, 1 },
            { 1, 1 },
        },
    },
    [TetrisConfig.PieceType.T] = {
        name = "T",
        shape = {
            { 0, 1, 0 },
            { 1, 1, 1 },
            { 0, 0, 0 },
        },
    },
    [TetrisConfig.PieceType.J] = {
        name = "J",
        shape = {
            { 1, 0, 0 },
            { 1, 1, 1 },
            { 0, 0, 0 },
        },
    },
    [TetrisConfig.PieceType.L] = {
        name = "L",
        shape = {
            { 0, 0, 1 },
            { 1, 1, 1 },
            { 0, 0, 0 },
        },
    },
    [TetrisConfig.PieceType.S] = {
        name = "S",
        shape = {
            { 0, 1, 1 },
            { 1, 1, 0 },
            { 0, 0, 0 },
        },
    },
    [TetrisConfig.PieceType.Z] = {
        name = "Z",
        shape = {
            { 1, 1, 0 },
            { 0, 1, 1 },
            { 0, 0, 0 },
        },
    },
}

-- ===================== SRS 旋转（Super Rotation System） =====================
-- 仅 I 需要显式 4 态：朴素矩阵旋转会让 I 在标准踢墙表里错位。
-- 其余 JLSTZ 用朴素 3x3 矩阵旋转即等价于 SRS；O 朴素旋转恒等（旋转视觉不变）。
-- 4 态顺序固定为：1=出生(0) / 2=R(顺时针90) / 3=2(180) / 4=L(逆时针90=顺时针270)。
TetrisConfig.SRSRotationStates = {
    [TetrisConfig.PieceType.I] = {
        { {0,0,0,0}, {1,1,1,1}, {0,0,0,0}, {0,0,0,0} },  -- 出生：第 2 行横
        { {0,0,1,0}, {0,0,1,0}, {0,0,1,0}, {0,0,1,0} },  -- R：第 3 列竖
        { {0,0,0,0}, {0,0,0,0}, {1,1,1,1}, {0,0,0,0} },  -- 2：第 3 行横
        { {0,1,0,0}, {0,1,0,0}, {0,1,0,0}, {0,1,0,0} },  -- L：第 2 列竖
    },
}

-- SRS 踢墙表。偏移为 (dx, dy)：dx=列偏移(+右)，dy=行偏移(+下)。
-- 已在标准表（y 向上为正）基础上翻转 y 符号，以适配本局「行号向下增大」的坐标系。
-- 键：fromRot(1..4) -> toRot(1..4)；值：5 个测试偏移（顺序敏感，第 1 个恒为 (0,0)）。
TetrisConfig.SRSKicks = {
    -- JLSTZ（含 O）共用
    JLSTZ = {
        [1] = {
            [2] = {{0,0},{-1,0},{-1,-1},{0,2},{-1,2}},   -- 0->R
            [4] = {{0,0},{1,0},{1,-1},{0,2},{1,2}},      -- 0->L
        },
        [2] = {
            [1] = {{0,0},{1,0},{1,1},{0,-2},{1,-2}},     -- R->0
            [3] = {{0,0},{1,0},{1,1},{0,-2},{1,-2}},     -- R->2
        },
        [3] = {
            [2] = {{0,0},{-1,0},{-1,-1},{0,2},{-1,2}},   -- 2->R
            [4] = {{0,0},{1,0},{1,-1},{0,2},{1,2}},      -- 2->L
        },
        [4] = {
            [3] = {{0,0},{-1,0},{-1,1},{0,-2},{-1,-2}},   -- L->2
            [1] = {{0,0},{-1,0},{-1,1},{0,-2},{-1,-2}},   -- L->0
        },
    },
    -- I 专属
    I = {
        [1] = {
            [2] = {{0,0},{-2,0},{1,0},{-2,1},{1,-2}},     -- 0->R
            [4] = {{0,0},{-1,0},{2,0},{-1,-2},{2,1}},     -- 0->L
        },
        [2] = {
            [1] = {{0,0},{2,0},{-1,0},{2,-1},{-1,2}},     -- R->0
            [3] = {{0,0},{-1,0},{2,0},{-1,-2},{2,1}},     -- R->2
        },
        [3] = {
            [2] = {{0,0},{1,0},{-2,0},{1,2},{-2,-1}},     -- 2->R
            [4] = {{0,0},{2,0},{-1,0},{2,-1},{-1,2}},     -- 2->L
        },
        [4] = {
            [3] = {{0,0},{-2,0},{1,0},{-2,1},{1,-2}},     -- L->2
            [1] = {{0,0},{1,0},{-2,0},{1,2},{-2,-1}},     -- L->0
        },
    },
}

-- ===================== 手感 / 节奏 =====================
TetrisConfig.Timing = {
    -- 重力下落间隔（秒），随等级提升而缩短；索引 = 等级，超出取最后一个
    GravityIntervalByLevel = { 0.80, 0.72, 0.63, 0.55, 0.47, 0.38, 0.30, 0.22, 0.17, 0.13, 0.10, 0.08, 0.07, 0.06, 0.05 },
    SoftDropInterval = 0.05,  -- 软降时的下落间隔（秒）
    LockDelay = 0.50,         -- 触底后的锁定延迟（秒）
    LinesPerLevel = 10,       -- 每消除多少行升 1 级
    MaxLevel = 15,
}

-- ===================== 计分 =====================
TetrisConfig.Score = {
    LineClear = { 100, 300, 500, 800 },  -- 1/2/3/4 行基础分（乘以等级）
    SoftDropPerCell = 1,
    HardDropPerCell = 2,
    ComboBonus = 50,                      -- 连续消除奖励（乘以 combo 次数）
    -- T-Spin 计分：基础分（不叠加普通消行分，由 clearLines 二选一），乘以等级，仍可叠加 combo。
    -- 键 = 同时消除的行数（0=仅 T-Spin 不消行）。
    TSpin = {
        Full = { [0] = 400, [1] = 800, [2] = 1200, [3] = 1600 },
        Mini = { [0] = 100, [1] = 200, [2] = 400 },
    },
}

-- ===================== 渲染层映射（3D 世界） =====================
-- 单位：米。CreateActor 使用米制；Class API（如 K2_TeleportTo）使用厘米，切勿混用。
TetrisConfig.Render = {
    -- 3D 方块预设：编辑器注册后由 AssetRef 解析（须执行 update preset 生成 AssetRef.lua）
    BlockAssetRefKey = "44_CreativeAsset_3400003",
    -- 下区（底 10 行）方块预设：单资源动态实例上限约 100，底 10 行用第二个资源分摊，避免创建失败
    BlockAssetRefKeyBottom = "44_CreativeAsset_3400006",
    -- Actor 模式（CreateActor）使用的预设键：CreateActor 需要 ActorPreset 类型，
    -- 不能用动态实例的 CreativeAsset 键（如 44_CreativeAsset_*）。Actor 模式无实例上限，单预设即可覆盖全盘。
    BlockActorPresetKey = "46_ActorPreset_2074770",
    -- 备用方块模型（圆角方块积木）
    BlockModelID = "2205202",
    -- 边框（左/右/下三侧外框）资源：与方块上区同模型，用作盘面外边缘
    BorderAssetRefKey = "44_CreativeAsset_3400003",
    BlockScale = 1.0,        -- 方块模型缩放，按模型实际尺寸调整

    -- 兜底隐藏方式：ToggleInstanceVisible 对部分动态实例无效时开启，
    -- 改为把不需要显示的格子缩放设为 0（需先确认 SetInstanceScale 对实例有效）。
    UseScaleToHide = false,

    -- 显隐语义翻转开关（保留作逃生舱；现有证据表明并非语义问题）
    InvertVisible = false,

    -- 强制 Actor 模式：用 CreativeGameAPI.CreateActor 造真实 Actor，绕过动态实例
    --（InstanceAPI.CreateInstance）≈100 的池上限。实测 CreateActor 可生成 200+ 个对象。
    ForceActorMode = true,

    -- 实例创建后需若干帧才真正 spawn，过早下发显隐会被静默丢弃。
    -- SettleFrames：开局前 N 次刷新强制全量下发显隐（忽略脏检查），确保每格都被成功设置。
    -- SettleInterval：稳定期每次刷新的间隔（秒）。
    SettleFrames = 8,
    SettleInterval = 0.1,
    -- 在此之前持续尝试解析底层 Actor，超过后放弃，避免每帧无谓开销
    ActorResolveFrames = 12,
    CellSize = 1.0,          -- 单个格子边长（米）
    CellGap = 0.02,          -- 格子间隙（米），避免模型互相穿插
    -- 盘面左上角在世界中的锚点（米）；BoardOrigin.Z 为顶行高度，向下递减
    BoardOrigin = { X = 0.0, Y = 0.0, Z = 10.0 },

    -- 是否把盘面锚定到本地玩家附近。开启后忽略 BoardOrigin，改用
    -- 玩家坐标 + AnchorOffset，避免在空旷的世界原点找不到盘面。
    AnchorToPlayer = true,
    -- 相对玩家的偏移（米，世界轴向，与角色朝向无关）：
    -- X 正 = 东 / Y 正 = 北 / Z 正 = 上。棋盘是平行于 XZ 的竖直面。
    AnchorOffset = { X = 0.0, Y = 8.0, Z = 21.0 },  -- 抬高锚点：盘面总高 ≈(20-1)*1.02≈19.4m，须保证底行在地面之上（Z=12 时底行没入地下，约 7 行看不见）

    -- 每种方块颜色对应的模型 ID。引擎无运行时改材质接口，颜色必须烘焙进模型。
    -- 未准备好的颜色回退到 BlockModelID（表现为单色）。
    ColorModelIDs = {
        [1] = nil,  -- I 青色
        [2] = nil,  -- O 黄色
        [3] = nil,  -- T 紫色
        [4] = nil,  -- J 蓝色
        [5] = nil,  -- L 橙色
        [6] = nil,  -- S 绿色
        [7] = nil,  -- Z 红色
    },
}

-- ===================== 原生 UI（引擎自带 HUD / 屏幕操作按钮） =====================
-- 用 NativeControlAPI 控制，类型枚举见 EnvLua/Core/Define/CommonDefine.lua:668 NativeControlType（1~30）。
TetrisConfig.NativeUI = {
    Enabled = true,        -- 开局隐藏、回合结束还原
    -- 需要保留显示的控件类型（填 NativeControlType 数值），空表 = 全隐藏。
    -- 注意：NativeControlType 由编辑器运行时注入，本文件（纯数据）里不便直接引用，需要保留时填数字，
    -- 例：KeepTypes = { 1 } 表示保留小地图。
    KeepTypes = {},
    RetryFrames = 6,       -- 开局重发次数：原生 UI 会在角色生成后被重建，一次下发可能被覆盖
    RetryInterval = 0.5,   -- 重发间隔（秒）
}

-- ===================== 输入（CustomUI 按钮） =====================
-- 按钮需在编辑器 UI Editor 预放置，把 InstanceUUID 填到这里。
-- 来自全局表 CreativeInstance（形如 CreativeInstance["1_CreativeInstance_xxx"]）
-- CreativeInstance 由编辑器运行时注入；此处做 nil 保护，避免本地静态检查报错。
local function ci(key)
    if type(CreativeInstance) == "table" then
        return CreativeInstance[key]
    end
    return nil
end

TetrisConfig.UI = {
    BtnDown  = ci("1_CreativeInstance_23643899469166357"),  -- 硬降（本作无软降）
    BtnHold  = ci("1_CreativeInstance_23643899871618965"),
    BtnLeft  = ci("1_CreativeInstance_23643901535093337"),
    BtnRight = ci("1_CreativeInstance_23643901176767026"),
    BtnRoll  = ci("1_CreativeInstance_23643901459867306"),
    BtnSkill = ci("1_CreativeInstance_23643902211339624"),
}

-- 技能按钮：本期占位（技能系统属 P4），点击仅记录日志
TetrisConfig.SkillEnabled = false

-- ===================== 调试 =====================
TetrisConfig.Debug = {
    PrintBoardBounds = true,  -- Build 完成后打印盘面世界坐标范围
    PrintGrid = false,        -- 每次刷新打印期望显隐的字符画（排查行列映射用，较刷屏）
    DumpCellStatus = true,    -- 逐行打印 已创建/当前显示/期望显示，定位“生成了但被隐藏”或“没生成”
    ShowPieceInfo = true,     -- 每次生成新下落方块时，把信息上屏
    ShowPieceInfoPopup = false, -- false = 聊天框(SendQuickMenuMessage)；true = 屏幕弹窗(SendBattlePopupMessage)
    ShowGameOverInfo = true,  -- 结束时上屏结算
}

return TetrisConfig
