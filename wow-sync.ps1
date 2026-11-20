<#
.SYNOPSIS
  ErLuoSiFangKuai 工程 <-> WOW 活动工程目录的单向同步工具（分离结构）。

.DESCRIPTION
  本地开发目录与 WOW 活动工程目录（由 config.json 的 projectID 指定）是分离的。
  同步方向均为单向，绝不交叉：

    push    本地 EnvLua/Server  -> 活动目录 EnvLua/Server
            本地 EnvLua/Common  -> 活动目录 EnvLua/Common
            本地 EnvLua/Client  -> 活动目录 EnvLua/Client（排除 Client/Actor，见 pull）
            （玩法代码本地权威，镜像覆盖到活动目录；Common 为双端共享区，Client 为客户端权威代码区）

    pull    活动目录 EnvLua/Core + EnvLua/Preset  -> 本地
            （Core/Preset 由 WOW 每次开启自动同步到活动目录，活动目录最权威，
              拉回本地供 Agent 基于最新 API 声明与资源预设工作）

    sync    一键完成：先 pull（拉回 Core/Preset）再 push（上传 Server/Common/Client）。
            顺序先拉后推——本地先对齐最新环境，再发布玩法代码。两者目录隔离，互不干扰。
            push/sync 前会实测目标目录写权限；可写即放行（无需右键提权）。

    status  只读比对 Server / Core / Preset 的差异，不改动任何文件。

  架构红线（务必遵守）：
    - Core/Preset 是 WOW 托管只读区：本地副本永远只从活动目录 pull，绝不 push 到活动目录。
    - Server 是用户玩法代码区：本地权威，永远只 push 到活动目录，不从活动目录 pull。
    - Common 是双端共享代码区：本地权威，随 push 上传（客户端化迁移后 Board/AI/Config 在此）。
    - Client 是客户端权威代码区：本地权威，随 push 上传（客户端化迁移后玩法/UI/渲染/输入在此）。
    - 两组方向互不相通，禁止出现"本地 Core/Preset -> 活动"或"活动 Server/Common/Client -> 本地"。
#>
param(
    [ValidateSet('push','pull','sync','status')]
    [string]$Action = 'status',
    # 显式指定目标 WOW 工程 ID（形如 52267426440_1789354100）。
    # 默认值已锁定为本工程实际活动目录（见 config.json 的 projectID），防止自动选择误判。
    # 如需临时切换目标，用 -WowProjectId 指定。
    [string]$WowProjectId = '52267426440_1795140807'
)

$ErrorActionPreference = 'Stop'
$SourceDir = $PSScriptRoot
# 活动工程下载根。WOW Editor 重装后下载根已迁至 "C:\Program Files\WOW Editor Pro\Game\download"，
# 与本地开发根（c:\Custom\...）不再同处一个父目录，故此处硬编码新下载根，不再从 $SourceDir 推导。
$DownloadRoot = 'C:\Program Files\WOW Editor Pro\Game\download'

# 定位活动工程目录
if ($WowProjectId -ne '') {
    $WowDir = Join-Path $DownloadRoot $WowProjectId
    if (-not (Test-Path $WowDir)) {
        Write-Host "指定的工程目录不存在: $WowDir" -ForegroundColor Red
        exit 1
    }
} else {
    $allProjects = Get-ChildItem -Path $DownloadRoot -Directory |
        Where-Object { $_.Name -match '^\d+_\d+$' -and $_.FullName -ne $SourceDir }
    $WowDir = ($allProjects | Sort-Object { [int64]($_.Name -split '_')[1] } -Descending)[0].FullName
}

<#
.SYNOPSIS
  执行 robocopy。/MIR 镜像（补齐缺失 + 更新变化 + 删除多余）；/L 仅列出差异。
  robocopy 退出码 0-7 均属正常（0=无变化,1=已复制,2=额外,3=两者,...），>=8 才是失败。
