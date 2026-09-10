# blissmom

## Instagram 팔로워 일일 리포트

매일 아침 8시(KST)에 Instagram 계정의 팔로워 추이(전일 대비)와 최근 24시간 반응(좋아요/댓글, 인기 게시물 댓글 요약)을 Discord 채널로 전송합니다.

### 동작 방식

- `scripts/daily_follower_report.py`가 Instagram Graph API로 현재 팔로워 수와 최근 게시물 반응을 조회합니다.
- `data/follower_history.json`에 날짜별 팔로워 수 스냅샷을 저장해 전일 대비 증감을 계산합니다.
- 결과를 Discord Webhook으로 전송합니다.
- Claude Code Routine이 매일 08:00 KST에 이 스크립트를 실행합니다.

### 필요한 환경 변수

`.env.example` 참고:

| 변수명 | 설명 |
| --- | --- |
| `IG_ACCESS_TOKEN` | Instagram Graph API 액세스 토큰 (instagram_basic, instagram_manage_insights, instagram_manage_comments 권한 필요) |
| `IG_USER_ID` | Instagram Business/Creator 계정 숫자 ID |
| `DISCORD_WEBHOOK_URL` | 리포트를 게시할 Discord 채널의 Incoming Webhook URL |
| `GRAPH_API_VERSION` (선택) | 기본값 `v21.0` |

이 값들은 Claude Code 환경(Environment) 설정의 환경 변수로 등록해야 Routine 실행 시 스크립트가 읽을 수 있습니다.

### 수동 실행

```bash
IG_ACCESS_TOKEN=... IG_USER_ID=... DISCORD_WEBHOOK_URL=... python3 scripts/daily_follower_report.py
```
