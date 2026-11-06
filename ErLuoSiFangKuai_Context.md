# ErLuoSiFangKuai（俄罗斯方块）项目背景

> 本文档供 AI Agent 了解本项目。每次新会话请先读取本文件与 `AI_WOW_Rules.md`。

## 玩法概述（待用户确认后补全）

* **类型** ：待填（如：俄罗斯方块 / 单人 / 多人合作 / 对抗）
* **主题** ：俄罗斯方块经典玩法
* **目标** ：待填（消行得分 / 对战淘汰 等）
* **规则** ：待填

## 项目结构（约定）

```
EnvLua/Server/ErLuoSiFangKuai/   # 玩法代码放这里（可写区）
├── ErLuoSiFangKuaiGameMain.lua   # 玩法入口（被 ServerGameMain 转发调用）
├── ErLuoSiFangKuaiConfig.lua     # 配置常量
└── ...                            # 网格/方块/消行/AI 等子模块
```

入口：`EnvLua/Server/ServerGameMain.lua`（标准 Server 范式，require 本工程的玩法模块并转发生命周期）。

## 开发阶段（待用户确认后补全）

| 阶段 | 内容 | 状态 |
| ---- | ---- | ---- |
| P0 | 技术预研（API 校验、框架搭建） | 🔲 |
| P1 | 核心玩法 MVP | 🔲 |
| P2 | 局内事件 | 🔲 |
| P3 | UI | 🔲 |
| P4 | 流程闭环 | 🔲 |
| P5 | 美术 / 音效 | 🔲 |
| P6 | 测试 | 🔲 |

## 已验证的 API（实跑后在此记录）