#>
function Invoke-RoboMirror {
    param(
        [string]$From,
        [string]$To,
        [switch]$ListOnly,
        [string]$ExcludeDir,
        [string]$ExcludeFile
    )
    if (-not (Test-Path $From)) {
        Write-Host "  源不存在，跳过: $From" -ForegroundColor Yellow
        return
    }
    $excludeArg = @()
    if ($ExcludeDir) { $excludeArg += @('/XD', $ExcludeDir) }
    if ($ExcludeFile) { $excludeArg += @('/XF', $ExcludeFile) }
    if ($ListOnly) {
        robocopy $From $To /L /NJH /NJS /NP /NDL /R:0 /W:0 @excludeArg
    } else {
        robocopy $From $To /MIR /NJH /NJS /NP /NDL /NC /R:0 /W:0 @excludeArg
        if ($LASTEXITCODE -ge 8) {
            Write-Host "  robocopy 失败 (exit=$LASTEXITCODE): $From -> $To" -ForegroundColor Red
            exit $LASTEXITCODE
        }
    }
}

# 路径映射
$ServerSrc = Join-Path $SourceDir "EnvLua/Server"
$ServerDst = Join-Path $WowDir    "EnvLua/Server"
$CoreSrc   = Join-Path $SourceDir "EnvLua/Core"
$CoreDst   = Join-Path $WowDir    "EnvLua/Core"
$PresetSrc = Join-Path $SourceDir "EnvLua/Preset"
$PresetDst = Join-Path $WowDir    "EnvLua/Preset"
$CommonSrc = Join-Path $SourceDir "EnvLua/Common"
$CommonDst = Join-Path $WowDir    "EnvLua/Common"
$ClientSrc = Join-Path $SourceDir "EnvLua/Client"
$ClientDst = Join-Path $WowDir    "EnvLua/Client"
# Client/Actor 下是引擎/编辑器生成的 Actor_*.lua（活动目录权威），只 pull 不 push。
$ClientActorSrc = Join-Path $SourceDir "EnvLua/Client/Actor"
$ClientActorDst = Join-Path $WowDir    "EnvLua/Client/Actor"
# Client/Actor/ClassicGameState.lua 是「编辑器槽位绑定」的手写脚本（本地权威）。
# 活动目录里的副本可能停留在旧版，一旦被 pull 的 /MIR 回灌，就会把本地正确版本覆盖成旧版
# （曾导致 P6 自测崩溃、引擎实跑旧架构代码）。因此 pull 时排除该文件：
#   - /XF 排除的文件在 /MIR 模式下不会被 purge 删除；
#   - 该文件仍由 push 单向更新到活动目录（push 只排除 Actor_*.lua，不含它）。
$ClientActorPullExclude = 'ClassicGameState.lua'

# 单向：本地 Server + Common + Client -> 活动目录（覆盖）
# Client 推送必须排除 Actor 子目录，否则 /MIR 会删掉活动目录里引擎生成的 Actor_*.lua。
function Push-Server {
    # 构建版本号 +1：写完本地文件后随本次 push 一起上传到活动目录。
    # 运行时 Server/Client 的 GameMain:OnStart 会打印它，用于确认当前跑的是否为最新上传版本。
    $versionFile = Join-Path $CommonSrc "BuildVersion.lua"
    if (Test-Path $versionFile) {
        $verText = [System.IO.File]::ReadAllText($versionFile)
        $verMatch = [regex]::Match($verText, '(?m)^\s*return\s+(\d+)')
        if ($verMatch.Success) {
            $newVer = [int]$verMatch.Groups[1].Value + 1
            $newVerText = [regex]::Replace($verText, '(?m)^(\s*return\s+)(\d+)', '${1}' + $newVer, 1)
            [System.IO.File]::WriteAllText($versionFile, $newVerText)
            Write-Host "[push] 构建版本号: $($verMatch.Groups[1].Value) -> $newVer" -ForegroundColor Magenta
        } else {
            Write-Host "[push] 警告: BuildVersion.lua 未找到 return <数字> 行，跳过版本号自增" -ForegroundColor Yellow
        }
    } else {
        Write-Host "[push] 警告: 未找到 $versionFile，跳过版本号自增" -ForegroundColor Yellow
    }
    Write-Host "[push] Server 本地 -> 活动目录 (单向覆盖)" -ForegroundColor Cyan
    Invoke-RoboMirror -From $ServerSrc -To $ServerDst
    Write-Host "[push] Common 本地 -> 活动目录 (双端共享区)" -ForegroundColor Cyan
    Invoke-RoboMirror -From $CommonSrc -To $CommonDst
    Write-Host "[push] Client 本地 -> 活动目录 (排除引擎生成的 Actor_*.lua)" -ForegroundColor Cyan
    Invoke-RoboMirror -From $ClientSrc -To $ClientDst -ExcludeFile 'Actor_*.lua'
    Write-Host "推送完成" -ForegroundColor Green
}

