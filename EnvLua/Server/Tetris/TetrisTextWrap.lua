-- 文本宽度适配公共工具（帮助界面 3 页 / 技能选择界面 2 个槽位描述 共用）。
-- UMG 文本框宽度有限，长文案会溢出。CustomUIAPI.SetTextContent 只吃纯字符串、无自动换行接口，
-- 故写入前自行按「UTF-8 字符数」插入 \n。计数不能用 #s（字节数）：中文 3 字节/字、阿语 2 字节/字。
-- 每行上限 X = 当前语言下「候选文本中最长一条」的字符数 × Ratio(默认 0.5，即减半)，
-- 或由 cfg.XByLang[lang] 直接指定。配置见 TetrisConfig.HelpWrap / TetrisConfig.SkillSelectWrap。
-- 本模块只做纯字符串处理，不依赖引擎 API，便于两处 UI 复用同一套规则。

local TetrisTextWrap = {}

-- UTF-8 字符串 → 字符数组（逐字符；不依赖 utf8 库，兼容 Lua 5.1）
function TetrisTextWrap.Utf8Chars(s)
    local t, i, n = {}, 1, #s
    while i <= n do
        local b = s:byte(i)
        local w = 1
        if b >= 0xF0 and b <= 0xF7 then w = 4
        elseif b >= 0xE0 and b <= 0xEF then w = 3
        elseif b >= 0xC0 and b <= 0xDF then w = 2 end
        if i + w - 1 > n then w = 1 end
        t[#t + 1] = s:sub(i, i + w - 1)
        i = i + w
    end
    return t
end

-- 候选文本数组 → 最长一条的字符数（元素须为该语言下的纯字符串）
function TetrisTextWrap.MaxChars(texts)
    local maxLen = 0
    for _, t in ipairs(texts or {}) do
        if type(t) == "string" then
            local c = #TetrisTextWrap.Utf8Chars(t)
            if c > maxLen then maxLen = c end
        end
    end
    return maxLen
end

-- 计算当前语言的每行上限 X：XByLang 指定则直接用；否则 maxLen × Ratio 向上取整，下限 MinChars。
-- 返回 nil 表示不启用折行（cfg 未启用 / 无候选文本）。
function TetrisTextWrap.Limit(maxLen, lang, cfg)
    if not cfg or not cfg.Enabled then return nil end
    local fixed = cfg.XByLang and cfg.XByLang[lang]
    if fixed and fixed >= 1 then return fixed end
    if not maxLen or maxLen <= 0 then return nil end
    -- 向上取整：保证「最长一条」减半后正好折成 2 行（floor 时 2X < maxLen 会切成 3 行）
    local x = math.ceil(maxLen * (cfg.Ratio or 0.5))
    local minC = cfg.MinChars or 1
    if x < minC then x = minC end
    return x
end

-- 当前语言对应的字号：FontSizeByLang[lang] 优先，未配置则回退 FontSize；都没配返回 nil（不改动控件）
function TetrisTextWrap.FontSizeFor(lang, cfg)
    if not cfg then return nil end
    return (cfg.FontSizeByLang and cfg.FontSizeByLang[lang]) or cfg.FontSize
end

-- 折行核心：文本字符数超过 limit 时按每行 ≤ limit 字符插入 \n（不做尾部补齐）。
-- 优先在行尾附近的空白/连字符处断开（不拆开英文、阿语单词）；无空白（中文）则按字符硬切。
function TetrisTextWrap.WrapLines(s, limit)
    if not limit or limit < 1 then return s end
    -- 已有换行先分段，各段独立折行（避免把 \n 当普通字符计入行宽）
    if s:find("\n", 1, true) then
        local parts, out = {}, {}
        for seg in (s .. "\n"):gmatch("([^\n]*)\n") do parts[#parts + 1] = seg end
        for _, seg in ipairs(parts) do out[#out + 1] = TetrisTextWrap.WrapLines(seg, limit) end
        return table.concat(out, "\n")
    end
    local cs = TetrisTextWrap.Utf8Chars(s)
    if #cs <= limit then return s end
    local lines, start = {}, 1
    while start <= #cs do
        local stop = math.min(start + limit - 1, #cs)
        if stop >= #cs then
            lines[#lines + 1] = table.concat(cs, "", start, #cs)
            break
        end
        local cut = nil
        local minCut = start + math.floor(limit * 0.6)
        for j = stop, minCut, -1 do
            if cs[j] == " " or cs[j] == "\t" or cs[j] == "-" then cut = j break end
        end
        if cut then
            lines[#lines + 1] = table.concat(cs, "", start, cut - 1)
            start = cut + 1
            while cs[start] == " " or cs[start] == "\t" do start = start + 1 end
        else
            lines[#lines + 1] = table.concat(cs, "", start, stop)
            start = stop + 1
        end
    end
    -- 每行去掉首尾空白：既清掉断点残留空格，也避免阿语(RTL)双向排版把空格挪到行首
    local cleaned = {}
    for _, line in ipairs(lines) do
        local s2 = (line:gsub("^%s+", ""):gsub("%s+$", ""))
        if s2 ~= "" then cleaned[#cleaned + 1] = s2 end
    end
    return table.concat(cleaned, "\n")
end

-- 折行 + 尾部补齐：多行时，把较短的行在末尾用空格补到「最长行」等长。
-- 目的：文本控件为居中/右对齐时，等长的各行左边界才一致，消除第二行看起来"前面一堆空格"的缩进感。
-- 引擎没有文本对齐接口（CustomUIAPI 无 Justification/Alignment），只能用等长行做视觉补偿。
-- 必须在最外层统一补齐：分段递归里各段长度不同，逐段补会导致段与段之间仍不对齐。
function TetrisTextWrap.WrapText(s, limit, cfg)
    local wrapped = TetrisTextWrap.WrapLines(s, limit)
    if not (cfg and cfg.PadToAlign) then return wrapped end
    if not wrapped:find("\n", 1, true) then return wrapped end   -- 单行无需补齐
    local rows, maxLen = {}, 0
    for row in (wrapped .. "\n"):gmatch("([^\n]*)\n") do
        rows[#rows + 1] = row
        local c = #TetrisTextWrap.Utf8Chars(row)
        if c > maxLen then maxLen = c end
    end
    for i, row in ipairs(rows) do
        local pad = maxLen - #TetrisTextWrap.Utf8Chars(row)
        if pad > 0 then rows[i] = row .. string.rep(" ", pad) end
    end
    return table.concat(rows, "\n")
end

-- DebugWrap 日志用：空格 → ·，换行 → ⏎（便于肉眼分辨行首/行尾空白）
function TetrisTextWrap.Visualize(s)
    return (s:gsub(" ", "·"):gsub("\n", "⏎\n"))
end

return TetrisTextWrap
