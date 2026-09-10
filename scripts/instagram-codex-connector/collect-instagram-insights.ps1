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
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $body = $_.ErrorDetails.Message
        }
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
    # PowerShell 5.1의 ConvertTo-Json은 원소가 1개인 배열을 배열이 아닌 단일 객체로
    # 직렬화해버리는 경우가 있어(대시보드 JS가 배열 메서드를 호출하다 깨짐), 결과 문자열이
    # '['로 시작하지 않으면 강제로 대괄호를 씌워 항상 JSON 배열이 되도록 보정한다.
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

function Get-DashboardHtmlTemplate {
    @'
<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>__USERNAME__ 인스타그램 대시보드</title>
<script src="https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.0/chart.umd.min.js"></script>
<style>
  :root {
    --pink: #ec4899;
    --pink-light: #fce7f3;
    --bg: #faf7f8;
    --card: #ffffff;
    --text: #1f2937;
    --muted: #6b7280;
    --border: #f0e4ec;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    background: var(--bg);
    color: var(--text);
    font-family: -apple-system, "Segoe UI", "Malgun Gothic", sans-serif;
    padding: 24px 16px 60px;
  }
  .wrap { max-width: 980px; margin: 0 auto; }
  .eyebrow {
    color: var(--pink);
    font-weight: 700;
    font-size: 12px;
    letter-spacing: .04em;
    margin-bottom: 4px;
  }
  h1 { font-size: 26px; margin: 0 0 4px; }
  h1 .gain { color: var(--pink); }
  .meta { color: var(--muted); font-size: 13px; margin-bottom: 20px; }
  .card {
    background: var(--card);
    border: 1px solid var(--border);
    border-radius: 16px;
    padding: 20px;
    margin-bottom: 20px;
  }
  .stats {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(130px, 1fr));
    gap: 14px;
  }
  .stat-box { text-align: left; }
  .stat-label { font-size: 12px; color: var(--muted); margin-bottom: 6px; }
  .stat-value { font-size: 22px; font-weight: 700; }
  .stat-value.pink { color: var(--pink); }
  canvas { max-width: 100%; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid var(--border); white-space: nowrap; }
  th { color: var(--muted); font-weight: 600; }
  .media-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(160px, 1fr));
    gap: 14px;
  }
  .media-card {
    border: 1px solid var(--border);
    border-radius: 12px;
    overflow: hidden;
    text-decoration: none;
    color: var(--text);
    display: block;
  }
  .media-card img {
    width: 100%;
    aspect-ratio: 1;
    object-fit: cover;
    display: block;
    background: var(--pink-light);
  }
  .media-card .body { padding: 10px; }
  .media-card .caption {
    font-size: 12px;
    color: var(--muted);
    display: -webkit-box;
    -webkit-line-clamp: 2;
    -webkit-box-orient: vertical;
    overflow: hidden;
    margin-bottom: 6px;
    min-height: 30px;
  }
  .media-card .metrics { font-size: 11px; color: var(--pink); font-weight: 600; }
  .table-wrap { overflow-x: auto; }
  @media (prefers-color-scheme: dark) {
    :root {
      --pink: #f472b6;
      --pink-light: #3b1f2b;
      --bg: #17141a;
      --card: #221d26;
      --text: #f2eef3;
      --muted: #9a94a3;
      --border: #33283a;
    }
  }
