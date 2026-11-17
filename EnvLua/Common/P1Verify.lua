-- P1 验证：5 个纯逻辑模块下沉 Common 后，双端 require 是否全部成功。
-- 纯探针，被两端 GameMain:OnStart 调用一次；不参与玩法。
local P1Verify = {}

local MODULES = {
    "EnvLua.Common.Tetris.TetrisConfig",
    "EnvLua.Common.Tetris.TetrisBoard",
    "EnvLua.Common.Tetris.PuyoBoard",
    "EnvLua.Common.Tetris.TetrisAI",
    "EnvLua.Common.Tetris.TetrisTextWrap",
}

function P1Verify.Run(realm)
    print("[P1][" .. tostring(realm) .. "] === 开始验证 Common/Tetris 模块 require ===")
    local allOk = true
    for _, name in ipairs(MODULES) do
        local ok, modOrErr = pcall(require, name)
        if ok then
            print("[P1][" .. tostring(realm) .. "] OK   " .. name)
        else
            allOk = false
            print("[P1][" .. tostring(realm) .. "] FAIL " .. name .. " -> " .. tostring(modOrErr))
        end
    end
    -- 额外做一次真实计算：确认 Board 可实例化并跑一步（验证不是空壳）
    local okB, boardOrErr = pcall(function()
        local Board = require("EnvLua.Common.Tetris.TetrisBoard")
        local b = Board:new()
        if b.reset then b:reset() end
        return b
    end)
    print("[P1][" .. tostring(realm) .. "] Board:new+reset = " .. tostring(okB) ..
        (okB and "" or (" -> " .. tostring(boardOrErr))))

    print("[P1][" .. tostring(realm) .. "] 结论: " .. (allOk and "全部 require 成功" or "存在失败项"))
    return allOk
end

return P1Verify
