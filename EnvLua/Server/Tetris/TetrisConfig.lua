-- 俄罗斯方块配置：盘面尺寸、方块定义、手感参数、渲染映射。
-- 纯数据，不依赖引擎 API。
local TetrisConfig = {}

-- ===================== 盘面 =====================
TetrisConfig.Board = {
    Cols = 10,   -- 宽（列）；9×20=180，上下两区各 90，低于单资源 ≈100 上限
    Rows = 20,   -- 高（行）
    -- 网格坐标约定：row 1 = 最顶行，row Rows = 最底行；col 1 = 最左列
}

-- ===================== 消行节奏 =====================
-- 即将消除的行：其方块在锁定的当帧直接归还对象池（立即消失）；
-- 其余需要下落的块延迟 ClearDelay 秒后，再按现存 parent-shift 方式整体下移。
TetrisConfig.Clear = {
    EffectDuration = 0.5,   -- 单位：秒。被消除格上播放的特效持续时间；也是「特效播完→方块下落」的延迟（见 ScheduleClearResume）。
    ClearDelay = 0.9,    -- 单位：秒。消除→下落→出块 的总窗口；必须 ≥ EffectDuration，差值 = 下落后方块展示时间（让"落下"可见）。
    LockFlashDelay = 0.35,   -- 单位：秒。方块锁定后、满行被消除前的"落地停顿"：让玩家看到方块落定、满行亮起的一瞬，再触发消除。
    EffectPresetKey = "13_EffectPreset_100032",  -- 消行特效资源 Key（AssetRef，需在 VSCode 插件注册并执行 update preset）。
    -- 特效尺寸（缩放倍数）。FVector，各分量默认 1.0 = 原始大小；
    -- 例 {X=2,Y=2,Z=2} 放大到 2 倍，{X=0.5,Y=0.5,Z=0.5} 缩小一半。
    -- 由 SceneEffectAPI.SetSceneEffectScale 在创建后应用（CreateSceneEffect 无缩放参数）。
    -- x：高度，y：长度
    EffectScale = { X = 7.0, Y = 1.5, Z = 1.0 },
    -- 特效播放位置的额外偏移（单位：米）。
    -- 注意：水平（X/Y）已由 LeftOffsetM 接管（沿盘面本地左向，保证多盘一致）；
    -- 此处仅保留竖直分量 Z 作上下微调（沿世界 -Z，与行方向一致），X/Y 不再参与水平定位。
    EffectPositionOffset = { X = 0.0, Y = -5.25, Z = 0.0 },
    -- 爆破道具竖版消除特效：道具爆破改为一整列消除，在该列「最下方块」处由下往上播放竖版光束。
    BlastEffectPresetKey = nil,  -- 竖版特效资源 Key；nil = 复用上面的 EffectPresetKey（若有专用竖向 VFX，填其 Key 并将 BlastEffectRot 设为 0）
    BlastEffectScale = { X = 7, Y = 2.5, Z = 1.0 },  -- 竖版缩放（绝对倍数，1.0=原始大小）：X=水平宽度，Y=竖直长度，Z=深度厚度；按需微调，代码不限制尺寸。
    BlastEffectRot = { X = -90.0, Y = 0.0, Z = 0.0 },    -- 将横版特效立为竖版的额外旋转(Pitch=-90 朝上)；yaw 自动叠 boardYaw 正对玩家
    BlastEffectOffset = { X = 0.0, Y = 0.0, Z = 0.0 },    -- 位置微调（米）
    -- 位移道具特效：位移块消除→整行右移时，在位移块所在行播放横向特效。
    ShiftEffectPresetKey = "13_EffectPreset_100043",  -- 位移特效资源 Key（AssetRef，需在 VSCode 插件注册并执行 update preset）。
    ShiftEffectScale = { X = 3.0, Y = 3.0, Z = 3.0 },  -- 位移特效缩放（按需微调）
    ShiftEffectRot = { X = 0.0, Y = 0.0, Z = -90.0 },    -- 看预览窗口，上面有坐标轴
    ShiftEffectOffset = { X = -2.0, Y = 0.0, Z = 0.0 }, -- 位移特效位置微调（米）
}

-- ===================== 初始预填版面（开局即存在的方块） =====================
-- 让开局盘面直接带有方块，可在编辑器/配置里自由布置；预填成满行时「开局即可消除」。
-- 时机：Board:reset() 末尾、方块 spawn() 之前写入 grid；是否立即消除由 AutoClearOnStart 控制。
TetrisConfig.InitialLayout = {
    -- 总开关：false = 完全不预填（等同原版）；true = 按下面数据预填。
    Enabled = true,
    -- 开局自动消除初始满行（播放下落动画，且不计分/不污染 combo 等级）。
    -- false = 保留预填满行，直到玩家第一次锁定方块（lockPiece 的 clearLines）才消除。
    AutoClearOnStart = true,

    -- 预填数据（两种写法可同时用，都会叠加写入 grid）：
    --   Rows  ：数组，索引 1 = 顶行，#Rows = 底行，每行字符串 = Cols 个字符。
    --   ByRow ：字典 {[row]=str}，按行号精确预填（1=顶，Rows=底），只写有内容的行即可。
    -- 字符含义：'.' = 空，'1'~'7' = 方块颜色/类型（见 PieceType），'8' = 垃圾块。
    -- 注意：预填块请避免占据顶部 1~4 行（方块从顶行 spawn），否则开局会因无法生成而直接结束。
    Rows = nil,
    ByRow = {
        -- 取消下行注释 = 底行填满，开局立刻消除（演示「初始就能消除」）：
        --[20] = "1111.11111",
        -- 例：第 19 行局部填充（开头 1、末尾两格）：
         --[19] = "1.......11",
        -- 多行同消（四连消）示例：
         [20] = "1111111.11", [19] = "111.111111", [18] = "111.111111", [17] = "1111111.11",
    },
}

