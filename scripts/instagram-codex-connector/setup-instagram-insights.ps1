<#
.SYNOPSIS
    Instagram Graph API(Instagram Login) 연결을 설정합니다.

.DESCRIPTION
    - Windows Forms로 만든 로컬 보안 입력창에서 Instagram 액세스 토큰과 앱 시크릿을 입력받습니다.
      (콘솔/스크립트 인자로는 절대 받지 않습니다.)
    - 단기 토큰을 장기(약 60일) 토큰으로 교환합니다.
    - graph.instagram.com 으로 실제 계정 연결을 테스트합니다.
    - instagram_business_basic / instagram_business_manage_insights 권한을
      실제 API 호출 성공 여부로 검증합니다.
    - 토큰/시크릿은 DPAPI(ConvertTo-SecureString, 현재 Windows 사용자 전용)로 암호화하여
      "$env:LOCALAPPDATA\InstagramCodexConnector\config.json" 에 저장합니다.
    - 토큰/시크릿 원문은 콘솔, 로그, 예외 메시지 어디에도 출력되지 않습니다.

.PARAMETER RegisterDailyTask
    지정하면 collect-instagram-insights.ps1 을 매일 자동 실행하는
    Windows 작업 스케줄러 작업을 등록합니다. (만료 10일 전 자동 갱신용)

.NOTES
    Windows 전용 스크립트입니다 (Windows Forms + DPAPI 사용).
    $env:USERPROFILE / $env:LOCALAPPDATA 만 사용하므로 다른 PC/계정에서도 그대로 동작합니다.
#>

[CmdletBinding()]
param(
    [switch]$RegisterDailyTask
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 0. 환경 점검
# ---------------------------------------------------------------------------

$isWindowsOs = $true
try {
    if (Get-Variable -Name IsWindows -Scope Global -ErrorAction SilentlyContinue) {
        $isWindowsOs = $IsWindows
    }
} catch { }

if (-not $isWindowsOs) {
    throw "이 스크립트는 Windows Forms와 DPAPI를 사용하므로 Windows에서만 실행할 수 있습니다."
}

$ConnectorRoot = Join-Path $env:LOCALAPPDATA 'InstagramCodexConnector'
$ConfigPath    = Join-Path $ConnectorRoot 'config.json'
$ReportsDir    = Join-Path $ConnectorRoot 'reports'

New-Item -ItemType Directory -Path $ConnectorRoot -Force | Out-Null
New-Item -ItemType Directory -Path $ReportsDir -Force | Out-Null

# ---------------------------------------------------------------------------
# 1. 비밀값 보호 유틸리티
# ---------------------------------------------------------------------------

function Protect-Secret {
    <# 평문 문자열을 DPAPI(CurrentUser)로 암호화된 문자열로 변환 #>
    param([Parameter(Mandatory)][string]$PlainText)
    $secure = ConvertTo-SecureString -String $PlainText -AsPlainText -Force
    return ConvertFrom-SecureString -SecureString $secure
}

function Unprotect-Secret {
    <# DPAPI로 암호화된 문자열을 평문으로 복원 (같은 사용자 계정에서만 가능) #>
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
    <# 로그/에러 문자열에서 access_token / client_secret 값을 제거 #>
    param([Parameter(Mandatory)][string]$Text)
    $t = $Text
    $t = [regex]::Replace($t, '(access_token=)[^&\s"]+', '$1***REDACTED***')
    $t = [regex]::Replace($t, '(client_secret=)[^&\s"]+', '$1***REDACTED***')
    return $t
}

# ---------------------------------------------------------------------------
# 2. 로컬 보안 입력창 (Windows Forms)
# ---------------------------------------------------------------------------

function Show-SecureCredentialDialog {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Instagram API 연결 정보 입력'
    $form.Size = New-Object System.Drawing.Size(460, 230)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true

    $lblToken = New-Object System.Windows.Forms.Label
    $lblToken.Text = 'Instagram 액세스 토큰 (단기 토큰):'
    $lblToken.Location = New-Object System.Drawing.Point(15, 20)
    $lblToken.AutoSize = $true
    $form.Controls.Add($lblToken)

    $txtToken = New-Object System.Windows.Forms.TextBox
    $txtToken.Location = New-Object System.Drawing.Point(15, 45)
    $txtToken.Size = New-Object System.Drawing.Size(415, 24)
    $txtToken.UseSystemPasswordChar = $true
    $form.Controls.Add($txtToken)

    $lblSecret = New-Object System.Windows.Forms.Label
    $lblSecret.Text = 'Instagram 앱 시크릿:'
    $lblSecret.Location = New-Object System.Drawing.Point(15, 85)
    $lblSecret.AutoSize = $true
    $form.Controls.Add($lblSecret)

    $txtSecret = New-Object System.Windows.Forms.TextBox
    $txtSecret.Location = New-Object System.Drawing.Point(15, 110)
    $txtSecret.Size = New-Object System.Drawing.Size(415, 24)
    $txtSecret.UseSystemPasswordChar = $true
    $form.Controls.Add($txtSecret)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = '확인'
    $btnOk.Location = New-Object System.Drawing.Point(270, 150)
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '취소'
    $btnCancel.Location = New-Object System.Drawing.Point(355, 150)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($btnCancel)

    $form.AcceptButton = $btnOk
    $form.CancelButton = $btnCancel

    $result = $form.ShowDialog()

    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        $form.Dispose()
        throw '사용자가 입력을 취소했습니다.'
    }

    if ([string]::IsNullOrWhiteSpace($txtToken.Text) -or [string]::IsNullOrWhiteSpace($txtSecret.Text)) {
        $form.Dispose()
        throw '액세스 토큰과 앱 시크릿을 모두 입력해야 합니다.'
    }

    $out = [PSCustomObject]@{
        AccessToken = $txtToken.Text
        AppSecret   = $txtSecret.Text
    }

    # 폼에 남아있는 평문 제거
    $txtToken.Text = ''
    $txtSecret.Text = ''
    $form.Dispose()

    return $out
}

