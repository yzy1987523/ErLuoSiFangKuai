<#
.SYNOPSIS
  ErLuoSiFangKuai 工程 <-> WOW 活动工程目录的单向同步工具（分离结构）。

.DESCRIPTION
  本地开发目录与 WOW 活动工程目录（由 config.json 的 projectID 指定）是分离的。
  同步方向均为单向，绝不交叉：

    push    本地 EnvLua/Server  -> 活动目录 EnvLua/Server
            （玩法代码本地权威，镜像覆盖到活动目录）

    pull    活动目录 EnvLua/Core + EnvLua/Preset  -> 本地
            （Core/Preset 由 WOW 每次开启自动同步到活动目录，活动目录最权威，
              拉回本地供 Agent 基于最新 API 声明与资源预设工作）

    sync    一键完成：先 pull（拉回 Core/Preset）再 push（上传 Server）。
            顺序先拉后推——本地先对齐最新环境，再发布玩法代码。两者目录隔离，互不干扰。

    status  只读比对 Server / Core / Preset 的差异，不改动任何文件。

  架构红线（务必遵守）：
    - Core/Preset 是 WOW 托管只读区：本地副本永远只从活动目录 pull，绝不 push 到活动目录。
    - Server 是用户玩法代码区：本地权威，永远只 push 到活动目录，不从活动目录 pull。
    - 两组方向互不相通，禁止出现"本地 Core/Preset -> 活动"或"活动 Server -> 本地"。
#>
param(
    [ValidateSet('push','pull','sync','status')]
    [string]$Action = 'status',
    # 显式指定目标 WOW 工程 ID（形如 52267426440_1789354100）。
    # 默认值已锁定为本工程实际活动目录（见 config.json 的 projectID），防止自动选择误判。
    # 如需临时切换目标，用 -WowProjectId 指定。
    [string]$WowProjectId = '52267426440_1789721007'
)

$ErrorActionPreference = 'Stop'
$SourceDir = $PSScriptRoot
$DownloadRoot = Split-Path $SourceDir -Parent

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
        [switch]$ListOnly
    )
    if (-not (Test-Path $From)) {
        Write-Host "  源不存在，跳过: $From" -ForegroundColor Yellow
        return
    }
    if ($ListOnly) {
        robocopy $From $To /L /NJH /NJS /NP /NDL
    } else {
        robocopy $From $To /MIR /NJH /NJS /NP /NDL /NC
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

# 单向：本地 Server -> 活动目录（覆盖）
function Push-Server {
    Write-Host "[push] Server 本地 -> 活动目录 (单向覆盖)" -ForegroundColor Cyan
    Invoke-RoboMirror -From $ServerSrc -To $ServerDst
    Write-Host "推送完成" -ForegroundColor Green
}

# 单向：活动目录 Core + Preset -> 本地（拉回最新 API 声明与资源预设）
function Pull-Assets {
    Write-Host "[pull] Core + Preset 活动目录 -> 本地 (单向拉回)" -ForegroundColor Cyan
    Write-Host "  -> Core" -ForegroundColor Gray
    Invoke-RoboMirror -From $CoreDst   -To $CoreSrc
    Write-Host "  -> Preset" -ForegroundColor Gray
    Invoke-RoboMirror -From $PresetDst -To $PresetSrc
    Write-Host "拉取完成" -ForegroundColor Green
}

Write-Host "本地工程: $SourceDir"
Write-Host "活动目录: $WowDir"
Write-Host ""

switch ($Action) {
    'push'  { Push-Server }
    'pull'  { Pull-Assets }
    'sync'  { Pull-Assets; Push-Server }
    'status' {
        Write-Host "[status] 差异比对 (Server / Core / Preset)" -ForegroundColor Yellow
        Write-Host "--- Server (本地 -> 活动) ---" -ForegroundColor Gray
        Invoke-RoboMirror -From $ServerSrc -To $ServerDst -ListOnly
        Write-Host "--- Core (活动 -> 本地) ---" -ForegroundColor Gray
        Invoke-RoboMirror -From $CoreDst -To $CoreSrc -ListOnly
        Write-Host "--- Preset (活动 -> 本地) ---" -ForegroundColor Gray
        Invoke-RoboMirror -From $PresetDst -To $PresetSrc -ListOnly
    }
}
