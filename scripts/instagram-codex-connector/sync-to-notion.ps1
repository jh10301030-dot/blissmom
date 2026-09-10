<#
.SYNOPSIS
    최신 인스타그램 리포트(reports\latest.json)를 노션 "성과" 페이지에 동기화합니다.

.DESCRIPTION
    setup-notion-sync.ps1 로 저장된 노션 통합 토큰을 사용해 상단 요약 콜아웃과
    일별 로그 표를 갱신합니다. 노션 연동이 설정되어 있지 않으면 조용히 종료합니다
    (오류를 내지 않음 - collect-instagram-insights.ps1 에서 항상 호출되기 때문).
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ConnectorRoot = Join-Path $env:LOCALAPPDATA 'InstagramCodexConnector'
$NotionConfigPath = Join-Path $ConnectorRoot 'notion-config.json'
$LatestJsonPath = Join-Path $ConnectorRoot 'reports\latest.json'

if (-not (Test-Path $NotionConfigPath)) {
    # 노션 연동이 아직 설정되지 않음 - 조용히 종료 (setup-notion-sync.ps1 로 먼저 설정)
    return
}
if (-not (Test-Path $LatestJsonPath)) {
    Write-Warning "동기화할 리포트가 없습니다: $LatestJsonPath"
    return
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

try {
    $notionConfig = Get-Content -Path $NotionConfigPath -Raw | ConvertFrom-Json
    $notionToken = Unprotect-Secret -EncryptedText $notionConfig.encryptedToken
    $pageId = $notionConfig.pageId

    $headers = @{
        Authorization    = "Bearer $notionToken"
        'Notion-Version' = '2022-06-28'
    }

    $report = Get-Content -Path $LatestJsonPath -Raw | ConvertFrom-Json
    $today = ([DateTime]::Parse($report.generatedAtUtc)).ToLocalTime().ToString('yyyy-MM-dd')
    $followers = $report.account.followersCount
    $delta = $report.account.followersDelta
    $deltaText = '-'
    if ($null -ne $delta) {
        $deltaText = if ([int]$delta -gt 0) { "+$delta" } else { "$delta" }
    }
    $totalReach = $report.summary.totalReach
    $totalSaved = $report.summary.totalSaved
    $totalShares = $report.summary.totalShares
    $username = $report.account.username

    # 1) 페이지 하위 블록 조회 (콜아웃 / 표 블록 찾기)
    $childrenUri = "https://api.notion.com/v1/blocks/$pageId/children?page_size=50"
    $children = Invoke-RestMethod -Uri $childrenUri -Headers $headers -Method Get

    $calloutBlock = $children.results | Where-Object { $_.type -eq 'callout' } | Select-Object -First 1
    $tableBlock = $children.results | Where-Object { $_.type -eq 'table' } | Select-Object -First 1

    # 2) 상단 요약 콜아웃 갱신 (기존 아이콘/색상 유지)
    if ($calloutBlock) {
        $summaryText = "계정: @$username$([Environment]::NewLine)팔로워: ${followers}명 (전일 대비 $deltaText)$([Environment]::NewLine)연동 상태: Instagram Graph API 연결 완료$([Environment]::NewLine)마지막 동기화: $today"
        $calloutPatch = @{
            callout = @{
                rich_text = @(
                    @{ type = 'text'; text = @{ content = $summaryText } }
                )
                icon  = $calloutBlock.callout.icon
                color = $calloutBlock.callout.color
            }
        }
        $calloutPatchJson = $calloutPatch | ConvertTo-Json -Depth 10
        Invoke-RestMethod -Uri "https://api.notion.com/v1/blocks/$($calloutBlock.id)" -Headers $headers -Method Patch -Body $calloutPatchJson -ContentType 'application/json; charset=utf-8' | Out-Null
    }

    # 3) 표에 오늘자 행 추가 (헤더 바로 아래에 삽입 -> 최신이 항상 위)
    if ($tableBlock) {
        $rowChildrenUri = "https://api.notion.com/v1/blocks/$($tableBlock.id)/children?page_size=5"
        $rowChildren = Invoke-RestMethod -Uri $rowChildrenUri -Headers $headers -Method Get
        $headerRow = $rowChildren.results | Select-Object -First 1

        $cells = @(
            ,@(@{ type = 'text'; text = @{ content = "$today" } })
            ,@(@{ type = 'text'; text = @{ content = "$followers" } })
            ,@(@{ type = 'text'; text = @{ content = "$deltaText" } })
            ,@(@{ type = 'text'; text = @{ content = "$totalReach" } })
            ,@(@{ type = 'text'; text = @{ content = "$totalSaved" } })
            ,@(@{ type = 'text'; text = @{ content = "$totalShares" } })
        )

        $newRowBlock = @{
            type      = 'table_row'
            table_row = @{ cells = $cells }
        }

        $appendBody = @{ children = @($newRowBlock) }
        if ($headerRow) { $appendBody['after'] = $headerRow.id }

        $appendJson = $appendBody | ConvertTo-Json -Depth 10
        Invoke-RestMethod -Uri "https://api.notion.com/v1/blocks/$($tableBlock.id)/children" -Headers $headers -Method Patch -Body $appendJson -ContentType 'application/json; charset=utf-8' | Out-Null
    }

    Write-Host "Notion 동기화 완료 (@$username, ${followers}명)" -ForegroundColor Green
} catch {
    Write-Warning "Notion 동기화 실패(무시하고 계속 진행): $($_.Exception.Message)"
} finally {
    $notionToken = $null
    [System.GC]::Collect()
}