-- ===================== 方块（四格骨牌） =====================
-- 7 种标准 Tetromino，spawn 形态用 0/1 矩阵表示（1 = 占位）。
-- 旋转态由矩阵旋转自动生成，O 型旋转后形态不变。
TetrisConfig.PieceType = {
    I = 1, O = 2, T = 3, J = 4, L = 5, S = 6, Z = 7,
    -- 道具方块（单格）：格值 9/10/11，注意避开垃圾块格值 8
    ITEM_BLAST = 9,   -- 爆破块：消除时清除以本格为中心的 5×5 区域
    ITEM_SHIFT = 10,  -- 位移块：消除时所有行整体右移 1 列
    ITEM_CHARGE = 11, -- 充能块：消除时立即 +1 power
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
        -- 4×4 框，2×2 块居中（行/列 2~3）。旋转对 4×4 框中心对称，故旋转不变形（SRS O 行为）。
        -- 与 I 同用 4×4 框：二者都「绕 4×4 框中心转」，其余 5 种绕 3×3 框中心格转。
        shape = {
            { 0, 0, 0, 0 },
            { 0, 1, 1, 0 },
            { 0, 1, 1, 0 },
            { 0, 0, 0, 0 },
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
    -- 道具方块：1×1 单格（形状即一个占位）。3 种仅在「能力」上不同，外观靠 Next/Hold 图标与 3D 浮空图区分。
    [TetrisConfig.PieceType.ITEM_BLAST] = { name = "BLAST", shape = { { 1 } } },
    [TetrisConfig.PieceType.ITEM_SHIFT] = { name = "SHIFT", shape = { { 1 } } },
    [TetrisConfig.PieceType.ITEM_CHARGE] = { name = "CHARGE", shape = { { 1 } } },
}

-- ===================== 道具方块（单格 + 3 种道具） =====================
-- 每个下落方块有 Prob 概率为「道具方块」；是则等概率取 Types 中一种。
-- 三种道具（格值见 PieceType.ITEM_*，避开垃圾块 8）：
--   9  = 爆破块：消除含本格的方块时，清除本格所在的【一整列】（跳过本应整体消除的满行），并在该列最下方块处播放竖版消除特效
--   10 = 位移块：消除含本格的方块时，所有行整体向右平移 1 列（每行从最右格起右移 1，目标格被占/越界则跳过）
--   11 = 充能块：消除含本格的方块时，立即额外获得 1 个 power（技能能量）
TetrisConfig.Item = {
    Debug = false,                     -- 调试：打印 2D 图片解析 / 3D 组件生成与定位日志（上线前改 false）
    Prob = 0.95,                       -- 单个方块为道具方块的概率（≈每 100 个 15 个）
    Types = { 9, 9, 9 },             -- 与 PieceType.ITEM_* 对应（当前 3 种，之后扩充只加 PieceImages，方块恒为灰块）
    TypeMin = 9,                        -- 道具类别下界：格值 >= TypeMin 即视为道具（与类型无关、可无限扩充）
    BlockModelKey = "50_CreativeAsset_115324270",  -- 道具方块本体：灰色 1×1 立方（复用垃圾块灰模 ColorModelIDs[8]）
    BlastRadius = 2,                    -- 【已废弃】爆破改为消除一整列，不再按半径；保留字段仅供参考

    -- 3D 浮空图标：活动道具方块上方挂一个 3D UI 图片控件显示对应道具图。
    -- 图片与 2D Next/Hold 共用 TetrisConfig.PieceImages[9/10/11]（单一图源，不要在此重复定义）。
    -- 待编辑器提供：① 带 WidgetComponent 的 Actor 预设（PresetKey）；② Widget 内图片组件名（ImageChildName）。
    Widget3D = {
        Enabled = true,                -- 资源就绪后改为 true 才生成浮空图标
        PresetKey = "46_ActorPreset_1822956872",   -- 带 WidgetComponent 的 Actor 预设
        ImageChildName = "icon",          -- Widget 内图片组件名（运行时按道具切换图）
        LiftM = 0.0,                             -- 垂直偏移（米，正=抬高 / 负=压低）；默认 0 = 与方块同高。想上下调位置就改这个
        FrontOffsetM = 0.51,                       -- 沿「盘面正前方（朝玩家）」的偏移距离（米）；= -boardForward * FrontOffsetM。想前后调位置就改这个
        PoolSize = 24,                           -- 3D 图标池上限（道具同存数量，正常对局难超；超限的道具格不显示图标）
    },
}

-- 判断格值是否为「道具块」：单一类别，格值 >= Item.TypeMin 即道具（灰色块 + 3D 图，与类型无关、可无限扩充）。
-- 垃圾块 = 8 已 < TypeMin，普通方块 1..7 也更小的范围，故不会误判。
TetrisConfig.IsItemType = function(v)
    if type(v) == "table" then return v.item ~= nil end   -- 格子结构 {color,item}
    return type(v) == "number" and v >= (TetrisConfig.Item.TypeMin or 9)   -- 方块类别号(active.type)
end

-- ===================== 旋转（数据层与渲染层共享的唯一真相） =====================
-- 统一两侧旋转规则：旋转用矩阵 CW 旋转（TetrisBoard.rotateMatrixCW），
-- 渲染层用「轴心 + 偏移旋转(rotateOffset)」复现同一旋转，二者数学等价（已验证任意 n 下等价）。
-- 旋转轴心（SRS 约定）：
--   I / O  → 4×4 框中心 = (2.5, 2.5)（框内 1-based 坐标，即两格之间）
--   T/S/Z/J/L → 3×3 框中心格 = (2, 2)（即中间那格）
-- 数据层 rotateMatrixCW 对 3×3 固定中心格、对 4×4 固定框中心，天然符合上述轴心；
-- 渲染层 piecePivot 显式取此轴心，确保两侧永不漂移。
TetrisConfig.Rotation = {
    -- 旋转框尺寸（格）：I/O 4×4，其余 3×3
    Box = { [1] = 4, [2] = 4, [3] = 3, [4] = 3, [5] = 3, [6] = 3, [7] = 3, [9] = 1, [10] = 1, [11] = 1 },
    -- 旋转轴心（框内 1-based 坐标 r=行, c=列）
    Pivot = {
        [1] = { r = 2.5, c = 2.5 }, [2] = { r = 2.5, c = 2.5 },
        [3] = { r = 2, c = 2 },     [4] = { r = 2, c = 2 },
        [5] = { r = 2, c = 2 },     [6] = { r = 2, c = 2 },
        [7] = { r = 2, c = 2 },
        [9] = { r = 1, c = 1 },     [10] = { r = 1, c = 1 },
        [11] = { r = 1, c = 1 },
    },
    -- SRS 踢墙偏移表。键为 (from, to) 旋转态（0..3 = rot-1）；偏移 (x, y)，y 向上为正。
    -- 数据层棋盘 y 向下为正，应用时 newY = y - ky。
    -- 3×3 方块（T/S/Z/J/L）共用 JLSTZ 表；I 用专属 4×4 表；O 旋转不变形，只试 (0,0)。
    JLSTZ = {
        [0] = { [1] = { {0,0},{-1,0},{-1,1},{0,-2},{-1,-2} } },
        [1] = { [0] = { {0,0},{ 1,0},{ 1,-1},{0,2},{ 1,2} },
                [2] = { {0,0},{ 1,0},{ 1,-1},{0,2},{ 1,2} } },
        [2] = { [1] = { {0,0},{-1,0},{-1,1},{0,-2},{-1,-2} },
                [3] = { {0,0},{ 1,0},{ 1,1},{0,-2},{ 1,-2} } },
        [3] = { [2] = { {0,0},{-1,0},{-1,-1},{0,2},{-1,2} },
                [0] = { {0,0},{-1,0},{-1,-1},{0,2},{-1,2} } },
    },
    I = {
        [0] = { [1] = { {0,0},{-2,0},{ 1,0},{-2,-1},{ 1,2} } },
        [1] = { [0] = { {0,0},{ 2,0},{-1,0},{ 2,1},{-1,-2} },
                [2] = { {0,0},{-1,0},{ 2,0},{-1, 2},{ 2,-1} } },
        [2] = { [1] = { {0,0},{ 1,0},{-2,0},{ 1,-2},{-2, 1} },
                [3] = { {0,0},{ 2,0},{-1,0},{ 2, 1},{-1,-2} } },
        [3] = { [2] = { {0,0},{-2,0},{ 1,0},{-2,-1},{ 1, 2} },
                [0] = { {0,0},{ 1,0},{-2,0},{ 1,-2},{-2, 1} } },
    },
}

-- ===================== 手感 / 节奏 =====================
TetrisConfig.Timing = {
    -- 重力下落间隔（秒），随等级提升而缩短；索引 = 等级，超出取最后一个
    GravityIntervalByLevel = { 0.80, 0.72, 0.63, 0.55, 0.51, 0.48, 0.43, 0.42, 0.37, 0.33, 0.30, 0.28, 0.27, 0.26, 0.25 },
    SoftDropInterval = 0.05,  -- 软降时的下落间隔（秒）
    LockDelay = 0.25,         -- 触底后的锁定延迟（秒）：方块落到底不立刻锁定，给玩家滑动/转身窗口
    LockResetLimit = 15,       -- 落地后「移动/旋转重置」延迟的最大次数（超过后不再重置，防止无限拖延）
    LinesPerLevel = 10,       -- 每消除多少行升 1 级
    MaxLevel = 15,
}

-- ===================== 计分 =====================
TetrisConfig.Score = {
    LineClear = { 100, 300, 500, 800 },  -- 1/2/3/4 行基础分（乘以等级）
    SoftDropPerCell = 1,
    HardDropPerCell = 2,
    LockPerPiece = 1,                     -- 方块正常锁定（落地）即计 1 分（与消行/软降/硬降加分叠加）
    ComboBonus = 50,                      -- 连续消除奖励（乘以 combo 次数）
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
    -- 边框（左/右/下三侧外框）资源：与方块同模型，用【动态实例】生成（InstanceAPI.CreateInstance），
    -- 因此必须是 CreativeAsset（44_CreativeAsset_*），不能传 ActorPreset。
    BorderAssetRefKey = "44_CreativeAsset_3400003",
    -- 外边框（立方体方框）总开关：true=生成左/右/下三侧外框；false=不生成（纯盘面，无立方体方框）
    BorderEnabled = false,

    BlockScale = 1,        -- 方块模型缩放，按模型实际尺寸调整

    -- 兜底隐藏方式：ToggleInstanceVisible 对部分动态实例无效时开启，
    -- 改为把不需要显示的格子缩放设为 0（需先确认 SetInstanceScale 对实例有效）。
    UseScaleToHide = false,

    -- 显隐语义翻转开关（保留作逃生舱；现有证据表明并非语义问题）
    InvertVisible = false,

    -- 强制 Actor 模式：用 CreativeGameAPI.CreateActor 造真实 Actor，绕过动态实例
    --（InstanceAPI.CreateInstance）≈100 的池上限。实测 CreateActor 可生成 200+ 个对象。
    ForceActorMode = true,

    -- 整体方块模式：活动方块用「1 个隐藏根 Actor + 4 个挂在其上的子方块」组成整体，
    -- 位移/旋转只传送根（1 次调用），落地后根归位、棋盘单元方块接管显示，消行时单元方块消失。
    -- 棋盘静态层（已落定方块）仅在锁定/消行时全量同步，平时零流量，是消除逐格延迟的关键。
    UseWholePiece = true,
    -- 旋转方向符号：对齐数据层 rotateMatrixCW（默认 +1）。之前为修正“看背面导致镜像”误改成 -1，
    -- 现已将渲染层绕竖直轴转 180° 看到正面，本符号必须恢复 +1 才能与数据层一致。
    PieceSpinSign = 1,

    -- 整体方块（统一运动）实现优先级：方案3(附着子Actor) > 方案2(组件,已证不可用) > 方案1(4 Actor)。
    --
    -- 方案3（当前启用）：1 个隐形根 Actor(EmptyActor) + 4 个方块子 Actor 附着在根上。
    --   移动/下落/旋转只传送「根 Actor」一次 → 4 子 Actor 随根原子跟随。
    --   关键：子 Actor 是真实 Actor，其「附着关系」会被复制（不同于方案2 的组件 transform 不复制），
    --   因此客户端也能看到 4 格同步移动/旋转，彻底消除错位与 4 倍流量。
    --   旋转通过对「根 Actor」设绕 Y(Pitch) 轴 (rot-1)*90° 实现；子 Actor 相对偏移在构建时按 rot=1 烘焙，随根转动。
    --   前置（编辑器注册 + update preset 进入 AssetRef）：
    --     1) PieceRootPresetKey   —— 隐形根(EmptyActor) 46_ActorPreset_1670711180，必须有；
    --     2) PieceChildPresetKey  —— 方块子 Actor（复用盘面方块预设 46_ActorPreset_2074770），必须有。
    UseWholePieceAttach = true,
    PieceQueueSize = 7,        -- 方块队列预生成深度（轻量队列封装用；默认 7 覆盖全部形状）
    -- 方案2（已证不可用，关闭）：本引擎不复制运行时 AddComponent 子组件的 transform，客户端全叠原点。
    UseWholePieceV2 = false,

    PieceRootPresetKey = "46_ActorPreset_1585104836", -- 隐形根（EmptyActor）
    PieceChildPresetKey = "46_ActorPreset_2074770",   -- 方块子 Actor（与盘面同模型，已注册）
    PieceComponentPresetKey = "47_ComponentPreset_5", -- StaticMeshComponent（方案2 用，已弃用）
    PieceMeshAssetKey = "44_CreativeAsset_3400003",  -- 立方体（方案2 用，已弃用）

    -- 开局预览：初始化时 7 种方块已全部建好，此开关让它们先摆在盘面前方排成一排，
    -- 暂停下落 PreviewSeconds 秒供肉眼核对形状，再正式开始下落。仅整体模式(方案3)有效。
    PreviewBeforeStart = true,
    PreviewSeconds = 3,
    -- 开局展示区（7 种方块停车场）布局参数。每块棋盘在自身盘面上方并排摆出 7 种方块（双方共 14 个）。
    -- 偏移全部在此控制；单位：HeightCells / GapCells 为「格」（格距 = CellSize + CellGap），NormalOffsetM 为「米」。
    Showcase = {
        HeightCells = 13,    -- 盘面上方多少格（沿世界 Z 抬高）
        GapCells = 4,        -- 相邻方块间隔多少格（沿盘面 right 居中展开 7 列）
        NormalOffsetM = 5, -- 沿盘面显示法线(由 boardRight 推导，含 BoardFlipAxis180 翻转)偏移米；
                             --   正 = 朝玩家方向弹出盘面、负 = 贴回盘面（仅改 X/Y，不影响高度）
    },
    -- 消行动画：把会下落的方块临时挂到 parent-shift 根整体下移，移完拆父还原为独立 Actor。
    -- 关闭则消行退化为逐格传送（更安全但流量大、可能出现逐格延迟）。
    UseParentShiftOnClear = true,

    -- 下一个方块预览：游戏进行中(有方块正在下落时)在盘面一侧显示 nextQueue[1]。
    -- 为此再预建一套 7 种整体实例作预览专用(与活动方块的 7 个互不干扰)，
    -- 连同活动 7 个 + Hold 7 个共 21 个 = 每型 3 个(活动/下一/暂存)，即使三者同型(7-bag 跨袋边界可能出现)也能同屏渲染。
    EnableNextPreview = false,
    NextPreviewSide = "right",  -- "left" = 盘面左侧(旧行为)；"right" = 盘面右侧
    NextPreviewLeftCells = 0,   -- 预览区与盘面之间的间距格数（沿预览所在侧的“外移”方向）；0 表示自动 = Cols + 3
    -- 预览方块位置偏移量（单位：格，沿盘面轴向）：
    --   right = 沿预览所在侧的“外移”方向额外外移(+) / 内移(-)的格数（与 NextPreviewLeftCells 同向）；
    --   z     = 竖直方向偏移格数（+ 抬高 / - 降低）。用于微调预览的确切落点。
    NextPreviewOffset = { right = 0, z = 0 },

    -- Hold 暂存方块：固定在盘面左侧显示 board.holdType（无暂存时隐藏全部）。
    -- 同样预建一套 7 种整体实例作 Hold 专用(与活动/下一预览都不冲突)，带来总数 21 个。
    EnableHoldPreview = false,
    HoldPreviewSide = "left",   -- 固定左侧
    HoldPreviewGapCells = 0,    -- 与盘面间距格数（沿“外移”方向）；0 = 自动 = Cols + 3
    -- Hold 方块位置偏移量（单位：格，沿盘面轴向，语义同 NextPreviewOffset）：
    --   right = 沿“外移”方向额外格数；z = 竖直偏移格数。
    HoldPreviewOffset = { right = -9, z = 0 },

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
    AnchorToPlayer = false,  -- 已弃用：盘面仅以 SceneObjects.SpawnPointKey 定位，不再锚定玩家
    -- 相对玩家的偏移（米，世界轴向，与角色朝向无关）：
    -- X 正 = 东 / Y 正 = 北 / Z 正 = 上。棋盘是平行于 XZ 的竖直面。
    AnchorOffset = { X = 0.0, Y = 8.0, Z = 21.0 },  -- 抬高锚点：盘面总高 ≈(20-1)*1.02≈19.4m，须保证底行在地面之上（Z=12 时底行没入地下，约 7 行看不见）

    -- 每种方块（子方块）对应的「彩色模型」AssetRef Key（网格资源，形如 "44_CreativeAsset_*" / "50_CreativeAsset_*"）。
    -- 引擎无运行时改材质接口，颜色必须烘焙进模型；渲染层用 SetStaticMesh 把单元方块换成对应彩色网格。
    -- 数值 1..7 对应 TetrisConfig.PieceType（I/O/T/J/L/S/Z），8 = 垃圾块（灰色）。
    -- 未填 / 未注册（AssetRef 解析为 nil）→ 回退默认单色模型（BlockActorPresetKey / PieceChildPresetKey）。
    -- 用法：把 7 个着色方块模型（与现有盘面方块同规格的立方体）在编辑器注册 → 执行 update preset →
    --       把生成的 7 个 Key 填到下面（替换 PLACEHOLDER_x）。垃圾块单独用灰色模型。当前为占位，待替换真实 Key。
    -- 8 个模型按编号顺序（1=I 2=O 3=T 4=J 5=L 6=S 7=Z 8=垃圾）；各模型已烘焙好对应颜色。
    ColorModelIDs = {
        [1] = "50_CreativeAsset_114280860",        -- I 青色（Cyan）
        [2] = "50_CreativeAsset_114956395",        -- O 黄色（Yellow）
        [3] = "50_CreativeAsset_116336317",        -- T 紫色（Purple）
        [4] = "50_CreativeAsset_119832590",        -- J 蓝色（Blue）
        [5] = "50_CreativeAsset_114505299",        -- L 橙色（Orange）
        [6] = "50_CreativeAsset_115828003",        -- S 绿色（Green）
        [7] = "50_CreativeAsset_110257472",        -- Z 红色（Red）
        [8] = "50_CreativeAsset_115324270",        -- 垃圾块 灰色（Gray）
    },
}

