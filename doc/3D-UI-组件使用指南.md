# 3D 世界空间 UI 组件（WidgetComponent）使用指南

> 适用引擎：WOW Editor Pro（PUBGM UGC 创造模式）沙箱 Lua
> 验证时间：2026-10-14，验证场景：俄罗斯方块双盘「盘面背后 3D 分数挂件」
> 权威来源：`EnvLua/Core/LuaHint/*.lua`、`EnvLua/Core/WoWWidgetComponent.lua`（禁止凭记忆编造，找不到先扫 Core/LuaHint）

---

## 0. 一句话结论

把一个**带 WidgetComponent 的 ActorPreset** 用 `Game:CreateActor(AssetRef[...])` 动态生成到世界里，就是「3D UI 挂件」。要改它内部的文本：
**`Actor → GetComponentByClass("WidgetComponent") → GetUserWidgetObject(pawn) → GetWidgetFromName("控件名") → SetTextContent(文本)`**。

内部子控件**没有 InstanceUUID**，不能用 2D HUD 那套 `CustomUIAPI.SetTextContent(ps, uuid, text)`，必须直接对运行时拿到的控件对象调 `SetTextContent`。

---

## 1. 三层结构（务必分清，否则取不到）

```
挂件 Actor（CreateActor 生成，世界空间）
 └─ WidgetComponent（WoWWidgetComponent / WoWWidgetComponentBase）   ← 组件层
     └─ WoWUserWidget（UMG 控件树根）                               ← 控件层
         ├─ 子控件 A（WoWCustomUIText 等，按编辑器里的"控件名"寻址）
         └─ 子控件 B ...
```

Lua 侧**不能直接**从 `WidgetComponent` 上 `GetAllWidgets()`（会报错，该方法属于 `WoWUserWidget` 而非组件）。必须先从组件取到 `WoWUserWidget`，再在控件层操作。

---

## 2. 创建挂件 Actor

挂件是一个普通的 3D Actor，只是它身上挂了 `WidgetComponent`：

```lua
-- AssetRef["<Key>"] 指向一个含 WidgetComponent 的 ActorPreset（需在 VSCode 插件注册 + update preset）
local actor = Game:CreateActor(AssetRef["<Key>"], location, rotation, ...)
-- 坐标单位：CreateActor 是 Domain API → 米(m)。挂件自身定位若走 Class API（SetActorLocation 等）则是厘米(cm)。
```

> 资源引用规则：创建/加载用 `AssetRef["<Key>"]`；查询/比较用 `<PresetName>["<Key>"]` 整数 ID。严禁传裸数字。

---

## 3. 运行时按名取子控件（已验证正确链路）

```lua
-- 入参：挂件 Actor 实例
function GetTextControl(actor)
    -- (1) 取 WidgetComponent：优先 GetComponentByClass，失败回退 GetComponentByName
    local wc
    pcall(function()
        if type(actor.GetComponentByClass) == "function" then
            wc = actor:GetComponentByClass("WidgetComponent")
        end
    end)
    if not wc then
        for _, nm in ipairs({ "UI", "Widget", "WidgetComp", "WidgetComponent" }) do
            local ok, c = pcall(function() return actor:GetComponentByName(nm) end)
            if ok and c then wc = c; break end
        end
    end
    if not wc then return nil end

    -- (2) 取玩家 pawn 列表（GetUserWidgetObject 必须传 PlayerCharacter！空参返回 nil）
    local plist
    pcall(function()
        local okP, p = pcall(function() return Game:GetAllPlayerPawns() end)
        if okP and p then plist = p end
    end)
    -- 注意：Game:GetAllPlayerPawns() 返回 LuaArray，必须用 :Num() / :Get(i)，下标 0 基，不能用 # 或 pairs
    if not plist or type(plist.Num) ~= "function" or plist:Num() <= 0 then
        return nil   -- 首帧玩家可能未生成，下一帧重试
    end

    -- (3) 组件(WoWWidgetComponent) → WoWUserWidget（逐玩家尝试，拿到即止）
    local uw
    for i = 0, plist:Num() - 1 do
        local pawn = plist:Get(i)
        if pawn then
            pcall(function() uw = wc:GetUserWidgetObject(pawn) end)
            if not uw then pcall(function() uw = wc:GetWidget(pawn) end) end
            if uw then break end
        end
    end
    if not uw then return nil end

    -- (4) WoWUserWidget → 子控件（按编辑器里该控件的"控件名 / WidgetName"）
    local tw = nil
    for _, cn in ipairs({ "ui_enemyscore", "ScoreText", "Text", "Score", "Label" }) do
        pcall(function()
            local t = uw:GetWidgetFromName(cn)
            if t then tw = t end
        end)
        if tw then break end
    end
    if not tw then return nil end

    -- (5) 设文本（见第 4 节）
    return tw
end
```

