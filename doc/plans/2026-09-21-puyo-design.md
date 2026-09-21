# 噗哟噗哟（Puyo Puyo）玩法设计文档

> 在现有「俄罗斯方块」EnvLua 工程上，新增第二种玩法「噗哟噗哟（四消）」，
> 通过**逻辑/渲染双解耦** + **对象池按方块表示分类**，与 Tetris 共用同一套
> 出生点装置 / 相机 / 输入 / 对战总控，仅替换「棋盘逻辑」与「渲染器」。

日期：2026-09-21
状态：MVP 实施中（单人可玩为第一阶段目标）

---

## 1. 目标与范围

- **MVP（第一阶段）**：单人可玩 Puyo——模式选择 → Puyo 规则 → 渲染（池3/4）→ top-out。
- **第二阶段**：双人对称对战（捣乱行 garbage、最后存活胜），复用 Tetris 的 Versus 框架。
- **不变**：出生点装置定位、固定相机、CustomUI 输入路由、TetrisMatch 总控骨架。

## 2. 玩法规则（Puyo 核心）

- 盘面 `6 列 × 12 行`（classic）。`grid[row][col]`，row 1=顶，row Rows=底，col 1=最左。
- 单元格值：`0`=空，`1..4`=颜色（4 种：红/绿/蓝/黄）。
- **活动对子**：一次落下 2 个噗哟，{ c1, c2, x, y, rot }，以 **c1 为枢轴** 位于 `(x,y)`，
  c2 相对枢轴：
  - rot=1：c2 在 `(x, y-1)`（上方）
  - rot=2：c2 在 `(x+1, y)`（右侧）
  - rot=3：c2 在 `(x, y+1)`（下方）
  - rot=4：c2 在 `(x-1, y)`（左侧）
- 出生：枢轴 `x = 3`（居中），`y = 2`，rot=1（即 c2 在第 1 行、c1 在第 2 行）。
- 操作：左/右移（dx）、旋转 CW（rot 循环）、软降（每 tick 下移）、硬降（落底即锁）。
- **锁定**：把 c1/c2 写入 grid；随后触发连锁消除。
- **消除（同色连通）**：4-连通同色块 ≥4 个即消除。消除后**逐列竖直下落填补空隙**，
  再扫描新一批 ≥4 连通组，**循环直到无消除**，消除轮数记为 chain（连锁倍数计分）。
- **top-out**：出生即无法放置（spawn 位置已占用）→ `isGameOver = true`。

## 3. 对象池方案（4 类，按方块「表示」分类）

| # | 池 | 来源玩法 | 颜色 | 实现 |
|---|---|---|---|---|
| 1 | 整体方块（7 型 whole-piece） | Tetris | 整块单色 | 现有 `TetrisRenderer`（不变）|
| 2 | 单色单元方块 | Tetris | 单色 | 现有 `BlockActorPresetKey` 池（不变）|
| 3 | **多色单元方块** | Puyo | **4 色模型 + `SetStaticMesh` 换 mesh** | 新建 `PuyoRenderer` |
| 4 | **成对的整体方块** | Puyo | **根 + 2 子，各子 `SetStaticMesh` 换色** | 新建 `PuyoRenderer` |

- **多色上色机制**：引擎无运行时改材质 API（已确认），故提供 4 种颜色的方块模型
  （`BlockMesh_Red/Green/Blue/Yellow`，`44_CreativeAsset_*` 类型），取格时调
  `StaticMeshComponent:SetStaticMesh(meshRef)` 换色（仅 acquire 时一次，非每帧，开销可忽略）。
  该 API 在 `TetrisRenderer.lua:657` 已验证可用。
- **池 4 结构**：复用「方案2」——1 个隐形根 `EmptyActor` + 2 个 `StaticMeshComponent` 子组件
  （正好一对噗哟）；取对子时按 `(c1,c2)` 调 `SetStaticMesh` 给两子换色，再设相对偏移，
  旋转只转根（与 Tetris whole-piece 同源）。

## 4. 逻辑 / 渲染双解耦架构

完全镜像 Tetris 三件套，仅替换内部实现：

```
PuyoBoard   (纯逻辑)  ≡  TetrisBoard
PuyoRenderer(渲染)    ≡  TetrisRenderer
PuyoGame    (控制)    ≡  TetrisGame
```

