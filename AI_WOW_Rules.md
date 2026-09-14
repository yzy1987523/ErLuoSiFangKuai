WOW Editor Pro Lua 开发权威规则（ErLuoSiFangKuai 工程通用）
一、三类权威资料来源（唯一真相来源，严禁凭记忆编造 API）
EnvLua/Core/LuaHint/*.lua：Domain API（Functional 级，如 PlayerAPI/CreativeGameAPI/CustomUIAPI，坐标单位=米 m）和 Class API（Class System 级，如 WoW*/F* 包装类，坐标单位=厘米 cm）。
EnvLua/Core/Define/RcEventIdDefine.lua：事件 ID/名称/回调参数的唯一来源，只用这一个文件。
EnvLua/Preset/*.lua + *.json：所有预设资源（Sound/Effect/Item/Monster/NPC/Vehicle/Skill/Buff/ActorPreset/ComponentPreset 等）。

二、开发流程（参考 EnvLua/Core/Skill/VibeCoding.md）
Mode A 新代码：环境加载 → 意图解析 → 生成前 API 预校验 → 路由选择（Domain 优先于 Class）→ 生成 → 生成后自校验。
Mode B 分析现有代码：与 Core/ 官方文件 diff，先输出冲突报告再问用户，绝不静默改写。
API 找不到时：必须先做"目录扫描回退"（扫描 Core/LuaHint 与 Preset 是否有未收录的新文件），仍找不到才报"不存在"并停止生成。

三、资源引用规则（极易错）
AssetRef["<Key>"] 返回资源引用句柄，用于【创建/加载资源】的 API（CreateActor/AddComponent/PlaySound 等）。
<PresetName>["<Key>"]（如 ActorPreset/SkillPreset）返回整数 ID，用于【查询/比较/日志】。
决策依据：看目标 API 在 Core/LuaHint 里的 ---@param 是否含 "passing AssetRef to resolve this resource"。
需用 AssetRef 的预设须在 VSCode 插件注册并执行 update preset，否则 AssetRef.lua 无该键会失败。严禁传裸数字 ID 给需加载资源的参数。

四、坐标单位
Domain API 用米（m）；Class API 用厘米（cm）。严禁混用；跨层需显式换算并注明单位。

五、日志 API（真实签名来自 Core/LuaHint/Log.lua）
Log.Info/Error/Warning(Content) — 写历史日志
Log.SendQuickMenuMessage(PlayerState, Content) — 发到游戏内聊天框（首个参数必须是 PlayerState，非仅 msg）
Log.SendBattlePopupMessage(PlayerState, Content) — 弹窗
CustomLogAPI.ReportLogInfo(PlayerState, EventType) — 上报自定义日志事件
print(...) — 输出到编辑器/游戏控制台。测试命令只用小写字母/数字/符号。

六、事件监听注册：优先放在 OnRoundStart 回调，而非 OnStart（除非确需仅游戏启动跑一次）。

七、运行时调试
Lua Development Assistant 插件仅做代码同步/上传，无源码级断点调试能力。沙箱 Lua 跑在引擎(UE4)内部，未暴露 Debug Adapter Protocol。调试手段以 print() / Log.* / 弹窗 / assert / pcall / xpcall 为主。

八、CustomUI API 关键陷阱（已核实）
CustomUIAPI 没有 CreateUI / RemoveUI / GetUI 这类"动态创建"接口。所有 widget 必须在编辑器 UI Editor 中预放置。
从 PRESETS 面板复制 InstanceUUID（形如 CreativeInstance["1_CreativeInstance_xxxxxxxx"]）。
用 CustomUIAPI.SetTextContent(PlayerState, InstanceUUID, Text) 更新文字（传 PlayerState 按玩家个性化，nil 广播）。
用 CustomUIAPI.SetWidgetVisible(PlayerState, InstanceUUID, bVisible) 控制可见性。切勿自己造"创建 UI"的封装。

九、WoWPlayerState 标识
只用 GetPlayerKey()（返回 number，用于子系统 API 的玩家标识）。WoWPlayerStateBase 没有 GetUID()，GetUID() 仅来自底层 proxy（如 actor 的 _sluaud:GetUID()），对 PlayerState 调用会 nil 报错。

十、WoWClass 与 WoWObject 框架
WoWClass 和 WoWObject 是全局变量，无需 require。定义类：local C = WoWClass(base, nil, classImpl)，返回的是类（不是实例）。
ctor 占位符规则：框架创建的实例（继承 WoWActor/WoWActorComponent/WoWSceneComponent/WoWPlayerState）用 ctor(_, _)；用户自己实例化用 ctor(_) 或 ctor(_, a, b)。
ctor 内不要调用 __super.ctor（框架自动链式父类构造），否则父类构造执行两次。
WoWObject 提供：AddVPEvent / RemoveVPEvent；AddCustomEvent / RemoveCustomEvent / PostCustomEvent；AddEnvControlEvent / Remove；AddTimer / AddTimerOnce / RemoveTimer；Release()（自动清理所有事件与定时器）。

十一、项目结构
EnvLua/Core/ — 引擎 API 声明层，只读不修改
EnvLua/Preset/ — 预制资源 (.lua+.json)，受管只读区
EnvLua/Server/ — 用户玩法代码入口，写这里
标准入口：EnvLua/Server/ServerGameMain.lua，底部三行不能删/换序

十二、ServerGameMain 生命周期
local CServerGameMain = WoWClass(require("EnvLua.Core.WoWGameMain"), nil, ServerGameMain)
回调顺序（以 WoWGameMain 实际声明为准）：OnStart → OnGameStart → OnRoundStart → OnRoundEnd → OnGameEnd → OnDestroy。
在 OnRoundStart 注册事件/定时器，OnRoundEnd 清理。

十三、架构红线（Preset 是受管只读区，禁止手动修改）
EnvLua/Preset/ 与 EnvLua/Core/ 相同，是 WOWHelper 插件托管的只读/受管区。手改会被 WOW 重连时还原，且磁盘改动由插件负责同步。
玩法代码 → EnvLua/Server/（可写区）；预制资源 → 只在 WOW Editor 内修改，再执行 update preset，由插件写进 Preset/*.lua（只读但由其管理）。
Server 代码改动：直接 VS Code 保存触发上传，或跑 wow-sync.ps1 推送；Preset 不要碰磁盘文本。
