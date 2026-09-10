#Requires -Version 5.1
<#
  collect-instagram-insights.ps1

  재사용 가능한 수집 스크립트. 실행할 때마다:
  - DPAPI로 암호화된 config.json을 복호화 (현재 Windows 사용자만 가능)
  - 토큰 만료 10일 이내이면 자동으로 장기 토큰을 갱신 (refresh_access_token)
  - graph.instagram.com 으로 실제 프로필/최근 게시물 5개의
    조회(views) · 도달(reach) · 저장(saved) · 공유(shares) 데이터를 수집
  - 결과를 JSON + Markdown 파일로 저장
  - 콘솔에는 계정명 / 연결 성공 여부 / 만료일만 출력 (토큰·시크릿 값은 절대 출력하지 않음)

  다른 PC/사용자에서도 그대로 동작하도록 $env:LOCALAPPDATA만 사용합니다.
  설정/리포트 모두 OneDrive 등 클라우드 동기화 대상이 아닌 로컬 전용 폴더에 저장됩니다.
  최초 1회는 setup-instagram-insights.ps1 을 먼저 실행해야 합니다.
#>

[CmdletBinding()]
param(
    [int]$MediaLimit = 5,
    [int]$RenewalWindowDays = 10
)

$ErrorActionPreference = "Stop"

$ConfigDir  = Join-Path $env:LOCALAPPDATA "InstagramCodexConnector"
$ConfigPath = Join-Path $ConfigDir "config.json"
$ApiBase    = "https://graph.instagram.com"

if (-not (Test-Path $ConfigPath)) {
    throw "설정 파일을 찾을 수 없습니다: $ConfigPath`nsetup-instagram-insights.ps1 을 먼저 실행해주세요."
}

function Unprotect-StringDpapi {
    param([Parameter(Mandatory)][string]$EncryptedValue)
    $secure = $EncryptedValue | ConvertTo-SecureString
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($secure)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringUni($bstr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($bstr)
    }
}

function Protect-StringDpapi {
    param([Parameter(Mandatory)][string]$PlainValue)
    $secure = ConvertTo-SecureString -String $PlainValue -AsPlainText -Force
    $encrypted = ConvertFrom-SecureString -SecureString $secure
    return $encrypted
}