- `PuyoBoard`：纯逻辑，不依赖引擎 API；输出 `getCell/ getActivePair / getNextPair / getGhostPair`。
- `PuyoRenderer`：读取 `PuyoBoard` 状态，管理池 3/4，处理 `Build/Update/Clear/ResolveOrigin/GetBoardCenter`。
- `PuyoGame`：串联两者，负责重力 tick、UI 输入路由（`OnBtnLeft/Right/Roll/Down/Skill`）、
  top-out 上报 `match:OnPlayerOut`、HUD。
- **接口对齐**：`TetrisMatch` 仅依赖统一接口（`Init/Start/StartSpectator/Stop/OnBtn*/opponent/
  board:isOver()/playerKey/playerState/running`），`PuyoGame` 必须暴露同名方法。

## 5. 双玩法接入

- 新增 `TetrisConfig.GameMode.Puyo = "puyo"`。
- `TetrisModeSelect`：`IMPLEMENTED` 加入 Puyo；`WidgetIDs/Bindings` 增加 `BtnPuyo`。
- `TetrisMatch` 工厂化：原 `Init` 直接 `TetrisGame:new` 改为按模式建实例
  （`createGame(mode, spawnKey, index)` → `TetrisGame` 或 `PuyoGame`），在 `OnModeSelected`
  已知每盘模式后再建实例并 `Init`；未分配玩家的旁观盘沿用已选玩家模式（单人时即单一 Puyo 盘）。

## 6. 配置新增（`TetrisConfig`）

```lua
TetrisConfig.Puyo = {
    Board = { Cols = 6, Rows = 12 },
    Colors = 4,                     -- 颜色数（4 色；预留 5 色扩展）
    -- 旋转方向符号（对齐数据层 CW）
    PairSpinSign = 1,
    -- 重力节奏（秒）
    GravityInterval = 0.8,
    -- 连锁计分（chain 倍数）
    ChainBonus = { [1]=10, [2]=30, [3]=70, [4]=120, [5]=200 },
    -- 4 色方块模型（SetStaticMesh 用，需在编辑器注册并执行 update preset）
    BlockMesh = {
        [1] = "44_CreativeAsset_XXXX_Red",
        [2] = "44_CreativeAsset_XXXX_Green",
        [3] = "44_CreativeAsset_XXXX_Blue",
        [4] = "44_CreativeAsset_XXXX_Yellow",
    },
    -- 复用 Tetris 的渲染几何参数（CellSize/CellGap/出生点定位键等）
    Render = TetrisConfig.Render,
    SceneObjects = TetrisConfig.SceneObjects,
}
```

> 渲染复用 Tetris 的 `Render`（CellSize/CellGap/ForceActorMode/UseWholePieceAttach/
> PieceRootPresetKey/PieceChildPresetKey/BlockActorPresetKey）与 `SceneObjects`（出生点装置），
> 不重复定义定位逻辑——盘面仍由 `ResolveOrigin` 按各自出生点 yaw 摆正（已修复双盘旋转 bug）。

## 7. 资源需求（编辑器侧）

- 4 种颜色的立方体方块模型（红/绿/蓝/黄），注册进 AssetRef，供 `SetStaticMesh` 换色。
- （可选）Puyo 专属 HUD 文本控件（分数/连锁）；未配则复用 Tetris 的 HUD 控件或跳过。

## 8. 实现里程碑

- [x] **M1 逻辑层** `PuyoBoard.lua`：网格、生成、左/右移、旋转、软/硬降、锁定、连锁消除、top-out。
- [ ] **M2 渲染层** `PuyoRenderer.lua`：池3（落定多色单元，换 mesh）+ 池4（活动对子，根+2 子换色）+ 预览。
- [ ] **M3 控制层** `PuyoGame.lua`：重力 tick、输入路由、top-out 上报、HUD。
- [ ] **M4 接入** `TetrisConfig`/`TetrisModeSelect`/`TetrisMatch`：GameMode.Puyo + 工厂 + 选择按钮。
- [ ] **M5 联调**：双人对称下，分别转几次方块确认落地方向正确（已修旋转 bug 后各盘自正）。

## 9. 已知风险 / 注意

- 双盘各用各自 `self.boardYaw` 绕轴旋转（修复过的旋转 bug），Puyo 对子旋转须同样按实例 yaw，
  不能写成模块级全局。
- 池 4 用「方案2 根+组件」换色（每子 `SetStaticMesh`）；若发现客户端不同步，退化为方案3（根+2 子 Actor）。
- 捣乱行（garbage）/对战第二阶段再接，MVP 不实现 `addGarbage/applyGarbage`。