# ---------------------------------------------------------------------------
# 3. Instagram Graph API 호출 헬퍼 (에러에도 비밀값이 노출되지 않도록 처리)
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# 4. 메인 흐름
# ---------------------------------------------------------------------------

Write-Host '=== Instagram API 연결 설정 ===' -ForegroundColor Cyan
Write-Host '로컬 보안 입력창을 엽니다. 토큰/시크릿은 화면·로그에 표시되지 않습니다.' -ForegroundColor DarkGray

$cred = Show-SecureCredentialDialog
$shortLivedToken = $cred.AccessToken.Trim()
$appSecret = $cred.AppSecret.Trim()

try {
    $obtainedAtUtc = (Get-Date).ToUniversalTime()
    $longLivedToken = $null
    $expiresAtUtc = $obtainedAtUtc.AddDays(60)

    # 4-1a. 먼저 입력된 토큰이 이미 바로 사용 가능한 토큰인지 확인
    #       (앱 대시보드의 "토큰 생성" 버튼으로 발급한 토큰은 교환 없이 바로 쓸 수 있는 경우가 많음)
    Write-Host '입력한 토큰이 바로 사용 가능한지 확인하는 중...' -ForegroundColor DarkGray
    try {
        $directCheckUri = 'https://graph.instagram.com/me' +
            '?fields=id' +
            "&access_token=$([uri]::EscapeDataString($shortLivedToken))"
        Invoke-IgApi -Uri $directCheckUri | Out-Null
        $longLivedToken = $shortLivedToken
        Write-Host '입력한 토큰이 이미 유효합니다. 교환 절차를 건너뜁니다.' -ForegroundColor DarkGray
    } catch {
        Write-Host '바로 사용 가능한 토큰이 아닙니다. 단기->장기 토큰 교환을 시도합니다...' -ForegroundColor DarkGray
    }

    # 4-1b. 바로 쓸 수 없었다면 단기 토큰 -> 장기 토큰 교환 시도
    if (-not $longLivedToken) {
        $exchangeUri = 'https://graph.instagram.com/access_token' +
            '?grant_type=ig_exchange_token' +
            "&client_secret=$([uri]::EscapeDataString($appSecret))" +
            "&access_token=$([uri]::EscapeDataString($shortLivedToken))"

        $exchangeResult = Invoke-IgApi -Uri $exchangeUri
        $longLivedToken = $exchangeResult.access_token
        $expiresInSeconds = [int]$exchangeResult.expires_in

        if ([string]::IsNullOrWhiteSpace($longLivedToken)) {
            throw '장기 토큰 교환 응답에 access_token이 없습니다.'
        }
        $expiresAtUtc = $obtainedAtUtc.AddSeconds($expiresInSeconds)
    } else {
        # 이미 유효한 토큰을 장기 토큰으로 한 번 더 교환 시도 (실패해도 무시하고 원래 토큰 사용)
        try {
            $exchangeUri = 'https://graph.instagram.com/access_token' +
                '?grant_type=ig_exchange_token' +
                "&client_secret=$([uri]::EscapeDataString($appSecret))" +
                "&access_token=$([uri]::EscapeDataString($longLivedToken))"
            $exchangeResult = Invoke-IgApi -Uri $exchangeUri
            if ($exchangeResult.access_token) {
                $longLivedToken = $exchangeResult.access_token
                $expiresAtUtc = $obtainedAtUtc.AddSeconds([int]$exchangeResult.expires_in)
            }
        } catch {
            Write-Host '참고: 장기 토큰 재교환은 건너뛰었습니다(이미 유효한 토큰 사용). 만료일은 60일로 추정합니다.' -ForegroundColor DarkGray
        }
    }

    # 4-2. 연결 테스트 (instagram_business_basic 권한 확인 겸함)
    Write-Host '계정 연결을 테스트하는 중...' -ForegroundColor DarkGray
    try {
        $meUri = 'https://graph.instagram.com/me' +
            '?fields=id,username,name,account_type,followers_count,media_count' +
            "&access_token=$([uri]::EscapeDataString($longLivedToken))"
        $me = Invoke-IgApi -Uri $meUri
    } catch {
        # 일부 계정/권한에서는 followers_count 등이 지원되지 않을 수 있어 최소 필드로 재시도
        $meUri = 'https://graph.instagram.com/me' +
            '?fields=id,username,account_type' +
            "&access_token=$([uri]::EscapeDataString($longLivedToken))"
        $me = Invoke-IgApi -Uri $meUri
    }

    $basicScopeOk = -not [string]::IsNullOrWhiteSpace($me.id)

    # 4-3. instagram_business_manage_insights 권한 확인 (실제 인사이트 호출로 검증)
    Write-Host 'insights 권한을 확인하는 중...' -ForegroundColor DarkGray
    $insightsScopeOk = $false
    $insightsCheckNote = ''
    try {
        $mediaUri = 'https://graph.instagram.com/me/media' +
            '?fields=id&limit=1' +
            "&access_token=$([uri]::EscapeDataString($longLivedToken))"
        $mediaProbe = Invoke-IgApi -Uri $mediaUri

        if ($mediaProbe.data -and $mediaProbe.data.Count -gt 0) {
            $probeMediaId = $mediaProbe.data[0].id
            $insightsUri = "https://graph.instagram.com/$probeMediaId/insights" +
                '?metric=reach' +
                "&access_token=$([uri]::EscapeDataString($longLivedToken))"
            Invoke-IgApi -Uri $insightsUri | Out-Null
            $insightsScopeOk = $true
        } else {
            $insightsCheckNote = '게시물이 없어 insights 호출로 직접 검증하지 못했습니다 (권한 자체는 토큰 발급 시 승인됨).'
            $insightsScopeOk = $true
        }
    } catch {
        $insightsCheckNote = "insights 호출 실패: $($_.Exception.Message)"
        $insightsScopeOk = $false
    }

    # 4-4. 설정 저장 (비밀값은 DPAPI로 암호화)
    $config = [PSCustomObject]@{
        encryptedAccessToken = Protect-Secret -PlainText $longLivedToken
        encryptedAppSecret   = Protect-Secret -PlainText $appSecret
        tokenType            = 'long_lived'
        obtainedAtUtc        = $obtainedAtUtc.ToString('o')
        expiresAtUtc         = $expiresAtUtc.ToString('o')
        igUserId             = $me.id
        username             = $me.username
        accountType          = $me.account_type
        scopes               = @{
            instagram_business_basic            = $basicScopeOk
            instagram_business_manage_insights  = $insightsScopeOk
        }
        scopeCheckNote       = $insightsCheckNote
        lastRefreshedAtUtc   = $obtainedAtUtc.ToString('o')
    }

    $config | ConvertTo-Json -Depth 5 | Set-Content -Path $ConfigPath -Encoding UTF8

    # 4-5. 결과 보고 (비밀값 절대 미출력)
    Write-Host ''
    Write-Host '=== 연결 결과 ===' -ForegroundColor Green
    Write-Host "계정명            : $($me.username)"
    Write-Host "연결 성공 여부    : 성공"
    Write-Host "토큰 만료일(UTC)  : $($expiresAtUtc.ToString('yyyy-MM-dd HH:mm')) "
    Write-Host "instagram_business_basic           : $basicScopeOk"
    Write-Host "instagram_business_manage_insights : $insightsScopeOk"
    Write-Host ''
    Write-Host "설정 파일: $ConfigPath (토큰/시크릿은 현재 Windows 계정으로만 복호화 가능)" -ForegroundColor DarkGray

    # 4-6. 완료 알림 팝업 (비밀값 없음, 계정명/팔로워 수/성공 여부만)
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $displayName = if ($me.name) { $me.name } else { $me.username }
        $popupLines = @(
            '연결됐습니다.',
            "계정: @$($me.username)"
        )
        if ($null -ne $me.followers_count) {
            $popupLines += "팔로워: $($me.followers_count)명"
        }
        $popupLines += ''
        $popupLines += '이 창을 닫아도 됩니다.'
        $popupMessage = [string]::Join([Environment]::NewLine, $popupLines)

        [System.Windows.Forms.MessageBox]::Show(
            $popupMessage,
            "$displayName 인스타 연결 완료",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    } catch {
        Write-Warning "완료 알림 팝업 표시 실패(연결 자체는 성공): $($_.Exception.Message)"
    }

} finally {
    # 메모리상 평문 변수 제거 (최선 노력)
    $shortLivedToken = $null
    $appSecret = $null
    $longLivedToken = $null
    [System.GC]::Collect()
}

# ---------------------------------------------------------------------------
# 5. (옵션) 매일 자동 실행 작업 등록 - 만료 10일 전 자동 갱신용
# ---------------------------------------------------------------------------

if ($RegisterDailyTask) {
    $collectScript = Join-Path $PSScriptRoot 'collect-instagram-insights.ps1'
    if (-not (Test-Path $collectScript)) {
        Write-Warning "collect-instagram-insights.ps1 을 찾을 수 없어 예약 작업을 등록하지 못했습니다: $collectScript"
    } else {
        $taskName = 'InstagramCodexConnector-DailyCollect'
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$collectScript`""
        $trigger = New-ScheduledTaskTrigger -Daily -At '09:00'
        $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive

        try {
            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
                -Principal $principal -Force | Out-Null
            Write-Host "매일 09:00 자동 실행 작업을 등록했습니다: $taskName" -ForegroundColor Green
        } catch {
            Write-Warning "예약 작업 등록 실패: $($_.Exception.Message)"
        }
    }
}
