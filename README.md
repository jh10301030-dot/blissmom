# blissmom — Instagram 성과 분석 대시보드

인스타그램 팔로워/콘텐츠 성과를 자동으로 수집·분석하고, 매일/매주 리포트를 만들어주는 대시보드입니다.

## 제공 기능

- **매일 08:00 브리프**: 팔로워 수(전일 대비 증감)와 최근 콘텐츠 성과 요약을 자동 생성
- **최근 게시물 5개 비교**: 조회·도달·저장·공유 수를 표로 비교
- **이번 주 TOP 3 콘텐츠**: 저장·공유에 가중치를 둔 종합 점수로 선정
- **저장률 높은 콘텐츠 공통점 분석**: 공통 해시태그, 콘텐츠 유형, 캡션 길이, 게시 시간대
- **조회수 급상승 알림**: 전일 대비 조회수가 설정한 임계값(기본 +50%) 이상 오른 게시물 감지
- **매주 월요일 09:00 주간 보고서**: 지난 7일 발행 수, 팔로워 증가, TOP 3, 저장률 인사이트, 다음 주 추천 주제
- **팔로워 증가 & 콘텐츠 발행 그래프**: 날짜별 팔로워 추이와 게시물 발행 기록을 함께 시각화
- **다음 콘텐츠 주제 추천 3개**: 최근 성과 상위 콘텐츠의 해시태그/유형을 기반으로 추천

## 실행 방법

```bash
npm install
npm start
```

기본적으로 `http://localhost:3000` 에서 대시보드가 열립니다.

### 실제 Instagram 데이터 연동

`.env.example`을 `.env`로 복사한 뒤 Instagram Graph API 자격 증명을 입력하세요.

```bash
cp .env.example .env
```

- `IG_ACCESS_TOKEN`: Instagram 비즈니스/크리에이터 계정에 연결된 Facebook 앱의 장기 액세스 토큰
- `IG_BUSINESS_ACCOUNT_ID`: Instagram 비즈니스 계정 ID

두 값이 비어 있으면 앱은 **데모 모드**로 실행되어, 실제 API 없이도 모든 기능을 테스트할 수 있는 샘플 데이터를 생성합니다.

### 예약 작업 (cron)

서버 실행 중에는 다음 작업이 `TIMEZONE`(기본 `Asia/Seoul`) 기준으로 자동 실행됩니다.

| 주기 | 작업 |
| --- | --- |
| 매시 정각 | 팔로워/게시물 성과 스냅샷 수집 |
| 매일 08:00 | 일일 브리프 생성 |
| 매주 월요일 09:00 | 주간 성과 보고서 생성 |

수동으로 즉시 실행하려면 대시보드의 "지금 데이터 새로고침" / "다시 생성" 버튼을 사용하거나, 아래 API를 직접 호출하세요.

## API

| Method | Path | 설명 |
| --- | --- | --- |
| GET | `/api/status` | 데모 모드 여부, 타임존, 급상승 임계값 |
| POST | `/api/collect` | 팔로워/게시물 스냅샷 즉시 수집 |
| GET | `/api/posts/recent?limit=5` | 최근 게시물 성과 비교 |
| GET | `/api/posts/top?limit=3` | 이번 주 TOP N 콘텐츠 |
| GET | `/api/analysis/save-rate` | 저장률 높은 콘텐츠 공통점 |
| GET | `/api/analysis/spikes` | 조회수 급상승 콘텐츠 |
| GET | `/api/analysis/timeline` | 팔로워/발행 기록 시계열 |
| GET | `/api/analysis/recommendations?limit=3` | 다음 콘텐츠 주제 추천 |
| GET/POST | `/api/reports/daily/latest`, `/api/reports/daily/generate` | 일일 브리프 조회/생성 |
| GET/POST | `/api/reports/weekly/latest`, `/api/reports/weekly/generate` | 주간 보고서 조회/생성 |

## 데이터 저장

수집된 팔로워/게시물 성과 이력은 `data/blissmom.sqlite`(SQLite)에 누적 저장되며, day-over-day 비교와 주간/월간 추이 분석에 사용됩니다.