-- ===================== 原生 UI（引擎自带 HUD / 屏幕操作按钮） =====================
-- 用 NativeControlAPI 控制，类型枚举见 EnvLua/Core/Define/CommonDefine.lua:668 NativeControlType（1~30）。
TetrisConfig.NativeUI = {
    Enabled = true,        -- 进入游戏即隐藏原生 UI，且不再还原
    -- 需要保留显示的控件类型（填 NativeControlType 数值），空表 = 全隐藏。
    -- 注意：NativeControlType 由编辑器运行时注入，本文件（纯数据）里不便直接引用，需要保留时填数字，
    -- 例：KeepTypes = { 1 } 表示保留小地图。
    KeepTypes = {},
    RetryFrames = 6,       -- 开局重发次数：原生 UI 会在角色生成后被重建，一次下发可能被覆盖
    RetryInterval = 0.5,   -- 重发间隔（秒）
}

-- ===================== 远景背景墙（4×3 模型块，置于盘面背后） =====================
-- 完全复用盘面的「视线前向 / 右向 / 上向(+Z) / 偏航」基底：
--   墙心 = 盘心 + 视线前向(装置→盘面) * DistanceX（即盘面背后 X 米）；
--   4 列沿盘面 right 向量展开，3 行沿世界 +Z 展开；每块复用盘面偏航旋转、放大 ScaleN 倍。
-- X 与 N 均为运行后手调参数（直接改这里重跑即可）。
TetrisConfig.BackgroundWall = {
    Enabled = true,         -- 是否生成远景背景墙
    DistanceX = 30,         -- 墙心位于盘心沿视线方向再前 X 米（盘面背后距离，调此值）
    ScaleN = 10,            -- 每个块放大倍数（模型原生尺寸 × N）
    Cols = 4,               -- 横向块数（沿盘面 right）
    Rows = 3,               -- 纵向块数（沿世界 +Z）
    BlockBaseSize = 1,      -- 模型原生边长（米），块间距 pitch = BaseSize*N + Gap
    BlockGap = 0,           -- 块间空隙（米）
    -- 12 个模型块的资源键（AssetRef / CreativeAsset 预设 key，形如 "44_CreativeAsset_3400003"）。
    -- 数量 < 12 时按索引循环复用；只填 1 个 key 即代表 12 块为同一模型。为空则跳过并告警。
    BlockKeys = {
        "50_CreativeAsset_111637870",
        "50_CreativeAsset_111726298",
        "50_CreativeAsset_111005022",
        "50_CreativeAsset_114960804",
        "50_CreativeAsset_115776786",
        "50_CreativeAsset_117344364",
        "50_CreativeAsset_113077723",
        "50_CreativeAsset_114321708",
        "50_CreativeAsset_111886810",
        "50_CreativeAsset_113868679",
        "50_CreativeAsset_116411456",
        "50_CreativeAsset_111151203",
    },
}