---

## 4. 写文本（已验证）

```lua
local tw = GetTextControl(actor)
if not tw then return end

-- 首选：WoWCustomUIText 的 SetTextContent（控件对象级，对所有玩家生效）
if type(tw.SetTextContent) == "function" then
    pcall(function() tw:SetTextContent("1") end)
elseif type(tw.SetText) == "function" then   -- 基类 WoWCustomUIWidget:SetText 也行
    pcall(function() tw:SetText("1") end)
end
```

- `tw:SetTextContent(Text)`：`EnvLua/Core/LuaHint/WoWCustomUIText.lua`，控件对象级，无 PlayerState 参数。
- `tw:SetText(Text)`：`EnvLua/Core/LuaHint/WoWCustomUIWidget.lua`（基类通用设文本）。
- **世界空间 WidgetComponent 的内容是共享渲染的**，直接 `tw:SetTextContent` 对所有玩家生效，**无需遍历 pawn 逐个设置**。

---

## 5. 关键陷阱（踩坑记录，按严重度排序）

1. **`GetUserWidgetObject(pawn)` / `GetWidget(pawn)` 必须传 PlayerCharacter**。空参调用返回 nil（这是之前最大的坑，误以为「组件拿不到控件」）。
2. **`GetAllWidgets()` 在 `WidgetComponent`（组件）上不存在会报错**，只在 `WoWUserWidget`（控件）上有效。别在组件层调它，直接用 `GetWidgetFromName` 更稳。
3. **按名取子控件用 `GetWidgetFromName(WidgetName)`**，不是 `FindChild` / `GetChildByName` / `GetControls` 等（那些在 WoWUserWidget 上要么不存在要么返回空）。
4. **子控件没有 InstanceUUID**。`GetWoWObjectID()` / `GetInstanceUUID()` 都返回 nil——它不是独立摆放在场景里的 CreativeInstance。**因此不能用 `CustomUIAPI.SetAllPlayerTextContent(uuid, text)`**（那条只服务 2D 预放置 HUD）。必须直接对运行时对象 `SetTextContent`。
5. **LuaArray 遍历**：`Game:GetAllPlayerPawns()` 返回 LuaArray，必须用 `:Num()` / `:Get(i)`（0 基），`#arr` 和 `pairs(arr)` 都得到 0/空，会误判「没有玩家」。
6. **首帧玩家未生成**：`GetAllPlayerPawns():Num() == 0` 时函数应返回 nil 等下一帧重试；命中后**缓存控件对象**（如 `self._behindWidgetTextComp`）避免每帧重复查找与重复写。
7. **AssetRef 晚注册**：`CreateActor` 可能在 AssetRef 未注册时失败（返回 nil）。用 `_behindWidgetActor` 做幂等保护，并在 poolReady / Update 阶段重试生成；生成后再补刷缓存的分数。

---

## 6. 与 2D HUD（CustomUIAPI）的区别

