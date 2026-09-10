<#
.SYNOPSIS
    저장된 Instagram 연결 정보로 프로필/최근 콘텐츠 인사이트를 수집합니다.

.DESCRIPTION
    - setup-instagram-insights.ps1 이 저장한 "$env:LOCALAPPDATA\InstagramCodexConnector\config.json"
      을 읽어 DPAPI로 복호화합니다 (같은 Windows 사용자 계정에서만 성공).
    - 토큰 만료 10일 이내이면 graph.instagram.com 의 refresh_access_token 으로
      자동 갱신하고 설정 파일을 다시 암호화하여 저장합니다.
    - 프로필과 최근 콘텐츠 5개(기본값)의 조회(views)/도달(reach)/저장(saved)/공유(shares)를 수집합니다.
    - 결과를 JSON, Markdown 파일로 저장합니다.
    - 토큰/시크릿 원문은 콘솔, 로그, 파일 어디에도 평문으로 출력되지 않습니다.

.PARAMETER MediaCount
    수집할 최근 콘텐츠 개수 (기본값 5)

.NOTES
    Windows 전용 (DPAPI 사용). $env:USERPROFILE / $env:LOCALAPPDATA 만 사용합니다.
#>

[CmdletBinding()]
param(
    [int]$MediaCount = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ConnectorRoot = Join-Path $env:LOCALAPPDATA 'InstagramCodexConnector'
$ConfigPath    = Join-Path $ConnectorRoot 'config.json'
$ReportsDir    = Join-Path $ConnectorRoot 'reports'
$RefreshThresholdDays = 10

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

function Protect-Secret {
    param([Parameter(Mandatory)][string]$PlainText)
    $secure = ConvertTo-SecureString -String $PlainText -AsPlainText -Force
    return ConvertFrom-SecureString -SecureString $secure
}

function Redact-Secret {
    param([Parameter(Mandatory)][string]$Text)
    $t = $Text
    $t = [regex]::Replace($t, '(access_token=)[^&\s"]+', '$1***REDACTED***')
    $t = [regex]::Replace($t, '(client_secret=)[^&\s"]+', '$1***REDACTED***')
    return $t
}

function Invoke-IgApi {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'GET'
    )
    try {
        return Invoke-RestMethod -Uri $Uri -Method $Method
    } catch {
        $status = $null
        try { $status = [int]$_.Exception.Response.StatusCode } catch { }
        $body = $null
        try {
            $stream = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $body = $reader.ReadToEnd()
        } catch { }
        $safeBody = if ($body) { Redact-Secret -Text $body } else { '(응답 본문 없음)' }
        throw "Instagram API 호출 실패 (HTTP $status): $safeBody"
    }
}

# ---------------------------------------------------------------------------
# 1. 설정 로드 및 복호화
# ---------------------------------------------------------------------------

$config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
$accessToken = Unprotect-Secret -EncryptedText $config.encryptedAccessToken
$expiresAtUtc = [DateTime]::Parse($config.expiresAtUtc, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)

