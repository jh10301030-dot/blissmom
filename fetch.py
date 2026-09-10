"""인스타그램 Graph API에서 지표를 받아 로컬 CSV/JSON에 누적 저장한다.

몇 번을 다시 실행해도 안전(멱등)하도록 설계했다:
- 팔로워 수는 "오늘의 공식 기록"이 이미 있으면 다시 쓰지 않는다.
- 계정 일별 지표(reach 등)는 날짜별로 병합만 하고 기존 행을 지우지 않는다.
- 게시물 인사이트는 캐시에 있으면(그리고 3주 이내 게시물이 아니면) 다시 부르지 않는다.
- 썸네일은 이미 파일이 있으면 다시 받지 않는다.

단독 실행: python fetch.py
"""
from __future__ import annotations

import sys
import time
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Optional

import requests

from common import (
    ApiError,
    api_get,
    api_get_full_url,
    data_dir,
    download_file,
    load_config,
    load_json,
    log,
    read_csv_rows,
    save_config,
    save_json_atomic,
    thumbs_dir,
    upsert_csv_rows,
)

FOLLOWERS_CSV = "daily_followers.csv"
FOLLOWERS_FIELDS = ["date", "followers_count", "media_count", "recorded_at", "source"]

ACCOUNT_METRICS_CSV = "daily_account_metrics.csv"
ACCOUNT_METRICS_FIELDS = [
    "date",
    "reach",
    "profile_views",
    "website_clicks",
    "accounts_engaged",
    "views",
    "total_interactions",
    "updated_at",
]

MEDIA_JSON = "media.json"
MEDIA_INSIGHTS_CACHE_JSON = "media_insights_cache.json"
LATEST_REFERENCE_JSON = "latest_reference.json"
FETCH_RESULT_JSON = "fetch_result.json"

TOTAL_VALUE_METRICS = [
    "profile_views",
    "website_clicks",
    "accounts_engaged",
    "views",
    "total_interactions",
]

# 게시물 인사이트: 지원 안 되는 지표가 섞이면 전체가 에러나므로, 넓은 세트부터
# 좁은 세트로 낮춰가며 재시도한다.
MEDIA_INSIGHT_TIERS = [
    ["views", "reach", "saved", "shares", "total_interactions"],
    ["reach", "saved", "total_interactions"],
    ["reach", "saved"],
    ["reach"],
]

MAX_ACCOUNT_METRIC_BACKFILL_DAYS = 30


def make_session() -> requests.Session:
    s = requests.Session()
    s.headers.update({"User-Agent": "blissmom-insta-dashboard/1.0"})
    return s


def ensure_ig_user_id(cfg: dict, session: requests.Session) -> str:
    ig_id = cfg.get("ig_user_id") or ""
    if ig_id:
        return ig_id
    log("ig_user_id 가 설정되지 않아 자동으로 찾는 중...")
    data = api_get(
        session,
        "me/accounts",
        {
            "fields": "instagram_business_account{id,username}",
            "access_token": cfg["access_token"],
        },
        cfg["api_version"],
    )
    for page in data.get("data", []):
        iba = page.get("instagram_business_account")
        if iba and iba.get("id"):
            ig_id = iba["id"]
            log(f"인스타그램 비즈니스 계정 발견: {iba.get('username')} ({ig_id})")
            cfg["ig_user_id"] = ig_id
            save_config(cfg)
            return ig_id
    raise ApiError(
        "연결된 인스타그램 비즈니스/크리에이터 계정을 찾지 못했습니다. "
        "페이스북 페이지와 인스타그램 계정이 연결되어 있는지 확인해주세요."
    )


