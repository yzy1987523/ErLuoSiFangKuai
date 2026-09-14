<#
.SYNOPSIS
    将本工程的 EnvLua/Server 推送到 WOW 活动工程目录
#>
param(
    [ValidateSet('push','pull','status')]
    [string]$Action = 'status',
    # 显式指定目标 WOW 工程 ID（形如 52267426440_1785914193）。
    # 默认值已锁定为本工程实际活动目录，防止自动选择误判。
    # 如需临时切换目标，用 -WowProjectId 指定。
    [string]$WowProjectId = '52267426440_1789354100'
)

$ErrorActionPreference = 'Stop'
$SourceDir = $PSScriptRoot
$DownloadRoot = Split-Path $SourceDir -Parent

# 自动找最新的 WOW 工程目录
$allProjects = Get-ChildItem -Path $DownloadRoot -Directory |
    Where-Object { $_.Name -match '^\d+_\d+$' -and $_.FullName -ne $SourceDir }

if ($WowProjectId -ne '') {
    $WowDir = Join-Path $DownloadRoot $WowProjectId
    if (-not (Test-Path $WowDir)) {
        Write-Host "指定的工程目录不存在: $WowDir" -ForegroundColor Red
        exit 1
    }
} else {
    $WowDir = ($allProjects | Sort-Object { [int64]($_.Name -split '_')[1] } -Descending)[0].FullName
}

$SrcSync = Join-Path $SourceDir "EnvLua/Server"
$WowSync = Join-Path $WowDir "EnvLua/Server"

Write-Host "源: $SrcSync"
Write-Host "目标: $WowSync"
Write-Host ""

if ($Action -eq 'push') {
    Write-Host "推送中..." -ForegroundColor Cyan
    robocopy $SrcSync $WowSync /MIR /NJH /NJS /NP /NDL /NC
    Write-Host "推送完成" -ForegroundColor Green
} elseif ($Action -eq 'pull') {
    Write-Host "拉取中..." -ForegroundColor Cyan
    robocopy $WowSync $SrcSync /MIR /NJH /NJS /NP /NDL /NC
    Write-Host "拉取完成" -ForegroundColor Green
} else {
    Write-Host "差异：" -ForegroundColor Yellow
    robocopy $SrcSync $WowSync /L /NJH /NJS /NP /NDL
}