try {
    # -----------------------------------------------------------------------
    # 2. 만료 10일 이내면 자동 갱신
    # -----------------------------------------------------------------------
    $daysLeft = ($expiresAtUtc - (Get-Date).ToUniversalTime()).TotalDays

    if ($daysLeft -le $RefreshThresholdDays) {
        Write-Host "토큰 만료까지 $([math]::Round($daysLeft,1))일 남아 자동 갱신을 시도합니다..." -ForegroundColor Yellow
        try {
            $refreshUri = 'https://graph.instagram.com/refresh_access_token' +
                '?grant_type=ig_refresh_token' +
                "&access_token=$([uri]::EscapeDataString($accessToken))"
            $refreshResult = Invoke-IgApi -Uri $refreshUri

            $accessToken = $refreshResult.access_token
            $expiresInSeconds = [int]$refreshResult.expires_in
            $expiresAtUtc = (Get-Date).ToUniversalTime().AddSeconds($expiresInSeconds)

            $config.encryptedAccessToken = Protect-Secret -PlainText $accessToken
            $config.expiresAtUtc = $expiresAtUtc.ToString('o')
            $config.lastRefreshedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            $config | ConvertTo-Json -Depth 5 | Set-Content -Path $ConfigPath -Encoding UTF8

            Write-Host "토큰 갱신 완료. 새 만료일(UTC): $($expiresAtUtc.ToString('yyyy-MM-dd'))" -ForegroundColor Green
        } catch {
            Write-Warning "자동 갱신 실패, 기존 토큰으로 계속 진행합니다: $($_.Exception.Message)"
        }
    }

    # -----------------------------------------------------------------------
    # 3. 프로필 조회
    # -----------------------------------------------------------------------
    Write-Host '프로필 정보를 가져오는 중...' -ForegroundColor DarkGray
    $profileUri = 'https://graph.instagram.com/me' +
        '?fields=id,username,account_type,media_count' +
        "&access_token=$([uri]::EscapeDataString($accessToken))"
    $profile = Invoke-IgApi -Uri $profileUri

    # -----------------------------------------------------------------------
    # 4. 최근 콘텐츠 목록 조회
    # -----------------------------------------------------------------------
    Write-Host "최근 콘텐츠 $MediaCount 개를 가져오는 중..." -ForegroundColor DarkGray
    $mediaUri = 'https://graph.instagram.com/me/media' +
        "?fields=id,caption,media_type,media_product_type,permalink,timestamp&limit=$MediaCount" +
        "&access_token=$([uri]::EscapeDataString($accessToken))"
    $mediaList = Invoke-IgApi -Uri $mediaUri

    # -----------------------------------------------------------------------
    # 5. 콘텐츠별 인사이트(조회/도달/저장/공유) 수집
    # -----------------------------------------------------------------------
    $metricSets = @(
        @('views', 'reach', 'saved', 'shares'),
        @('reach', 'saved'),
        @('reach')
    )

    $mediaInsights = @()
    foreach ($item in $mediaList.data) {
        Write-Host "  - $($item.id) 인사이트 확인 중..." -ForegroundColor DarkGray
        $insightValues = [ordered]@{
            views  = 'N/A'
            reach  = 'N/A'
            saved  = 'N/A'
            shares = 'N/A'
        }
        $lastError = $null

        foreach ($metrics in $metricSets) {
            try {
                $metricParam = ($metrics -join ',')
                $insightsUri = "https://graph.instagram.com/$($item.id)/insights" +
                    "?metric=$metricParam" +
                    "&access_token=$([uri]::EscapeDataString($accessToken))"
                $insightsResult = Invoke-IgApi -Uri $insightsUri

                foreach ($metricData in $insightsResult.data) {
                    $value = 'N/A'
                    if ($metricData.values -and $metricData.values.Count -gt 0) {
                        $value = $metricData.values[0].value
                    } elseif ($null -ne $metricData.total_value.value) {
                        $value = $metricData.total_value.value
                    }
                    $insightValues[$metricData.name] = $value
                }
                $lastError = $null
                break
            } catch {
                $lastError = $_.Exception.Message
                continue
            }
        }

        $insightNote = ''
        if ($lastError) {
            $insightNote = "일부 지표 조회 실패: $lastError"
        }

        $mediaInsights += [PSCustomObject]@{
            id               = $item.id
            mediaType        = $item.media_type
            mediaProductType = $item.media_product_type
            timestamp        = $item.timestamp
            permalink        = $item.permalink
            caption          = $item.caption
            views            = $insightValues.views
            reach            = $insightValues.reach
            saved            = $insightValues.saved
            shares           = $insightValues.shares
            insightNote      = $insightNote
        }
    }

    # -----------------------------------------------------------------------
    # 6. 결과 저장 (JSON / Markdown)
    # -----------------------------------------------------------------------
    $generatedAtUtc = (Get-Date).ToUniversalTime()
    $timestampTag = $generatedAtUtc.ToString('yyyyMMdd-HHmmss')

    $report = [PSCustomObject]@{
        generatedAtUtc = $generatedAtUtc.ToString('o')
        account        = [PSCustomObject]@{
            username    = $profile.username
            id          = $profile.id
            accountType = $profile.account_type
            mediaCount  = $profile.media_count
        }
        tokenExpiresAtUtc = $expiresAtUtc.ToString('o')
        media          = $mediaInsights
    }

    $jsonPath = Join-Path $ReportsDir "instagram-insights-$timestampTag.json"
    $mdPath   = Join-Path $ReportsDir "instagram-insights-$timestampTag.md"
    $latestJsonPath = Join-Path $ReportsDir 'latest.json'
    $latestMdPath   = Join-Path $ReportsDir 'latest.md'

    $report | ConvertTo-Json -Depth 6 | Set-Content -Path $jsonPath -Encoding UTF8
    $report | ConvertTo-Json -Depth 6 | Set-Content -Path $latestJsonPath -Encoding UTF8

    $md = New-Object System.Text.StringBuilder
    [void]$md.AppendLine("# Instagram Insights Report")
    [void]$md.AppendLine("")
    [void]$md.AppendLine("- 계정: **$($profile.username)** (id: $($profile.id), $($profile.account_type))")
    [void]$md.AppendLine("- 생성 시각(UTC): $($generatedAtUtc.ToString('yyyy-MM-dd HH:mm'))")
    [void]$md.AppendLine("- 토큰 만료일(UTC): $($expiresAtUtc.ToString('yyyy-MM-dd'))")
    [void]$md.AppendLine("")
    [void]$md.AppendLine("| 콘텐츠 ID | 타입 | 게시일 | 조회(views) | 도달(reach) | 저장(saved) | 공유(shares) | 링크 |")
    [void]$md.AppendLine("|---|---|---|---|---|---|---|---|")
    foreach ($m in $mediaInsights) {
        [void]$md.AppendLine("| $($m.id) | $($m.mediaType) | $($m.timestamp) | $($m.views) | $($m.reach) | $($m.saved) | $($m.shares) | $($m.permalink) |")
    }
    if ($mediaInsights | Where-Object { $_.insightNote }) {
        [void]$md.AppendLine("")
        [void]$md.AppendLine("> 일부 콘텐츠는 미디어 유형상 지원되지 않는 지표가 있어 N/A 로 표기되었습니다.")
    }

    Set-Content -Path $mdPath -Value $md.ToString() -Encoding UTF8
    Set-Content -Path $latestMdPath -Value $md.ToString() -Encoding UTF8

    # -----------------------------------------------------------------------
    # 7. 콘솔 요약 (비밀값 절대 미출력)
    # -----------------------------------------------------------------------
    Write-Host ''
    Write-Host '=== 수집 완료 ===' -ForegroundColor Green
    Write-Host "계정명          : $($profile.username)"
    Write-Host "연결 성공 여부  : 성공"
    Write-Host "토큰 만료일     : $($expiresAtUtc.ToString('yyyy-MM-dd'))"
    Write-Host "JSON 리포트     : $jsonPath"
    Write-Host "Markdown 리포트 : $mdPath"

} finally {
    $accessToken = $null
    [System.GC]::Collect()
}