def record_today_followers(cfg: dict, session: requests.Session, ig_id: str) -> dict:
    path = data_dir() / FOLLOWERS_CSV
    rows = read_csv_rows(path)
    today_str = date.today().isoformat()
    already_official = any(r["date"] == today_str for r in rows)

    info = api_get(
        session,
        f"{ig_id}",
        {"fields": "followers_count,media_count", "access_token": cfg["access_token"]},
        cfg["api_version"],
    )
    followers_count = info.get("followers_count")
    media_count = info.get("media_count")
    now_iso = datetime.now().isoformat(timespec="seconds")

    result = {
        "followers_count": followers_count,
        "media_count": media_count,
        "as_of": now_iso,
        "written_as_official_today": False,
    }

    if already_official:
        log(f"오늘({today_str}) 팔로워 수는 이미 공식 기록됨 - CSV는 덮어쓰지 않음")
    else:
        hour_now = datetime.now().hour
        if hour_now >= int(cfg.get("daily_record_hour", 9)):
            new_row = {
                today_str: {
                    "date": today_str,
                    "followers_count": followers_count,
                    "media_count": media_count,
                    "recorded_at": now_iso,
                    "source": "official",
                }
            }
            upsert_csv_rows(path, FOLLOWERS_FIELDS, "date", new_row)
            result["written_as_official_today"] = True
            log(f"오늘({today_str}) 팔로워 {followers_count}명 공식 기록 완료")
        else:
            log(
                f"아직 하루 기준 시각({cfg.get('daily_record_hour')}시) 전이라 "
                f"오늘 공식 기록은 건너뜀 (참고용 값만 저장)"
            )

    # 실시간 참고용 값 (기록에는 반영하지 않음, 화면에는 "참고용" 표시)
    save_json_atomic(
        data_dir() / LATEST_REFERENCE_JSON,
        {
            "followers_count": followers_count,
            "media_count": media_count,
            "as_of": now_iso,
            "note": "참고용, 기록 미반영",
        },
    )
    return result


def _parse_end_time_to_date(end_time: str) -> str:
    # end_time 예: "2024-01-02T08:00:00+0000" -> 그 값이 대표하는 날짜는 end_time 전날
    try:
        dt = datetime.strptime(end_time, "%Y-%m-%dT%H:%M:%S%z")
        d = (dt - timedelta(seconds=1)).date()
        return d.isoformat()
    except ValueError:
        return end_time[:10]


def update_reach_series(cfg: dict, session: requests.Session, ig_id: str) -> int:
    path = data_dir() / ACCOUNT_METRICS_CSV
    existing = {r["date"]: r for r in read_csv_rows(path)}

    until_d = date.today()
    since_d = until_d - timedelta(days=MAX_ACCOUNT_METRIC_BACKFILL_DAYS - 1)

    since_ts = int(datetime.combine(since_d, datetime.min.time(), tzinfo=timezone.utc).timestamp())
    until_ts = int(
        (datetime.combine(until_d, datetime.min.time(), tzinfo=timezone.utc) + timedelta(days=1)).timestamp()
    )

    try:
        data = api_get(
            session,
            f"{ig_id}/insights",
            {
                "metric": "reach",
                "period": "day",
                "since": since_ts,
                "until": until_ts,
                "access_token": cfg["access_token"],
            },
            cfg["api_version"],
        )
    except ApiError as e:
        log(f"reach 지표 조회 실패: {e}")
        return 0

    updates = {}
    for series in data.get("data", []):
        if series.get("name") != "reach":
            continue
        for v in series.get("values", []):
            d_str = _parse_end_time_to_date(v.get("end_time", ""))
            updates.setdefault(d_str, {"date": d_str, "reach": v.get("value")})

    now_iso = datetime.now().isoformat(timespec="seconds")
    for d_str, fields in updates.items():
        fields["updated_at"] = now_iso

    upsert_csv_rows(path, ACCOUNT_METRICS_FIELDS, "date", updates)
    log(f"일별 reach {len(updates)}일치 갱신")
    return len(updates)