-- ===================== 盘面背后 3D UI 挂件（WidgetComponent Actor） =====================
-- 需求：每个盘面（双盘各一）的「背后」各生成 1 个带 WidgetComponent 的 Actor，用于显示 3D UI。
-- 定位完全复用盘面基底（与背景墙同源）：
--   挂件位置 = 盘心 + 视线前向(装置→盘面, 即 boardForward) * DistanceBehindM（盘面背后若干米）；
--   旋转复用盘面偏航 self.rot（与盘面同向，使 3D UI 正面朝向玩家）。
-- 必须在 AssetRef 注册该 ActorPreset 并执行 update preset（GenerateAssetRef.lua 才会生成键）。
TetrisConfig.BehindBoardWidget = {
    Enabled = true,                                   -- 是否生成盘面背后 3D UI 挂件
    PresetKey = "46_ActorPreset_1273493010",           -- 带 WidgetComponent 的 Actor 预设键（AssetRef）
    DistanceBehindM = 0.51,                               -- 盘心沿视线方向再向后推的距离（盘面背后，调此值）
    Scale = { X = 7.52, Y = 7.52, Z = 7.52 },                   -- 整体缩放（影响 WidgetComponent 的世界尺寸）
    SideOffsetM = 0,                                   -- 沿盘面右向量 right 的左右偏移（正=玩家右手侧）
    HeightOffsetM = 0,                                 -- 沿世界 +Z 的额外抬高（与盘心高度叠加）
    -- 每个棋盘的额外偏置旋转（绕竖直/Yaw 轴，单位°）：按棋盘 index 区分，让挂件呈对称倾斜。
    -- 1号 +45°、2号 −45°；未列出的棋盘不额外偏置（0°）。
    -- 测试时用-45，正式用-180
    RotationBiasByIndex = { [1] = -180, [2] = 180 },
    -- 挂件 Actor 上「对方分数」文本组件：运行时从 Actor 实例按 组件名/类名 直接获取（不依赖 UUID）。
    -- 两个挂件各生成一个，组件就在各自 Actor 下，按实例获取天然互不干扰（盘1挂件显盘2分、盘2挂件显盘1分）。
    -- 候选名与候选类都会尝试，第一个拿到且有 SetText/SetTextContent 方法的即用；按需增删以匹配编辑器命名。
    OpponentScoreTextCompName = { "ScoreText", "Text", "OpponentScore", "Score", "TextComp", "Label" },
    OpponentScoreTextCompClass = { "TextComponent", "TextRenderComponent", "WoWTextComponent", "WidgetComponent" },
    -- 当文本组件是 WidgetComponent 内部的 UMG 子控件时填这里：UMG 内文本控件的名字（编辑器里给该文本控件命的名）。
    OpponentScoreTextChildName = { "ui_enemyscore", "ScoreText", "Text", "OpponentScore", "Score", "Label" },
}

-- ===================== 盘面前方 3D 大框（用户所述“3D大框”，替代双方 2D 的 Hold/Next 显示） =====================
-- 与 BehindBoardWidget 相对：延法线方向相反——位于「盘面前方（朝玩家一侧）」，即 盘心 - boardForward * DistanceFrontM。
-- 每个盘面（双盘各一）各生成一个带 WidgetComponent 的 Actor，其 UMG 内含 Hold / Next 两个图片控件；
-- 运行时按 HoldImageChildName / NextImageChildName 在 UMG 内定位图片控件并注入 PieceImages 图片（与 2D Hold/Next 同源）。
-- 显示道具图片（类型 >= Item.TypeMin，即 PieceImages[9/10/11]）时颜色强制为白色；普通方块按 PieceTint 染色。
TetrisConfig.BigFrame3D = {
    Enabled = true,                                       -- 默认关闭；填入下方 PresetKey 并置 true 后生效（替代 2D Hold/Next）
    -- 3D 大框 Actor 预设键（46_ActorPreset_*，带 WidgetComponent 的 UMG，内含 Hold / Next 两个 Image 控件）
    -- 【必填】在编辑器里创建一个带 WidgetComponent 的 ActorPreset，UMG 内放两个 Image 控件，注册后填入其键
    PresetKey = "46_ActorPreset_612940845",
    DistanceFrontM = -0.5,                                  -- 盘心沿 +boardForward（与 BehindBoardWidget 同侧=朝玩家可见侧）的距离；调大以避开 0.6m 处的背后挂件，避免重叠。与 DistanceBehindM 同为 +forward 侧。
    Scale = { X = 2.52, Y = 2.52, Z = 2.52},                    -- 整体缩放（影响 WidgetComponent 的世界尺寸）
    SideOffsetM = 0,                                       -- 沿盘面右向量 right 的左右偏移（正=玩家右手侧）
    HeightOffsetM = -0,                                     -- 沿世界 +Z 的额外抬高
    -- 按棋盘 index 的额外偏置旋转（绕竖直/Yaw 轴，单位°）：双盘对称倾斜。
    -- 必须与可见的「背后挂件(BehindBoardWidget)」用相同偏置，因为玩家始终在盘面同一侧(-forward)看两者，
    -- 两者 WidgetComponent 法线都需指向 -forward（朝玩家）。翻反(180/-180)会让前方大框背面朝玩家→整片不可见。
    RotationBiasByIndex = { [1] = 0, [2] = 0 },
    -- UMG 内图片控件名（编辑器里给 Hold / Next 图片控件命的名）：按顺序匹配第一个有效的。
    -- 你的结构是 ui → front → hold / next，真实控件名是 "hold" / "next"，中间容器为 "front"（FrontContainerName）。
    FrontContainerName = "front",                              -- hold/next 所在的中间容器（ui 下的 front 组），用于按层级定位
    HoldImageChildName = { "hold", "Hold", "HoldImg", "HoldImage", "Image_Hold" },
    NextImageChildName = { "next", "Next", "NextImg", "NextImage", "Image_Next" },
    -- 攻势技能(SK06)高亮：ui 下与 front 同级的 backlight 图片，默认隐藏；点击攻势时显示、攻击结算(方块落地/消行)后隐藏
    BacklightChildName = { "backlight", "Backlight", "BackLight", "Glow" },
}