function Invoke-InstagramApi {
    param([Parameter(Mandatory)][string]$Uri)
    try {
        return Invoke-RestMethod -Uri $Uri -Method Get -ErrorAction Stop
    } catch {
        # Windows PowerShell 5.1과 PowerShell 7+ 모두에서 안전하게 응답 본문을 추출
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            throw "Instagram API 오류: $($_.ErrorDetails.Message)"
        }
        throw "Instagram API 호출 실패: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# 설정 로드 + 복호화
# ---------------------------------------------------------------------------
$config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json

$accessToken = Unprotect-StringDpapi -EncryptedValue $config.encryptedAccessToken
$appSecret   = Unprotect-StringDpapi -EncryptedValue $config.encryptedAppSecret

$expiresAtUtc = $null
if ($config.tokenExpiresAtUtc) {
    $expiresAtUtc = [DateTime]::Parse($config.tokenExpiresAtUtc, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
}

# ---------------------------------------------------------------------------
# 만료 10일 전 자동 갱신
# ---------------------------------------------------------------------------
$renewed = $false
$needsRenewal = (-not $expiresAtUtc) -or ((New-TimeSpan -Start (Get-Date).ToUniversalTime() -End $expiresAtUtc).TotalDays -le $RenewalWindowDays)

if ($needsRenewal) {
    Write-Host "토큰 만료 $RenewalWindowDays 일 이내이거나 만료일을 알 수 없어 자동 갱신을 시도합니다..." -ForegroundColor Cyan
    try {
        $refreshUri = "$ApiBase/refresh_access_token?grant_type=ig_refresh_token&access_token=$([uri]::EscapeDataString($accessToken))"
        $refreshResult = Invoke-InstagramApi -Uri $refreshUri
        $accessToken = $refreshResult.access_token
        if ($refreshResult.expires_in) {
            $expiresAtUtc = (Get-Date).ToUniversalTime().AddSeconds([double]$refreshResult.expires_in)
        }
        $renewed = $true
        Write-Host "토큰 갱신 성공." -ForegroundColor Green
    } catch {
        Write-Warning "토큰 자동 갱신에 실패했습니다 (기존 토큰으로 계속 진행): $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# 연결 테스트 + 프로필 조회
# ---------------------------------------------------------------------------
$connectionOk = $false
$igProfile = $null

try {
    $meUri = "$ApiBase/me?fields=id,username,account_type,media_count&access_token=$([uri]::EscapeDataString($accessToken))"
    $igProfile = Invoke-InstagramApi -Uri $meUri
    $connectionOk = $true
} catch {
    $connectionOk = $false
    Write-Warning "계정 연결 테스트에 실패했습니다: $($_.Exception.Message)"
}

$mediaResults = @()

if ($connectionOk) {
    try {
        $mediaUri = "$ApiBase/me/media?fields=id,caption,media_type,media_product_type,permalink,timestamp&limit=$MediaLimit&access_token=$([uri]::EscapeDataString($accessToken))"
        $mediaList = Invoke-InstagramApi -Uri $mediaUri

        foreach ($item in $mediaList.data) {
            $metricsToTry = @("views", "reach", "saved", "shares")
            $metricValues = [ordered]@{}

            try {
                $metricStr = ($metricsToTry -join ",")
                $insightsUri = "$ApiBase/$($item.id)/insights?metric=$metricStr&access_token=$([uri]::EscapeDataString($accessToken))"
                $insights = Invoke-InstagramApi -Uri $insightsUri
                foreach ($m in $insights.data) {
                    $val = $null
                    if ($m.values -and $m.values.Count -gt 0) { $val = $m.values[0].value }
                    elseif ($m.total_value) { $val = $m.total_value.value }
                    $metricValues[$m.name] = $val
                }
            } catch {
                # 미디어 유형이 지원하지 않는 metric이 섞여 있으면 하나씩 재시도
                foreach ($metric in $metricsToTry) {
                    try {
                        $singleUri = "$ApiBase/$($item.id)/insights?metric=$metric&access_token=$([uri]::EscapeDataString($accessToken))"
                        $single = Invoke-InstagramApi -Uri $singleUri
                        $val = $null
                        if ($single.data[0].values -and $single.data[0].values.Count -gt 0) {
                            $val = $single.data[0].values[0].value
                        } elseif ($single.data[0].total_value) {
                            $val = $single.data[0].total_value.value
                        }
                        $metricValues[$metric] = $val
                    } catch {
                        $metricValues[$metric] = "N/A"
                    }
                }
            }

            $mediaResults += [PSCustomObject]@{
                id               = $item.id
                caption          = $item.caption
                mediaType        = $item.media_type
                mediaProductType = $item.media_product_type
                permalink        = $item.permalink
                timestamp        = $item.timestamp
                views            = $metricValues["views"]
                reach            = $metricValues["reach"]
                saved            = $metricValues["saved"]
                shares           = $metricValues["shares"]
            }
        }
    } catch {
        Write-Warning "최근 게시물 조회에 실패했습니다: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# 설정 파일 갱신 (토큰이 갱신된 경우에만 다시 암호화하여 저장)
# ---------------------------------------------------------------------------
if ($renewed) {
    $config.encryptedAccessToken = Protect-StringDpapi -PlainValue $accessToken
    $config.tokenExpiresAtUtc = if ($expiresAtUtc) { $expiresAtUtc.ToString("o") } else { $null }
    $config.lastVerifiedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    $config | ConvertTo-Json -Depth 6 | Set-Content -Path $ConfigPath -Encoding UTF8
}

$accessToken = $null
$appSecret = $null
[System.GC]::Collect()

# ---------------------------------------------------------------------------
# 결과 저장 (JSON + Markdown)
# ---------------------------------------------------------------------------
$reportsDir = $config.reportsDir
if (-not $reportsDir) { $reportsDir = Join-Path $ConfigDir "reports" }
New-Item -ItemType Directory -Force -Path $reportsDir | Out-Null

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$jsonPath = Join-Path $reportsDir "insights-$timestamp.json"
$mdPath   = Join-Path $reportsDir "insights-$timestamp.md"

$tokenExpiresAtUtcStr = $null
if ($expiresAtUtc) { $tokenExpiresAtUtcStr = $expiresAtUtc.ToString("o") }

$report = [PSCustomObject]@{
    collectedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    connectionOk   = $connectionOk
    account        = [PSCustomObject]@{
        username   = $igProfile.username
        accountType = $igProfile.account_type
        mediaCount = $igProfile.media_count
    }
    tokenExpiresAtUtc = $tokenExpiresAtUtcStr
    media          = $mediaResults
}

$report | ConvertTo-Json -Depth 6 | Set-Content -Path $jsonPath -Encoding UTF8

$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine("# Instagram Insights Report")
[void]$md.AppendLine("")
[void]$md.AppendLine("- 수집 시각(UTC): $($report.collectedAtUtc)")
[void]$md.AppendLine("- 계정명: $($igProfile.username)")
[void]$md.AppendLine("- 계정 유형: $($igProfile.account_type)")
[void]$md.AppendLine("- 연결 성공 여부: $connectionOk")
[void]$md.AppendLine("")
[void]$md.AppendLine("| 게시물 | 유형 | 게시일 | 조회 | 도달 | 저장 | 공유 |")
[void]$md.AppendLine("|---|---|---|---|---|---|---|")
foreach ($m in $mediaResults) {
    $captionShort = "(캡션 없음)"
    if ($m.caption) {
        $cleaned = ($m.caption -replace "\r?\n", " ") -replace "\|", "\|"
        $captionShort = $cleaned.Substring(0, [Math]::Min(30, $cleaned.Length))
    }
    $link = $captionShort
    if ($m.permalink) { $link = "[$captionShort]($($m.permalink))" }
    [void]$md.AppendLine("| $link | $($m.mediaType) | $($m.timestamp) | $($m.views) | $($m.reach) | $($m.saved) | $($m.shares) |")
}

Set-Content -Path $mdPath -Value $md.ToString() -Encoding UTF8

# ---------------------------------------------------------------------------
# 결과 보고: 계정명 / 연결 성공 여부 / 만료일만 출력
# ---------------------------------------------------------------------------
$expiresDisplay = if ($expiresAtUtc) { $expiresAtUtc.ToLocalTime().ToString("yyyy-MM-dd HH:mm") } else { "알 수 없음" }

Write-Host ""
Write-Host "$($igProfile.username) 인스타 성과 연결" -ForegroundColor Green
Write-Host "  연결 상태 : $(if ($connectionOk) { '성공' } else { '실패' })"
Write-Host "  토큰 만료일: $expiresDisplay"
Write-Host "  JSON 리포트 : $jsonPath"
Write-Host "  Markdown 리포트: $mdPath"
