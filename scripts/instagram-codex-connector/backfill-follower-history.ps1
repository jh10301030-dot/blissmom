<#
.SYNOPSIS
    Instagram 계정 인사이트의 일별 팔로워 순증감(follower_count) 지표로
    과거 날짜별 팔로워 수를 복원해서 history.json 에 채웁니다.

.DESCRIPTION
    Instagram Graph API는 계정 레벨 인사이트에서 "하루 동안 팔로워가 몇 명
    늘거나 줄었는지"(follower_count, period=day)를 일정 기간 보관합니다.
    오늘 알고 있는 팔로워 수에서 거꾸로 하루씩 빼 나가면, 과거 날짜별
    "그날 끝난 시점의 팔로워 수"를 계산할 수 있습니다.

    Meta가 이 지표를 실제로 며칠/몇 달치나 보관하는지는 계정마다 다를 수
    있어 미리 장담할 수 없습니다. 이 스크립트는 가능한 만큼 가져와서
    채우고, 어디까지 복원됐는지 결과로 알려줍니다.

    이미 실제로 수집된(라이브) 날짜는 더 정확하므로 덮어쓰지 않고,
    수집을 시작하기 전의 "빈 날짜"만 채웁니다.

.PARAMETER DaysBack
    오늘로부터 며칠 전까지 시도해볼지 (기본값 180일)
#>

[CmdletBinding()]
param(
    [int]$DaysBack = 180
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SCRIPT_VERSION = '2026-09-11-v3-diag'
Write-Host "[스크립트 버전: $SCRIPT_VERSION]" -ForegroundColor Magenta

$ConnectorRoot = Join-Path $env:LOCALAPPDATA 'InstagramCodexConnector'
$ConfigPath    = Join-Path $ConnectorRoot 'config.json'
$ReportsDir    = Join-Path $ConnectorRoot 'reports'
$HistoryPath   = Join-Path $ReportsDir 'history.json'

New-Item -ItemType Directory -Path $ReportsDir -Force | Out-Null

if (-not (Test-Path $ConfigPath)) {
    throw "설정 파일이 없습니다: $ConfigPath  먼저 setup-instagram-insights.ps1 을 실행하세요."
}

function Unprotect-Secret {
    param([Parameter(Mandatory)][string]$EncryptedText)
    $secure = ConvertTo-SecureString -String $EncryptedText
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Redact-Secret {
    param([Parameter(Mandatory)][string]$Text)
    return [regex]::Replace($Text, '(access_token=)[^&\s"]+', '$1***REDACTED***')
}

function Invoke-IgApi {
    param([Parameter(Mandatory)][string]$Uri)
    try {
        return Invoke-RestMethod -Uri $Uri -Method Get
    } catch {
        $status = $null
        try { $status = [int]$_.Exception.Response.StatusCode } catch { }
        $body = $null
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $body = $_.ErrorDetails.Message }
        if (-not $body) {
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                if ($stream.CanSeek) { $stream.Position = 0 }
                $reader = New-Object System.IO.StreamReader($stream)
                $body = $reader.ReadToEnd()
            } catch { }
        }
        $safeBody = '(응답 본문 없음)'
        if ($body) { $safeBody = Redact-Secret -Text $body }
        throw "Instagram API 호출 실패 (HTTP $status): $safeBody"
    }
}

function ConvertTo-JsonArraySafe {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$InputObject,
        [int]$Depth = 5
    )
    if ($InputObject.Count -eq 0) { return '[]' }
    $json = ConvertTo-Json -InputObject $InputObject -Depth $Depth -Compress
    if ($InputObject.Count -eq 1 -and -not $json.TrimStart().StartsWith('[')) {
        $json = "[$json]"
    }
    return $json
}

function To-UnixTime($dt) {
    return [long]([DateTimeOffset]$dt).ToUnixTimeSeconds()
}

$config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
$accessToken = Unprotect-Secret -EncryptedText $config.encryptedAccessToken
$igUserId = $config.igUserId

