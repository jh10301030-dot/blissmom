<#
.SYNOPSIS
    바탕화면에 "인스타 브리프 보기" 바로가기를 만듭니다.

.DESCRIPTION
    더블클릭하면 최신 인스타그램 브리프(latest.md)를 메모장으로 바로 열어주는
    바탕화면 바로가기를 생성합니다. 한 번만 실행하면 됩니다.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$targetBat = Join-Path $PSScriptRoot '4_결과보기.bat'
if (-not (Test-Path $targetBat)) {
    throw "4_결과보기.bat 을 찾을 수 없습니다: $targetBat (같은 폴더에 있어야 합니다)"
}

$desktopPath = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktopPath '인스타 브리프 보기.lnk'

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $targetBat
$shortcut.WorkingDirectory = $PSScriptRoot
$shortcut.IconLocation = 'shell32.dll,44'
$shortcut.Description = '인스타그램 최신 브리프(팔로워/콘텐츠 성과) 보기'
$shortcut.Save()

Write-Host ''
Write-Host '=== 바로가기 생성 완료 ===' -ForegroundColor Green
Write-Host "바탕화면에 만들어졌습니다: $shortcutPath"
Write-Host '이제부터는 바탕화면의 "인스타 브리프 보기" 아이콘만 더블클릭하면 됩니다.'