def update_total_value_metrics(cfg: dict, session: requests.Session, ig_id: str) -> int:
    """profile_views/website_clicks/accounts_engaged/views/total_interactions.

    metric_type=total_value 는 하루 단위로만 받을 수 있어 날짜마다 1콜씩 호출한다.
    이미 5개 필드가 모두 채워진 날짜는 건너뛴다(불필요한 API 호출 방지).
    """
    path = data_dir() / ACCOUNT_METRICS_CSV
    existing = {r["date"]: r for r in read_csv_rows(path)}

    today = date.today()
    updates = {}
    days_called = 0
    for offset in range(MAX_ACCOUNT_METRIC_BACKFILL_DAYS):
        d = today - timedelta(days=offset)
        d_str = d.isoformat()
        row = existing.get(d_str, {})
        already_complete = all(row.get(m) not in (None, "") for m in TOTAL_VALUE_METRICS)
        if already_complete:
            continue

        since_ts = int(datetime.combine(d, datetime.min.time(), tzinfo=timezone.utc).timestamp())
        until_ts = int(
            (datetime.combine(d, datetime.min.time(), tzinfo=timezone.utc) + timedelta(days=1)).timestamp()
        )
        try:
            data = api_get(
                session,
                f"{ig_id}/insights",
                {
                    "metric": ",".join(TOTAL_VALUE_METRICS),
                    "metric_type": "total_value",
                    "period": "day",
                    "since": since_ts,
                    "until": until_ts,
                    "access_token": cfg["access_token"],
                },
                cfg["api_version"],
            )
            days_called += 1
        except ApiError as e:
            log(f"{d_str} total_value 지표 조회 실패: {e}")
            continue

        fields = {"date": d_str}
        for series in data.get("data", []):
            name = series.get("name")
            tv = series.get("total_value", {})
            if name in TOTAL_VALUE_METRICS:
                fields[name] = tv.get("value")
        fields["updated_at"] = datetime.now().isoformat(timespec="seconds")
        updates[d_str] = fields

    if updates:
        upsert_csv_rows(path, ACCOUNT_METRICS_FIELDS, "date", updates)
    log(f"일별 total_value 지표: {days_called}일 API 호출, {len(updates)}일 갱신")
    return days_called


def fetch_media_list(cfg: dict, session: requests.Session, ig_id: str) -> dict:
    path = data_dir() / MEDIA_JSON
    store = load_json(path, {"media": {}, "last_updated": None})

    fields = (
        "id,caption,media_type,media_product_type,permalink,timestamp,"
        "like_count,comments_count,thumbnail_url,media_url"
    )
    limit = int(cfg.get("media_fetch_limit", 100))
    params = {"fields": fields, "limit": min(limit, 50), "access_token": cfg["access_token"]}

    fetched = 0
    try:
        data = api_get(session, f"{ig_id}/media", params, cfg["api_version"])
        while True:
            for m in data.get("data", []):
                mid = m["id"]
                prev = store["media"].get(mid, {})
                prev.update(m)
                store["media"][mid] = prev
                fetched += 1
            next_url = data.get("paging", {}).get("next")
            if next_url and fetched < limit:
                data = api_get_full_url(session, next_url)
            else:
                break
    except ApiError as e:
        log(f"게시물 목록 조회 실패: {e}")

    store["last_updated"] = datetime.now().isoformat(timespec="seconds")
    save_json_atomic(path, store)
    log(f"게시물 목록 {fetched}건 갱신 (누적 보관 {len(store['media'])}건)")
    return store


