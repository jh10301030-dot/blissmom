<#
.SYNOPSIS
    계정에 게시된 모든 피드 콘텐츠의 성과(조회/도달/저장/공유)를 한 번에 분석합니다.

.DESCRIPTION
    collect-instagram-insights.ps1 은 매일 "최근 5개"만 확인하지만, 이 스크립트는
    계정이 지금까지 올린 모든 게시물을 훑어서 media-archive.json 에 채워 넣습니다.
    이렇게 하면 대시보드 "월간 리포트" 탭에 계정 개설 이후 전체 기간의 발행 수/
    평균 조회·도달/저장률/TOP3 가 표시됩니다.

    (단, 팔로워 "수" 히스토리는 Instagram API가 소급 제공하지 않으므로
    오늘 이후부터만 계속 쌓입니다. 이건 게시물별 성과 데이터만 채웁니다.)

    게시물 수가 많으면 오래 걸릴 수 있고, API 호출 한도에 걸릴 수도 있습니다.
    중간에 창을 닫거나 한도에 걸려 멈춰도 안전합니다 - 이미 분석된 게시물은
    저장되어 있어서, 다시 실행하면 못 끝낸 부분부터 이어서 진행합니다.

.PARAMETER ForceRefresh
    이미 분석된 게시물도 최신 수치로 다시 조회하고 싶을 때 사용합니다.
#>

