#Requires -Version 5.1
<#
  setup-instagram-insights.ps1

  1회 초기 설정 스크립트.
  - Windows 로컬 GUI 입력창으로 Instagram 액세스 토큰 / 앱 시크릿을 입력받음
  - 장기 액세스 토큰(60일)으로 교환
  - graph.instagram.com에 실제 API 호출로 연결 테스트
  - instagram_business_basic / instagram_business_manage_insights 권한을 실제 호출로 확인
  - 토큰/시크릿은 DPAPI(CurrentUser)로 암호화하여
    %LOCALAPPDATA%\InstagramCodexConnector\config.json 에만 저장
  - 콘솔에는 계정명 / 연결 성공 여부 / 토큰 만료일만 출력 (토큰·시크릿 값은 절대 출력하지 않음)

  다른 PC/사용자에서도 그대로 동작하도록 $env:LOCALAPPDATA만 사용합니다.
  설정/리포트 모두 OneDrive 등 클라우드 동기화 대상이 아닌 로컬 전용 폴더에 저장됩니다.
#>

[CmdletBinding()]
param(
    # 실행 후 매일 자동으로 collect-instagram-insights.ps1 을 실행하는
    # Windows 예약 작업(Scheduled Task)을 등록합니다.
    # collect 스크립트가 매 실행마다 "만료 10일 전" 여부를 확인해 자동 갱신하므로,
    # 이 옵션을 켜야 "자동 갱신"이 사람 개입 없이 실제로 동작합니다.
    [switch]$RegisterDailyTask,

    [string]$DailyTaskTime = "09:00"
)

$ErrorActionPreference = "Stop"

if (-not $IsWindows -and $PSVersionTable.PSVersion.Major -ge 6) {
    throw "이 스크립트는 Windows에서만 동작합니다. (DPAPI 및 Windows Forms 입력창 필요)"
}

# ---------------------------------------------------------------------------
# 경로 정의: 고정 사용자명이나 절대경로를 쓰지 않고 환경변수만 사용
# ---------------------------------------------------------------------------
$ConfigDir  = Join-Path $env:LOCALAPPDATA "InstagramCodexConnector"
$ConfigPath = Join-Path $ConfigDir "config.json"
# %LOCALAPPDATA%는 OneDrive 등 클라우드 동기화 대상이 아닌, 이 PC에만 남는 로컬 전용 폴더입니다.
# (Documents/Desktop/Pictures는 OneDrive 폴더 백업으로 자동 동기화되는 경우가 많아 피합니다.)
$ReportsDir = Join-Path $ConfigDir "reports"

New-Item -ItemType Directory -Force -Path $ConfigDir  | Out-Null
New-Item -ItemType Directory -Force -Path $ReportsDir | Out-Null

$ApiBase = "https://graph.instagram.com"

