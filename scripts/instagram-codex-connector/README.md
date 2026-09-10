# Instagram Codex Connector (Windows)

Windows PC에서 Instagram Graph API(Instagram Login) 연결을 설정하고,
프로필/최근 콘텐츠 인사이트를 주기적으로 수집하기 위한 PowerShell 스크립트입니다.

> **중요**: 이 스크립트는 Windows Forms(GUI 입력창)와 DPAPI(사용자별 암호화)를 사용하므로
> **Windows PC에서 직접 실행**해야 합니다. 이 저장소를 다운로드/클론한 뒤 로컬에서 실행하세요.

## 구성 파일

| 파일 | 역할 |
|---|---|
| `setup-instagram-insights.ps1` | 최초 1회(또는 토큰 재발급 시) 실행. 보안 입력창으로 토큰/앱 시크릿을 받아 연결·검증 후 암호화 저장 |
| `collect-instagram-insights.ps1` | 팔로워 수(전날 대비 증감 포함) + 최근 콘텐츠 5개의 조회/도달/저장/공유 데이터를 "아침 브리프" 형태의 JSON/Markdown으로 저장. 만료 10일 이내면 토큰을 자동 갱신 |
| `register-daily-brief.ps1` | `collect-instagram-insights.ps1`을 매일 오전 8시(기본값)에 자동 실행하도록 Windows 작업 스케줄러에 등록 (토큰/시크릿을 다루지 않는 별도 스크립트) |
| `make-desktop-shortcut.ps1` | 바탕화면에 최신 대시보드를 여는 바로가기 아이콘 생성 |
| `setup-notion-sync.ps1` | 노션 통합 토큰을 입력받아 "블리스맘 오피스 > 성과" 페이지 연동을 설정 |
| `sync-to-notion.ps1` | `collect-instagram-insights.ps1` 실행 시 자동 호출되어 노션 페이지의 요약/일별 표를 갱신 (노션 연동 미설정 시 조용히 건너뜀) |
| `1_연결설정.bat` / `2_인사이트수집.bat` / `3_아침브리프_자동등록.bat` / `4_결과보기.bat` / `5_바탕화면_바로가기_만들기.bat` / `6_노션연동설정.bat` | 위 스크립트들을 더블클릭만으로 실행하기 위한 실행기 |

## 노션(Notion) 자동 동기화 설정

1. https://www.notion.so/my-integrations 에서 "New integration" 클릭 → 이름 지정 후 생성
2. 생성된 통합의 "Internal Integration Secret" 복사 (`ntn_`으로 시작)
3. 노션에서 "블리스맘 오피스 > 성과" 페이지를 열고, 우측 상단 `...` → "연결 추가"에서
   방금 만든 통합을 추가 (이 단계가 없으면 API가 403/404로 접근을 거부합니다)
4. `6_노션연동설정.bat` 실행 → 위에서 복사한 시크릿 입력

이후 `2_인사이트수집.bat`(또는 매일 자동 브리프)을 실행할 때마다 노션 페이지의
상단 요약과 일별 로그 표가 자동으로 최신 상태로 갱신됩니다.

`collect-instagram-insights.ps1`을 실행할 때마다 `reports\dashboard.html` 이 생성/갱신됩니다.
팔로워 성장 그래프, 월별 순증, 최근 콘텐츠 카드, 일별 로그 표가 있는 시각적 대시보드로,
더블클릭하면 기본 브라우저로 바로 열립니다 (`4_결과보기.bat` 또는 바탕화면 바로가기 사용).

## 사용 방법

```powershell
# 1) 최초 연결 설정 (GUI 입력창이 열립니다)
.\setup-instagram-insights.ps1

# 2) 인사이트 수집 (필요할 때마다 수동 실행)
.\collect-instagram-insights.ps1

# 3) (선택) 매일 오전 8시에 2번을 자동 실행하도록 등록
#        -> 만료 10일 전 자동 갱신도 매일 같이 확인됩니다.
.\register-daily-brief.ps1
```