</style>
</head>
<body>
<div class="wrap">
  <div class="eyebrow">DAILY_METRICS.EXE</div>
  <h1>@__USERNAME__ 일별 지표 <span class="gain">__FOLLOWERS__명</span></h1>
  <div class="meta">생성 시각: __GENERATED_AT__ · 토큰 만료일: __TOKEN_EXPIRY__</div>

  <div class="card stats">
    <div class="stat-box">
      <div class="stat-label">오늘 팔로워</div>
      <div class="stat-value pink">__FOLLOWERS__</div>
    </div>
    <div class="stat-box">
      <div class="stat-label">기간 순증</div>
      <div class="stat-value">__PERIOD_GAIN__</div>
    </div>
    <div class="stat-box">
      <div class="stat-label">일평균 순증</div>
      <div class="stat-value">__AVG_GAIN__</div>
    </div>
    <div class="stat-box">
      <div class="stat-label">최고 증가일</div>
      <div class="stat-value" style="font-size:16px">__BEST_DAY__</div>
    </div>
    <div class="stat-box">
      <div class="stat-label">발행 콘텐츠</div>
      <div class="stat-value">__MEDIA_COUNT__</div>
    </div>
  </div>

  <div class="card">
    <div class="eyebrow">GROWTH_CHART</div>
    <canvas id="growthChart" height="90"></canvas>
  </div>

  <div class="card">
    <div class="eyebrow">MONTHLY_GAIN</div>
    <canvas id="monthlyChart" height="90"></canvas>
  </div>

  <div class="card">
    <div class="eyebrow">RECENT_CONTENT</div>
    <div class="media-grid" id="mediaGrid"></div>
  </div>

  <div class="card">
    <div class="eyebrow">DAILY_LOG</div>
    <div class="table-wrap">
      <table id="dailyLogTable">
        <thead>
          <tr><th>날짜</th><th>요일</th><th>팔로워</th><th>전일 대비</th><th>도달 합계</th><th>저장 합계</th><th>공유 합계</th></tr>
        </thead>
        <tbody></tbody>
      </table>
    </div>
  </div>
</div>

<script>
  var history = __HISTORY_JSON__;
  var monthly = __MONTHLY_JSON__;
  var media = __MEDIA_JSON__;
  var weekdayNames = ['일','월','화','수','목','금','토'];

  function fmtDate(d) {
    var dt = new Date(d + 'T00:00:00');
    return d + ' (' + weekdayNames[dt.getDay()] + ')';
  }

  try {
    if (typeof Chart !== 'undefined' && history.length > 0) {
      var ctx1 = document.getElementById('growthChart').getContext('2d');
      new Chart(ctx1, {
        type: 'line',
        data: {
          labels: history.map(function (h) { return h.date; }),
          datasets: [{
            label: '팔로워',
            data: history.map(function (h) { return h.followersCount; }),
            borderColor: '#ec4899',
            backgroundColor: 'rgba(236,72,153,0.12)',
            fill: true,
            tension: 0.25,
            pointRadius: 0
          }]
        },
        options: {
          plugins: { legend: { display: false } },
          scales: { y: { beginAtZero: false } }
        }
      });
    } else {
      document.getElementById('growthChart').insertAdjacentHTML('afterend', '<p style="color:#9ca3af;font-size:13px">데이터가 더 쌓이면 그래프가 표시됩니다.</p>');
    }
  } catch (e) { console.error('growth chart error', e); }

  try {
    if (typeof Chart !== 'undefined' && monthly.length > 0) {
      var ctx2 = document.getElementById('monthlyChart').getContext('2d');
      new Chart(ctx2, {
        type: 'bar',
        data: {
          labels: monthly.map(function (m) { return m.month; }),
          datasets: [{
            label: '월별 순증',
            data: monthly.map(function (m) { return m.gain; }),
            backgroundColor: '#ec4899',
            borderRadius: 6
          }]
        },
        options: {
          plugins: { legend: { display: false } }
        }
      });
    } else {
      document.getElementById('monthlyChart').insertAdjacentHTML('afterend', '<p style="color:#9ca3af;font-size:13px">데이터가 더 쌓이면 그래프가 표시됩니다.</p>');
    }
  } catch (e) { console.error('monthly chart error', e); }

  try {
    var grid = document.getElementById('mediaGrid');
    if (media.length === 0) {
      grid.innerHTML = '<p style="color:#9ca3af;font-size:13px">최근 콘텐츠가 없습니다.</p>';
    }
    media.forEach(function (m) {
      var a = document.createElement('a');
      a.href = m.permalink || '#';
      a.target = '_blank';
      a.rel = 'noopener';
      a.className = 'media-card';
      var img = m.thumbnailUrl ? '<img src="' + m.thumbnailUrl + '" loading="lazy">' : '';
      var caption = (m.caption || '(캡션 없음)').toString();
      a.innerHTML = img +
        '<div class="body">' +
        '<div class="caption">' + caption.replace(/</g, '&lt;') + '</div>' +
        '<div class="metrics">조회 ' + m.views + ' · 도달 ' + m.reach + ' · 저장 ' + m.saved + ' · 공유 ' + m.shares + '</div>' +
        '</div>';
      grid.appendChild(a);
    });
  } catch (e) { console.error('media grid error', e); }

  try {
    var tbody = document.querySelector('#dailyLogTable tbody');
    history.slice().reverse().forEach(function (h) {
    var tr = document.createElement('tr');
    var delta = (h.followersDelta === null || h.followersDelta === undefined) ? '-' :
      (h.followersDelta > 0 ? '+' + h.followersDelta : h.followersDelta);
    tr.innerHTML = '<td>' + fmtDate(h.date) + '</td>' +
      '<td>' + weekdayNames[new Date(h.date + 'T00:00:00').getDay()] + '</td>' +
      '<td>' + h.followersCount + '</td>' +
      '<td>' + delta + '</td>' +
      '<td>' + h.totalReach + '</td>' +
      '<td>' + h.totalSaved + '</td>' +
      '<td>' + h.totalShares + '</td>';
    tbody.appendChild(tr);
    });
  } catch (e) { console.error('daily log table error', e); }