try {
    Write-Host '=== 팔로워 히스토리 복원 시도 ===' -ForegroundColor Cyan

    # 오늘 팔로워 수 확보 (역산의 기준점)
    $profileUri = 'https://graph.instagram.com/me?fields=id,followers_count' +
        "&access_token=$([uri]::EscapeDataString($accessToken))"
    $rawProfile = Invoke-IgApi -Uri $profileUri
    $profile = $rawProfile | Select-Object id, followers_count
    if ($null -eq $profile.followers_count) {
        throw '오늘자 팔로워 수를 가져올 수 없어 역산 기준점을 만들 수 없습니다.'
    }
    $anchorFollowers = [int]$profile.followers_count
    $anchorDate = (Get-Date).Date

    Write-Host "기준점: $($anchorDate.ToString('yyyy-MM-dd')) = ${anchorFollowers}명" -ForegroundColor DarkGray

    # 기존 history.json 로드
    $history = @()
    if (Test-Path $HistoryPath) {
        try { $history = @(Get-Content -Path $HistoryPath -Raw | ConvertFrom-Json) } catch { $history = @() }
    }
    $historyByDate = @{}
    foreach ($h in $history) {
        $hNorm = $h | Select-Object date, followersCount, followersDelta, totalReach, totalSaved, totalShares, mediaCount
        # 예전 버그로 생긴 손상된 기록(date 가 문자열이 아니거나 형식이 안 맞음)은 걸러낸다
        if ($hNorm.date -is [string] -and $hNorm.date -match '^\d{4}-\d{2}-\d{2}$') {
            $historyByDate[$hNorm.date] = $hNorm
        }
    }

    # 계정 레벨 일별 팔로워 순증감(follower_count) 조회 - 25일씩 구간을 나눠서 요청
    $endDate = $anchorDate
    $startDate = $anchorDate.AddDays(-$DaysBack)
    $allDeltas = @()   # @{ date = 'yyyy-MM-dd'; delta = <int> }
    $earliestGot = $null
    $anyChunkFailed = $false

    $chunkEnd = $endDate
    while ($chunkEnd -gt $startDate) {
        $chunkStart = $chunkEnd.AddDays(-25)
        if ($chunkStart -lt $startDate) { $chunkStart = $startDate }

        Write-Host "  $($chunkStart.ToString('yyyy-MM-dd')) ~ $($chunkEnd.ToString('yyyy-MM-dd')) 구간 조회 중..." -ForegroundColor DarkGray

        $sinceTs = To-UnixTime $chunkStart
        $untilTs = To-UnixTime $chunkEnd
        $insightsUri = "https://graph.instagram.com/$igUserId/insights" +
            '?metric=follower_count&period=day&metric_type=time_series' +
            "&since=$sinceTs&until=$untilTs" +
            "&access_token=$([uri]::EscapeDataString($accessToken))"

        try {
            $result = Invoke-IgApi -Uri $insightsUri
            $metricEntry = $result.data | Select-Object -First 1
            if ($metricEntry -and $metricEntry.values) {
                foreach ($v in $metricEntry.values) {
                    $vNorm = $v | Select-Object value, end_time
                    if ($vNorm.end_time) {
                        $d = ([DateTime]$vNorm.end_time).ToString('yyyy-MM-dd')
                        $allDeltas += [PSCustomObject]@{ date = $d; delta = [int]$vNorm.value }
                        if (-not $earliestGot -or $d -lt $earliestGot) { $earliestGot = $d }
                    }
                }
            }
        } catch {
            Write-Warning "이 구간은 데이터를 가져오지 못했습니다: $($_.Exception.Message)"
            $anyChunkFailed = $true
        }

        $chunkEnd = $chunkStart
        Start-Sleep -Milliseconds 400
    }

    if ($allDeltas.Count -eq 0) {
        Write-Host ''
        Write-Warning 'follower_count 인사이트 데이터를 하나도 가져오지 못했습니다.'
        Write-Warning '계정에 이 지표가 아직 없거나(계정을 최근에 비즈니스로 전환), Meta가 이 기간 데이터를 보관하고 있지 않을 수 있습니다.'
        return
    }

    # 날짜 내림차순으로 정렬 후, 오늘 팔로워 수에서 거꾸로 절대값 복원
    $allDeltas = $allDeltas | Sort-Object date -Descending -Unique
    $runningCount = $anchorFollowers
    $filled = 0
    $skippedExisting = 0

    foreach ($d in $allDeltas) {
        # d.delta 는 "그 날 끝난 시점 - 그 전날 끝난 시점" 변화량이므로
        # 그 전날 시점 팔로워 수 = 그 날 시점 팔로워 수 - 그 날의 변화량
        $endOfDayCount = $runningCount
        $runningCount = $runningCount - [int]$d.delta

        if ($historyByDate.ContainsKey($d.date)) {
            $skippedExisting++
            continue
        }

        $historyByDate[$d.date] = [PSCustomObject]@{
            date           = $d.date
            followersCount = $endOfDayCount
            followersDelta = [int]$d.delta
            totalReach     = $null
            totalSaved     = $null
            totalShares    = $null
            mediaCount     = $null
        }
        $filled++
    }

    $history = @($historyByDate.Values | Sort-Object { [DateTime]$_.date })
    Set-Content -Path $HistoryPath -Value (ConvertTo-JsonArraySafe -InputObject $history -Depth 5) -Encoding UTF8

    Write-Host ''
    Write-Host '=== 복원 결과 ===' -ForegroundColor Green
    Write-Host "새로 채운 날짜 수     : $filled"
    Write-Host "이미 있어서 건너뜀    : $skippedExisting"
    if ($earliestGot) {
        Write-Host "가장 오래된 복원 날짜 : $earliestGot"
    }
    if ($anyChunkFailed) {
        Write-Host ''
        Write-Host '일부 구간은 못 가져왔습니다. 그래도 가능한 만큼은 채워졌습니다.' -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host '(진단 목적으로 대시보드 자동 갱신은 이번에 건너뜁니다. 2_인사이트수집.bat 을 직접 실행해 주세요.)' -ForegroundColor Yellow

} finally {
    $accessToken = $null
    [System.GC]::Collect()
}