def update_recent_media_insights(
    cfg: dict, session: requests.Session, media_store: dict
) -> int:
    cache_path = data_dir() / MEDIA_INSIGHTS_CACHE_JSON
    cache = load_json(cache_path, {})

    recent_days = int(cfg.get("recent_days_for_media_insights", 21))
    cutoff = datetime.now(timezone.utc) - timedelta(days=recent_days)

    updated = 0
    for mid, m in media_store["media"].items():
        ts = m.get("timestamp")
        try:
            published = datetime.strptime(ts, "%Y-%m-%dT%H:%M:%S%z") if ts else None
        except ValueError:
            published = None

        is_recent = published is not None and published >= cutoff
        never_cached = mid not in cache

        if not (is_recent or never_cached):
            continue

        got = None
        used_metrics: list = []
        last_err = None
        for tier in MEDIA_INSIGHT_TIERS:
            try:
                data = api_get(
                    session,
                    f"{mid}/insights",
                    {"metric": ",".join(tier), "access_token": cfg["access_token"]},
                    cfg["api_version"],
                )
                got = data
                used_metrics = tier
                break
            except ApiError as e:
                last_err = e
                if e.status_code and e.status_code < 500:
                    continue
                break

        if got is None:
            log(f"게시물 {mid} 인사이트 조회 실패(모든 지표 세트 실패): {last_err}")
            continue

        metrics = {}
        for series in got.get("data", []):
            name = series.get("name")
            values = series.get("values", [])
            if values:
                metrics[name] = values[0].get("value")

        cache[mid] = {
            "fetched_at": datetime.now().isoformat(timespec="seconds"),
            "metrics_requested": used_metrics,
            "metrics": metrics,
            "published_at": ts,
        }
        updated += 1

    save_json_atomic(cache_path, cache)
    log(f"게시물 인사이트 {updated}건 갱신(최근 {recent_days}일 + 신규)")
    return updated


def download_missing_thumbnails(session: requests.Session, media_store: dict) -> int:
    tdir = thumbs_dir()
    downloaded = 0
    for mid, m in media_store["media"].items():
        dest = tdir / f"{mid}.jpg"
        if dest.exists():
            continue
        url = m.get("thumbnail_url") or m.get("media_url")
        if not url:
            continue
        if download_file(session, url, dest):
            downloaded += 1
    log(f"썸네일 {downloaded}건 신규 다운로드 (누적 {len(list(tdir.glob('*.jpg')))}건)")
    return downloaded


def run(cfg: Optional[dict] = None) -> dict:
    """launch.py 등 다른 모듈에서 in-process 로 호출하기 위한 진입점.

    표준출력을 파싱하지 않고 반환 dict / fetch_result.json 파일로 결과를 전달한다.
    """
    result = {
        "started_at": datetime.now().isoformat(timespec="seconds"),
        "ok": False,
        "errors": [],
    }
    try:
        cfg = cfg or load_config()
    except Exception as e:
        result["errors"].append(str(e))
        save_json_atomic(data_dir() / FETCH_RESULT_JSON, result)
        raise

    session = make_session()
    try:
        ig_id = ensure_ig_user_id(cfg, session)
        result["ig_user_id"] = ig_id

        followers_info = record_today_followers(cfg, session, ig_id)
        result["followers"] = followers_info

        update_reach_series(cfg, session, ig_id)
        update_total_value_metrics(cfg, session, ig_id)

        media_store = fetch_media_list(cfg, session, ig_id)
        result["media_count"] = len(media_store["media"])

        insights_updated = update_recent_media_insights(cfg, session, media_store)
        result["media_insights_updated"] = insights_updated

        thumbs_downloaded = download_missing_thumbnails(session, media_store)
        result["thumbs_downloaded"] = thumbs_downloaded
        result["thumbs_total"] = len(list(thumbs_dir().glob("*.jpg")))

        account_rows = read_csv_rows(data_dir() / ACCOUNT_METRICS_CSV)
        result["account_metric_days"] = len(account_rows)
        follower_rows = read_csv_rows(data_dir() / FOLLOWERS_CSV)
        result["follower_days"] = len(follower_rows)

        result["ok"] = True
    except Exception as e:
        result["errors"].append(str(e))
        log(f"fetch 실패: {e}")
    finally:
        result["finished_at"] = datetime.now().isoformat(timespec="seconds")
        save_json_atomic(data_dir() / FETCH_RESULT_JSON, result)

    return result


def main() -> int:
    result = run()
    if result["ok"]:
        log("fetch.py 완료")
        return 0
    else:
        log(f"fetch.py 오류와 함께 종료: {result['errors']}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