# ---------------------------------------------------------------------------
# DPAPI 암호화 헬퍼
#   ConvertFrom-SecureString(-Key 없이)는 Windows DPAPI(CurrentUser+CurrentMachine)를
#   사용하므로, 같은 Windows 사용자 계정으로 같은 PC에 로그인해야만 복호화할 수 있습니다.
# ---------------------------------------------------------------------------
function Protect-StringDpapi {
    param([Parameter(Mandatory)][System.Security.SecureString]$SecureValue)
    $encrypted = ConvertFrom-SecureString -SecureString $SecureValue
    return $encrypted
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

function ConvertTo-PlainTextFromSecureString {
    param([Parameter(Mandatory)][System.Security.SecureString]$SecureValue)
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($SecureValue)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringUni($bstr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($bstr)
    }
}

# ---------------------------------------------------------------------------
# GUI 입력창 (Windows Forms) - 값은 화면/로그에 표시되지 않음(마스킹)
# ---------------------------------------------------------------------------
function Show-CredentialInputDialog {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "인스타 성과 자동보고 연결"
    $form.Size = New-Object System.Drawing.Size(480, 340)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true

    $lblHeader = New-Object System.Windows.Forms.Label
    $lblHeader.Text = "인스타 성과 자동보고 연결"
    $lblHeader.Font = New-Object System.Drawing.Font($lblHeader.Font.FontFamily, 12, [System.Drawing.FontStyle]::Bold)
    $lblHeader.Location = New-Object System.Drawing.Point(15, 15)
    $lblHeader.AutoSize = $true
    $form.Controls.Add($lblHeader)

    $lblDesc = New-Object System.Windows.Forms.Label
    $lblDesc.Text = "Meta에서 방금 만든 액세스 토큰과 Instagram 앱 시크릿 코드를 붙여넣으세요.`r`n값은 채팅이나 저장소에 남지 않고, 이 Windows 사용자만 열 수 있게 암호화됩니다."
    $lblDesc.Location = New-Object System.Drawing.Point(15, 45)
    $lblDesc.Size = New-Object System.Drawing.Size(440, 45)
    $form.Controls.Add($lblDesc)

    $lblToken = New-Object System.Windows.Forms.Label
    $lblToken.Text = "액세스 토큰"
    $lblToken.Location = New-Object System.Drawing.Point(15, 100)
    $lblToken.AutoSize = $true
    $form.Controls.Add($lblToken)

    $txtToken = New-Object System.Windows.Forms.TextBox
    $txtToken.Location = New-Object System.Drawing.Point(15, 122)
    $txtToken.Size = New-Object System.Drawing.Size(440, 24)
    $txtToken.UseSystemPasswordChar = $true
    $form.Controls.Add($txtToken)

    $lblSecret = New-Object System.Windows.Forms.Label
    $lblSecret.Text = "Instagram 앱 시크릿 코드"
    $lblSecret.Location = New-Object System.Drawing.Point(15, 155)
    $lblSecret.AutoSize = $true
    $form.Controls.Add($lblSecret)

    $txtSecret = New-Object System.Windows.Forms.TextBox
    $txtSecret.Location = New-Object System.Drawing.Point(15, 177)
    $txtSecret.Size = New-Object System.Drawing.Size(440, 24)
    $txtSecret.UseSystemPasswordChar = $true
    $form.Controls.Add($txtSecret)

    $lblHelper = New-Object System.Windows.Forms.Label
    $lblHelper.Text = "두 값을 입력한 뒤 아래 버튼을 눌러주세요."
    $lblHelper.Location = New-Object System.Drawing.Point(15, 210)
    $lblHelper.Size = New-Object System.Drawing.Size(440, 20)
    $lblHelper.ForeColor = [System.Drawing.Color]::DimGray
    $form.Controls.Add($lblHelper)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = "저장하고 연결 테스트"
    $btnOk.Location = New-Object System.Drawing.Point(170, 245)
    $btnOk.Size = New-Object System.Drawing.Size(180, 32)
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($btnOk)
    $form.AcceptButton = $btnOk

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "취소"
    $btnCancel.Location = New-Object System.Drawing.Point(365, 245)
    $btnCancel.Size = New-Object System.Drawing.Size(80, 32)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($btnCancel)
    $form.CancelButton = $btnCancel

    $result = $form.ShowDialog()

    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        $form.Dispose()
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($txtToken.Text) -or [string]::IsNullOrWhiteSpace($txtSecret.Text)) {
        $form.Dispose()
        throw "토큰과 앱 시크릿을 모두 입력해야 합니다."
    }

    $secureToken  = New-Object System.Security.SecureString
    foreach ($ch in $txtToken.Text.ToCharArray())  { $secureToken.AppendChar($ch) }
    $secureSecret = New-Object System.Security.SecureString
    foreach ($ch in $txtSecret.Text.ToCharArray()) { $secureSecret.AppendChar($ch) }
    $secureToken.MakeReadOnly()
    $secureSecret.MakeReadOnly()

    # 평문 텍스트 컨트롤 내용을 즉시 지움 (메모리에 남는 시간을 최소화)
    $txtToken.Text  = "*" * 8
    $txtSecret.Text = "*" * 8
    $form.Dispose()

    return [PSCustomObject]@{
        AccessToken = $secureToken
        AppSecret   = $secureSecret
    }
}