-- ===================== 远景背景 3D UI 挂件（背景图 WidgetComponent Actor） =====================
-- 需求：每个盘面（双盘各一）的「背后更远处」各生成 1 个带 WidgetComponent 的 Actor，用于显示远景背景图。
-- 生成方式完全照搬 BehindBoardWidget（仅依赖出生点装置 + ActorPreset(AssetRef)），纯背景、不挂接 renderer、
-- 不依赖文本组件；数值请按实际背景图尺寸/位置自行调整。
-- 必须在 AssetRef 注册该 ActorPreset 并执行 update preset（GenerateAssetRef.lua 才会生成键）。
TetrisConfig.BackgroundWidget = {
    Enabled = true,                                   -- 是否生成远景背景 3D UI 挂件（双盘 → 2 个 Actor）
    PresetKey = "46_ActorPreset_830160950",           -- 带 WidgetComponent 的远景背景 Actor 预设键（AssetRef）
    DistanceBehindM = -1,                              -- 盘心沿视线方向再向后推的距离（远景，比 BehindBoardWidget 更远）
    Scale = { X = 13, Y = 13, Z = 13 },               -- 整体缩放（影响 WidgetComponent 的世界尺寸）
    SideOffsetM = -30,                                  -- 沿盘面右向量 right 的左右偏移（正=玩家右手侧）
    HeightOffsetM = 0,                                -- 沿世界 +Z 的额外抬高（与盘心高度叠加）
    -- 每个棋盘的额外偏置旋转（绕竖直/Yaw 轴，单位°）：按棋盘 index 区分，让远景呈对称倾斜。
    -- 1号 +180°、2号 −180°；未列出的棋盘不额外偏置（0°）。
    RotationBiasByIndex = { [1] = 180, [2] =-180 },
    -- 对手标识图：本挂件 UMG 内名为 ImageChildName 的图片子控件，按对手类型切换（真人/简单/普通/困难）。
    -- 名字需与编辑器里给该图片控件命的名完全一致（含空格/全角半角）。
    ImageChildName = "正方形 29",
    OpponentImages = {
        Human  = "23_ImagePreset_181441242063729",  -- 真人对手
        Easy   = "23_ImagePreset_181441695453675",  -- 简单 AI
        Normal = "23_ImagePreset_181443061864228",  -- 普通 AI
        Hard   = "23_ImagePreset_181442655198730",  -- 困难 AI
    },
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
    BtnDown  = ci("1_CreativeInstance_23643900874412580"),  -- 硬降（本作无软降）
    BtnHold  = ci("1_CreativeInstance_23643900251825011"),
    BtnLeft  = ci("1_CreativeInstance_23643899028893263"),
    BtnRight = ci("1_CreativeInstance_23643902202474034"),
    BtnRoll  = ci("1_CreativeInstance_23643902309645984"),
    BtnSkill = ci("1_CreativeInstance_23643901308713165"),   -- 技能按钮（蓄满点击释放：向对手扔垃圾）

    -- 分数 / 消行 / 等级 HUD 文本控件：
    --   在编辑器 UI Editor 中预放置「文本控件」，复制其 InstanceUUID 填到下面（形如 "1_CreativeInstance_xxxx"）。
    --   未放置 / 未填 → UpdateHUD 自动跳过（不报错）。占位 key 需替换为真实 InstanceUUID。
    ScoreLabel = ci("1_CreativeInstance_23643898111776723"),
    LinesLabel = ci("1_CreativeInstance_FILL_LINES"),
    LevelLabel = ci("1_CreativeInstance_FILL_LEVEL"),

    -- 2D 图片组件：显示 Hold / Next 方块（SetImageWidgetContent 换图）。填编辑器预放置的图片控件 InstanceUUID。
    HoldImg = ci("1_CreativeInstance_23643900748630271"),   -- Hold 槽图片组件
    NextImg = ci("1_CreativeInstance_23643898717166573"),   -- Next 槽图片组件

    -- Combo 图片组件：每次消除(按消除行数)显示对应图，到点自动隐藏（见 TetrisGame:ShowComboImage）。
    --   ComboImg        = 图片控件实例（容器），运行时按行数换图；
    --   ComboImgByRows  = 消除行数 → 图片 AssetRef 键（1/2/3 各一张，4&5 共用一张）；行数 >5 回落到 5；
    --   ComboImgDuration= 显示时长（秒），到点自动隐藏；连消时刷新为满窗口。
    ComboImg = ci("1_CreativeInstance_23643901081703507"),
    ComboImgByRows = {
        [1] = "23_ImagePreset_181442738434917",
        [2] = "23_ImagePreset_181444424376355",
        [3] = "23_ImagePreset_181444856678574",
        [4] = "23_ImagePreset_181444578235925",
        [5] = "23_ImagePreset_181444578235925",
    },
    ComboImgDuration = 1.7,   -- 显示时长（秒）

    -- 充能块消除提示图片：道具-充能块被消除时显示 1 秒后自动隐藏（见 TetrisGame:ShowChargeItemImage）。
    --   ChargeItemImg       = 图片控件实例（CreativeInstance），消除充能块时显示；
    --   ChargeItemImgDuration = 显示时长（秒），到点自动隐藏。
    ChargeItemImg = ci("1_CreativeInstance_23643901123532648"),
    ChargeItemImgDuration = 1.7,   -- 显示时长（秒）

    -- 爆炸（爆破）道具块消除提示图片：道具-爆破块(ITEM_BLAST=9)被消除时显示 BlastImgDuration 秒后自动隐藏（见 TetrisGame:ShowBlastImage）。
    --   BlastImg          = 图片控件实例（CreativeInstance），消除爆破块时显示；
    --   BlastImgDuration  = 显示时长（秒），到点自动隐藏（隐藏时透明度改 0）。
    BlastImg = ci("1_CreativeInstance_23643898862002159"),
    BlastImgDuration = 1.7,   -- 显示时长（秒）

    -- 垃圾行提示框（对战 / 人机）：根据双方 board.pendingGarbage 显示「即将发 / 即将收垃圾」。
    -- 即将给对手扔垃圾：对手盘 pendingGarbage>0（我刚发起的攻击尚未在对手盘落地）。
    GarbageSendHint = ci("1_CreativeInstance_23643899752970406"),
    -- 即将被对手扔垃圾：本盘 pendingGarbage>0（对手发的垃圾将在我下次落子时落入）。
    GarbageRecvHint = ci("1_CreativeInstance_23643901821514970"),

    -- 对手分数文本控件：显示 self.opponent.board.score（对战 / 人机通用）
    OpponentScoreLabel = ci("1_CreativeInstance_23643899615395720"),
}

-- ===================== 输入手感（长按 / 自动横移 DAS-）ARR） =====================
-- 左右键支持「长按连续横移」：短按 = 点一次移一格（CustomUIClicked）；
-- 长按 = 按住越过引擎长按阈值后进入连发（CustomUILongPressed / CustomUILongPressReleased）。
-- DAS（Delayed Auto Shift）：按下后到首次连发的延迟；ARR（Auto Repeat Rate）：连发间隔。
-- 单位：秒。DAS 越小「起步越快」，ARR 越小「连发越快」。
TetrisConfig.Input = {
    LongPressEnabled = true,       -- 总开关：false = 左右键只响应短按，不进入长按连发
    DAS = 0.16,                    -- 首次连发延迟（秒）
    ARR = 0.06,                    -- 连发间隔（秒，越小越快
}

-- ===================== 方块图片资源（2D UI 显示 Hold / Next） =====================
-- 每种方块（type 1..7，顺序见 TetrisConfig.PieceType：I=1,O=2,T=3,J=4,L=5,S=6,Z=7）
-- 对应一张「图片资源 ImageID」，由 SetImageWidgetContent 注入到上面的 HoldImg / NextImg 槽位。
-- ImageID 需通过 vscode 插件注册预设（AssetRef）后获得；未填则对应槽位留空/隐藏。
TetrisConfig.PieceImages = {
    [1] = "23_ImagePreset_181443043387535",  -- I
    [2] = "23_ImagePreset_181443578873772",  -- O
    [3] = "23_ImagePreset_181441571605653",  -- T
    [4] = "23_ImagePreset_181442020947558",  -- J
    [5] = "23_ImagePreset_181441618721512",  -- L
    [6] = "23_ImagePreset_181443114759746",  -- S
    [7] = "23_ImagePreset_181444179307978",  -- Z
    -- 道具方块（9/10/11）：Next / Hold 与 3D 浮空图标共用同一套图（单一图源，见下）。
    [9]  = "23_ImagePreset_181443677212097",   -- 爆破块
    [10] = "23_ImagePreset_181442507346340",   -- 位移块
    [11] = "23_ImagePreset_181443922126642",   -- 充能块
}

-- Hold / Next 图片底色（白色底图，由 SetImageWidgetColor 叠加 tint 出各色）。
-- 分量 R/G/B ∈ [0,1]（不是 0~255），由下方 HEX 换算而来；改色直接改 PieceTintHex 即可。
-- 8 = 垃圾块（灰色），Next/Hold 通常不显示垃圾，预留以防复用。
TetrisConfig.PieceTintHex = {
    [1] = "1bdef2",  -- I 青
    [2] = "ffff3f",  -- O 黄
    [3] = "ae3dfd",  -- T 紫
    [4] = "016afe",  -- J 蓝
    [5] = "ffa700",  -- L 橙
    [6] = "18ed6f",  -- S 绿
    [7] = "fa2827",  -- Z 红
    [8] = "a0abb3",  -- 垃圾 灰
}
TetrisConfig.PieceTint = {
    [1] = { X = 0.10588, Y = 0.87059, Z = 0.94902 },  -- I 青 1bdef2
    [2] = { X = 1.00000, Y = 1.00000, Z = 0.24706 },  -- O 黄 ffff3f
    [3] = { X = 0.68235, Y = 0.23922, Z = 0.99216 },  -- T 紫 ae3dfd
    [4] = { X = 0.00392, Y = 0.41569, Z = 0.99608 },  -- J 蓝 016afe
    [5] = { X = 1.00000, Y = 0.65490, Z = 0.00000 },  -- L 橙 ffa700
    [6] = { X = 0.09412, Y = 0.92941, Z = 0.43529 },  -- S 绿 18ed6f
    [7] = { X = 0.98039, Y = 0.15686, Z = 0.15294 },  -- Z 红 fa2827
    [8] = { X = 0.62745, Y = 0.67059, Z = 0.70196 },  -- 垃圾 灰 a0abb3
}

-- ===================== 玩法枚举 =====================
-- 文档「玩法选择规则」：提供俄罗斯方块 / 四消两种玩法；切换规则支持「随机」。
TetrisConfig.GameMode = {
    Tetris = "tetris",   -- 俄罗斯方块（已实现）
    Match4 = "match4",   -- 四消（6×12 盘面 + 4 色方块，待资源与玩法模块，本期留桩）
    Puyo = "puyo",       -- 噗哟噗哟（四消，已实现：PuyoBoard/PuyoRenderer/PuyoGame）
    Random = "random",   -- 随机（从「已实现」的玩法中随机）
}