| 维度 | 2D 预放置 HUD | 3D 世界挂件（本文） |
|------|---------------|---------------------|
| 控件来源 | 编辑器 UI Editor 预放置 | `CreateActor(AssetRef)` 动态生成 |
| 寻址方式 | `CreativeInstance["1_CreativeInstance_xxx"]` 全局表拿 UUID | `GetWidgetFromName("控件名")` 按名取 |
| 写文本 API | `CustomUIAPI.SetTextContent(PlayerState, UUID, Text)` | `tw:SetTextContent(Text)`（控件对象级） |
| 是否有 InstanceUUID | 有 | **无**（子控件返回 nil） |
| 玩家个性化 | 传 PlayerState 区分每人 | 世界共享，全员一致 |

> 切勿混用：3D 挂件内部子控件**没有** UUID，硬套 `CustomUIAPI.SetTextContent(ps, uuid, text)` 会因 uuid 为 nil 而失败/走不到。

---

## 7. 权威 API 文件清单（Core/LuaHint）

- `WoWWidgetComponentBase.lua`：`GetUserWidgetObject(PlayerCharacter)` / `GetWidget(PlayerCharacter)`
- `WoWUserWidget.lua`：`GetWidgetFromName(WidgetName)` / `GetAllWidgets()` / `GetRootWidget()`
- `WoWCustomUIText.lua`：`SetTextContent(Text)` / `SetTextColor` / `SetTextFontSize`
- `WoWCustomUIWidget.lua`：`SetText(Text)`（基类通用设文本）/ `SetImageOpacity(Opacity)`
- `WoWCustomUIImage.lua`：`SetImageContent(ImageID)` / `SetImageColor(Color)` / `SetImageContentByAvatarImageID(AvatarImageID)`
- `CustomUIAPI.lua`：`SetTextContent(PlayerState, InstanceUUID, Text)` / `SetImageWidgetContent(PlayerState, InstanceUUID, ImageID)` / `SetImageWidgetColor(...)` / `SetWidgetVisible` 等（2D HUD 用）
- `WoWWidgetComponent.lua`：组件基类实现

---

## 8. 配置约定（本项目 Tetris 示例）

`TetrisConfig.BehindBoardWidget`：
- `Enabled`：是否生成背后挂件。
- `OpponentScoreTextChildName`：子控件候选名列表，首个命中即用（默认 `{ "ui_enemyscore" }`）。**该名必须与编辑器里文本控件的"控件名 / WidgetName"完全一致**。
- `DistanceBehindM` / 位置偏置：挂件挂盘面背后的距离（米，Domain 坐标）。

每个棋盘（盘1/盘2）各自生成一个挂件 Actor，控件挂在各自 Actor 下，按**实例**获取天然互不干扰（盘1 显示盘2 分数、盘2 显示盘1 分数）。

---

## 9. 调试 checklist

- [ ] 挂件 Actor 是否生成成功（`CreateActor` 非 nil）？AssetRef 是否已注册？
- [ ] `GetComponentByClass("WidgetComponent")` 是否拿到 wc？否则试 `GetComponentByName`。
- [ ] `GetAllPlayerPawns():Num()` 是否 > 0？首帧可能为 0，需重试。
- [ ] `GetUserWidgetObject(pawn)` 是否传了 pawn（非空参）？
- [ ] `GetWidgetFromName("控件名")` 的控件名是否与编辑器一致？（名不对返回 nil）
- [ ] 拿到 tw 后 `tw:SetTextContent("1")` 强制写一次，看世界挂件是否显示 `1`，隔离「渲染失效」与「分数没传进来」。
- [ ] 打印 `tw:GetWoWObjectID()` 确认 UUID 为 nil（属正常）→ 走直接 `SetTextContent`，不要走 `CustomUIAPI`。

---

## 10. 图片控件（WoWCustomUIImage）

若挂件 Widget 内含图片控件（头像 / 背景图等），换图方式：