</script>
</body>
</html>
'@
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
    try {
        $profileUri = 'https://graph.instagram.com/me' +
            '?fields=id,username,name,account_type,media_count,followers_count' +
            "&access_token=$([uri]::EscapeDataString($accessToken))"
        $rawProfile = Invoke-IgApi -Uri $profileUri
    } catch {
        $profileUri = 'https://graph.instagram.com/me' +
            '?fields=id,username,account_type,media_count' +
            "&access_token=$([uri]::EscapeDataString($accessToken))"
        $rawProfile = Invoke-IgApi -Uri $profileUri
    }
    # Select-Object 로 정규화: 응답에 없는 필드(name/followers_count 등)도 $null 로 항상 존재하게 만듦
    # (Set-StrictMode 상태에서 없는 속성에 바로 접근하면 오류가 나기 때문)
    $profile = $rawProfile | Select-Object id, username, name, account_type, media_count, followers_count

    # -----------------------------------------------------------------------
    # 4. 최근 콘텐츠 목록 조회
    # -----------------------------------------------------------------------
    Write-Host "최근 콘텐츠 $MediaCount 개를 가져오는 중..." -ForegroundColor DarkGray
    $mediaUri = 'https://graph.instagram.com/me/media' +
        "?fields=id,caption,media_type,media_product_type,permalink,timestamp,media_url,thumbnail_url&limit=$MediaCount" +
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
    foreach ($rawItem in $mediaList.data) {
        # 게시물마다 caption/media_url/thumbnail_url 등 일부 필드가 없을 수 있어 정규화
        $item = $rawItem | Select-Object id, caption, media_type, media_product_type, permalink, timestamp, media_url, thumbnail_url
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

                foreach ($rawMetricData in $insightsResult.data) {
                    # 응답 형태(values 배열 방식 / total_value 방식)가 지표마다 달라 정규화 후 접근
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

        $insightNote = ''
        if ($lastError) {
            $insightNote = "일부 지표 조회 실패: $lastError"
        }

        $thumbnailUrl = $item.media_url
        if ($item.media_type -eq 'VIDEO' -and $item.thumbnail_url) {
            $thumbnailUrl = $item.thumbnail_url
        }

        $mediaInsights += [PSCustomObject]@{
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
    }

    # -----------------------------------------------------------------------
    # 6. 전날 리포트와 비교 (팔로워 증감 계산용)
    # -----------------------------------------------------------------------
    $latestJsonPath = Join-Path $ReportsDir 'latest.json'
    $latestMdPath   = Join-Path $ReportsDir 'latest.md'
    $previousFollowers = $null
    $previousGeneratedAtUtc = $null
    if (Test-Path $latestJsonPath) {
        try {
            $previousReport = Get-Content -Path $latestJsonPath -Raw | ConvertFrom-Json
            $previousFollowers = $previousReport.account.followersCount
            $previousGeneratedAtUtc = $previousReport.generatedAtUtc
        } catch { }
    }

    $followersDelta = $null
    if ($null -ne $previousFollowers -and $null -ne $profile.followers_count) {
        $followersDelta = [int]$profile.followers_count - [int]$previousFollowers
    }

    # -----------------------------------------------------------------------
    # 7. 결과 저장 (JSON / Markdown) - 일일 브리프 형태
    # -----------------------------------------------------------------------
    $generatedAtUtc = (Get-Date).ToUniversalTime()
    $timestampTag = $generatedAtUtc.ToString('yyyyMMdd-HHmmss')

    $totalReach = ($mediaInsights | ForEach-Object { $_.reach } | Where-Object { $_ -ne 'N/A' } | Measure-Object -Sum).Sum
    $totalSaved = ($mediaInsights | ForEach-Object { $_.saved } | Where-Object { $_ -ne 'N/A' } | Measure-Object -Sum).Sum
    $totalShares = ($mediaInsights | ForEach-Object { $_.shares } | Where-Object { $_ -ne 'N/A' } | Measure-Object -Sum).Sum

    $report = [PSCustomObject]@{
        generatedAtUtc = $generatedAtUtc.ToString('o')
        account        = [PSCustomObject]@{
            username        = $profile.username
            id              = $profile.id
            accountType     = $profile.account_type
            mediaCount      = $profile.media_count
            followersCount  = $profile.followers_count
            followersDelta  = $followersDelta
        }
        tokenExpiresAtUtc = $expiresAtUtc.ToString('o')
        summary        = [PSCustomObject]@{
            totalReach  = $totalReach
            totalSaved  = $totalSaved
            totalShares = $totalShares
        }
        media          = $mediaInsights
    }

    $jsonPath = Join-Path $ReportsDir "instagram-insights-$timestampTag.json"
    $mdPath   = Join-Path $ReportsDir "instagram-insights-$timestampTag.md"

    $report | ConvertTo-Json -Depth 6 | Set-Content -Path $jsonPath -Encoding UTF8
    $report | ConvertTo-Json -Depth 6 | Set-Content -Path $latestJsonPath -Encoding UTF8

    $followersLine = "$($profile.followers_count)명"
    if ($null -ne $followersDelta) {
        if ($followersDelta -gt 0) { $followersLine += " (전날 대비 +$followersDelta)" }
        elseif ($followersDelta -lt 0) { $followersLine += " (전날 대비 $followersDelta)" }
        else { $followersLine += " (전날과 동일)" }
    }

    $md = New-Object System.Text.StringBuilder
    [void]$md.AppendLine("# 인스타그램 아침 브리프")
    [void]$md.AppendLine("")
    [void]$md.AppendLine("- 계정: **@$($profile.username)**")
    [void]$md.AppendLine("- 팔로워: **$followersLine**")
    [void]$md.AppendLine("- 생성 시각: $($generatedAtUtc.ToString('yyyy-MM-dd HH:mm')) (UTC)")
    [void]$md.AppendLine("- 최근 $($mediaInsights.Count)개 게시물 합계 - 도달: $totalReach, 저장: $totalSaved, 공유: $totalShares")
    [void]$md.AppendLine("- 토큰 만료일(UTC): $($expiresAtUtc.ToString('yyyy-MM-dd'))")
    [void]$md.AppendLine("")
    [void]$md.AppendLine("## 최근 콘텐츠 성과")
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
    # 8. 히스토리 누적 (팔로워 추이 그래프용)
    # -----------------------------------------------------------------------
    $historyPath = Join-Path $ReportsDir 'history.json'
    $todayKey = $generatedAtUtc.ToLocalTime().ToString('yyyy-MM-dd')

    $history = @()
    if (Test-Path $historyPath) {
        try { $history = @(Get-Content -Path $historyPath -Raw | ConvertFrom-Json) } catch { $history = @() }
    }
    $history = @($history | Where-Object { $_.date -ne $todayKey })
    $history += [PSCustomObject]@{
        date           = $todayKey
        followersCount = $profile.followers_count
        followersDelta = $followersDelta
        totalReach     = $totalReach
        totalSaved     = $totalSaved
        totalShares    = $totalShares
        mediaCount     = $profile.media_count
    }
    $history = @($history | Sort-Object { [DateTime]$_.date })
    Set-Content -Path $historyPath -Value (ConvertTo-JsonArraySafe -InputObject $history -Depth 5) -Encoding UTF8

    # -----------------------------------------------------------------------
    # 9. 대시보드(HTML) 생성 - 팔로워 성장 그래프 + 콘텐츠 성과
    # -----------------------------------------------------------------------
    $firstEntry = $history | Select-Object -First 1
    $lastEntry = $history | Select-Object -Last 1
    $periodGain = $null
    if ($firstEntry -and $lastEntry -and $null -ne $firstEntry.followersCount -and $null -ne $lastEntry.followersCount) {
        $periodGain = [int]$lastEntry.followersCount - [int]$firstEntry.followersCount
    }
    $deltaEntries = @($history | Where-Object { $null -ne $_.followersDelta })
    $avgDailyGain = $null
    if ($deltaEntries.Count -gt 0) {
        $sumDelta = ($deltaEntries | ForEach-Object { [int]$_.followersDelta } | Measure-Object -Sum).Sum
        $avgDailyGain = [math]::Round($sumDelta / $deltaEntries.Count)
    }
    $bestDayEntry = $deltaEntries | Sort-Object { [int]$_.followersDelta } -Descending | Select-Object -First 1

    $monthlyGains = @($history | Where-Object { $null -ne $_.followersDelta } |
        Group-Object { ([DateTime]$_.date).ToString('yyyy-MM') } |
        ForEach-Object {
            [PSCustomObject]@{
                month = $_.Name
                gain  = ($_.Group | ForEach-Object { [int]$_.followersDelta } | Measure-Object -Sum).Sum
            }
        } | Sort-Object month)

    $bestDayText = '-'
    if ($bestDayEntry) { $bestDayText = "$($bestDayEntry.date) (+$($bestDayEntry.followersDelta))" }
    $periodGainText = '-'
    if ($null -ne $periodGain) { $periodGainText = "$periodGain" }
    $avgGainText = '-'
    if ($null -ne $avgDailyGain) { $avgGainText = "$avgDailyGain" }

    $historyJsonData = ConvertTo-JsonArraySafe -InputObject $history -Depth 5
    $monthlyJsonData = ConvertTo-JsonArraySafe -InputObject $monthlyGains -Depth 5
    $mediaJsonData = ConvertTo-JsonArraySafe -InputObject $mediaInsights -Depth 5

    $dashboardPath = Join-Path $ReportsDir 'dashboard.html'
    $html = (Get-DashboardHtmlTemplate).
        Replace('__USERNAME__', $profile.username).
        Replace('__FOLLOWERS__', "$($profile.followers_count)").
        Replace('__PERIOD_GAIN__', $periodGainText).
        Replace('__AVG_GAIN__', $avgGainText).
        Replace('__BEST_DAY__', $bestDayText).
        Replace('__MEDIA_COUNT__', "$($profile.media_count)").
        Replace('__TOKEN_EXPIRY__', $expiresAtUtc.ToString('yyyy-MM-dd')).
        Replace('__GENERATED_AT__', $generatedAtUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm')).
        Replace('__HISTORY_JSON__', $historyJsonData).
        Replace('__MONTHLY_JSON__', $monthlyJsonData).
        Replace('__MEDIA_JSON__', $mediaJsonData)

    Set-Content -Path $dashboardPath -Value $html -Encoding UTF8

    # -----------------------------------------------------------------------
    # 10. 노션(Notion) 동기화 (설정되어 있을 때만, 실패해도 전체 흐름은 계속)
    # -----------------------------------------------------------------------
    try {
        $notionSyncScript = Join-Path $PSScriptRoot 'sync-to-notion.ps1'
        if (Test-Path $notionSyncScript) {
            & $notionSyncScript
        }
    } catch {
        Write-Warning "Notion 동기화 단계에서 오류(무시하고 계속): $($_.Exception.Message)"
    }

    # -----------------------------------------------------------------------
    # 11. 콘솔 요약 (비밀값 절대 미출력)
    # -----------------------------------------------------------------------
    Write-Host ''
    Write-Host '=== 수집 완료 ===' -ForegroundColor Green
    Write-Host "계정명          : $($profile.username)"
    Write-Host "팔로워          : $followersLine"
    Write-Host "연결 성공 여부  : 성공"
    Write-Host "토큰 만료일     : $($expiresAtUtc.ToString('yyyy-MM-dd'))"
    Write-Host "JSON 리포트     : $jsonPath"
    Write-Host "Markdown 리포트 : $mdPath"
    Write-Host "대시보드        : $dashboardPath"

} finally {
    $accessToken = $null
    [System.GC]::Collect()
}