PowerShell 실행 정책 때문에 스크립트가 차단되면, 관리자 권한 없이도 아래처럼 실행할 수 있습니다.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup-instagram-insights.ps1
```

## 보안 설계

- 토큰/앱 시크릿은 **명령줄 인자나 채팅으로 입력받지 않고**, Windows Forms로 만든 로컬 입력창
  (비밀번호 마스킹 처리)에서만 입력받습니다.
- 입력된 값은 `ConvertTo-SecureString` / `ConvertFrom-SecureString` (Windows DPAPI, CurrentUser 범위)로
  암호화되어 `$env:LOCALAPPDATA\InstagramCodexConnector\config.json` 에 저장됩니다.
  **다른 Windows 계정이나 다른 PC로 파일을 복사해도 복호화할 수 없습니다.**
- 모든 경로는 `$env:USERPROFILE`, `$env:LOCALAPPDATA` 기반으로 구성되어 사용자 이름이나
  PC마다 다른 절대 경로를 하드코딩하지 않습니다.
- API 오류 메시지에 토큰이 섞여 있을 경우를 대비해 `Redact-Secret` 함수로 `access_token=`,
  `client_secret=` 값을 항상 마스킹한 뒤에만 출력/저장합니다.
- 콘솔 출력과 저장되는 리포트에는 **계정명, 연결 성공 여부, 권한 확인 결과, 토큰 만료일**만
  표시되며 토큰/시크릿 원문은 어디에도 출력되지 않습니다.

## API 흐름

1. `GET https://graph.instagram.com/access_token?grant_type=ig_exchange_token&client_secret=...&access_token=...`
   → 단기 토큰을 장기(약 60일) 토큰으로 교환
2. `GET https://graph.instagram.com/me?fields=id,username,account_type&access_token=...`
   → 연결 테스트 + `instagram_business_basic` 권한 확인
3. `GET https://graph.instagram.com/me/media` 로 얻은 미디어 1건에 대해
   `GET https://graph.instagram.com/{media-id}/insights?metric=reach&access_token=...`
   → `instagram_business_manage_insights` 권한 확인
4. (수집 시) `GET https://graph.instagram.com/me/media?fields=...&limit=5` 로 최근 콘텐츠 5개 조회 후
   각 콘텐츠에 대해 `GET https://graph.instagram.com/{media-id}/insights?metric=views,reach,saved,shares`
5. 만료 10일 이내면 `GET https://graph.instagram.com/refresh_access_token?grant_type=ig_refresh_token&access_token=...`
   로 자동 갱신 후 설정 파일을 다시 암호화 저장

## 결과 파일

`collect-instagram-insights.ps1` 실행 시 아래 위치에 저장됩니다.

```
%LOCALAPPDATA%\InstagramCodexConnector\reports\instagram-insights-<타임스탬프>.json
%LOCALAPPDATA%\InstagramCodexConnector\reports\instagram-insights-<타임스탬프>.md
%LOCALAPPDATA%\InstagramCodexConnector\reports\latest.json   (최신본 덮어쓰기)
%LOCALAPPDATA%\InstagramCodexConnector\reports\latest.md     (최신본 덮어쓰기)
%LOCALAPPDATA%\InstagramCodexConnector\reports\dashboard.html (시각적 대시보드, 매번 갱신)
%LOCALAPPDATA%\InstagramCodexConnector\reports\history.json  (일자별 팔로워/성과 누적 기록)
```

## 알려진 제약

- 미디어 유형(이미지/동영상/릴스/캐러셀)에 따라 `views`/`shares` 등 일부 지표가 지원되지 않을 수
  있으며, 이 경우 해당 값은 리포트에 `N/A`로 표시됩니다.
- `instagram_business_manage_insights` 권한 확인은 계정에 게시물이 최소 1개 있을 때
  실제 API 호출로 검증됩니다. 게시물이 없으면 토큰 발급 시 승인된 스코프를 신뢰하고
  "직접 검증 못함"으로 기록합니다.