-- 调试：强制所有棋盘使用指定玩法（无选择按钮时测试用）。nil = 走正常选择流程。
-- 例：填 "puyo" 即可在不放置选择 UI 的情况下直接进入 Puyo。
TetrisConfig.ForceGameMode = nil

-- ===================== 玩法选择（开局前 UI 选择 → 传送到出生点） =====================
-- 方案：不切地图（当前 LevelPreset 仅 1 张），同图内先用 CustomUI 按钮选玩法，
-- 选完把玩家传送到各自出生点，再由 TetrisMatch 开局。
-- 按钮/文本需在编辑器 UI Editor 预放置，把 InstanceUUID 填到这里（与上面的 ci() 同源）。
-- 未放置（占位/未注入）时自动跳过选择阶段，保持「开局即玩」的旧行为，不影响现有流程。
-- 选择面板 = 父级面板（内含两个选择按键），面板整体显隐，按键各自注册点击事件。
TetrisConfig.ModeSelect = {
    Enabled = true,
    TimeoutSec = 20,          -- 无人选择时的超时秒数，超时按 DefaultMode 自动开局
    DefaultMode = "tetris",   -- 超时或跳过选择时的兜底玩法
    PanelKey  = ci("1_CreativeInstance_23643899474805030"),   -- 选择面板（父级）
    BtnTetris = nil,   -- 俄罗斯方块
    BtnMatch4 = nil,                                          -- 四消（旧桩，本期不做；留空不注册
    BtnPuyo   = nil,                                          -- 噗哟噗哟（复用原四消按钮）：本期不显示/不注册
}

-- ===================== 技能（俄罗斯方块：3 bar + 3 power） =====================
-- 规则：每消除 1 行获得 1 个 bar；集满 NeedBars(3) 个 bar 兑换 1 个 power（bar 清零）；
--       最多持有 MaxPower(3) 个 power；释放技能消耗 1 个 power（技能效果由所选 SK 决定）。
-- 控件：Bars = 3 个 bar 图片（按当前 bar 数显隐）；PowerSlots = 3 个 power 图片组件（按 power 数换图）。
-- （本作技能仅俄罗斯方块可用；噗哟暂未接入，见 PuyoGame:OnBtnSkill 占位。）
TetrisConfig.SkillEnabled = true
TetrisConfig.Skill = {
    NeedBars = 3,                                       -- 集满几个 bar 兑换 1 个 power
    MaxPower = 3,                                       -- 最多持有几个 power
    InitBars = 2,                                       -- 开局默认预填几条蓄能条（0=不送；< NeedBars，故开局不自动产生 power）
    DescText = ci("1_CreativeInstance_23643899335684710"),   -- 技能说明文本控件
    Desc     = "消除 1 行得 1 bar，集满 3 bar 得 1 power；释放技能消耗 1 power",
    IconImage = ci("1_CreativeInstance_23643899882881827"),   -- 局内技能 icon 图片控件（Image 控件）
    BigTipInstance = ci("1_CreativeInstance_23643900834440806"),  -- SK07「额外消行」中央大图提示组件（CreativeInstance 控件 UUID）

    -- 3 个 bar 图片（按当前 bar 数显隐：bar0=第1格, bar1=第2格, bar2=第3格/满）
    --   编辑器里这 3 张图已是「亮起的 bar」样式，代码只切换显隐，不换图。
    Bars = {
        ci("1_CreativeInstance_23643901209584926"),
        ci("1_CreativeInstance_23643899890453574"),
        ci("1_CreativeInstance_23643900127986274"),
    },
    -- 3 个 power 图片组件：按当前 power 数替换为「有/无」图片
    PowerSlots = {
        ci("1_CreativeInstance_23643898058381685"),
        ci("1_CreativeInstance_23643900333482517"),
        ci("1_CreativeInstance_23643899552703951"),
    },
    PowerEmptyImg = "23_ImagePreset_181443179020119",    -- 无 power 时显示
    PowerFullImg  = "23_ImagePreset_181443890598929",    -- 有 power 时显示

    -- 技能不可用（power=0）时，把技能按钮 BtnSkill 图片调暗（opacity 0~1，越小越暗）；
    -- 引擎 Button 控件无 tint/灰度接口，此为「置灰/不可用」近似。有 power 时恢复 1（不透明）。
    -- 若需真·灰度，改走 SetButtonNormalImage 切换灰图（见 BtnDisabledImg）。
    DisabledOpacity = 0.4,
    BtnNormalImg    = nil,   -- 可用态按钮图资源 Key（ImagePreset）；与 BtnDisabledImg 同时填才走切图方案
    BtnDisabledImg  = nil,   -- 不可用态灰图资源 Key（ImagePreset）；与 BtnNormalImg 同时填才走切图方案
}

-- ===================== 技能库（开局由玩家三选一，见 doc/技能.xls） =====================
-- 本期开放 SK-01 / SK-02 / SK-06 三个（SK-03/04/05 暂未开放）。
-- 每个技能：
--   key      技能编号（与表格一致）
--   name     技能名称（用于提示文本）
--   desc     技能说明（写入 Skill.DescText，开局替换原说明）
--   imageKey 技能按钮图片：编辑器注册的 ImagePreset 资源 Key（形如 "23_ImagePreset_xxxx"），
--            运行前需在 VSCode 插件注册预设并执行 update preset，使 AssetRef[imageKey] 可用；
--            否则代码回退直接用该字符串（引擎可能不识别）。下方为占位 Key，请替换。
--   type     "buff"（己方增益）/ "debuff"（敌方减益）
--   其余字段为效果参数（clearRows / attackBonus），由 TetrisGame:OnBtnSkill 读取。
TetrisConfig.Skills = {
    SK01 = {
        key = "SK01", name = "禁止转动", type = "debuff",
        desc = "对手接下来 1 个方块无法旋转（左右移动 / 软降 / 硬降 / Hold 不受影响）",
        imageKey = "23_ImagePreset_181445133927289",   -- 中央大图提示图片预设
        iconKey  = "23_ImagePreset_181442919461175",   -- 技能图标（局内 HUD / 选择按钮）
    },
    SK02 = {
        key = "SK02", name = "清除最下方两行", type = "buff", clearRows = 2,
        desc = "删除可见区最下方 2 行，上方整体下移 2 行（不计分 / 不消行 / 不送攻击）",
        imageKey = "23_ImagePreset_181444855524605",   -- 中央大图提示图片预设
        iconKey  = "23_ImagePreset_181443391878538",   -- 技能图标（局内 HUD / 选择按钮）
    },
    SK06 = {
        key = "SK06", name = "攻势", type = "buff", attackBonus = 1,
        desc = "接下来 1 次消行结算时，攻击行数 +1（单消亦从 0 行变为 1 行）",
        imageKey = "23_ImagePreset_181441732151158",   -- 中央大图提示图片预设
        iconKey  = "23_ImagePreset_181443140642203",   -- 技能图标（局内 HUD / 选择按钮）
    },
    SK07 = {
        key = "SK07", name = "赠送技能", type = "buff",
        desc = "释放后进入冷却：下次结算消除时，额外多消除下方一行；触发消除后冷却解除（冷却中再次点击提示：技能冷却中）。",
        imageKey = "23_ImagePreset_181444591440840",   -- 与中央大图提示共用同一图片预设
        iconKey  = "23_ImagePreset_181445135603547",   -- 技能图标（局内 HUD / 选择按钮）
        cdIndicator = "1_CreativeInstance_23643899321563373",   -- 消行时显示，1.5s后隐藏
    },
    SK08 = {
        key = "SK08", name = "左右对调", type = "debuff",
        desc = "释放后进入冷却：对手下一个方块下落期间左右方向键互换；对手当前方块落地后冷却解除（冷却中再次点击提示：技能冷却中）。",
        imageKey = "23_ImagePreset_181444605973235",   -- 中央大图提示图片预设
        iconKey  = "23_ImagePreset_181441605832442",   -- 技能图标（局内 HUD / 选择按钮）
        indicator = "1_CreativeInstance_23643899208638721",   -- 生效指示器组件：敌方左右对调期间显示，敌方该方块落地后隐藏
    },
}

