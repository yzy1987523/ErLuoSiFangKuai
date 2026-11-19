-- 构建版本号：由 wow-sync.ps1 在每次 push/sync 时自动 +1，并随 Common 区上传到活动目录。
-- 运行时由 Server/Client 的 GameMain:OnStart 打印，用来确认当前运行的是否为最新上传版本。
-- 请勿手动修改（同步脚本按独立的 return <整数> 行解析）。
return 83
