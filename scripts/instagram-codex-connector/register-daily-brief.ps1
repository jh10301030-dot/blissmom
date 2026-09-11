<#
.SYNOPSIS
    collect-instagram-insights.ps1 을 매일 오전 8시에 자동 실행하도록 등록합니다.

.DESCRIPTION
    Windows 작업 스케줄러에 매일 08:00 실행 작업을 등록해서, 팔로워 수와
    최근 콘텐츠 성과가 담긴 "인스타그램 아침 브리프"(JSON/Markdown)가
    자동으로 매일 갱신되도록 합니다.
    이 스크립트는 토큰/시크릿을 다루지 않으며, 이미 setup-instagram-insights.ps1 로
    연결이 완료되어 있어야 합니다.

.PARAMETER Time
    실행 시각 (기본값 08:00)
#>

[CmdletBinding()]
param(
    [string]$Time = '08:00'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$collectScript = Get-ChildItem -Path $PSScriptRoot -Filter 'collect*instagram*insights*.ps1' -File -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $collectScript) {
    throw "collect-instagram-insights.ps1 을 찾을 수 없습니다: $PSScriptRoot 폴더 안에 같이 있어야 합니다."
}

$configPath = Join-Path (Join-Path $env:LOCALAPPDATA 'InstagramCodexConnector') 'config.json'
if (-not (Test-Path $configPath)) {
    Write-Warning "아직 연결 설정이 안 되어 있습니다. 먼저 setup-instagram-insights.ps1(1_연결설정.bat)을 실행해 계정을 연결하세요."
}

$taskName = 'InstagramCodexConnector-DailyBrief'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$collectScript`""
$trigger = New-ScheduledTaskTrigger -Daily -At $Time
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null

Write-Host ''
Write-Host '=== 자동 브리프 등록 완료 ===' -ForegroundColor Green
Write-Host "매일 $Time 에 인스타그램 브리프를 자동으로 생성합니다."
Write-Host "작업 이름: $taskName"
Write-Host "결과 파일: $env:LOCALAPPDATA\InstagramCodexConnector\reports\latest.md"
Write-Host "           $env:LOCALAPPDATA\InstagramCodexConnector\reports\latest.json"
