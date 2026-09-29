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
