<#
.SYNOPSIS
    노션(Notion) 통합 토큰을 입력받아 "블리스맘 오피스 > 성과" 페이지 자동 동기화를 설정합니다.

.DESCRIPTION
    - 로컬 보안 입력창(Windows Forms)으로 Notion Internal Integration Secret 을 입력받습니다.
      (콘솔/스크립트 인자로는 절대 받지 않습니다.)
    - DPAPI(ConvertTo-SecureString, 현재 Windows 사용자 전용)로 암호화하여
      "$env:LOCALAPPDATA\InstagramCodexConnector\notion-config.json" 에 저장합니다.
    - 실제로 "성과" 페이지에 접근되는지 API 호출로 테스트합니다.
    - 토큰 원문은 콘솔, 로그, 예외 메시지 어디에도 출력되지 않습니다.

.NOTES
    사전 준비 (브라우저에서 딱 한 번만 하면 됩니다):
    1) https://www.notion.so/my-integrations 에서 "New integration" 클릭 후 이름 지정, 생성
    2) 생성된 통합의 "Internal Integration Secret" 복사 (ntn_ 으로 시작)
    3) 노션에서 "블리스맘 오피스 > 성과" 페이지를 열고, 우측 상단 "..." 메뉴 ->
       "연결 추가(Add connections)" 에서 방금 만든 통합을 추가
    이 3단계를 해두어야 아래 스크립트가 그 페이지에 접근할 수 있습니다.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 블리스맘 오피스 > 성과 페이지 (고정)
$PageId = '3d772214-ff24-80ab-b506-d7106559dacd'

$isWindowsOs = $true
try {
    if (Get-Variable -Name IsWindows -Scope Global -ErrorAction SilentlyContinue) {
        $isWindowsOs = $IsWindows
    }
} catch { }
if (-not $isWindowsOs) {
    throw '이 스크립트는 Windows Forms와 DPAPI를 사용하므로 Windows에서만 실행할 수 있습니다.'
}

$ConnectorRoot = Join-Path $env:LOCALAPPDATA 'InstagramCodexConnector'
New-Item -ItemType Directory -Path $ConnectorRoot -Force | Out-Null
$NotionConfigPath = Join-Path $ConnectorRoot 'notion-config.json'

function Protect-Secret {
    param([Parameter(Mandatory)][string]$PlainText)
    $secure = ConvertTo-SecureString -String $PlainText -AsPlainText -Force
    return ConvertFrom-SecureString -SecureString $secure
}

function Show-NotionTokenDialog {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Notion 연동 설정'
    $form.Size = New-Object System.Drawing.Size(480, 190)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "Notion Internal Integration Secret ('ntn_'으로 시작):"
    $lbl.Location = New-Object System.Drawing.Point(15, 20)
    $lbl.AutoSize = $true
    $form.Controls.Add($lbl)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Location = New-Object System.Drawing.Point(15, 45)
    $txt.Size = New-Object System.Drawing.Size(435, 24)
    $txt.UseSystemPasswordChar = $true
    $form.Controls.Add($txt)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = '확인'
    $btnOk.Location = New-Object System.Drawing.Point(290, 90)
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '취소'
    $btnCancel.Location = New-Object System.Drawing.Point(375, 90)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($btnCancel)

    $form.AcceptButton = $btnOk
    $form.CancelButton = $btnCancel

    $result = $form.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK -or [string]::IsNullOrWhiteSpace($txt.Text)) {
        $form.Dispose()
        throw '사용자가 입력을 취소했거나 값을 입력하지 않았습니다.'
    }
    $token = $txt.Text.Trim()
    $txt.Text = ''
    $form.Dispose()
    return $token
}

Write-Host '=== Notion 연동 설정 ===' -ForegroundColor Cyan
Write-Host '로컬 보안 입력창을 엽니다. 토큰은 화면·로그에 표시되지 않습니다.' -ForegroundColor DarkGray

$notionToken = Show-NotionTokenDialog

try {
    $headers = @{
        Authorization    = "Bearer $notionToken"
        'Notion-Version' = '2022-06-28'
    }
    Write-Host '"성과" 페이지 접근을 테스트하는 중...' -ForegroundColor DarkGray
    Invoke-RestMethod -Uri "https://api.notion.com/v1/pages/$PageId" -Headers $headers -Method Get | Out-Null

    $config = [PSCustomObject]@{
        encryptedToken = Protect-Secret -PlainText $notionToken
        pageId         = $PageId
        connectedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    $config | ConvertTo-Json -Depth 5 | Set-Content -Path $NotionConfigPath -Encoding UTF8

    Write-Host ''
    Write-Host '=== 연동 완료 ===' -ForegroundColor Green
    Write-Host '노션 "성과" 페이지 연결에 성공했습니다.'
    Write-Host '이제부터 collect-instagram-insights.ps1 을 실행할 때마다 자동으로 노션에도 반영됩니다.'
} catch {
    $status = $null
    try { $status = [int]$_.Exception.Response.StatusCode } catch { }
    if ($status -eq 404 -or $status -eq 403) {
        Write-Host ''
        Write-Warning '페이지에 접근할 수 없습니다. 노션에서 "성과" 페이지 우측 상단 "..." 메뉴 -> "연결 추가"에서 방금 만든 통합을 추가했는지 다시 확인해 주세요.'
    } else {
        Write-Warning "연동 테스트 실패: $($_.Exception.Message)"
    }
} finally {
    $notionToken = $null
    [System.GC]::Collect()
}