# ---------------------------------------------------------------------------
# graph.instagram.com 호출 헬퍼
# ---------------------------------------------------------------------------
function Invoke-InstagramApi {
    param(
        [Parameter(Mandatory)][string]$Uri
    )
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
# 메인 플로우
# ---------------------------------------------------------------------------
Write-Host "Instagram API Connector 설정을 시작합니다..." -ForegroundColor Cyan

$creds = Show-CredentialInputDialog
if (-not $creds) {
    Write-Host "사용자가 입력을 취소했습니다. 설정을 종료합니다." -ForegroundColor Yellow
    return
}

$plainToken  = ConvertTo-PlainTextFromSecureString -SecureValue $creds.AccessToken
$plainSecret = ConvertTo-PlainTextFromSecureString -SecureValue $creds.AppSecret

$longLivedToken = $null
$expiresAt      = $null

try {
    Write-Host "장기 액세스 토큰으로 교환 중..." -ForegroundColor Cyan
    $exchangeUri = "$ApiBase/access_token?grant_type=ig_exchange_token&client_secret=$([uri]::EscapeDataString($plainSecret))&access_token=$([uri]::EscapeDataString($plainToken))"
    $exchangeResult = Invoke-InstagramApi -Uri $exchangeUri

    $longLivedToken = $exchangeResult.access_token
    if ($exchangeResult.expires_in) {
        $expiresAt = (Get-Date).ToUniversalTime().AddSeconds([double]$exchangeResult.expires_in)
    }
    Write-Host "장기 토큰 교환 성공." -ForegroundColor Green
} catch {
    Write-Warning "장기 토큰 교환에 실패했습니다. 입력한 토큰이 이미 장기 토큰일 수 있어, 해당 토큰으로 계속 진행합니다."
    Write-Warning "상세 오류: $($_.Exception.Message)"
    $longLivedToken = $plainToken
    $expiresAt = $null
}

Write-Host "실제 계정 연결을 테스트 중입니다 (graph.instagram.com)..." -ForegroundColor Cyan

$connectionOk = $false
$igUserId = $null
$username = $null
$accountType = $null

try {
    $meUri = "$ApiBase/me?fields=id,username,account_type&access_token=$([uri]::EscapeDataString($longLivedToken))"
    $me = Invoke-InstagramApi -Uri $meUri
    $igUserId    = $me.id
    $username    = $me.username
    $accountType = $me.account_type
    $connectionOk = $true
} catch {
    $connectionOk = $false
    Write-Warning "계정 연결 테스트에 실패했습니다: $($_.Exception.Message)"
}

# instagram_business_basic: /me 호출 성공 여부로 확인
$permBasic = $connectionOk

# instagram_business_manage_insights: 계정 레벨 insights 호출로 실제 확인
$permInsights = $false
if ($connectionOk -and $igUserId) {
    try {
        $insightsUri = "$ApiBase/$igUserId/insights?metric=reach&period=day&metric_type=total_value&access_token=$([uri]::EscapeDataString($longLivedToken))"
        Invoke-InstagramApi -Uri $insightsUri | Out-Null
        $permInsights = $true
    } catch {
        $permInsights = $false
    }
}

if (-not $connectionOk) {
    # 평문 변수 정리 후 종료 (저장하지 않음: 검증 실패 시에는 파일을 남기지 않음)
    $plainToken = $null; $plainSecret = $null; $longLivedToken = $null
    [System.GC]::Collect()
    throw "Instagram 계정 연결에 실패하여 설정을 저장하지 않았습니다. 토큰/시크릿 값을 다시 확인한 뒤 스크립트를 재실행해주세요."
}

# ---------------------------------------------------------------------------
# DPAPI로 암호화하여 저장
# ---------------------------------------------------------------------------
$secureLongToken = ConvertTo-SecureString -String $longLivedToken -AsPlainText -Force
$secureAppSecret = ConvertTo-SecureString -String $plainSecret -AsPlainText -Force

$tokenExpiresAtUtcStr = $null
if ($expiresAt) { $tokenExpiresAtUtcStr = $expiresAt.ToString("o") }

$config = [PSCustomObject]@{
    schemaVersion       = 1
    igUserId            = $igUserId
    username            = $username
    accountType         = $accountType
    encryptedAccessToken = (Protect-StringDpapi -SecureValue $secureLongToken)
    encryptedAppSecret   = (Protect-StringDpapi -SecureValue $secureAppSecret)
    tokenObtainedAtUtc  = (Get-Date).ToUniversalTime().ToString("o")
    tokenExpiresAtUtc   = $tokenExpiresAtUtcStr
    permissions         = [PSCustomObject]@{
        instagram_business_basic            = $permBasic
        instagram_business_manage_insights  = $permInsights
    }
    lastVerifiedAtUtc   = (Get-Date).ToUniversalTime().ToString("o")
    reportsDir          = $ReportsDir
}

$config | ConvertTo-Json -Depth 6 | Set-Content -Path $ConfigPath -Encoding UTF8

# 파일 접근을 현재 사용자로만 제한 (best-effort, 실패해도 치명적이지 않음: DPAPI가 1차 방어선)
try {
    icacls $ConfigPath /inheritance:r | Out-Null
    icacls $ConfigPath /grant:r "$($env:USERNAME):(R,W)" | Out-Null
} catch {
    Write-Verbose "NTFS ACL 제한 설정을 건너뜁니다: $($_.Exception.Message)"
}

# 평문 비밀값 변수 정리
$plainToken = $null
$plainSecret = $null
$longLivedToken = $null
[System.GC]::Collect()

# ---------------------------------------------------------------------------
# 예약 작업 등록 (선택)
# ---------------------------------------------------------------------------
if ($RegisterDailyTask) {
    $collectScriptPath = Join-Path $PSScriptRoot "collect-instagram-insights.ps1"
    if (Test-Path $collectScriptPath) {
        try {
            $taskName = "InstagramCodexConnector-DailyRefresh"
            $action  = New-ScheduledTaskAction -Execute "powershell.exe" `
                -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$collectScriptPath`""
            $trigger = New-ScheduledTaskTrigger -Daily -At $DailyTaskTime
            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
                -Description "매일 Instagram 인사이트 수집 + 만료 10일 전 토큰 자동 갱신" `
                -Force | Out-Null
            Write-Host "매일 $DailyTaskTime 에 실행되는 예약 작업 '$taskName'을 등록했습니다." -ForegroundColor Green
        } catch {
            Write-Warning "예약 작업 등록에 실패했습니다: $($_.Exception.Message)"
        }
    } else {
        Write-Warning "collect-instagram-insights.ps1 을 찾을 수 없어 예약 작업을 등록하지 못했습니다."
    }
}

# ---------------------------------------------------------------------------
# 결과 보고: 계정명 / 연결 성공 여부 / 만료일만 출력 (토큰·시크릿 값은 절대 출력하지 않음)
# ---------------------------------------------------------------------------
$expiresDisplay = if ($expiresAt) { $expiresAt.ToLocalTime().ToString("yyyy-MM-dd HH:mm") } else { "알 수 없음 (다음 실행 시 갱신 시도)" }

Write-Host ""
Write-Host "$username 인스타 성과 연결" -ForegroundColor Green
Write-Host "  연결 상태 : $(if ($connectionOk) { '성공' } else { '실패' })"
Write-Host "  토큰 만료일: $expiresDisplay"
Write-Host "  권한 확인 : instagram_business_basic=$permBasic, instagram_business_manage_insights=$permInsights"
Write-Host "  설정 파일 : $ConfigPath"
Write-Host ""
Write-Host "이제부터 collect-instagram-insights.ps1 을 실행하면 저장된 이 연결을 그대로 사용합니다."