# 单向：活动目录 Core + Preset + Client/Actor -> 本地（拉回 API 声明/资源预设/引擎生成脚本）
function Pull-Assets {
    Write-Host "[pull] 活动目录 -> 本地 (Core + Preset + Client/Actor)" -ForegroundColor Cyan
    Write-Host "  -> Core" -ForegroundColor Gray
    Invoke-RoboMirror -From $CoreDst   -To $CoreSrc
    Write-Host "  -> Preset" -ForegroundColor Gray
    Invoke-RoboMirror -From $PresetDst -To $PresetSrc
    Write-Host "  -> Client/Actor (引擎生成脚本，只读拉回；排除 ClassicGameState.lua)" -ForegroundColor Gray
    Invoke-RoboMirror -From $ClientActorDst -To $ClientActorSrc -ExcludeFile $ClientActorPullExclude
    Write-Host "拉取完成" -ForegroundColor Green
}

Write-Host "本地工程: $SourceDir"
Write-Host "活动目录: $WowDir"
Write-Host ""

# 写权限探测（不依赖"是否管理员令牌"）：
# 活动目录在 C:\Program Files，但当前账号若已被授予该目录的 Modify 权限（如 Administrator 账户），
# 即使 PowerShell 未右键提权也能写入。故直接在目标目录创建临时文件实测，能写即放行。
# 仅 push/sync 需要写；pull/status 不探测。
if ($Action -eq 'push' -or $Action -eq 'sync') {
    $probe = Join-Path $WowDir ('.wow_sync_probe_' + [guid]::NewGuid().ToString('N'))
    $canWrite = $false
    try {
        [System.IO.File]::WriteAllText($probe, 'ok')
        $canWrite = $true
    } catch {
        $canWrite = $false
    } finally {
        if (Test-Path $probe) { Remove-Item $probe -Force -ErrorAction SilentlyContinue }
    }
    if (-not $canWrite) {
        Write-Host "错误：当前账号对活动目录没有写权限，无法 push。" -ForegroundColor Red
        Write-Host "目标目录: $WowDir" -ForegroundColor Gray
        Write-Host "解决（任选其一）：" -ForegroundColor Yellow
        Write-Host "  1) 右键 PowerShell -> 『以管理员身份运行』后重试" -ForegroundColor Yellow
        Write-Host "  2) 给当前账号授予该目录 Modify 权限（icacls）" -ForegroundColor Yellow
        exit 1
    }
}

switch ($Action) {
    'push'  { Push-Server }
    'pull'  { Pull-Assets }
    'sync'  { Pull-Assets; Push-Server }
    'status' {
        Write-Host "[status] 差异比对 (Server / Common / Client / Core / Preset)" -ForegroundColor Yellow
        Write-Host "--- Server (本地 -> 活动) ---" -ForegroundColor Gray
        Invoke-RoboMirror -From $ServerSrc -To $ServerDst -ListOnly
        Write-Host "--- Common (本地 -> 活动) ---" -ForegroundColor Gray
        Invoke-RoboMirror -From $CommonSrc -To $CommonDst -ListOnly
        Write-Host "--- Client (本地 -> 活动，排除 Actor_*.lua) ---" -ForegroundColor Gray
        Invoke-RoboMirror -From $ClientSrc -To $ClientDst -ListOnly -ExcludeFile 'Actor_*.lua'
        Write-Host "--- Client/Actor (活动 -> 本地，引擎生成；排除 ClassicGameState.lua) ---" -ForegroundColor Gray
        Invoke-RoboMirror -From $ClientActorDst -To $ClientActorSrc -ListOnly -ExcludeFile $ClientActorPullExclude
        Write-Host "--- Core (活动 -> 本地) ---" -ForegroundColor Gray
        Invoke-RoboMirror -From $CoreDst -To $CoreSrc -ListOnly
        Write-Host "--- Preset (活动 -> 本地) ---" -ForegroundColor Gray
        Invoke-RoboMirror -From $PresetDst -To $PresetSrc -ListOnly
    }
}