[CmdletBinding()]
param(
    [switch]$ForceRefresh
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SCRIPT_VERSION = '2026-09-11-v1'
Write-Host "[스크립트 버전: $SCRIPT_VERSION]" -ForegroundColor Magenta

$ConnectorRoot = Join-Path $env:LOCALAPPDATA 'InstagramCodexConnector'
$ConfigPath    = Join-Path $ConnectorRoot 'config.json'
$ReportsDir    = Join-Path $ConnectorRoot 'reports'
$ArchivePath   = Join-Path $ReportsDir 'media-archive.json'

New-Item -ItemType Directory -Path $ReportsDir -Force | Out-Null

if (-not (Test-Path $ConfigPath)) {
    throw "설정 파일이 없습니다: $ConfigPath  먼저 setup-instagram-insights.ps1(1_연결설정.bat)을 실행하세요."
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
    $t = $Text
    $t = [regex]::Replace($t, '(access_token=)[^&\s"]+', '$1***REDACTED***')
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

$config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
$accessToken = Unprotect-Secret -EncryptedText $config.encryptedAccessToken

try {
    $archive = @()
    if (Test-Path $ArchivePath) {
        try { $archive = @(Get-Content -Path $ArchivePath -Raw | ConvertFrom-Json) } catch { $archive = @() }
    }
    $archiveById = [ordered]@{}
    foreach ($m in $archive) {
        $mNorm = $m | Select-Object id, mediaType, mediaProductType, timestamp, permalink, caption, thumbnailUrl, views, reach, saved, shares, insightNote
        if ($mNorm.id) { $archiveById[$mNorm.id] = $mNorm }
    }

    $metricSets = @(
        @('views', 'reach', 'saved', 'shares'),
        @('reach', 'saved'),
        @('reach')
    )

    Write-Host '=== 전체 피드 분석 시작 ===' -ForegroundColor Cyan
    Write-Host '게시물 목록을 가져오는 중... (게시물이 많으면 시간이 걸립니다)' -ForegroundColor DarkGray

    $allMediaBasic = @()
    $pageLimit = 25
    $afterCursor = $null
    $pageNum = 0
    $listFields = 'id,caption,media_type,media_product_type,permalink,timestamp,media_url,thumbnail_url'

    while ($true) {
        $pageNum++
        Write-Host "  목록 $pageNum 페이지 조회 중... (누적 $($allMediaBasic.Count)개, 페이지 크기 $pageLimit)" -ForegroundColor DarkGray

        $pageUri = 'https://graph.instagram.com/me/media' +
            "?fields=$listFields&limit=$pageLimit" +
            "&access_token=$([uri]::EscapeDataString($accessToken))"
        if ($afterCursor) { $pageUri += "&after=$afterCursor" }

        try {
            $page = Invoke-IgApi -Uri $pageUri
        } catch {
            # "데이터를 줄여서 다시 요청하라"는 오류면 페이지 크기를 절반으로 줄여 같은 지점부터 재시도
            if ($_.Exception.Message -match '(?i)reduce the amount|"code"\s*:\s*1\b' -and $pageLimit -gt 5) {
                $pageLimit = [math]::Max(5, [int]($pageLimit / 2))
                Write-Warning "한 번에 가져오는 양이 너무 많아 페이지 크기를 $pageLimit 로 줄여 재시도합니다..."
                Start-Sleep -Seconds 2
                $pageNum--
                continue
            }
            throw
        }

        if ($page.data) { $allMediaBasic += $page.data }

        # 마지막 페이지에서는 paging/next/cursors/after 속성 자체가 없을 수 있어
        # (Set-StrictMode 상태에서 없는 속성 접근 시 오류가 나므로) Select-Object 로 정규화 후 확인
        $hasNextPage = $false
        if ($page.data -and $page.data.Count -gt 0 -and $page.paging) {
            $pagingNorm = $page.paging | Select-Object next, cursors
            if ($pagingNorm.next -and $pagingNorm.cursors) {
                $cursorsNorm = $pagingNorm.cursors | Select-Object after
                if ($cursorsNorm.after) {
                    $afterCursor = $cursorsNorm.after
                    $hasNextPage = $true
                }
            }
        }
        if (-not $hasNextPage) { break }
        Start-Sleep -Milliseconds 300
    }

    Write-Host "총 $($allMediaBasic.Count)개 게시물 발견. 성과 분석을 시작합니다..." -ForegroundColor Green

    $newlyProcessed = 0
    $skipped = 0
    $failed = 0
    $rateLimited = $false

    for ($i = 0; $i -lt $allMediaBasic.Count; $i++) {
        # 게시물마다 caption/media_url/thumbnail_url 등 일부 필드가 없을 수 있어 정규화
        $item = $allMediaBasic[$i] | Select-Object id, caption, media_type, media_product_type, permalink, timestamp, media_url, thumbnail_url
        $existing = $archiveById[$item.id]
        $hasValidInsight = $existing -and $existing.reach -ne 'N/A' -and $null -ne $existing.reach
        if ($hasValidInsight -and -not $ForceRefresh) {
            $skipped++
            continue
        }

        $newlyProcessed++
        Write-Host "[$($i + 1)/$($allMediaBasic.Count)] $($item.id) ($($item.timestamp)) 분석 중..." -ForegroundColor DarkGray

        $insightValues = [ordered]@{ views = 'N/A'; reach = 'N/A'; saved = 'N/A'; shares = 'N/A' }
        $lastError = $null

        foreach ($metrics in $metricSets) {
            try {
                $metricParam = ($metrics -join ',')
                $insightsUri = "https://graph.instagram.com/$($item.id)/insights" +
                    "?metric=$metricParam" +
                    "&access_token=$([uri]::EscapeDataString($accessToken))"
                $insightsResult = Invoke-IgApi -Uri $insightsUri

                foreach ($rawMetricData in $insightsResult.data) {
                    $metricData = $rawMetricData | Select-Object name, values, total_value
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

        if ($lastError) {
            $failed++
            if ($lastError -match '(?i)limit|rate|too many') {
                Write-Warning "API 호출 한도에 도달한 것 같습니다. 지금까지 진행한 내용을 저장하고 멈춥니다."
                Write-Warning "잠시 후(예: 1시간 뒤) 이 스크립트를 다시 실행하면 이어서 진행됩니다."
                $rateLimited = $true
                break
            }
        }

        $thumbnailUrl = $item.media_url
        if ($item.media_type -eq 'VIDEO' -and $item.thumbnail_url) { $thumbnailUrl = $item.thumbnail_url }

        $insightNote = ''
        if ($lastError) { $insightNote = "일부 지표 조회 실패: $lastError" }

        $archiveById[$item.id] = [PSCustomObject]@{
            id               = $item.id
            mediaType        = $item.media_type
            mediaProductType = $item.media_product_type
            timestamp        = $item.timestamp
            permalink        = $item.permalink
            caption          = $item.caption
            thumbnailUrl     = $thumbnailUrl
            views            = $insightValues.views
            reach            = $insightValues.reach
            saved            = $insightValues.saved
            shares           = $insightValues.shares
            insightNote      = $insightNote
        }

        if (($newlyProcessed % 20) -eq 0) {
            $archiveSnapshot = @($archiveById.Values)
            Set-Content -Path $ArchivePath -Value (ConvertTo-JsonArraySafe -InputObject $archiveSnapshot -Depth 5) -Encoding UTF8
        }

        Start-Sleep -Milliseconds 300
    }

    $archive = @($archiveById.Values)
    Set-Content -Path $ArchivePath -Value (ConvertTo-JsonArraySafe -InputObject $archive -Depth 5) -Encoding UTF8

    Write-Host ''
    Write-Host '=== 전체 피드 분석 결과 ===' -ForegroundColor Green
    Write-Host "전체 게시물     : $($allMediaBasic.Count)"
    Write-Host "새로 분석함     : $newlyProcessed"
    Write-Host "이미 분석되어 건너뜀 : $skipped"
    Write-Host "일부 지표 실패  : $failed"
    if ($rateLimited) {
        Write-Host ''
        Write-Host '아직 다 못 끝냈습니다. 나중에 이 스크립트를 다시 실행해서 이어서 진행하세요.' -ForegroundColor Yellow
    } else {
        Write-Host ''
        Write-Host '완료되었습니다! 대시보드를 새로 만드는 중...' -ForegroundColor Green
        $collectScript = Join-Path $PSScriptRoot 'collect-instagram-insights.ps1'
        if (Test-Path $collectScript) {
            try {
                & $collectScript
            } catch {
                Write-Warning "대시보드 갱신 중 오류(직접 2_인사이트수집.bat 을 실행해 주세요): $($_.Exception.Message)"
            }
        } else {
            Write-Warning 'collect-instagram-insights.ps1 을 찾을 수 없어 대시보드를 자동으로 갱신하지 못했습니다. 2_인사이트수집.bat 을 직접 실행해 주세요.'
        }
    }
} finally {
    $accessToken = $null
    [System.GC]::Collect()
}