| API | 状态 | 说明 |
| --- | --- | --- |
| CustomUIClicked (=120000) | ⚠️ 声明已确认，行为待实跑 | CustomUI 按钮**短按/点击**事件。`@listen InstanceID`（按控件 UUID 过滤），`@output` = 点击者 PlayerState。左右/下键短按在此派发（OnBtnLeft/Right/Down）。 |
| CustomUILongPressed (=120001) | ⚠️ 声明已确认，行为待实跑 | CustomUI 按钮**长按开始**事件。输出同上为 PlayerState。左右键长按 → StartMoveRepeat（DAS/ARR 连发）；下键长按 → StartSoftDrop（软降连发）。 |
| CustomUILongPressReleased (=120002) | ⚠️ 声明已确认，行为待实跑 | CustomUI 按钮**长按抬起**事件。输出 PlayerState。左右/下键抬起 → StopMoveRepeat / StopSoftDrop 停止连发。 |
| CameraAPI.LockCameraInput(ps, bLocked) | ⚠️ 声明已确认，待实跑 | 锁定/解锁摄像机旋转输入（屏蔽视角旋转，保留 WASD 移动）。查询用 IsCameraInputLocked(ps)。 |
| TetrisBoard:softDrop() | ✅ 已读源码确认 | 软降一格：成功下移并 +SoftDropPerCell 分，解除贴地状态；触底返回 false（不锁定），由重力/锁定延迟接管。 |
| TetrisBoard:hardDrop() | ✅ 已读源码确认 | 硬降：直接落底并 lockPiece() 锁定，+dist*HardDropPerCell 分。 |
| TetrisBoard 落地锁定延迟（tick / resetLockDelay） | ✅ 已读源码确认 | 方块「落不动」不再立即 lockPiece，改为累计 groundTimer（按重力周期累加）达 LockDelay(0.25s) 才锁定；move/rotate 成功且贴地时 resetLockDelay 把计时归零（上限 LockResetLimit=15，防无限拖延）；新块 spawn 重置为未贴地。硬降仍立即锁定。低等级重力慢时窗口实际 ≥ 重力周期。 |
| 3D 世界挂件 WidgetComponent 取子控件 + 写文本 | ✅ 2026-10-14 实跑验证 | `actor:GetComponentByClass("WidgetComponent")` 取组件 → `Game:GetAllPlayerPawns()`（LuaArray，`:Num()/:Get(i)` 0基）取 pawn → `wc:GetUserWidgetObject(pawn)` 取 WoWUserWidget → `uw:GetWidgetFromName("控件名")` 取子控件 → `tw:SetTextContent(文本)`。详见 `doc/3D-UI-组件使用指南.md`。 |
| 3D 挂件子控件无 InstanceUUID | ✅ 2026-10-14 实跑验证 | `tw:GetWoWObjectID()`/`GetInstanceUUID()` 均返回 nil；3D 挂件内部子控件不能用 `CustomUIAPI.SetAllPlayerTextContent(uuid,text)`，必须直接对 `tw` 对象 `SetTextContent`（世界空间共享渲染，全员生效）。 |
| 3D 挂件图片控件换图 | ✅ 2026-10-14 实跑验证 | `uw:GetWidgetFromName("图片控件名")` 取 `WoWCustomUIImage` → `w:SetImageContent(AssetRef["<ImageKey>"])`；`ImageID` 实际传 `AssetRef` 句柄（非整数 ID，与 2D HUD `resolveImg` 约定一致）。子控件 wrapper 不转发 `GetName()`，取编辑器名需 `w:GetProxy():GetName()`；定位图片推荐直接用 `GetWidgetFromName(编辑器名)`。详见 `doc/3D-UI-组件使用指南.md` 第 10 节。 |
| 获取玩家显示名 | ✅ 2026-10-14 实跑验证 | Core 无独立 `GetPlayerName()`。玩家名是 `WoWPlayerStateBase.PlayerName`（只读字段）。取 PlayerState 三法：`Game:GetAllPlayerStates()`（LuaArray，`:Num()/:Get(i)` 0基）、`pawn:GetPlayerState()`（`pawn` 为 `WoWSTExtraBaseCharacterBase`）、`Game:GetPlayerStateByPlayerKey(key)`；取稳定标识 `PlayerState:GetPlayerKey()→number`。示例：`ps.PlayerName`、`ps:GetPlayerKey()`。**注意**：冒号取方法本身语法报错，引用方法用点号 `ps.GetPlayerKey` 再 `ps:GetPlayerKey()`。 |
| CreativeInstance["<UUID>"] 返回数字 InstanceID | ✅ 2026-10-15 实跑验证 | 场景装置全局表 `CreativeInstance` 的 value 是**数字 InstanceID**（不是对象，早版代码误当对象取 `inst[getter]` 崩溃）。该数字可直接用于 `AddVPEvent(EventID, Func, Caller, ...)` 的第 4 参做 `@listen InstanceID` 精确过滤。签名来自 `Core/WoWObject.lua`：`AddVPEvent(EventID, Func, Caller, ...)`，`...` 即 @listen 过滤参数（按 RcEventIdDefine 顺序）；回调 `Func(Caller, ...outputs)`，Caller 即传入的 self。 |
| RankAPI 排行榜（SubmitScore/GetTopN/GetPlayerRank/AddRankUpdateCallback 等） | ⚠️ 声明已确认，行为待实跑 | `Core/LuaHint/RankAPI.lua` 提供完整排行榜 Domain API（全局直接用，无需 require）。提交：SubmitScore(ps,RankType,Value) 覆盖式；读取：GetPlayerRank(ps,RankType)→1基名次(0未上榜)/GetPlayerScore/GetTopN(RankType,N)→{Name,Value}/GetRankByRankRange/GetRankByScoreRange/GetTopNByTypes；刷新：RefreshRank(RankType)→刷新后触发回调；AddRankUpdateCallback(RankType, cb)（cb(rankType,data)）；管理：ClearRank/RemovePlayer(ps,RankType)。排行榜类型枚举 `Enum_CustomRank` 在 `Core/Define/CommonDefine.lua` 全局表 `CustomRank{Rank1..Rank5}`（引用 `UGCLuaGlobalDefine.Enum_CustomRank`），该文件无 return 需先 `pcall(require,"EnvLua.Core.Define.CommonDefine")` 触发加载，未注入时回退数字 1~5。HUDAPI.OverridePlayerLeaderboardShowState(ps,0/1/2) 控制原生排行榜 UI 显隐（0取消/1显示/2隐藏），与数据提交是两回事。无专门排行榜 VP 事件，刷新结果走 AddRankUpdateCallback。 |
| AudioAPI 音频播放（PlayAudio/StopAudio/StopAudioByPlayer） | ⚠️ 声明已确认，行为待实跑 | `Core/LuaHint/AudioAPI.lua` 提供音频 Domain API（全局直接用，无需 require）。PlayAudio(TargetObject, AudioID, Duration, Volume, bAllMap, bShowMark, AudiencePlayerState)→音频实例UUID；TargetObject 可为 PlayerState/建筑实例/Marker/Actor 或 Vector 位置；AudioID 是 SoundPreset，**必须在 vscode 插件注册预设后传 AssetRef 句柄**；bAllMap=true 全图播放，AudiencePlayerState=nil 表示所有玩家。StopAudio(UUID) 停所有玩家；StopAudioByPlayer(ps,UUID) 停指定玩家。无独立音乐/BGM API，音乐与音效复用 PlayAudio（靠 AudioID 区分不同 SoundPreset）；无全局音量/静音/暂停 API。**设计注意**：无「按类别(BGM/音效)音量」也无「中途改音量」API，UI 要分别控制 BGM/音效音量时，必须在 Lua 层按类型乘音量系数后传入 Volume；BGM 调音量需 StopAudio 后按新音量重播，短音效影响后续播放即可。 |
| 2D 按钮状态图片（SetButtonNormalImage/SetButtonPressedImage） | ⚠️ 声明已确认，传参约定待实跑 | `Core/LuaHint/WoWCustomUIButton.lua` 与 `CustomUIAPI.lua` 均提供分别设置按钮「正常态/按下态」图片接口：对象方法 `btn:SetButtonNormalImage(ImageID)`/`btn:SetButtonPressedImage(ImageID)`；全局 `CustomUIAPI.SetButtonNormalImage(ps,InstanceUUID,ImageID)`/`CustomUIAPI.SetButtonPressedImage(ps,InstanceUUID,ImageID)`。按下态可单独改。ImageID 注释称需在 vscode 插件注册预设并传 AssetRef 句柄解析，但 2D 图片 ID 与 3D 挂件 AssetRef 传参约定是否一致待实跑确认（2D SetAllPlayerImageContent 经验上可能传整数 ImageID 而非 AssetRef）。 |