-- ===================== 技能选择（开局前置 UI：开始游戏 → 三选一） =====================
-- 流程：开局先显示「开始游戏」按钮 → 点击后显示 3 个技能按钮（各自带技能图片）
-- → 点击任一技能 → 该玩家 3 个按钮全部失效 → 全部选完 / 超时 → 进入玩法选择或直接开局。
-- 控件 UUID 在编辑器 UI Editor 预放置后，从全局表 CreativeInstance 复制（形如 "1_CreativeInstance_xxxx"）。
-- 未放置 / 未注入时自动跳过本阶段，使用 DefaultSkill。
-- 若想「只保留技能选择、跳过玩法选择」，把 TetrisConfig.ModeSelect.Enabled 设为 false 即可。
TetrisConfig.SkillSelect = {
    Enabled = true,
    TimeoutSec = 20,                -- 无人选择时的超时秒数，超时按 DefaultSkill 开局
    DefaultSkill = "SK02",          -- 超时 / 跳过选择时的兜底技能（填 Skills 里的 key）
    ApplyImageToSkillIcon = true,    -- 进入游戏后，把局内技能 icon 图片控件替换为所选技能图片

    StartPanel = ci("1_CreativeInstance_23643901090745098"), -- 开始界面（容器面板，内含「开始游戏」按钮）：点击开始进入选择界面时整体隐藏
    StartBtn  = ci("1_CreativeInstance_23643901825073557"),  -- 「开始游戏」按钮：点击后显示技能选择面板
    PanelKey  = ci("1_CreativeInstance_23643901481771979"),  -- 技能选择面板（父级，内含 3 个技能按键）
    BtnSK01   = ci("1_CreativeInstance_23643901110827074"),  -- 技能按钮：SK-01 禁止转动
    BtnSK02   = ci("1_CreativeInstance_23643902157912974"),  -- 技能按钮：SK-02 清除最下方两行
    BtnSK06   = ci("1_CreativeInstance_23643900733325060"),  -- 技能按钮：SK-06 攻势
    BtnSK07   = ci("1_CreativeInstance_23643900548841233"),  -- 技能按钮：SK-07 赠送技能
    BtnSK08   = ci("1_CreativeInstance_23643901741151544"),  -- 技能按钮：SK-08 左右对调
    -- 选择界面各技能的独立图标组件（按钮本身只负责点击触发，图标显示在这些独立组件上）
    IconSK01  = ci("1_CreativeInstance_23643900737922680"),  -- SK-01 图标
    IconSK02  = ci("1_CreativeInstance_23643898435229426"),  -- SK-02 图标
    IconSK06  = ci("1_CreativeInstance_23643898516504238"),  -- SK-06 图标
    IconSK07  = ci("1_CreativeInstance_23643901228761309"),  -- SK-07 图标
    IconSK08  = ci("1_CreativeInstance_23643900267681567"),  -- SK-08 图标
}

-- ===================== 名字组件（对局 HUD：我方 / 对方 名字显示） =====================
TetrisConfig.NameUI = {
    SelfName = ci("1_CreativeInstance_23643899410907749"),  -- 我方名字组件（显示自己昵称）
    OppName  = ci("1_CreativeInstance_23643902237944181"),  -- 对方名字组件（显示对手昵称 / AI 角色名）
}

-- ===================== 头像组件（对局 HUD：我方 / 对方 头像显示） =====================
-- 开局从 AvatarPresets 中随机分配；2 名玩家时洗牌分配保证两者头像不同。
TetrisConfig.AvatarUI = {
    -- 头像框（容器组件）：若为图片控件也会被填图，非图片则忽略
    SelfAvatar = ci("1_CreativeInstance_23643899970464328"),  -- 我方头像组件
    OppAvatar  = ci("1_CreativeInstance_23643902263045933"),  -- 对方头像组件（你给的顺序为 对方/我方）
    -- 头像 icon（实际显示头像图片的子控件）
    SelfAvatarIcon = ci("1_CreativeInstance_23643901196455156"),  -- 我方头像 icon 组件
    OppAvatarIcon  = ci("1_CreativeInstance_23643900780098696"),  -- 对方头像 icon 组件（顺序同上为 对方/我方）
    -- 头像图片候选池（AssetRef 图片键）：开局随机分配，真人/AI 都从这里取；2 人时保证双方不同。
    -- 注：下方第 2、3 项当前为同一张图(181444908600059)，系重复录入；AssignAvatars 已去重，
    --      故实际可用为 4 张。如你确实想要 5 张不同的，把第 3 项换成另一张图的键即可。
    AvatarPresets = {
        "23_ImagePreset_181443134637078",
        "23_ImagePreset_181442580203129",
        "23_ImagePreset_181444908600059",
        "23_ImagePreset_181442334583358",
        "23_ImagePreset_181441512885511",
    },
}

-- ===================== 选完技能后隐藏的场景对象 =====================
-- 任意玩家点完技能即隐藏这些「场景对象」（CreativeInstance key），全程只执行一次。
-- 与 UI 控件不同，场景对象用 InstanceAPI.ToggleInstanceVisible(uuid, false) 隐藏（影响全体玩家，无需按玩家重复）。
TetrisConfig.HideAfterSkill = {
    "1_CreativeInstance_23643898160458360",
    "1_CreativeInstance_23643900034986535",
}

-- ===================== 选完技能后显示的 HUD =====================
-- 与 HideAfterSkill 相反：这些 UI 实例（CreativeInstance key）在「选完技能、显示 loading 时」
-- 一并 SetWidgetVisible(true) 给全体真人，作为游戏内 HUD。游戏开始后保持显示，不在隐藏 loading 时关闭。
TetrisConfig.ShowHudAfterSkill = {
    "1_CreativeInstance_23643901302086725",
}

-- ===================== 游戏提示文本（通用飘字） =====================
-- 任意提示（扔垃圾 / 被扔垃圾 / 技能就绪等）写入该文本，显示 HintDuration 秒后自动隐藏。
TetrisConfig.HintText = ci("1_CreativeInstance_23643900239436700")
-- Loading 加载界面：开局与「选技能后对象生成」期间显示的遮罩控件
TetrisConfig.LoadingScreen = ci("1_CreativeInstance_23643899809238462")
-- Loading 进度条：loading 显示期间 LoadingTime 秒内从 0 填充到 100%
TetrisConfig.LoadingProgress = ci("1_CreativeInstance_23643899128297494")
-- Loading 持续时间（秒）：初始遮罩超时隐藏、对象生成期 loading 到时、以及进度条填充动画时长。
-- 三处共用此值，改这一项即可统一调整 loading 节奏。默认 1 秒。
TetrisConfig.LoadingTime = 3
TetrisConfig.HintDuration = 2   -- 提示显示时长（秒），到点自动隐藏

-- ===================== AI 对手（单人模式） =====================
-- 单人时：第 2 块盘（无人类玩家的旁观盘）改为 AI 自动对战。
-- AI 自动选最优落点（朝向 + 列）、让方块自然下落、蓄满后自动放技能，并与人类互发垃圾。
-- 单人开局先弹「AI 难度选择面板」(PanelKey + 3 个难度按钮)，选完写入 match.aiDifficulty，
-- 落到 AI 盘 g.aiQuality（见 TetrisAI.bestMove 的 quality 参数：越低越易乱下、越弱）。
TetrisConfig.AI = {
    Enabled = true,        -- 单人模式把空盘变成自动机器人对手
    FreeLook = true,       -- AI 在场时人类不锁定相机，便于观察双方盘面

    -- 单人 AI 难度选择界面（控件需在编辑器 UI Editor 预放置，UUID 填这里）
    PanelKey = ci("1_CreativeInstance_23643900886574000"),  -- AiPanel：AI 难度选择容器面板
    BtnEasy   = ci("1_CreativeInstance_23643900012158637"),  -- 难度按钮：简单
    BtnNormal = ci("1_CreativeInstance_23643899828974623"),  -- 难度按钮：普通
    BtnHard   = ci("1_CreativeInstance_23643901829603942"),  -- 难度按钮：困难

    -- 各难度对应的 AI 落子质量（0~1）：1=始终最优（困难）；越低越常以随机落点代替最优（越弱）。
    -- 影响 AI 强度，不影响下落速度（速度由重力区间决定）。
    -- Name：该难度 AI 在结算/对局中显示的角色名（玩家盘显示真实玩家名，AI 盘显示此名）。
    DefaultDifficulty = "Normal",
    DifficultyLevels = {
        Easy   = { Quality = 0.55, Name = "小白" },
        Normal = { Quality = 0.80, Name = "强敌" },
        Hard   = { Quality = 1.00, Name = "大师" },
    },
}

-- ===================== 结算界面 =====================
-- 一方失败 / 时间到 / 提前触发 时，给全体玩家弹出结算面板并显示分数。
-- 面板与文本控件需在编辑器 UI Editor 预放置，把 InstanceUUID 填到这里（与上面的 ci() 同源）。
TetrisConfig.Settle = {
    Enabled = true,
    PanelKey = ci("1_CreativeInstance_23643902119497962"),   -- 结算面板（父级 Widget，SetWidgetVisible 控制显隐）    
    P1Score = ci("1_CreativeInstance_23643899546295419"),  -- 玩家1 分数文本控件
    P2Score = ci("1_CreativeInstance_23643901135143270"),  -- 玩家2 分数文本控件
    WinnerLabel = ci("1_CreativeInstance_23643900539144808"),  -- 胜者ID 文本控件
    TimeLimitSec = 0,     -- 对局时间上限（秒）；0 = 不限时（仅在「一方失败」时结束）
    -- 结束游戏 API：仅「提前触发结算」时调用（自然结束已走引擎流程，不调用）。
    -- 需填一个 function(match) 函数，内部调用引擎「结束游戏」接口；未填时回退 match:Stop()（触发 OnRoundEnd）。
    -- 例：EndGameCall = function(match) Game:EndGame() end
    EndGameCall = nil,
    ExitBtn    = ci("1_CreativeInstance_23643898739648472"),   -- 结算界面「结束游戏」按钮：点击执行 GameOutcomeAPI.SetRoundGameEnd(true)

    -- 引擎胜负上报：把每队的输赢告诉引擎（GameOutcomeAPI.SetTeamRoundOutcome），并推送分数（BattleDataAPI.SetPlayerIntegral）。
    -- 关闭后只走自建结算面板，引擎不知道谁赢谁输（影响官方结算/排名/MVP）。
    ReportOutcome = true,
    -- OutcomeType 取值：引擎桩只标注为 "Win/loss status"，本地未给枚举，需向编辑器/平台确认具体值。
    -- 默认按常见约定填 1=胜 2=负 3=平；若引擎要求枚举对象而非数字，改这里即可。
    OutcomeType = { Win = 1, Lose = 2, Draw = 3 },
}