1. **定位**：`uw:GetWidgetFromName("图片控件名")`（与文本同机制，按编辑器里给控件命的名）。识别图片控件可用 `type(w.SetImageContent) == "function"`（`SetImageContent` 是 `WoWCustomUIImage` 独有方法，基类 `WoWWidget` 没有）。
2. **换图**：`w:SetImageContent(AssetRef["<ImageKey>"])`。
   - **`ImageID` 参数实际传 `AssetRef["<Key>"]` 句柄（不是整数 ID）**。依据：2D HUD 的 `resolveImg` 返回 `AssetRef[key]` 再传给 `CustomUIAPI.SetImageWidgetContent`，且 `CustomUIAPI` 注释写明「传 AssetRef 解析资源」。
   - 世界空间挂件内容共享，直接 `SetImageContent` 对所有玩家生效。
3. **取名字注意**：子控件 wrapper（`WoWCustomUIText` / `WoWCustomUIImage` / `WoWWidget`）**不转发** `WoWObjectBase:GetName()`，直接 `w:GetName()` 在 Lua 侧取不到（返回 nil/报错）。要拿编辑器名字需绕到引擎 proxy：`w:GetProxy():GetName()`。但定位图片控件**推荐直接用 `GetWidgetFromName(编辑器名)`**，不依赖枚举改名。
4. **多个图片控件区分**：在编辑器给每个图片控件命不同名，用 `GetWidgetFromName(目标名)` 精确定位；`uw:GetAllWidgets()` 仅用于发现/调试（返回数组，兼容 LuaArray 与普通 table）。

权威文件：
- `WoWCustomUIImage.lua`：`SetImageContent(ImageID)` / `SetImageColor(Color)` / `SetImageContentByAvatarImageID(AvatarImageID)`
- `CustomUIAPI.lua`：`SetImageWidgetContent(PlayerState, InstanceUUID, ImageID)` / `SetImageWidgetColor(PlayerState, InstanceUUID, Color)`（2D HUD 用）

---

## 11. 获取玩家显示名（在挂件上显示玩家/对手名字用）

Core **没有独立的 `GetPlayerName()` 函数**。玩家名是 `WoWPlayerStateBase` 上的一个**只读字段 `PlayerName`**，需先拿到 `PlayerState` 再读属性。

**取 PlayerState 的三种方式**（均为 2026-10-14 实跑验证）：

| 方式 | API | 说明 |
|------|-----|------|
| 取全部玩家 | `Game:GetAllPlayerStates()` | 返回 LuaArray（`Num()/Get(i)`，0 基） |
| 从 pawn 取 | `pawn:GetPlayerState()` | `pawn` 为 `WoWSTExtraBaseCharacterBase`（即 `Game:GetAllPlayerPawns()` 的元素） |
| 按 key 取 | `Game:GetPlayerStateByPlayerKey(PlayerKey)` | `PlayerKey` 来自 `GetPlayerKey()` |

**读出名字与稳定标识**：

```lua
local states = Game:GetAllPlayerStates()
if states and type(states.Num) == "function" then
    for i = 0, states:Num() - 1 do
        local ps = states:Get(i)
        if ps then
            local name = ps.PlayerName              -- 玩家显示名（只读字段）
            local key  = ps:GetPlayerKey()          -- 玩家稳定标识 number
            -- 拿到后可直接：tw:SetTextContent(name) 显示在 3D 挂件上
        end
    end
end
```

**注意**：Lua 里 `ps:GetPlayerKey`（冒号无括号）会被当成缺参方法调用而**语法报错**。引用方法本身用点号 `ps.GetPlayerKey`，调用仍是 `ps:GetPlayerKey()`。

权威文件：
- `WoWPlayerStateBase.lua`：`@field PlayerName string [ReadOnly]`、`GetPlayerKey()`
- `GameAPI.lua`：`GetAllPlayerStates()` / `GetPlayerStateByPlayerKey(PlayerKey)`
- `WoWSTExtraBaseCharacterBase.lua`：`GetPlayerState()`