## ⚠️ 长按事件关键未决项（务必实跑确认）

- **长按手势是否额外触发 CustomUIClicked**：标准预期是「长按只发 LongPressed+LonPressReleased，不发 Clicked」。若引擎在长按起点也发一次 Clicked，则「下键长按软降」会先误触发一次硬降（方块锁死）。联调下键时必须先验证此项；若果然如此，需把硬降改为「延迟判定 + 长按取消」方案。
- **长按阈值**：引擎判定 LongPressed 的按住时长阈值未知（影响 DAS 手感，当前配置 DAS=0.16s 为连发首延迟，与引擎阈值无关，仅控制连发起步）。
- 连发实现用 `owner:AddTimerOnce` 递归（因 `AddTimer(...,0)` 实测不触发），并以 `_moveHoldGen` / `_softDropGen` 代际令牌防残留定时器串扰。

## 已验证不存在的 API（曾错误使用，避免重复踩坑）

| API | 说明 |
| --- | --- |
| （待实跑填充） | |

## 架构红线（务必遵守，详见 AI_WOW_Rules.md）

1. **Preset / Core 是只读受管区**，禁止手动改磁盘文本；资源只经 WOW Editor + update preset 产出。
2. **玩法代码只写 EnvLua/Server/**，子目录按模块划分（如 EnvLua/Server/ErLuoSiFangKuai/）。
3. **ServerGameMain.lua 底部三行不能删/换序**（引擎靠它识别 GameMain）。
4. 坐标单位：Domain API=米，Class API=厘米，跨层显式换算并注明。
5. 资源引用：创建资源用 AssetRef["<Key>"]，查询比较用 <PresetName>["<Key>"] 整数 ID，严禁裸数字。

## 待实跑确认事项

1. require("EnvLua.Server.ErLuoSiFangKuai.XXX") 子目录 require 是否可用（基于 require 约定应可行）。
2. CreativeInstance 全局注入时机（HUD 相关 widget 应在游戏开始后才访问）。
3. 具体玩法所需的 API 逐项在 Core/LuaHint 实跑校验。

## 待向用户确认（阻塞点）

* 单人还是多人 / 合作还是对抗
* 棋盘尺寸与方块集合
* 是否需要 AI 对手 / 填充
* 计分 / 段位 / 排行榜本期是否做
* 美术与音效资源是否已有预制
