<#
.SYNOPSIS
    history.json 파일 안에 실제로 무엇이 들어있는지 그대로 보여주는 진단 스크립트입니다.
    (문제 원인을 찾기 위한 용도이며, 아무 것도 바꾸지 않습니다.)
#>

$ConnectorRoot = Join-Path $env:LOCALAPPDATA 'InstagramCodexConnector'
$HistoryPath = Join-Path $ConnectorRoot 'reports\history.json'

Write-Host '=== history.json 진단 ===' -ForegroundColor Cyan
Write-Host "현재 사용자(USERNAME)   : $env:USERNAME"
Write-Host "LOCALAPPDATA 경로       : $env:LOCALAPPDATA"
Write-Host "확인하는 파일 경로      : $HistoryPath"
Write-Host ''

if (-not (Test-Path $HistoryPath)) {
    Write-Host '이 경로에 history.json 파일이 없습니다.' -ForegroundColor Red
} else {
    $fileInfo = Get-Item $HistoryPath
    Write-Host "파일 크기               : $($fileInfo.Length) 바이트"
    Write-Host "마지막 수정 시각        : $($fileInfo.LastWriteTime)"
    Write-Host ''

    $raw = Get-Content -Path $HistoryPath -Raw
    try {
        $data = $raw | ConvertFrom-Json
        $arr = @($data)
        Write-Host "파싱된 전체 항목 수     : $($arr.Count)" -ForegroundColor Green
        if ($arr.Count -gt 0) {
            $dates = $arr | ForEach-Object { "$($_.date)" } | Sort-Object
            Write-Host "가장 이른 날짜          : $($dates | Select-Object -First 1)"
            Write-Host "가장 늦은 날짜          : $($dates | Select-Object -Last 1)"
            Write-Host ''
            Write-Host '전체 날짜 목록:' -ForegroundColor Yellow
            $dates | ForEach-Object { Write-Host "  $_" }
        }
    } catch {
        Write-Host "JSON 파싱 오류: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ''
        Write-Host '파일 내용 앞부분 500자:' -ForegroundColor Yellow
        Write-Host $raw.Substring(0, [Math]::Min(500, $raw.Length))
    }
}

Write-Host ''
Write-Host '=== 진단 끝 ===' -ForegroundColor Cyan