-- ===================== 双人对战（经典对攻） =====================
-- 固定 2 名玩家：各自出生点前方一块棋盘，各自独立控制；
-- 消行给对手底部塞垃圾行，先顶出者判负（最后存活胜）。
TetrisConfig.Versus = {
    Enabled = true,
    -- 消 N 行 → 给对手发几行垃圾（按 cleared 行数索引；无对应档位按 0）。
    --   经典规则：1 行=0、2 行=1、3 行=2、4 行(Tetris)=4。
    GarbageTable = { [1] = 1, [2] = 3, [3] = 5, [4] = 7 },
    MaxPending = 30,   -- 待注入垃圾行上限（防止无限堆叠）
}

-- ===================== 场景标记对象（编辑器预放置的 CreativeInstance Actor） =====================
-- UUID 来自全局表 CreativeInstance（编辑器运行时注入），运行时按 key 动态取（不在加载期取，避免 nil）。
--   盘面与固定相机均以 SpawnPointKey（出生点装置）为唯一基准；CameraMarkerKey / SpawnMarkerKey 已废弃不再使用。
TetrisConfig.SceneObjects = {
    -- 出生点装置：玩家在此生成；棋盘在其前方 BoardForwardDistM 米处生成（来自全局表 CreativeInstance）。
    -- 盘面与固定相机均以该装置为唯一基准（CameraMarkerKey / SpawnMarkerKey 已废弃）。
    -- 出生点装置 1：第 1 名玩家在此生成，棋盘在其正前方 BoardForwardDistM 米处
    SpawnPointKey   = "1_CreativeInstance_23643902170822016",
    
    -- 出生点装置 2：第 2 名玩家在此生成（无第 2 人时该盘作为旁观盘渲染）
    SpawnPointKey2  = "1_CreativeInstance_23643899581850377",    
}

-- 出生点装置前方生成棋盘的距离（米，可配置）：棋盘中心 = 装置位置 + 世界 +Y(北) * 该值。
TetrisConfig.BoardForwardDistM = 36

-- 盘面左右偏移（米，沿盘面右向量 right，正=向玩家右手侧移）：与 BoardForwardDistM 垂直，仅平移不改朝向/前后。
TetrisConfig.BoardSideOffsetM = 0

-- 盘面相对玩家朝向的额外旋转（度，从上方俯视）：仅微调“盘心落点”方位（绕出生装置公转），不改盘面自身轴向。
-- 当前朝向源用角色 Actor 前向（pawn:GetActorForwardVector）；若盘面仍不正对，调此值：
--   盘偏右 → 给负值（逆时针转回正前）；盘偏左 → 给正值。例如偏右约 90° 先试 -90。
TetrisConfig.BoardYawOffsetDeg = 0

-- 盘面“自身轴向”翻转 180°：仅翻转盘面本地系（right/法线/旋转轴），盘心位置不变（不绕出生装置公转）。
-- 与 BoardYawOffsetDeg 的区别：后者会让盘面绕出生装置公转到背后；本开关让盘面留在原位、原地翻正。
-- 用于玩家始终看“背面”导致左右/旋转全部镜像时，置 true 即可看到正面（配合 PieceSpinSign=+1 与正常按键方向）。
TetrisConfig.BoardFlipAxis180 = true

-- 盘面整体离地高度（米）：棋盘底行距“出生点装置所在水平面”的间隙，越大盘面越悬空越高。
TetrisConfig.BoardHeightOffsetM = -8.5

-- 固定相机（玩家自身第三人称相机）参数：
TetrisConfig.Camera = {
    PlayerToBoardM = 22,  -- 占位：玩家站位到盘面水平距离（SetCameraOffset 方案暂未用）
    CamBackM = 3,         -- 相机在玩家身后的退后距离（米，SetCameraDistance）
    OffsetXM = 0,         -- 新方案：盘已在玩家正前方，相机默认看向盘心；X 偏移通常设 0（前/后微调）
    OffsetYM = 0,         -- Y 偏移通常设 0（左/右微调）
    OffsetZM = 0,         -- Z 偏移：相机相对默认位的上下（米）；想俯视盘面上方设正值，想仰视设负值
    ZExtraM = 0,          -- 兼容旧名（被 OffsetZM 优先读取）
    LockMovement = false, -- 是否锁定玩家移动（固定位置，仅供观战）—— 临时去掉限制：允许玩家自由移动
    LockRotation = false,  -- 是否锁定摄像机旋转（玩家无法自由转视角，始终看向盘心）—— 临时去掉限制：允许自由转视角
}

-- ===================== 调试 =====================
TetrisConfig.Debug = {
    PrintBoardBounds = false,  -- Build 完成后打印盘面世界坐标范围
    PrintGrid = false,        -- 每次刷新打印期望显隐的字符画（排查行列映射用，较刷屏）
    DumpCellStatus = false,    -- 逐行打印 已创建/当前显示/期望显示，定位“生成了但被隐藏”或“没生成”
    ShowPieceInfo = false,    -- 每次生成新下落方块时上屏（已改由 HUD 显示分数，默认关闭避免刷屏）
    ShowPieceInfoPopup = false, -- false = 聊天框(SendQuickMenuMessage)；true = 屏幕弹窗(SendBattlePopupMessage)
    ShowGameOverInfo = false,  -- 结束时上屏结算
    PrintGarbage = false,     -- 对战：打印发/收垃圾行日志
    DropDbg = false,           -- 下落时每 15 帧打印所有子块实际坐标 vs 预期坐标（[Tetris][DropDbg]）
    LockDbg = false,           -- 锁定加分调试：打印哪块盘(玩家/对手)在 lockPiece 加分，以及对手分控件是否写入成功
}

-- ===================== 噗哟噗哟（四消）玩法 =====================
-- 复用 Tetris 的渲染几何（Render）与场景标记（SceneObjects：出生点装置），
-- 不重复定义盘面定位逻辑；仅描述 Puyo 专属参数。
TetrisConfig.Puyo = {
    Board = { Cols = 6, Rows = 12 },   -- classic 6×12
    Colors = 4,                        -- 颜色数（预留 5 色扩展）
    BlockScale = 0.5,                  -- 噗哟彩色方块模型缩放（独立于俄方块；模型偏大就调小，如 0.8/0.5）
    PairSpinSign = 1,                  -- 旋转方向符号（对齐数据层 CW）
    GravityInterval = 0.8,             -- 重力下落间隔（秒）
    -- 连锁计分（chain 倍数）
    ChainBonus = { [1] = 10, [2] = 30, [3] = 70, [4] = 120, [5] = 200 },
    ShowGhost = false,                 -- 幽灵（落点预览）对子（false = 关闭盘面落点预览）
    -- 消除动画时序（分步骤：停顿 → 回收+特效 → 等特效完 → 下落）
    ClearPauseSec = 0.35,                       -- 消除前停顿（秒）：先等待 x 秒，方块仍可见
    ClearEffectKey = "13_EffectPreset_100021",  -- 消除特效资源 Key（AssetRef；编辑器注册并 update preset）
    ClearEffectDuration = 0.5,                  -- 特效播放时长（秒）：等特效播完再执行下落
    ClearEffectScale = { X = 1.0, Y = 1.0, Z = 1.0 },     -- 特效缩放
    ClearEffectOffset = { X = 0, Y = 0, Z = 0 },         -- 特效位置额外偏移（米）
    PreviewSideCells = 9,              -- 预览区与盘面间距（沿盘面右向量外移的格数）
    -- 4 色方块模型（SetStaticMesh 换色用）：编辑器已注册的 CreativeAsset。
    BlockMesh = {
        [1] = "50_CreativeAsset_119799555",
        [2] = "50_CreativeAsset_115405987",
        [3] = "50_CreativeAsset_114457864",
        [4] = "50_CreativeAsset_118057836",
    },
    -- 复用 Tetris 的渲染与场景资源（盘面对齐/对象池/出生点）
    Render = TetrisConfig.Render,
    SceneObjects = TetrisConfig.SceneObjects,
}

return TetrisConfig
