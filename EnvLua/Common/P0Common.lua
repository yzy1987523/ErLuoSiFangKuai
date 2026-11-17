-- P0 验证①：验证 EnvLua.Common.* 在 Server / Client 双端均 require 成功。
-- 纯数据模块，不依赖引擎 API，双端加载期安全。
local P0Common = {}

P0Common.TAG = "[P0]"
P0Common.LOADED = true
P0Common.PING_FUNC = "P0_OnServerPing"  -- GameState 上 S→C 广播的同名方法

function P0Common.Log(...)
    print(P0Common.TAG, ...)
end

return P0Common
