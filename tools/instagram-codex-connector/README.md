# Instagram Codex Connector (Windows)

Windows PC에서 개인 Instagram 계정을 graph.instagram.com(Instagram API with Instagram
Login)에 연결하고, 프로필/최근 게시물 인사이트를 주기적으로 수집하기 위한 PowerShell
스크립트 모음입니다.

> **중요**: 이 스크립트들은 반드시 **Windows PC**에서 직접 실행해야 합니다. DPAPI 암호화와
> Windows Forms 입력창은 Windows 전용 기능이라 macOS/Linux나 원격 서버에서는 동작하지
> 않습니다. (이 저장소를 관리하는 Claude Code 세션은 클라우드의 Linux 컨테이너에서
> 실행되고 있어, 스크립트 자체는 여기서 작성했지만 실제 실행·계정 연결 테스트는 여러분의
> Windows PC에서 직접 해주셔야 합니다.)

## 사전 준비물

- Windows 10/11, PowerShell 5.1 이상 (Windows PowerShell 또는 PowerShell 7+)
- 이미 발급받은 **Instagram 액세스 토큰**과 **Instagram 앱 시크릿**
  (Meta 개발자 콘솔에서 발급한 값. 채팅이나 코드, 커밋에 절대 입력하지 마세요.)
- 해당 Instagram 계정에 `instagram_business_basic`, `instagram_business_manage_insights`
  권한(스코프)이 부여되어 있어야 함

## 1. 최초 설정: `setup-instagram-insights.ps1`

```powershell
cd <이 폴더 경로>
./setup-instagram-insights.ps1
```

실행하면:

1. Windows 로컬 GUI 창이 열리고, 액세스 토큰 / 앱 시크릿을 입력하는 마스킹된 입력란이
   표시됩니다. (콘솔에 입력하지 않으므로 터미널 로그·히스토리에 남지 않습니다.)
2. 입력한 토큰을 `graph.instagram.com/access_token` (`ig_exchange_token`)으로 교환해
   60일짜리 장기 액세스 토큰을 발급받습니다.
3. `graph.instagram.com/me` 를 실제로 호출해 계정 연결을 검증합니다.
4. 계정 레벨 `insights` 호출이 성공하는지로 `instagram_business_manage_insights` 권한을,
   `me` 호출 성공 여부로 `instagram_business_basic` 권한을 실제로 확인합니다.
5. 연결에 성공한 경우에만, 토큰과 앱 시크릿을 **DPAPI(CurrentUser)로 암호화**하여
   `%LOCALAPPDATA%\InstagramCodexConnector\config.json` 에 저장합니다. 이 값은 **같은
   Windows 사용자 계정으로 같은 PC에 로그인했을 때만 복호화**할 수 있습니다.
6. 콘솔에는 **계정명 / 연결 성공 여부 / 토큰 만료일**만 출력됩니다. 토큰과 앱 시크릿
   원문은 어떤 경우에도 화면·로그에 출력되지 않습니다.

매일 자동으로 인사이트를 수집하고 만료 10일 전 토큰을 자동 갱신하는 Windows 예약 작업을
같이 등록하려면:

```powershell
./setup-instagram-insights.ps1 -RegisterDailyTask -DailyTaskTime "09:00"
```

## 2. 인사이트 수집: `collect-instagram-insights.ps1`

```powershell
./collect-instagram-insights.ps1
```

실행할 때마다:

1. `config.json`을 읽어 DPAPI로 복호화합니다.
2. 토큰 만료가 **10일 이내**(또는 만료일을 알 수 없는 경우)면
   `graph.instagram.com/refresh_access_token` (`ig_refresh_token`)으로 **자동 갱신**하고,
   갱신된 토큰을 다시 DPAPI로 암호화해 `config.json`에 저장합니다.
3. 프로필과 최근 게시물 5개(`/me/media`)를 조회합니다.
4. 게시물별로 `/{media-id}/insights` 를 호출해 **조회(views) · 도달(reach) · 저장(saved)
   · 공유(shares)** 값을 수집합니다. (게시물 유형에 따라 일부 지표가 지원되지 않으면
   `N/A`로 표시됩니다.)
5. 결과를 아래 위치에 JSON + Markdown으로 저장합니다.
   - `%LOCALAPPDATA%\InstagramCodexConnector\reports\insights-<timestamp>.json`
   - `%LOCALAPPDATA%\InstagramCodexConnector\reports\insights-<timestamp>.md`

   `%LOCALAPPDATA%`는 OneDrive 폴더 백업(Known Folder Move) 대상이 아닌, 이 PC에만
   남는 로컬 전용 폴더입니다. Documents/Desktop/Pictures처럼 자동으로 클라우드에
   동기화되지 않습니다.
6. 콘솔에는 **계정명 / 연결 성공 여부 / 토큰 만료일 / 리포트 파일 경로**만 출력됩니다.

## 보안 설계

- 토큰·앱 시크릿은 **Windows Forms 로컬 GUI 입력창**으로만 입력받습니다. 채팅, 커맨드라인
  인자, 환경변수 등으로 요구하지 않습니다.
- 저장 시 항상 **DPAPI(CurrentUser 범위)** 로 암호화하며, 평문은 파일에 절대 기록하지
  않습니다. 복호화는 동일 Windows 사용자 계정 + 동일 PC에서만 가능합니다.
- 설정 파일에는 추가로 `icacls`를 이용해 현재 사용자만 읽기/쓰기 가능하도록
  ACL을 제한합니다(best-effort).
- 모든 콘솔 출력·경고·오류 메시지는 토큰/시크릿 원문을 포함하지 않도록 작성되어 있습니다.
- 고정된 사용자명이나 `C:\Users\<이름>` 형태의 절대경로를 사용하지 않고, 항상
  `$env:LOCALAPPDATA`만 사용하므로 다른 Windows PC/계정에서도 그대로 동작합니다.
- 설정 파일(`config.json`)과 인사이트 리포트(JSON/Markdown) 모두 `%LOCALAPPDATA%` 하위에
  저장됩니다. Documents가 OneDrive로 자동 백업되도록 설정된 PC라도, 토큰이 포함되지 않은
  리포트조차 클라우드로 올라가지 않고 **이 컴퓨터에만** 남습니다.

## 참고: 사용한 API 엔드포인트

- 장기 토큰 교환: `GET https://graph.instagram.com/access_token?grant_type=ig_exchange_token&client_secret=...&access_token=...`
- 장기 토큰 갱신: `GET https://graph.instagram.com/refresh_access_token?grant_type=ig_refresh_token&access_token=...`
- 프로필 조회: `GET https://graph.instagram.com/me?fields=id,username,account_type,media_count`
- 최근 게시물: `GET https://graph.instagram.com/me/media?fields=id,caption,media_type,media_product_type,permalink,timestamp`
- 게시물 인사이트: `GET https://graph.instagram.com/{media-id}/insights?metric=views,reach,saved,shares`

## 알려진 제약

- Meta는 2025년부터 일부 인사이트 지표(`impressions`, 비-Reels `video_views` 등)를
  단계적으로 폐지하고 있습니다. 게시물 유형에 따라 `views` 지표가 지원되지 않으면 해당
  값은 리포트에 `N/A`로 표시됩니다.
- `instagram_business_basic`/`instagram_business_manage_insights` 권한 확인은 별도의
  "권한 조회" 엔드포인트가 아니라, 실제로 해당 권한이 필요한 API를 호출해 성공 여부로
  판단합니다(가장 신뢰할 수 있는 실제 검증 방식입니다).
